-- Multi-tenant + Orders/Sales baseline (RLS-ready pattern)

create extension if not exists pgcrypto;

-- Organizations (tenants)
create table if not exists public.organizations (
  id uuid primary key default gen_random_uuid(),
  name text not null,
  created_at timestamptz not null default now(),
  created_by uuid null
);

create table if not exists public.organization_members (
  org_id uuid not null references public.organizations(id) on delete cascade,
  user_id uuid not null,
  role text not null default 'member',
  created_at timestamptz not null default now(),
  primary key (org_id, user_id)
);

-- Customers
create table if not exists public.customers (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  email text null,
  phone text null,
  created_at timestamptz not null default now()
);

-- Products
create table if not exists public.products (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  sku text not null,
  name text not null,
  price_cents int not null default 0,
  currency text not null default 'PYG',
  active boolean not null default true,
  created_at timestamptz not null default now(),
  unique (org_id, sku)
);

-- Orders
create table if not exists public.orders (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  customer_id uuid null references public.customers(id) on delete set null,
  status text not null default 'draft', -- draft|confirmed|invoiced|cancelled
  notes text null,
  total_cents int not null default 0,
  currency text not null default 'PYG',
  created_at timestamptz not null default now(),
  created_by uuid null
);

-- Order items
create table if not exists public.order_items (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  order_id uuid not null references public.orders(id) on delete cascade,
  product_id uuid null references public.products(id) on delete set null,
  sku text null,
  name text not null,
  qty int not null default 1,
  unit_price_cents int not null default 0,
  line_total_cents int not null default 0,
  created_at timestamptz not null default now()
);

create index if not exists idx_orders_org on public.orders(org_id);
create index if not exists idx_order_items_order on public.order_items(order_id);

-- API keys for third-party callers (store only hash)
create table if not exists public.api_keys (
  id uuid primary key default gen_random_uuid(),
  org_id uuid not null references public.organizations(id) on delete cascade,
  name text not null,
  key_hash text not null,
  created_at timestamptz not null default now(),
  revoked_at timestamptz null
);

create index if not exists idx_api_keys_org on public.api_keys(org_id);

-- RLS: enable (policies are app-specific; boilerplate keeps pattern documented)
alter table public.organizations enable row level security;
alter table public.organization_members enable row level security;
alter table public.customers enable row level security;
alter table public.products enable row level security;
alter table public.orders enable row level security;
alter table public.order_items enable row level security;
alter table public.api_keys enable row level security;

-- Example policy pattern (you can customize):
-- Allow members of org to read/write org-scoped rows
-- NOTE: You will need auth.uid() support and membership rows populated.
-- create policy "org members can read orders"
-- on public.orders for select
-- using (
--   exists (
--     select 1 from public.organization_members m
--     where m.org_id = orders.org_id
--       and m.user_id = auth.uid()
--   )
-- );
