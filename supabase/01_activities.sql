-- 01_activities.sql
-- Removes the first version (it's empty, so nothing is lost), then rebuilds it.
drop table if exists public.activities;

create table public.activities (
  id                     uuid primary key default gen_random_uuid(),
  business_id            uuid,                 -- future multi-business support
  code                   text not null unique, -- short ID shown on the map, e.g. 'LA1'
  name                   text not null,
  type                   text not null check (type in ('camping', 'rock_activity')),
  area_group             text,                 -- e.g. 'Lower Area'; null for rock activities
  description            text,
  price                  numeric(10,2) not null check (price >= 0),
  price_unit             text not null check (price_unit in ('per_night', 'per_person')),
  per_person_price       numeric(10,2) not null default 0 check (per_person_price >= 0),
  capacity               integer check (capacity > 0),  -- max people; null = not confirmed yet
  requires_down_payment  boolean not null default true,
  down_payment_percent   numeric(5,2) not null default 50
                           check (down_payment_percent between 0 and 100),
  advance_notice_days    integer not null default 2 check (advance_notice_days >= 0),
  is_active              boolean not null default true,
  created_at             timestamptz not null default now()
);
