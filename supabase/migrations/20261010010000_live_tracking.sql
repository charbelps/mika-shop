-- =====================================================================
-- Mika Shop: migration 33, live driver tracking (Phase 1c D3).
-- The customer sees our driver on a map on the track page, ONLY for the order he is driving to
-- right now, and only until he taps Delivered / Not delivered. One customer at a time.
--  * driver_live: ONE row per driver = the order he is heading to + his last position.
--    No history: each new position overwrites the last one, the row is deleted when the
--    delivery ends. Nobody can read or write the table directly (no rights, no rules):
--    only through the functions below.
--  * driver_live_start(order): DRIVER, his own order that is on the way (OUT_FOR_DELIVERY).
--    Replaces the order he was sharing before (that customer stops seeing him).
--  * driver_live_update(lat, lng, accuracy): DRIVER, his position (about every 15 s).
--  * driver_live_stop(): DRIVER, stops sharing.
--  * Trigger on orders: the row is deleted as soon as the order is no longer on the way with
--    that driver (delivered, not delivered, back at the shop, cancelled, other driver...).
--  * track_live(order_no, phone): visitors, same check as track_order (number + phone).
--    Returns the status, and while that order is being driven to: the driver's position if it
--    is fresh (10 minutes), and the distance to the delivery address when the customer's
--    location link has coordinates. Never the customer's own coordinates, never a name.
--  * driver_live_cleanup(): every 15 minutes, deletes rows not updated for 2 hours.
-- =====================================================================

create table if not exists public.driver_live (
  driver_id  uuid primary key references auth.users (id) on delete cascade,
  order_id   bigint not null unique references public.orders (id) on delete cascade,
  lat        double precision check (lat is null or lat between -90 and 90),
  lng        double precision check (lng is null or lng between -180 and 180),
  accuracy   real check (accuracy is null or accuracy >= 0),
  started_at timestamptz not null default now(),
  updated_at timestamptz,
  check ((lat is null) = (lng is null))
);
comment on table public.driver_live is
  'Live tracking (D3): the order each driver is heading to + his LAST position only. Deleted when the delivery ends. No direct access: functions only.';

alter table public.driver_live enable row level security;
-- no policies on purpose: nobody reads or writes it directly, not even staff
revoke all on table public.driver_live from public, anon, authenticated;

-- ---------- coordinates in a customer's location link (Google Maps / OpenStreetMap / plain) ----------
create or replace function public.location_coords(p_url text)
returns double precision[]
language plpgsql
immutable
set search_path = ''
as $$
declare
  m text[];
begin
  if p_url is null or p_url = '' then
    return null;
  end if;
  -- ...!3d33.89!4d35.50 (exact pin), @33.89,35.50 (map centre), ?q= / query= / ll= / destination= 33.89,35.50,
  -- #map=17/33.89/35.50 (OpenStreetMap)
  m := regexp_match(p_url, '!3d(-?\d{1,2}\.\d+)!4d(-?\d{1,3}\.\d+)');
  if m is null then m := regexp_match(p_url, '[?&](?:q|query|ll|destination|daddr)=(-?\d{1,2}\.\d+)(?:,|%2C)\s*(-?\d{1,3}\.\d+)', 'i'); end if;
  if m is null then m := regexp_match(p_url, '@(-?\d{1,2}\.\d+),(-?\d{1,3}\.\d+)'); end if;
  if m is null then m := regexp_match(p_url, '#map=\d+/(-?\d{1,2}\.\d+)/(-?\d{1,3}\.\d+)'); end if;
  if m is null then
    return null;
  end if;
  if m[1]::double precision not between -90 and 90 or m[2]::double precision not between -180 and 180 then
    return null;
  end if;
  return array[m[1]::double precision, m[2]::double precision];
end;
$$;
revoke all on function public.location_coords(text) from public, anon, authenticated;

-- straight-line distance in km (haversine)
create or replace function public.km_between(lat1 double precision, lng1 double precision, lat2 double precision, lng2 double precision)
returns double precision
language sql
immutable
set search_path = ''
as $$
  select 2 * 6371 * asin(sqrt(
    power(sin(radians(lat2 - lat1) / 2), 2) +
    cos(radians(lat1)) * cos(radians(lat2)) * power(sin(radians(lng2 - lng1) / 2), 2)))
$$;
revoke all on function public.km_between(double precision, double precision, double precision, double precision) from public, anon, authenticated;

-- ---------- driver: start / update / stop ----------
create or replace function public.driver_live_start(p_order_id bigint)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'DRIVER' then
    raise exception 'Only drivers can use this' using errcode = '42501';
  end if;
  -- only his own order (anything else answers "not found", like an order he can't see)
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.driver_id = auth.uid() and o.carrier = 'DRIVER') then
    raise exception 'ORDER_NOT_FOUND' using errcode = 'P0001';
  end if;
  if not exists (select 1 from public.orders o where o.id = p_order_id and o.status = 'OUT_FOR_DELIVERY') then
    raise exception 'NOT_ON_THE_WAY' using errcode = 'P0001';
  end if;
  -- one customer at a time: this replaces whatever he was sharing before (position kept: same driver)
  insert into public.driver_live (driver_id, order_id, started_at)
  values (auth.uid(), p_order_id, now())
  on conflict (driver_id) do update set order_id = excluded.order_id, started_at = excluded.started_at;
  return jsonb_build_object('order_id', p_order_id);
