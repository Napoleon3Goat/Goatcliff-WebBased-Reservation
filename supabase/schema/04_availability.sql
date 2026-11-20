-- =====================================================================
-- 04 AVAILABILITY
-- Which dates and spots are free.
--
-- How it works (four guards, all inside the database):
--   1. Camping: one group per area per night (the double-booking rule).
--   2. Rock: max people per day (80), and no bookings on closed days.
--   3. Tents: 5 "good for 4" and 3 "good for 2" per night.
--   4. Staff can close a day, change one day's limit, or reopen it (date_overrides).
-- The guest calendar asks two small functions: which dates are taken, which are closed.
--
-- A booking "holds its spot" while it is pending, down payment or paid, and not cancelled.
-- An online booking that isn't paid yet holds its spot for 5 minutes only. Once the guest
-- sends their payment proof, the timer stops and it waits for staff to check it.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Closed days and changed limits (one row per activity per date)
--   is_closed = true             -> closed that day
--   daily_capacity = 60          -> that day's limit is 60 instead of the normal 80
--   is_closed = false, no limit  -> a normal day again (reopened). I keep the row for history.
-- ---------------------------------------------------------------------
create table public.date_overrides (
  id              uuid primary key default gen_random_uuid(),
  activity_id     uuid not null references public.activities (id),
  override_date   date not null,
  daily_capacity  integer check (daily_capacity >= 0),
  is_closed       boolean not null default false,
  reason          text not null,                                      -- only staff see it
  set_by          uuid not null references public.admin_accounts (id),   -- who did it
  created_at      timestamptz not null default now(),
  unique (activity_id, override_date)
);

create index date_overrides_set_by_idx on public.date_overrides (set_by);


-- ---------------------------------------------------------------------
-- GUARD 1: no double booking for camping.
-- Refuse a new booking if another active booking has the SAME area
-- and their nights OVERLAP. daterange = arrival to check-out
-- (check-out day not counted, so one group can leave and another arrive that day).
-- This needs the btree_gist add-on.
-- It also works when two guests press Book at the same second.
-- ---------------------------------------------------------------------
create extension if not exists btree_gist with schema extensions;

alter table public.bookings
  add constraint no_double_booking_camping
  exclude using gist (
    activity_id with =,                                   -- same area
    daterange(visit_date, visit_date + nights) with &&    -- nights overlap
  )
  where (nights is not null                               -- camping only
         and payment_status in ('pending', 'down_payment', 'paid')
         and attendance_status <> 'cancelled');


-- ---------------------------------------------------------------------
-- GUARD 2: closed days + rock daily limit.
-- Runs before a booking is saved (or its date, nights, activity, group size or override changes).
-- ---------------------------------------------------------------------
create function public.check_booking_availability()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  activity_type   text;
  normal_limit    integer;   -- the activity's usual daily limit (80 for rock)
  changed_limit   integer;   -- that day's limit if staff changed it
  day_limit       integer;   -- the limit I actually use
  people_booked   integer;   -- people already booked that day
