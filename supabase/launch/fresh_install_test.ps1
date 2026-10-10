# =====================================================================
# Mika Shop launch rehearsal. Safe: touches NOTHING online (not TEST, not LIVE).
# Builds an EMPTY throwaway PostgreSQL on this PC (temp folder, port 55433), applies every
# migration in supabase\migrations in order (exactly what LIVE gets at launch), then checks:
#   1. every migration applies cleanly on an empty database
#   2. the result has the same tables / functions / rules as TEST (compared with the newest
#      nightly dump in Desktop\mika-shop-backups\backups)
#   3. every setting key and delivery area that TEST has also comes from the migrations
#      (nothing that was only typed by hand on TEST), and no test data is in it
#   4. every SQL test in supabase\tests passes on it (after loading the test products)
# Then it stops the database and deletes the folder.
#
# Needs: PostgreSQL installed locally (scoop install postgresql) and the backups repo cloned.
# Run from the mika-shop folder:
#   powershell -ExecutionPolicy Bypass -File supabase\launch\fresh_install_test.ps1
#   ... -Keep   (leave the database running for a look; the script prints how to delete it)
# Expected "not applicable" tests: photo uploads (Storage is only a stand-in here) and the
# pg_cron schedule test (pg_cron is a stand-in too).
# =====================================================================
param([string]$Dump, [switch]$Keep)
$ErrorActionPreference = 'Continue'
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$port = 55433
$work = Join-Path $env:TEMP 'mika-fresh'
$pgBin = Join-Path (scoop prefix postgresql) 'bin'
if (-not (Test-Path "$pgBin\psql.exe")) { throw "PostgreSQL not found. Install it with: scoop install postgresql" }
$env:PGPASSWORD = ''
function PgExe($name) { Join-Path $pgBin "$name.exe" }
function Write-Utf8($path, $text) { [IO.File]::WriteAllText($path, $text, (New-Object Text.UTF8Encoding $false)) }
function Local-Sql([string]$sql, [string]$db = 'mika') {
  $f = Join-Path $work 'local.sql'
  Write-Utf8 $f $sql
  & (PgExe 'psql') -X -q -A -t -F '|' -h localhost -p $port -U postgres -d $db -v ON_ERROR_STOP=1 -f $f 2>&1
}
$fail = 0; $emptyFiles = 0
function Report($name, $ok, $detail) {
  if (-not $ok) { $script:fail++ }
  "{0}  {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { "  -- $detail" } else { '' })
}

