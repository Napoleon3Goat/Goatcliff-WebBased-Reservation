-- 05_guest_accounts.sql
-- Optional guest login (not required to book).
-- Exists only with Data Privacy Act consent.

create table public.guest_accounts (
  id                uuid primary key default gen_random_uuid(),
  auth_user_id      uuid unique references auth.users(id) on delete set null,
  name              text not null,
  email             text not null unique,
  contact_number    text,
  consent_given_at  timestamptz not null,   -- when they agreed to the privacy notice
  created_at        timestamptz not null default now()
);

alter table public.guest_accounts enable row level security;
