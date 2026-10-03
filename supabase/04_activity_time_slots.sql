-- 04_activity_time_slots.sql
-- Time windows for rock activities (camping has none).
-- Data is added once Goatcliff confirms the schedule.

create table public.activity_time_slots (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references public.activities(id),
  start_time   time not null,
  end_time     time not null,
  capacity     integer check (capacity > 0),  -- max guests in this slot; null = not confirmed yet
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),

  check (end_time > start_time),       -- blocks typos like 9:00 to 7:30
  unique (activity_id, start_time)     -- no duplicate 7:30 slot for the same activity
);

alter table public.activity_time_slots enable row level security;