begin
  -- Step 1. Some bookings skip the whole check.
  -- 1a. Staff used the override (walk-in on a full day).
  if new.capacity_override then
    return new;
  end if;

  -- 1b. The group is cancelled or didn't show, so it doesn't take a spot.
  if new.attendance_status not in ('upcoming', 'done') then
    return new;
  end if;

  -- 1c. The booking expired or was refunded, so it doesn't take a spot.
  if new.payment_status not in ('pending', 'down_payment', 'paid') then
    return new;
  end if;

  -- Step 2. Is any of the booked dates closed?
  --         Camping checks every night of the stay. Rock (no nights) checks just its one day.
  --         (one closed day in the stay is enough)
  if exists (
    select 1 from public.date_overrides
    where activity_id = new.activity_id
      and is_closed
      and override_date >= new.visit_date                           -- from the first day
      and override_date <  new.visit_date + coalesce(new.nights, 1) -- up to the last night (rock: 1 day)
  ) then
    raise exception 'DATE_CLOSED: this activity is closed on one of the selected dates.';
  end if;

  -- Step 3. Look up the activity and LOCK it, so bookings are checked one at a time.
  select type, daily_capacity into activity_type, normal_limit
  from public.activities
  where id = new.activity_id
  for update;

  -- Camping is done here (guard 1 already protects it).
  if activity_type <> 'rock_activity' then
    return new;
  end if;

  -- Step 4. That day's limit: the changed one if there is one, otherwise the normal one.
  select daily_capacity into changed_limit
  from public.date_overrides
  where activity_id = new.activity_id and override_date = new.visit_date;

  if changed_limit is not null then
    day_limit := changed_limit;
  else
    day_limit := normal_limit;
  end if;

  if day_limit is null then
    return new;   -- no limit set
  end if;

  -- Step 5. Count everyone already booked that day (viewers included).
  --         Finished groups still count toward the day.
  --         (coalesce(..., 0) = 0 if nobody's booked yet)
  select coalesce(sum(group_size), 0) into people_booked
  from public.bookings
  where activity_id = new.activity_id
    and visit_date = new.visit_date
    and id <> new.id                                        -- not this booking itself
    and attendance_status in ('upcoming', 'done')
    and (   payment_status in ('down_payment', 'paid')                  -- paid or partly paid
         or (payment_status = 'pending' and hold_expires_at is null)    -- unpaid, no timer
         or (payment_status = 'pending' and hold_expires_at > now()));  -- unpaid, timer still running

  -- Step 6. Too many? Refuse.
  if people_booked + new.group_size > day_limit then
    raise exception 'DAY_FULL: % has % of % spots taken; this group of % does not fit.',
      new.visit_date, people_booked, day_limit, new.group_size;
  end if;

  return new;
end;
$$;

revoke execute on function public.check_booking_availability() from public, anon, authenticated;

create trigger enforce_availability
  before insert or update of visit_date, nights, activity_id, group_size, capacity_override
  on public.bookings
  for each row execute function public.check_booking_availability();


-- ---------------------------------------------------------------------
-- GUARD 3: tents (5 good-for-4, 3 good-for-2 per night).
-- For every night of the stay, I add up the tents other groups already have
-- that night. If this booking would go over the stock, I refuse.
-- ---------------------------------------------------------------------
create function public.check_tent_stock()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare
  night          date;      -- the night I'm checking
  tents_4_taken  integer;   -- good-for-4 tents other groups have that night
  tents_2_taken  integer;   -- good-for-2 tents other groups have that night
begin
  -- Step 1. Some bookings skip the check.
  -- 1a. No tents rented.
  if new.tents_for_4 = 0 and new.tents_for_2 = 0 then
    return new;
  end if;

  -- 1b. Cancelled, so the tents go back.
  if new.attendance_status = 'cancelled' then
    return new;
  end if;

  -- 1c. Expired or refunded, so the tents go back.
  if new.payment_status not in ('pending', 'down_payment', 'paid') then
    return new;
  end if;

  -- Step 2. One tent check at a time, so two bookings
  --         can't grab the last tents at the same second.
  perform pg_advisory_xact_lock(hashtext('goatcliff_tents'));

  -- Step 3. Check each night, from the arrival night to the last night.
  night := new.visit_date;
  while night < new.visit_date + new.nights loop

    -- 3a. Add up the tents other groups have that night (0 if none).
    select coalesce(sum(tents_for_4), 0), coalesce(sum(tents_for_2), 0)
      into tents_4_taken, tents_2_taken
    from public.bookings
    where id <> new.id                                    -- not this booking itself
      and nights is not null                              -- camping bookings only
      and attendance_status <> 'cancelled'
      and payment_status in ('pending', 'down_payment', 'paid')
      and (hold_expires_at is null or hold_expires_at > now())   -- NEW: skip holds whose time is up
      and night >= visit_date                             -- they arrived on or before this night
      and night <  visit_date + nights;                   -- and haven't left yet

    -- 3b. Over the stock (5 good-for-4, 3 good-for-2)? Refuse.
    if tents_4_taken + new.tents_for_4 > 5 or tents_2_taken + new.tents_for_2 > 3 then
      raise exception 'TENTS_FULL: not enough tents on % (good-for-4 left: %, good-for-2 left: %).',
        night, 5 - tents_4_taken, 3 - tents_2_taken;
    end if;

    night := night + 1;   -- next night
  end loop;

  return new;
end;
$$;

revoke execute on function public.check_tent_stock() from public, anon, authenticated;

create trigger check_tent_stock
  before insert or update of tents_for_4, tents_for_2, visit_date, nights, attendance_status, payment_status
  on public.bookings
  for each row execute function public.check_tent_stock();


-- ---------------------------------------------------------------------
-- Start the 5-minute timer on every online booking.
-- I set it here, not on the website, so nobody can give themselves a longer hold.
-- Staff-entered bookings (walk-in, Messenger, phone) get no timer.
-- ---------------------------------------------------------------------
create function public.start_payment_hold()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.source = 'online' then
    new.hold_expires_at := now() + interval '5 minutes';
  end if;
  return new;
end;
$$;

revoke execute on function public.start_payment_hold() from public, anon, authenticated;

create trigger start_payment_hold
  before insert on public.bookings
  for each row execute function public.start_payment_hold();


-- ---------------------------------------------------------------------
-- End the holds whose 5 minutes are up: they become "expired".
-- (p_skip = a booking to leave alone, the one being saved right now.)
-- ---------------------------------------------------------------------
create function public.release_expired_holds(p_skip uuid default null)
returns void
language sql
security definer
set search_path = ''
as $$
  update public.bookings
  set payment_status = 'expired'
  where payment_status = 'pending'
    and hold_expires_at < now()                      -- timer ran out (empty timer = never expires)
    and (p_skip is null or id <> p_skip);            -- leave the skipped booking alone
$$;

revoke execute on function public.release_expired_holds(uuid) from public, anon;
grant execute on function public.release_expired_holds(uuid) to authenticated;   -- the admin site's lists

-- Before a booking is saved (or moved), clear out ended holds first,
-- so an abandoned hold never blocks the camping double-booking rule.
create function public.free_expired_holds()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  perform public.release_expired_holds(new.id);
  return new;
end;
$$;

revoke execute on function public.free_expired_holds() from public, anon, authenticated;

create trigger free_expired_holds
  before insert or update of visit_date, nights, activity_id
  on public.bookings
  for each row execute function public.free_expired_holds();


-- ---------------------------------------------------------------------
-- Guest calendar, part 1: which dates are taken?
-- Gives back only the date, nights and number of people. Never names or contacts.
-- ---------------------------------------------------------------------
create function public.booked_dates(p_activity_id uuid, p_from date, p_to date)
returns table (visit_date date, nights integer, people integer)
language sql
stable
security definer
set search_path = ''
as $$
  select b.visit_date, b.nights, b.group_size              -- b = bookings
  from public.bookings b
  where b.activity_id = p_activity_id
    and b.visit_date <= p_to                              -- starts before the end of the range
    and b.visit_date + coalesce(b.nights, 1) > p_from     -- ends after the start of the range
    and b.payment_status in ('pending', 'down_payment', 'paid')
    and b.attendance_status <> 'cancelled'
    and (b.hold_expires_at is null or b.hold_expires_at > now())   -- NEW: skip holds whose time is up
$$;

grant execute on function public.booked_dates(uuid, date, date) to anon, authenticated;


-- ---------------------------------------------------------------------
-- Guest calendar, part 2: which dates are closed? (dates only, never the reason)
-- ---------------------------------------------------------------------
create function public.closed_dates(p_activity_id uuid, p_from date, p_to date)
returns table (closed_date date)
language sql
stable
security definer
set search_path = ''
as $$
  select override_date
  from public.date_overrides
  where activity_id = p_activity_id
    and is_closed
    and override_date between p_from and p_to
$$;

grant execute on function public.closed_dates(uuid, date, date) to anon, authenticated;


-- ---------------------------------------------------------------------
-- Access rules: only managers see and change closed days and limits.
-- ---------------------------------------------------------------------
alter table public.date_overrides enable row level security;

create policy "Managers can view date overrides" on public.date_overrides
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can set date overrides" on public.date_overrides
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can update date overrides" on public.date_overrides
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));
