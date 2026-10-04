-- =====================================================================
-- Mika Shop: migration 1, the whole starting schema.
-- Tables, check constraints, indexes, staff + my_role(), RLS on every
-- table with the policies from CLAUDE.md section 6, and explicit GRANTs
-- (the projects have "Automatically expose new tables" OFF, so nothing
-- is reachable from the browser unless granted here).
-- Storage bucket + policies are in the next migration.
-- =====================================================================

-- ---------- helpers ---------------------------------------------------

-- Keeps updated_at current on every UPDATE.
create or replace function public.set_updated_at()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  new.updated_at := now();
  return new;
end;
$$;

-- ---------- settings --------------------------------------------------

create table public.settings (
  key        text primary key,
  value      text not null default '',
  is_public  boolean not null default false,
  updated_at timestamptz not null default now()
);
comment on table public.settings is 'All business details (name, currency, payment details...). Public keys are readable by the shop.';

create trigger settings_updated_at before update on public.settings
  for each row execute function public.set_updated_at();

-- ---------- staff + my_role() ----------------------------------------

create table public.staff (
  user_id    uuid primary key references auth.users (id) on delete cascade,
  name       text not null,
  role       text not null check (role in ('ADMIN', 'OWNER', 'DRIVER')),
  active     boolean not null default true,
  created_at timestamptz not null default now()
);
comment on table public.staff is 'Staff logins and their role. Users are created in Supabase Auth, then added here.';

-- Role of the logged-in user ('ADMIN' / 'OWNER' / 'DRIVER'), or null for
-- customers / logged-out visitors / deactivated staff.
-- security definer so it can read staff without being blocked by RLS.
create or replace function public.my_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select s.role
  from public.staff s
  where s.user_id = auth.uid()
    and s.active
$$;

-- ---------- catalog ---------------------------------------------------

create table public.categories (
  id         bigint generated always as identity primary key,
  name_en    text not null check (length(trim(name_en)) > 0),
  name_ar    text not null default '',
  parent_id  bigint references public.categories (id) on delete restrict,
  sort       integer not null default 0,
  active     boolean not null default true,
  created_at timestamptz not null default now(),
  check (parent_id is null or parent_id <> id)
);
create index categories_parent_idx on public.categories (parent_id);

create table public.products (
  sku             text primary key
                  check (sku ~ '^[A-Za-z0-9][A-Za-z0-9._-]{0,39}$'),
  name_en         text not null check (length(trim(name_en)) > 0),
  name_ar         text not null default '',
  desc_en         text not null default '',
  desc_ar         text not null default '',
  category_id     bigint references public.categories (id) on delete restrict,
  price           numeric(10,2) not null check (price >= 0),
  compare_price   numeric(10,2) check (compare_price is null or compare_price >= 0),
  stock           integer not null default 0 check (stock >= 0),
  has_variants    boolean not null default false,
  photos          text[] not null default '{}',
  featured        boolean not null default false,
  active          boolean not null default true,
  ar_needs_review boolean not null default false,
  created_at      timestamptz not null default now(),
  updated_at      timestamptz not null default now()
);
comment on column public.products.sku is 'Letters, digits, dot, dash, underscore (max 40). Photo files are named after it (SKU.jpg, SKU_2.jpg).';
comment on column public.products.stock is 'Used only when has_variants is false.';
comment on column public.products.photos is 'Storage paths in bucket product-photos; the first one is the main photo.';
create index products_category_idx on public.products (category_id);
create index products_active_idx on public.products (active);
create index products_featured_idx on public.products (featured) where featured and active;

create trigger products_updated_at before update on public.products
  for each row execute function public.set_updated_at();

create table public.variants (
  id       bigint generated always as identity primary key,
  sku      text not null references public.products (sku) on delete restrict on update cascade,
  label_en text not null check (length(trim(label_en)) > 0),
  label_ar text not null default '',
  price    numeric(10,2) check (price is null or price >= 0),
  stock    integer not null default 0 check (stock >= 0),
  active   boolean not null default true,
  sort     integer not null default 0
);
comment on column public.variants.price is 'Null = use the product price.';
create index variants_sku_idx on public.variants (sku);

-- ---------- delivery --------------------------------------------------

