# =====================================================================
# Mika Shop restore test, option A (Phase 1, step 13). Safe: touches NOTHING online.
# Restores a nightly dump into a THROWAWAY PostgreSQL on this PC (temp folder, port 55432),
# checks it, then stops it and deletes the folder (it is only a copy).
#
# Needs: PostgreSQL installed locally (scoop install postgresql), the backups repo cloned at
# Desktop\mika-shop-backups, and (for the comparison with TEST) the Supabase CLI linked to TEST.
#
# Run from the mika-shop folder:
#   powershell -ExecutionPolicy Bypass -File supabase\restore-test\restore_local.ps1
#   ... -Dump <path to a .dump>   (default: newest file in mika-shop-backups\backups)
#   ... -Keep                     (leave the copy running for a look; delete by hand afterwards)
#
# Checks: (1) the dump's table of contents, (2) row counts per table vs TEST right now,
# (3) functions / policies / triggers vs TEST, (4) data integrity (stock = last stock_log,
# order totals = items + fee), (5) every SQL test in supabase\tests run against the copy.
# Expected "not applicable" results: the photo-upload tests (Storage is not in database dumps)
# and the pg_cron schedule test (the cron job lives outside the public schema).
# =====================================================================
param([string]$Dump, [switch]$Keep)
$ErrorActionPreference = 'Continue'   # native tools write progress to stderr; failures are checked by hand
$repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
$port = 55432
$work = Join-Path $env:TEMP 'mika-restore'
$pgBin = Join-Path (scoop prefix postgresql) 'bin'
if (-not (Test-Path "$pgBin\pg_restore.exe")) { throw "PostgreSQL not found. Install it with: scoop install postgresql" }
$env:PGPASSWORD = ''
function PgExe($name) { Join-Path $pgBin "$name.exe" }
function Local-Sql([string]$sql, [string]$db = 'mika') {
  $f = Join-Path $work 'local.sql'
  [IO.File]::WriteAllText($f, $sql, (New-Object Text.UTF8Encoding $false))
  & (PgExe 'psql') -X -q -A -t -F '|' -h localhost -p $port -U postgres -d $db -v ON_ERROR_STOP=1 -f $f 2>&1
}
function Test-Sql([string]$sql) {
  $f = Join-Path $work 'q.sql'
  [IO.File]::WriteAllText($f, $sql, (New-Object Text.UTF8Encoding $false))
  Push-Location $repo
  try { $raw = (& supabase db query --linked -f $f -o json 2>$null) -join "`n" } finally { Pop-Location }
  @(($raw | ConvertFrom-Json).rows)
}
$fail = 0
function Report($name, $ok, $detail) {
  if (-not $ok) { $script:fail++ }
  "{0}  {1}{2}" -f ($(if ($ok) { 'PASS' } else { 'FAIL' })), $name, $(if ($detail) { "  -- $detail" } else { '' })
}

