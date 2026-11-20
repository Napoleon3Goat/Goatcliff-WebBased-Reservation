-- =====================================================================
-- Update 9 functions and 2 report views (Nov 20)
--
-- What this does:
--   * Replaces the code inside 9 functions with the commented, step-by-step versions.
--   * Replaces 2 report views (provinces, discounts) with clearer versions.
--     A view is a saved query with no data inside, so nothing is lost.
--   * Tables, data, access rules and photos aren't touched. No new tables.
--   * "create or replace" keeps each name, permission and trigger,
--     so the website keeps working the same way.
--   * begin ... commit: if any part fails, nothing changes at all.
--
-- Undo: run schema/undo_update_dev.sql to put the old versions back.
-- =====================================================================

begin;


-- Helper: "what role is the logged-in person?"
-- Gives back super_admin / staff_admin / field_staff, or nothing for guests
-- and for staff who were turned off.
-- security definer so it can read admin_accounts (that table is locked).
create or replace function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.admin_accounts
  where auth_user_id = auth.uid()   -- auth.uid() = whoever's logged in
    and is_active
$$;


-- Rule: always keep at least one active Super Admin.
-- Before a staff row is changed or deleted, I check:
--   is this person an active Super Admin, and would this change remove that?
--   if yes, and nobody else is an active Super Admin, I refuse.
create or replace function public.keep_one_super_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Step 1. Was this person an active Super Admin? If not, there's nothing to protect.
  if old.role = 'super_admin' and old.is_active then

    -- Step 2. Does this change take that away? (deleted, demoted, or turned off)
    if tg_op = 'DELETE' or new.role <> 'super_admin' or not new.is_active then

      -- Step 3. Is somebody else still an active Super Admin? If not, I refuse.
      if not exists (select 1 from public.admin_accounts
                     where role = 'super_admin'
                       and is_active
                       and id <> old.id) then
        raise exception 'LAST_SUPER_ADMIN: add or activate another Super Admin first.';
      end if;

    end if;
  end if;

  -- Step 4. Let the change through.
  --         (delete returns the old row, update returns the new one)
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;


-- Write down which staff member entered the booking.
-- Before a booking is saved, I look up who is logged in.
-- A guest isn't staff, so it stays empty (= booked online).
-- I overwrite whatever the website sent, so nobody can fake it.
create or replace function public.set_booking_created_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.created_by := (select id from public.admin_accounts where auth_user_id = auth.uid());
  return new;
end;
$$;


-- "Check my booking": the guest types the reference number + email.
-- Both must match. It shows only that one booking, with no contact details.
create or replace function public.lookup_booking(p_reference text, p_email text)
returns table (reference_number text, activity text, visit_date date, nights int, group_size int,
               total_amount numeric, amount_due numeric, amount_paid numeric,
               payment_status text, attendance_status text)
language sql
stable
security definer
set search_path = ''
as $$
  select b.reference_number, a.name, b.visit_date, b.nights, b.group_size,
         b.total_amount, b.amount_due, b.amount_paid, b.payment_status, b.attendance_status
  from public.bookings b
  join public.activities a on a.id = b.activity_id
  where b.reference_number = upper(trim(p_reference))
    and lower(b.email) = lower(trim(p_email))
$$;


-- GUARD 2: closed days + rock daily limit.
-- Runs before a booking is saved (or its date, nights, activity, group size or override changes).
create or replace function public.check_booking_availability()
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


-- GUARD 3: tents (5 good-for-4, 3 good-for-2 per night).
-- For every night of the stay, I add up the tents other groups already have
-- that night. If this booking would go over the stock, I refuse.
create or replace function public.check_tent_stock()
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


-- Guest calendar, part 1: which dates are taken?
-- Gives back only the date, nights and number of people. Never names or contacts.
create or replace function public.booked_dates(p_activity_id uuid, p_from date, p_to date)
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
$$;


-- Guest calendar, part 2: which dates are closed? (dates only, never the reason)
create or replace function public.closed_dates(p_activity_id uuid, p_from date, p_to date)
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


-- Mark attendance: the ONE thing Field Staff may change.
-- I check that the person is staff, and that the status is done or failed_to_show.
create or replace function public.mark_attendance(p_booking_id uuid, p_status text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if public.current_admin_role() is null then
    raise exception 'NOT_STAFF: only staff can mark attendance.';
  end if;

  if p_status not in ('done', 'failed_to_show') then
    raise exception 'BAD_STATUS: attendance can only be done or failed_to_show.';
  end if;

  update public.bookings
  set attendance_status = p_status
  where id = p_booking_id;
end;
$$;


-- Where guests come from (typed text tidied: "pangasinan" = "Pangasinan"; blank = "Not given")
create or replace view public.report_monthly_provinces with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       case
         when province is null or trim(province) = '' then 'Not given'   -- left blank
         else initcap(trim(province))                                     -- "pangasinan " -> "Pangasinan"
       end as province,
       count(*) as bookings,
       sum(group_size) as people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;


-- Discounts given (number of people, not pesos)
create or replace view public.report_monthly_discounts with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       sum(senior_count) as seniors,
       sum(pwd_count)    as pwds,
       sum(child_count)  as children_7_below,
       sum(local_count)  as atok_locals,
       count(*) filter (where is_organizer) as organizer_bookings,                -- count only organizer bookings
       sum(case when is_organizer then group_size else 0 end) as organizer_people  -- their people (0 if none)
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1;


commit;