if (-not $Dump) {
  $Dump = (Get-ChildItem (Join-Path (Split-Path $repo -Parent) 'mika-shop-backups\backups\*.dump') | Sort-Object Name | Select-Object -Last 1).FullName
}
"TEST dump to compare with: $Dump"
if (Test-Path $work) { throw "$work already exists (an earlier run still running?). Stop it with: pg_ctl -D `"$work\data`" stop  then delete the folder." }
New-Item -ItemType Directory $work | Out-Null

try {
  # ---------- empty throwaway database + stand-ins ----------
  & (PgExe 'initdb') -D "$work\data" -U postgres -A trust -E UTF8 --no-locale 2>&1 | Out-Null
  cmd /c """$(PgExe 'pg_ctl')"" -D ""$work\data"" -o ""-p $port -c listen_addresses=localhost"" -l ""$work\pg.log"" -w start >nul 2>&1"
  if ($LASTEXITCODE) { throw "could not start the temporary database (see $work\pg.log)" }
  Local-Sql 'create database mika' 'postgres' | Out-Null
  $out = Local-Sql ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'fresh_standins.sql')))
  if ($LASTEXITCODE) { throw "stand-ins failed: $out" }

  # ---------- 1. every migration, in order, each in one transaction ----------
  $migs = @(Get-ChildItem (Join-Path $repo 'supabase\migrations\*.sql') | Sort-Object Name)
  $applied = 0; $migFail = $null
  foreach ($m in $migs) {
    # pg_cron / pg_net can't be installed locally: their stand-ins already exist, so only the
    # "create extension" lines are skipped. Everything else runs exactly as written.
    $sql = [IO.File]::ReadAllText($m.FullName) -replace '(?im)^[ \t]*create extension if not exists (pg_cron|pg_net)\b[^;]*;', '-- (stand-in) $0'
    $f = Join-Path $work 'mig.sql'
    Write-Utf8 $f $sql
    $o = & (PgExe 'psql') -X -q -h localhost -p $port -U postgres -d mika -v ON_ERROR_STOP=1 --single-transaction -f $f 2>&1
    if ($LASTEXITCODE) { $migFail = "$($m.Name): $(@($o | Where-Object { "$_" -match 'ERROR' }) -join ' ')"; break }
    $applied++
  }
  Report "all $($migs.Count) migrations apply to an empty database ($applied applied)" (-not $migFail) $migFail
  if ($migFail) { throw 'stopping: a migration failed' }

  # ---------- 2. same structure as TEST ----------
  # Left out of the comparison = things Supabase's servers add by themselves, not the migrations:
  #  * rls_auto_enable() (the project's "Enable automatic RLS" switch; ON for TEST and LIVE)
  #  * Supabase's own rights for service_role / postgres / supabase_admin
  #  * the public schema itself and its USAGE grants
  #  * realtime publication lines (pg_dump -n public on the fresh copy doesn't list them:
  #    checked separately below)
  # Role lists in rules are sorted ("authenticated, anon" = "anon, authenticated").
  $norm = {
    param($lines)
    $skip = $false
    foreach ($l in $lines) {
      if ($l -match '^CREATE FUNCTION public\.rls_auto_enable\(') { $skip = $true }
      if ($skip) { if ($l -eq '$$;') { $skip = $false }; continue }
      if ($l -match '^\s*--|^\s*$|^SET |^SELECT pg_catalog\.set_config|^\\(un)?restrict |supabase_admin' -or
          $l -match 'TO service_role;$|^ALTER DEFAULT PRIVILEGES FOR ROLE postgres|^CREATE SCHEMA public;|^COMMENT ON SCHEMA public|^GRANT USAGE ON SCHEMA public|^ALTER PUBLICATION supabase_realtime|rls_auto_enable') { continue }
      $l -replace ' TO authenticated, anon ', ' TO anon, authenticated '
    }
  }
  $testSchema = Join-Path $work 'test_schema.sql'
  & (PgExe 'pg_restore') --schema-only -n public --no-owner -f $testSchema $Dump 2>&1 | Out-Null
  $freshSchema = Join-Path $work 'fresh_schema.sql'
  & (PgExe 'pg_dump') -h localhost -p $port -U postgres -d mika --schema-only -n public --no-owner -f $freshSchema 2>&1 | Out-Null
  $a = & $norm (Get-Content $testSchema -Encoding UTF8)
  $b = & $norm (Get-Content $freshSchema -Encoding UTF8)
  $d = @(Compare-Object $a $b)
  $diffFile = Join-Path $env:TEMP 'mika-fresh-schema-diff.txt'
  if ($d.Count) {
    $d | ForEach-Object { "{0} {1}" -f $(if ($_.SideIndicator -eq '<=') { 'only TEST :' } else { 'only fresh:' }), $_.InputObject } | Set-Content $diffFile -Encoding UTF8
  }
  Report "structure (tables, columns, functions, rules, grants) = TEST ($($a.Count) lines compared)" ($d.Count -eq 0) $(if ($d.Count) { "$($d.Count) different lines, see $diffFile" })
  $testPub = @(Get-Content $testSchema -Encoding UTF8 | Where-Object { $_ -match '^ALTER PUBLICATION supabase_realtime ADD TABLE ONLY public\.(\S+);' } | ForEach-Object { $Matches[1] } | Sort-Object)
  $freshPub = @(Local-Sql "select tablename from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' order by 1" | ForEach-Object { "$_".Trim() } | Where-Object { $_ })
  Report "live updates (realtime) on the same tables as TEST: $($freshPub -join ', ')" (($testPub -join ',') -eq ($freshPub -join ',')) "TEST: $($testPub -join ', ')"

  # ---------- 3. seeded data: every TEST setting key + area comes from the migrations ----------
  $testData = Join-Path $work 'test_data.sql'
  & (PgExe 'pg_restore') --data-only -n public -t settings -t delivery_zones -f $testData $Dump 2>&1 | Out-Null
  $Local = { param($q) @(Local-Sql $q | ForEach-Object { "$_".Trim() } | Where-Object { $_ }) }
  $freshKeys = & $Local 'select key from public.settings order by 1'
  $txt = Get-Content $testData -Encoding UTF8
  $inSettings = $false; $inZones = $false; $testKeys = @(); $testAreas = @()
  foreach ($line in $txt) {
    if ($line -match '^COPY public\.settings ') { $inSettings = $true; $cols = ($line -replace '^COPY public\.settings \((.*)\) FROM stdin;$', '$1') -split ', '; continue }
    if ($line -match '^COPY public\.delivery_zones ') { $inZones = $true; $zcols = ($line -replace '^COPY public\.delivery_zones \((.*)\) FROM stdin;$', '$1') -split ', '; continue }
    if ($line -eq '\.') { $inSettings = $false; $inZones = $false; continue }
    if ($inSettings) { $testKeys += ($line -split "`t")[[array]::IndexOf($cols, 'key')] }
    if ($inZones) { $p = $line -split "`t"; $testAreas += "$($p[[array]::IndexOf($zcols, 'governorate')]) / $($p[[array]::IndexOf($zcols, 'district')])" }
  }
  $missingKeys = @($testKeys | Where-Object { $freshKeys -notcontains $_ })
  $extraKeys = @($freshKeys | Where-Object { $testKeys -notcontains $_ })
  Report "every setting key on TEST comes from the migrations ($($freshKeys.Count) keys)" ($missingKeys.Count -eq 0 -and $extraKeys.Count -eq 0) "only on TEST: $($missingKeys -join ', ')  only fresh: $($extraKeys -join ', ')"
  $freshAreas = & $Local "select governorate || ' / ' || district from public.delivery_zones order by 1"
  $handAreas = @($testAreas | Where-Object { $freshAreas -notcontains $_ })
  "     areas on TEST that are NOT in the migrations (test areas expected): $(if ($handAreas.Count) { $handAreas -join '; ' } else { 'none' })"
  Report "delivery areas from the migrations: $($freshAreas.Count), none of them a [TEST] area" (@($freshAreas | Where-Object { $_ -match '\[TEST\]' }).Count -eq 0) ''
  $counts = & $Local @"