if (-not $Dump) {
  $Dump = (Get-ChildItem (Join-Path (Split-Path $repo -Parent) 'mika-shop-backups\backups\*.dump') | Sort-Object Name | Select-Object -Last 1).FullName
}
"Dump: $Dump"
if (Test-Path $work) { throw "$work already exists (an earlier copy still running?). Stop it with: pg_ctl -D `"$work\data`" stop  then delete the folder." }
New-Item -ItemType Directory $work | Out-Null

try {
  # ---------- 1. table of contents ----------
  $toc = & (PgExe 'pg_restore') --list $Dump
  $entries = @($toc | Where-Object { $_ -match '^\d+;' })
  $tables = @($entries | Where-Object { $_ -match '^\d+; \d+ \d+ TABLE public (\S+) ' } | ForEach-Object { ($_ -split ' ')[5] })
  $tableData = @($entries | Where-Object { $_ -match ' TABLE DATA public ' })
  $funcs = @($entries | Where-Object { $_ -match ' FUNCTION public ' })
  $policies = @($entries | Where-Object { $_ -match ' POLICY public ' })
  "Table of contents: $($entries.Count) entries, $($tables.Count) public tables, $($funcs.Count) public functions, $($policies.Count) policies"
  $shop = 'categories','customers','delivery_zones','order_items','orders','products','settings','staff','stock_log','variants'
  Report 'dump has all 10 shop tables + their data' (@($shop | Where-Object { $tables -notcontains $_ }).Count -eq 0 -and $tableData.Count -ge 10) (($shop | Where-Object { $tables -notcontains $_ }) -join ',')

  # ---------- 2. throwaway database ----------
  & (PgExe 'initdb') -D "$work\data" -U postgres -A trust -E UTF8 --no-locale 2>&1 | Out-Null
  # started through cmd with output to nul: the server process would otherwise keep PowerShell's pipe open forever
  cmd /c """$(PgExe 'pg_ctl')"" -D ""$work\data"" -o ""-p $port -c listen_addresses=localhost"" -l ""$work\pg.log"" -w start >nul 2>&1"
  if ($LASTEXITCODE) { throw "could not start the temporary database (see $work\pg.log)" }
  Local-Sql 'create database mika' 'postgres' | Out-Null
  Local-Sql ([IO.File]::ReadAllText((Join-Path $PSScriptRoot 'standins.sql'))) | Out-Null

  # restore: the whole public schema + auth.users (staff logins point at it), nothing else
  $list = Join-Path $work 'restore.list'
  $keepLines = $toc | Where-Object { $_ -match '^\d+;' -and ($_ -match ' public ' -or $_ -match ' auth users ') -and $_ -notmatch ' SCHEMA - public ' }
  [IO.File]::WriteAllLines($list, [string[]]$keepLines)
  $restoreOut = & (PgExe 'pg_restore') -h localhost -p $port -U postgres -d mika --no-owner -L $list $Dump 2>&1
  $restoreErrors = @($restoreOut | Where-Object { "$_" -match 'error:' -and "$_" -notmatch 'errors ignored' })
  "pg_restore: $($restoreErrors.Count) errors"
  $restoreErrors | Select-Object -First 15 | ForEach-Object { "   $_" }

  # ---------- 3. row counts: copy vs TEST now ----------
  $countSql = @"
select table_name as t, (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from public.%I', table_name), false, true, '')))[1]::text as n
from information_schema.tables where table_schema = 'public' and table_type = 'BASE TABLE'
union all select 'auth.users', (select count(*) from auth.users)::text
order by 1;
"@
  $local = @{}; Local-Sql $countSql | ForEach-Object { $p = "$_" -split '\|'; if ($p.Count -eq 2) { $local[$p[0]] = $p[1] } }
  $remote = @{}; Test-Sql $countSql | ForEach-Object { $remote[$_.t] = "$($_.n)" }
  "Row counts (copy / TEST now):"
  foreach ($k in ($remote.Keys | Sort-Object)) { "   {0,-16} {1,6} / {2,6}{3}" -f $k, $local[$k], $remote[$k], $(if ($local[$k] -ne $remote[$k]) { '   <- different' } else { '' }) }
  $diff = @($remote.Keys | Where-Object { $local[$_] -ne $remote[$_] })
  Report 'row counts equal TEST (differences = changes made after the dump)' ($diff.Count -eq 0) ($diff -join ', ')

  # ---------- 4. functions / policies / triggers ----------
  $objSql = @"
select 'functions' as k, count(*)::text as n from pg_proc where pronamespace = 'public'::regnamespace
union all select 'policies', count(*)::text from pg_policies where schemaname = 'public'
union all select 'triggers', count(*)::text from pg_trigger t join pg_class c on c.oid = t.tgrelid where c.relnamespace = 'public'::regnamespace and not t.tgisinternal
union all select 'rls tables', count(*)::text from pg_class where relnamespace = 'public'::regnamespace and relkind = 'r' and relrowsecurity
union all select 'grants to anon', count(*)::text from information_schema.role_table_grants where table_schema = 'public' and grantee = 'anon'
order by 1;
"@
  $lo = @{}; Local-Sql $objSql | ForEach-Object { $p = "$_" -split '\|'; if ($p.Count -eq 2) { $lo[$p[0]] = $p[1] } }
  $ro = @{}; Test-Sql $objSql | ForEach-Object { $ro[$_.k] = "$($_.n)" }
  foreach ($k in ($ro.Keys | Sort-Object)) { Report "$k came back ($($lo[$k]) / TEST $($ro[$k]))" ($lo[$k] -eq $ro[$k]) '' }

  # ---------- 5. data integrity ----------
  $badStock = Local-Sql @"
with last as (select distinct on (sku, variant_id) sku, variant_id, stock_after from public.stock_log where stock_after is not null order by sku, variant_id, id desc)
select count(*) from last l
left join public.products p on l.variant_id is null and p.sku = l.sku
left join public.variants v on l.variant_id is not null and v.id = l.variant_id
where coalesce(p.stock, v.stock) is distinct from l.stock_after;
"@
  Report 'stock = last stock_log entry for every logged item' ("$badStock".Trim() -eq '0') "$badStock mismatches"
  $badTotals = Local-Sql @"
select count(*) from public.orders o
where o.subtotal <> (select coalesce(sum(line_total), 0) from public.order_items i where i.order_id = o.id)
   or o.total <> o.subtotal + o.delivery_fee
   or not exists (select 1 from public.order_items i where i.order_id = o.id);
"@
  Report 'every order: items present, subtotal = items, total = subtotal + fee' ("$badTotals".Trim() -eq '0') "$badTotals mismatches"
  $lastOrder = Local-Sql "select order_no || ' ' || to_char(created_at at time zone 'UTC', 'YYYY-MM-DD HH24:MI') || ' UTC' from public.orders order by id desc limit 1"
  "Newest order in the copy: $lastOrder"

  # ---------- 6. the SQL tests, against the copy ----------
  $na = 'photo|cron job'
  $tot = 0; $pass = 0; $naCount = 0
  foreach ($f in Get-ChildItem (Join-Path $repo 'supabase\tests\*_test.sql')) {
    $out = & (PgExe 'psql') -X -q -A -t -F '|' -h localhost -p $port -U postgres -d mika -f $f.FullName 2>&1
    $rows = @($out | Where-Object { "$_" -match '^\d+\|.*\|[tf]$' } | ForEach-Object { $p = "$_" -split '\|'; [pscustomobject]@{ test = ($p[1..($p.Count - 4)] -join '|'); expected = $p[-3]; got = $p[-2]; pass = ($p[-1] -eq 't') } })
    $realFails = @($rows | Where-Object { -not $_.pass -and $_.test -notmatch $na })
    $naFails = @($rows | Where-Object { -not $_.pass -and $_.test -match $na })
    $tot += $rows.Count; $pass += @($rows | Where-Object { $_.pass }).Count; $naCount += $naFails.Count
    "   {0,-28} {1}/{2}{3}" -f $f.BaseName, @($rows | Where-Object { $_.pass }).Count, $rows.Count, $(if ($naFails.Count) { "  ($($naFails.Count) not applicable: Storage / pg_cron)" } else { '' })
    $realFails | ForEach-Object { "      FAIL $($_.test): expected [$($_.expected)] got [$($_.got)]" }
    if ($rows.Count -eq 0) { "      no results: $($out | Select-Object -Last 3)" }
    if ($realFails.Count -or $rows.Count -eq 0) { $script:fail++ }
  }
  Report "SQL tests on the copy: $pass/$tot pass, $naCount not applicable (photos / pg_cron are not in database dumps)" ($pass + $naCount -eq $tot) ''
  $calls = Local-Sql 'select count(*) from net.calls'
  "Alert calls caught by the stand-in (nothing sent anywhere): $calls"
}
finally {
  if ($Keep) {
    "Copy left running on port $port (folder $work). Stop + delete with:"
    "   & '$(PgExe 'pg_ctl')' -D '$work\data' stop; Remove-Item -Recurse -Force '$work'"
  } else {
    if (Test-Path "$work\data\postmaster.pid") { & (PgExe 'pg_ctl') -D "$work\data" -m fast -w stop 2>&1 | Out-Null }
    Remove-Item -Recurse -Force $work -ErrorAction SilentlyContinue
    "Temporary copy stopped and deleted."
  }
}
"`nRESULT: $(if ($fail) { "$fail check(s) FAILED" } else { 'restore test OK' })"