create table public.delivery_zones (
  id              bigint generated always as identity primary key,
  governorate     text not null,
  governorate_ar  text not null default '',
  district        text not null,
  district_ar     text not null default '',
  fee             numeric(10,2) check (fee is null or fee >= 0),
  eta_days        text,
  default_carrier text check (default_carrier is null or default_carrier in ('DRIVER', 'COMPANY')),
  active          boolean not null default true,
  sort            integer not null default 0,
  unique (governorate, district)
);
comment on column public.delivery_zones.fee is 'Null = fee not set yet: orders to this district are refused until it is set.';
comment on column public.delivery_zones.eta_days is 'Free text such as 1 or 2-3 (days).';

-- ---------- customers & orders ---------------------------------------

create table public.customers (
  phone          text primary key check (phone ~ '^\+961[0-9]{7,8}$'),
  name           text not null,
  governorate    text,
  district       text,
  town           text,
  address        text,
  landmark       text,
  location_url   text,
  first_order_at timestamptz not null default now(),
  orders_count   integer not null default 0,
  total_spent    numeric(10,2) not null default 0,
  notes          text
);

create table public.orders (
  id             bigint generated always as identity primary key,
  order_no       text not null unique,
  created_at     timestamptz not null default now(),
  phone          text not null check (phone ~ '^\+961[0-9]{7,8}$'),
  name           text not null,
  governorate    text not null,
  district       text not null,
  town           text not null,
  address        text not null,
  landmark       text,
  location_url   text,
  subtotal       numeric(10,2) not null check (subtotal >= 0),
  delivery_fee   numeric(10,2) not null check (delivery_fee >= 0),
  total          numeric(10,2) not null check (total >= 0),
  payment_method text not null check (payment_method in ('COD', 'WHISH', 'OMT')),
  payment_status text not null check (payment_status in ('UNPAID', 'AWAITING', 'PAID')),
  payment_ref    text,
  status         text not null default 'NEW' check (status in (
                   'NEW', 'CONFIRMED', 'PACKED', 'OUT_FOR_DELIVERY', 'WITH_COMPANY',
                   'DELIVERED', 'CANCELLED', 'RETURNED', 'FAILED_ATTEMPT')),
  carrier        text check (carrier is null or carrier in ('DRIVER', 'COMPANY')),
  driver_id      uuid references public.staff (user_id) on delete set null,
  tracking_no    text,
  cash_collected numeric(10,2) check (cash_collected is null or cash_collected >= 0),
  cancel_reason  text,
  notes          text,
  updated_at     timestamptz not null default now()
);
create index orders_created_idx on public.orders (created_at desc);
create index orders_phone_idx on public.orders (phone);
create index orders_status_idx on public.orders (status);
create index orders_driver_idx on public.orders (driver_id) where driver_id is not null;

create trigger orders_updated_at before update on public.orders
  for each row execute function public.set_updated_at();

create table public.order_items (
  id         bigint generated always as identity primary key,
  order_id   bigint not null references public.orders (id) on delete restrict,
  sku        text not null,
  variant_id bigint,
  name_en    text not null,
  name_ar    text not null default '',
  label      text,
  qty        integer not null check (qty > 0),
  unit_price numeric(10,2) not null check (unit_price >= 0),
  line_total numeric(10,2) not null check (line_total >= 0)
);
comment on table public.order_items is 'Names and prices copied at order time: editing a product never changes old orders. No FK on sku/variant_id on purpose.';
create index order_items_order_idx on public.order_items (order_id);

-- ---------- stock log -------------------------------------------------

create table public.stock_log (
  id          bigint generated always as identity primary key,
  created_at  timestamptz not null default now(),
  sku         text not null,
  variant_id  bigint,
  change      integer not null,
  stock_after integer,
  reason      text not null check (reason in ('SALE', 'CANCEL', 'RETURN', 'MANUAL', 'IMPORT')),
  order_id    bigint references public.orders (id) on delete set null,
  by_user     uuid
);
create index stock_log_sku_idx on public.stock_log (sku, created_at desc);

-- ---------- Row Level Security: ON everywhere -------------------------

alter table public.settings       enable row level security;
alter table public.staff          enable row level security;
alter table public.categories     enable row level security;
alter table public.products       enable row level security;
alter table public.variants       enable row level security;
alter table public.delivery_zones enable row level security;
alter table public.customers      enable row level security;
alter table public.orders         enable row level security;
alter table public.order_items    enable row level security;
alter table public.stock_log      enable row level security;

