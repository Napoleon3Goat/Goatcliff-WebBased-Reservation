-- 03_admin_accounts.sql
-- Admin-side users. Login/password lives in Supabase Auth (auth.users);
-- this table adds the person's name and role.

create table public.admin_accounts (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid not null unique references auth.users(id) on delete cascade,
  name          text not null,
  role          text not null check (role in ('super_admin', 'staff_admin', 'field_staff')),
  is_active     boolean not null default true,
  created_at    timestamptz not null default now()
);

alter table public.admin_accounts enable row level security;