end;
$$;
revoke all on function public.driver_live_start(bigint) from public, anon;
grant execute on function public.driver_live_start(bigint) to authenticated;

create or replace function public.driver_live_update(p_lat double precision, p_lng double precision, p_accuracy real default null)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_order bigint;
begin
  if public.my_role() is distinct from 'DRIVER' then
    raise exception 'Only drivers can use this' using errcode = '42501';
  end if;
  if p_lat is null or p_lng is null or p_lat not between -90 and 90 or p_lng not between -180 and 180
     or (p_accuracy is not null and (p_accuracy < 0 or p_accuracy > 100000)) then
    raise exception 'INVALID_INPUT' using errcode = 'P0001';
  end if;
  update public.driver_live
     set lat = round(p_lat::numeric, 5)::double precision, lng = round(p_lng::numeric, 5)::double precision,
         accuracy = round(coalesce(p_accuracy, 0)), updated_at = now()
   where driver_id = auth.uid()
  returning order_id into v_order;
  if v_order is null then
    return jsonb_build_object('sharing', false);   -- nothing to share (delivery ended or never started)
  end if;
  return jsonb_build_object('sharing', true, 'order_id', v_order);
end;
$$;
revoke all on function public.driver_live_update(double precision, double precision, real) from public, anon;
grant execute on function public.driver_live_update(double precision, double precision, real) to authenticated;

create or replace function public.driver_live_stop()
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.my_role() is distinct from 'DRIVER' then
    raise exception 'Only drivers can use this' using errcode = '42501';
  end if;
  delete from public.driver_live where driver_id = auth.uid();
end;
$$;
revoke all on function public.driver_live_stop() from public, anon;
grant execute on function public.driver_live_stop() to authenticated;

-- what the driver's own screen needs: which order he is sharing (if any)
create or replace function public.driver_live_mine()
returns jsonb
language sql
stable
security definer
set search_path = ''
as $$
  select case when public.my_role() = 'DRIVER' then
    (select jsonb_build_object('order_id', order_id, 'started_at', started_at, 'updated_at', updated_at)
       from public.driver_live where driver_id = auth.uid())
  end
$$;
revoke all on function public.driver_live_mine() from public, anon;
grant execute on function public.driver_live_mine() to authenticated;

-- ---------- the delivery ends -> the position is deleted ----------
create or replace function public.orders_end_live()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.status is distinct from 'OUT_FOR_DELIVERY' or new.carrier is distinct from 'DRIVER'
     or new.driver_id is distinct from old.driver_id then
    delete from public.driver_live where order_id = new.id;
  end if;
  return null;
end;
$$;
revoke all on function public.orders_end_live() from public, anon, authenticated;

drop trigger if exists orders_end_live on public.orders;
create trigger orders_end_live
  after update of status, carrier, driver_id on public.orders
  for each row execute function public.orders_end_live();

-- ---------- the customer (track page) ----------
create or replace function public.track_live(p_order_no text, p_phone text)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_phone text := public.normalize_phone(p_phone);
  v_no text := upper(trim(coalesce(p_order_no, '')));
  o public.orders;
  l public.driver_live;
  v_dest double precision[];
  v_age integer;
  v jsonb;
begin
  if v_phone is null or v_no = '' or length(v_no) > 30 then
    return null;
  end if;
  select * into o from public.orders where upper(order_no) = v_no and phone = v_phone;
  if not found then
    return null;   -- same answer for a wrong number or a wrong phone
  end if;
  v := jsonb_build_object('status', o.status, 'sharing', false);
  if o.status <> 'OUT_FOR_DELIVERY' or o.carrier is distinct from 'DRIVER' then
    return v;
  end if;
  select * into l from public.driver_live where order_id = o.id and driver_id = o.driver_id;
  if not found then
    return v;      -- on the way, but the driver isn't heading to this customer yet
  end if;
  v := v || jsonb_build_object('sharing', true);
  if l.lat is null then
    return v || jsonb_build_object('position', false);   -- started, no GPS fix yet
  end if;
  v_age := greatest(0, extract(epoch from now() - l.updated_at))::integer;
  if v_age > 600 then
    return v || jsonb_build_object('position', false, 'stale', true);   -- no news for 10 minutes
  end if;
  v := v || jsonb_build_object('position', true, 'lat', l.lat, 'lng', l.lng, 'accuracy', l.accuracy, 'age_s', v_age);
  v_dest := public.location_coords(o.location_url);
  if v_dest is not null then
    v := v || jsonb_build_object('distance_km', round(public.km_between(l.lat, l.lng, v_dest[1], v_dest[2])::numeric, 1));
  end if;
  return v;
end;
$$;
revoke all on function public.track_live(text, text) from public;
grant execute on function public.track_live(text, text) to anon, authenticated;

-- ---------- safety net: forgotten rows (phone off, app closed) ----------
create or replace function public.driver_live_cleanup()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  n integer;
begin
  delete from public.driver_live where coalesce(updated_at, started_at) < now() - interval '2 hours';
  get diagnostics n = row_count;
  return n;
end;
$$;
revoke all on function public.driver_live_cleanup() from public, anon, authenticated;

select cron.schedule('driver-live-cleanup', '*/15 * * * *', 'select public.driver_live_cleanup()');