-- settings: public keys for everyone; all keys for staff; ADMIN edits.
create policy settings_read on public.settings for select to anon, authenticated
  using (is_public or public.my_role() is not null);
create policy settings_admin on public.settings for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- staff: each user sees their own row; ADMIN manages everyone.
create policy staff_read_self on public.staff for select to authenticated
  using (user_id = auth.uid());
create policy staff_admin on public.staff for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- catalog: public sees active rows; staff see everything; ADMIN edits.
create policy categories_read on public.categories for select to anon, authenticated
  using (active or public.my_role() is not null);
create policy categories_admin on public.categories for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

create policy products_read on public.products for select to anon, authenticated
  using (active or public.my_role() is not null);
create policy products_admin on public.products for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

create policy variants_read on public.variants for select to anon, authenticated
  using (
    (active and exists (select 1 from public.products p where p.sku = variants.sku and p.active))
    or public.my_role() is not null
  );
create policy variants_admin on public.variants for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

create policy zones_read on public.delivery_zones for select to anon, authenticated
  using (active or public.my_role() is not null);
create policy zones_admin on public.delivery_zones for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- customers: ADMIN everything, OWNER read-only. Public: nothing.
create policy customers_owner_read on public.customers for select to authenticated
  using (public.my_role() = 'OWNER');
create policy customers_admin on public.customers for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- orders: ADMIN everything, OWNER read-only, DRIVER only own orders.
create policy orders_owner_read on public.orders for select to authenticated
  using (public.my_role() = 'OWNER');
create policy orders_driver_read on public.orders for select to authenticated
  using (public.my_role() = 'DRIVER' and driver_id = auth.uid());
create policy orders_driver_update on public.orders for update to authenticated
  using (public.my_role() = 'DRIVER' and driver_id = auth.uid())
  with check (public.my_role() = 'DRIVER' and driver_id = auth.uid());
create policy orders_admin on public.orders for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- A DRIVER may change only status, cash_collected and notes.
create or replace function public.orders_driver_guard()
returns trigger
language plpgsql
set search_path = ''
as $$
begin
  if public.my_role() = 'DRIVER' then
    if (to_jsonb(new) - array['status', 'cash_collected', 'notes', 'updated_at'])
       is distinct from
       (to_jsonb(old) - array['status', 'cash_collected', 'notes', 'updated_at']) then
      raise exception 'Drivers can only change status, cash collected and notes'
        using errcode = '42501';
    end if;
  end if;
  return new;
end;
$$;
create trigger orders_driver_guard before update on public.orders
  for each row execute function public.orders_driver_guard();

-- order_items: same visibility as their order.
create policy order_items_owner_read on public.order_items for select to authenticated
  using (public.my_role() = 'OWNER');
create policy order_items_driver_read on public.order_items for select to authenticated
  using (
    public.my_role() = 'DRIVER'
    and exists (select 1 from public.orders o
                where o.id = order_items.order_id and o.driver_id = auth.uid())
  );
create policy order_items_admin on public.order_items for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- stock_log: ADMIN everything, OWNER read-only.
create policy stock_log_owner_read on public.stock_log for select to authenticated
  using (public.my_role() = 'OWNER');
create policy stock_log_admin on public.stock_log for all to authenticated
  using (public.my_role() = 'ADMIN') with check (public.my_role() = 'ADMIN');

-- ---------- GRANTs (auto-expose is OFF) --------------------------------
-- RLS above decides WHICH rows; these grants decide which tables the
-- browser roles may touch at all. anon gets read on the public catalog only.

grant usage on schema public to anon, authenticated;

grant select on public.settings, public.categories, public.products,
                public.variants, public.delivery_zones
  to anon;

grant select, insert, update, delete on
  public.settings, public.staff, public.categories, public.products,
  public.variants, public.delivery_zones, public.customers, public.orders,
  public.order_items, public.stock_log
  to authenticated;

grant usage, select on all sequences in schema public to authenticated;

-- Functions: nobody by default, then only what is needed.
revoke all on function public.my_role() from public;
grant execute on function public.my_role() to anon, authenticated;
revoke all on function public.set_updated_at() from public;
revoke all on function public.orders_driver_guard() from public;
