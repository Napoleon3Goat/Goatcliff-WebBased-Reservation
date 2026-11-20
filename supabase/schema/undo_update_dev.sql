-- =====================================================================
-- UNDO for migration 20261120000001_function_updates.sql
-- Puts dev's 9 functions and 2 report views back exactly as they were on Nov 20.
-- Only run this if something goes wrong after the update.
-- =====================================================================

begin;

CREATE OR REPLACE FUNCTION public.booked_dates(p_activity_id uuid, p_from date, p_to date)
 RETURNS TABLE(visit_date date, nights integer, people integer)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select b.visit_date, b.nights, b.group_size
  from public.bookings b
  where b.activity_id = p_activity_id
    and b.visit_date <= p_to
    and b.visit_date + coalesce(b.nights, 1) > p_from
    and b.payment_status in ('pending', 'down_payment', 'paid')
    and b.attendance_status <> 'cancelled'
$function$;

CREATE OR REPLACE FUNCTION public.check_booking_availability()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_type          text;
  v_default_cap   integer;
  v_override_cap  integer;
  v_cap           integer;
  v_booked        integer;
begin
  -- 1. Skip: admin override, or booking doesn't take up space
  if new.capacity_override
     or new.attendance_status not in ('upcoming', 'done')
     or new.payment_status not in ('pending', 'down_payment', 'paid') then
    return new;
  end if;

  -- 2. Closed on any of the booked dates? (camping checks every night)
  if exists (
    select 1 from public.date_overrides o
    where o.activity_id = new.activity_id
      and o.is_closed
      and o.override_date >= new.visit_date
      and o.override_date <  new.visit_date + coalesce(new.nights, 1)
  ) then
    raise exception 'DATE_CLOSED: this activity is closed on one of the selected dates.';
  end if;

  -- 3. Look up the activity and LOCK it (one check at a time)
  select type, daily_capacity into v_type, v_default_cap
  from public.activities
  where id = new.activity_id
  for update;

  if v_type <> 'rock_activity' then
    return new;
  end if;

  -- 4. Today's cap: the override if there is one, otherwise the default
  select daily_capacity into v_override_cap
  from public.date_overrides
  where activity_id = new.activity_id and override_date = new.visit_date;

  v_cap := coalesce(v_override_cap, v_default_cap);
  if v_cap is null then
    return new;   -- no daily limit set
  end if;

  -- 5. Count everyone booked that day (finished groups still count toward the DAY)
  select coalesce(sum(group_size), 0) into v_booked
  from public.bookings
  where activity_id = new.activity_id
    and visit_date = new.visit_date
    and id <> new.id
    and attendance_status in ('upcoming', 'done')
    and (payment_status in ('down_payment', 'paid')
         or (payment_status = 'pending'
             and (hold_expires_at is null or hold_expires_at > now())));

  if v_booked + new.group_size > v_cap then
    raise exception 'DAY_FULL: % has % of % spots taken; this group of % does not fit.',
      new.visit_date, v_booked, v_cap, new.group_size;
  end if;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.check_tent_stock()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
declare
  v_night date;
  v_4 integer;
  v_2 integer;
begin
  -- Skip: no tents, or the booking no longer holds its spot
  if (new.tents_for_4 = 0 and new.tents_for_2 = 0)
     or new.attendance_status = 'cancelled'
     or new.payment_status not in ('pending', 'down_payment', 'paid') then
    return new;
  end if;

  -- One tent check at a time, so two bookings can't take the last tents together
  perform pg_advisory_xact_lock(hashtext('goatcliff_tents'));

  -- Check every night of the stay
  for v_night in
    select d::date from generate_series(new.visit_date, new.visit_date + new.nights - 1, interval '1 day') d
  loop
    select coalesce(sum(tents_for_4), 0), coalesce(sum(tents_for_2), 0) into v_4, v_2
    from public.bookings
    where id <> new.id
      and nights is not null
      and attendance_status <> 'cancelled'
      and payment_status in ('pending', 'down_payment', 'paid')
      and v_night >= visit_date and v_night < visit_date + nights;

    if v_4 + new.tents_for_4 > 5 or v_2 + new.tents_for_2 > 3 then
      raise exception 'TENTS_FULL: not enough tents on % (good-for-4 left: %, good-for-2 left: %).',
        v_night, 5 - v_4, 3 - v_2;
    end if;
  end loop;

  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.closed_dates(p_activity_id uuid, p_from date, p_to date)
 RETURNS TABLE(closed_date date)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select o.override_date
  from public.date_overrides o
  where o.activity_id = p_activity_id
    and o.is_closed
    and o.override_date between p_from and p_to
$function$;

CREATE OR REPLACE FUNCTION public.current_admin_role()
 RETURNS text
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select role
  from public.admin_accounts
  where auth_user_id = auth.uid()
    and is_active
$function$;

CREATE OR REPLACE FUNCTION public.keep_one_super_admin()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if old.role = 'super_admin' and old.is_active
     and (tg_op = 'DELETE' or new.role <> 'super_admin' or not new.is_active)
     and not exists (select 1 from public.admin_accounts
                     where role = 'super_admin' and is_active and id <> old.id) then
    raise exception 'LAST_SUPER_ADMIN: add or activate another Super Admin first.';
  end if;
  if tg_op = 'DELETE' then return old; end if;
  return new;
end;
$function$;

CREATE OR REPLACE FUNCTION public.lookup_booking(p_reference text, p_email text)
 RETURNS TABLE(reference_number text, activity text, visit_date date, nights integer, group_size integer, total_amount numeric, amount_due numeric, amount_paid numeric, payment_status text, attendance_status text)
 LANGUAGE sql
 STABLE SECURITY DEFINER
 SET search_path TO ''
AS $function$
  select b.reference_number, a.name, b.visit_date, b.nights, b.group_size,
         b.total_amount, b.amount_due, b.amount_paid, b.payment_status, b.attendance_status
  from public.bookings b join public.activities a on a.id = b.activity_id
  where b.reference_number = upper(trim(p_reference))
    and lower(b.email) = lower(trim(p_email))
$function$;

CREATE OR REPLACE FUNCTION public.mark_attendance(p_booking_id uuid, p_status text)
 RETURNS void
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  if public.current_admin_role() is null then
    raise exception 'NOT_STAFF: only staff can mark attendance.';
  end if;
  if p_status not in ('done', 'failed_to_show') then
    raise exception 'BAD_STATUS: attendance can only be done or failed_to_show.';
  end if;
  update public.bookings set attendance_status = p_status where id = p_booking_id;
end;
$function$;

CREATE OR REPLACE FUNCTION public.set_booking_created_by()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO ''
AS $function$
begin
  new.created_by := (select id from public.admin_accounts where auth_user_id = auth.uid());
  return new;
end;
$function$;

-- The 2 report views exactly as they are in dev today.
create or replace view public.report_monthly_provinces with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       coalesce(nullif(initcap(trim(province)), ''), 'Not given') as province,
       count(*) as bookings,
       sum(group_size) as people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;

create or replace view public.report_monthly_discounts with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       sum(senior_count) as seniors,
       sum(pwd_count)    as pwds,
       sum(child_count)  as children_7_below,
       sum(local_count)  as atok_locals,
       count(*) filter (where is_organizer) as organizer_bookings,
       coalesce(sum(group_size) filter (where is_organizer), 0) as organizer_people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1;

commit;