select 'products ' || count(*) from public.products union all select 'categories ' || count(*) from public.categories
union all select 'orders ' || count(*) from public.orders union all select 'customers ' || count(*) from public.customers
union all select 'staff ' || count(*) from public.staff union all select 'filled settings ' || count(*) from public.settings where value <> ''
"@
  "     fresh database contents: $($counts -join ', ')"
  $filled = & $Local "select key || ' = ' || value from public.settings where value <> '' order by 1"
  "     settings that already have a value after the migrations: $(if ($filled.Count) { $filled -join '; ' } else { 'none' })"
  Report 'no test data in a fresh install (no products, orders, customers, staff)' (@($counts | Where-Object { $_ -match '^(products|categories|orders|customers|staff) [1-9]' }).Count -eq 0) ($counts -join ', ')
  $jobs = & $Local 'select jobname || '' '' || schedule from cron.job'
  Report 'the auto-cancel job gets scheduled' (($jobs -join ' ') -match 'cancel-unpaid-orders \*/15') ($jobs -join ', ')
  $rls = & $Local "select count(*) from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and not relrowsecurity"
  Report 'row security is ON for every table' ("$rls" -eq '0') "$rls table(s) without it"

  # ---------- 4. the SQL tests, after loading the test products ----------
  $o = Local-Sql ([IO.File]::ReadAllText((Join-Path $repo 'supabase\tests\test_data.sql')))
  if ($LASTEXITCODE) { "   test_data.sql: $($o | Select-Object -Last 3)" }
  $na = 'photo|cron job'
  $tot = 0; $pass = 0; $naCount = 0
  foreach ($f in Get-ChildItem (Join-Path $repo 'supabase\tests\*_test.sql')) {
    $out = & (PgExe 'psql') -X -q -A -t -F '|' -h localhost -p $port -U postgres -d mika -f $f.FullName 2>&1
    # result rows end with expected|got|t-or-f; some test files start each row with its number
    $rows = @($out | Where-Object { "$_" -match '^[^|]+\|.*\|.*\|[tf]$' -and "$_" -notmatch '^psql:' } | ForEach-Object {
      $p = "$_" -split '\|'; $first = $(if ($p[0] -match '^\d+$' -and $p.Count -ge 5) { 1 } else { 0 })
      [pscustomobject]@{ test = ($p[$first..($p.Count - 4)] -join '|'); expected = $p[-3]; got = $p[-2]; pass = ($p[-1] -eq 't') } })
    $realFails = @($rows | Where-Object { -not $_.pass -and $_.test -notmatch $na })
    $naFails = @($rows | Where-Object { -not $_.pass -and $_.test -match $na })
    $tot += $rows.Count; $pass += @($rows | Where-Object { $_.pass }).Count; $naCount += $naFails.Count
    "   {0,-28} {1}/{2}{3}" -f $f.BaseName, @($rows | Where-Object { $_.pass }).Count, $rows.Count, $(if ($naFails.Count) { "  ($($naFails.Count) not applicable)" } else { '' })
    $realFails | ForEach-Object { "      FAIL $($_.test): expected [$($_.expected)] got [$($_.got)]" }
    if ($rows.Count -eq 0) { "      no results: $(@($out | Where-Object { "$_" -match "ERROR" }) | Select-Object -First 1)"; $script:emptyFiles++ }
    if ($realFails.Count -or $rows.Count -eq 0) { $script:fail++ }
  }
  Report "SQL tests on the fresh install: $pass/$tot pass, $naCount not applicable (photos / pg_cron stand-ins)" ($pass + $naCount -eq $tot -and -not $script:emptyFiles) $(if ($script:emptyFiles) { "$($script:emptyFiles) test file(s) gave no results" })
}
finally {
  if ($Keep) {
    "Database left running on port $port (folder $work). Stop + delete with:"
    "   & '$(PgExe 'pg_ctl')' -D '$work\data' stop; Remove-Item -Recurse -Force '$work'"
  } else {
    if (Test-Path "$work\data\postmaster.pid") { & (PgExe 'pg_ctl') -D "$work\data" -m fast -w stop 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    "Temporary database stopped and deleted."
  }
}
"`nRESULT: $(if ($fail) { "$fail check(s) FAILED" } else { 'fresh install OK: the migrations alone build a working shop' })"
