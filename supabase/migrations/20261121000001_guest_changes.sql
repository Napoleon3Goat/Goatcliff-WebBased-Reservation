-- =====================================================================
-- Guests reschedule or cancel their own booking online (Nov 21)
--
-- What this does:
--   * On "Check my booking", a guest can reschedule or cancel.
--     To make a change they need the reference number + email + mobile number they booked with.
--   * Online changes: at least 2 days before the visit. New date: at least 2 days from today,
--     and on or before Dec 31 of the visit's year. Rescheduling is free.
--   * Reschedule: saved right away (the usual full / closed / taken / tent checks still run).
--   * Cancel: the booking is cancelled and the refund waits in the Requests "To do" list,
--     until staff send it and mark it refunded.
--   * Both are written in the Requests history as done by the guest (no staff member).
--   * Staff don't have the 2-day rule (they can still handle late changes and no-shows).
-- =====================================================================

begin;


-- ---------------------------------------------------------------------
-- 1. A change the guest made online has no staff member.
--    Empty processed_by = done by the guest, and only allowed for "guest request".
-- ---------------------------------------------------------------------
alter table public.cancellations alter column processed_by drop not null;

alter table public.cancellations
  add constraint guest_changes_are_guest_requests
  check (processed_by is not null or reason_category = 'guest_request');


-- ---------------------------------------------------------------------
-- 2. "Check my booking" also gives the activity code (the reschedule calendar needs it).
--    Changing what a function gives back means dropping it and making it again.
-- ---------------------------------------------------------------------
drop function public.lookup_booking(text, text);

create function public.lookup_booking(p_reference text, p_email text)
returns table (reference_number text, activity text, visit_date date, nights int, group_size int,
               total_amount numeric, amount_due numeric, amount_paid numeric,
               payment_status text, attendance_status text, activity_code text)
language sql
stable
security definer
set search_path = ''
as $$
  select b.reference_number, a.name, b.visit_date, b.nights, b.group_size,
         b.total_amount, b.amount_due, b.amount_paid, b.payment_status, b.attendance_status,
         a.code
  from public.bookings b
  join public.activities a on a.id = b.activity_id
  where b.reference_number = upper(trim(p_reference))
    and lower(b.email) = lower(trim(p_email))
$$;

grant execute on function public.lookup_booking(text, text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- 3. Helper: find the guest's booking. The reference, email AND mobile number must all match.
--    (Mobile numbers are compared as digits only, so "0917 123 4567" = "09171234567".)
--    Gives back the booking's id, or nothing. Only my other functions use it.
-- ---------------------------------------------------------------------
create function public.find_guest_booking(p_reference text, p_email text, p_mobile text)
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id
  from public.bookings
  where reference_number = upper(trim(p_reference))
    and lower(email) = lower(trim(p_email))
    and regexp_replace(contact_number, '[^0-9]', '', 'g') = regexp_replace(p_mobile, '[^0-9]', '', 'g')
$$;

revoke execute on function public.find_guest_booking(text, text, text) from public, anon, authenticated;


-- ---------------------------------------------------------------------
-- 4. The guest moves their booking to a new date.
-- ---------------------------------------------------------------------
create function public.guest_reschedule(p_reference text, p_email text, p_mobile text, p_new_date date)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  this_booking uuid;
  old_date    date;
  pay_status  text;          -- payment status
  visit       text;          -- attendance status
  timer_ends  timestamptz;   -- still inside the 5-minute payment timer?
  today       date := (now() at time zone 'Asia/Manila')::date;   -- today in the Philippines
begin
  -- Step 1. Find the booking (reference + email + mobile) and lock it.
  this_booking := public.find_guest_booking(p_reference, p_email, p_mobile);
  if this_booking is null then
    raise exception 'NOT_FOUND: the reference number, email and mobile number don''t match a booking.';
  end if;

  select visit_date, payment_status, attendance_status, hold_expires_at
    into old_date, pay_status, visit, timer_ends
  from public.bookings
  where id = this_booking
  for update;

  -- Step 2. Only active bookings can be moved.
  if visit <> 'upcoming' or pay_status not in ('pending', 'down_payment', 'paid') then
    raise exception 'NOT_ACTIVE: this booking can''t be changed online.';
  end if;

  if pay_status = 'pending' and timer_ends is not null then
    raise exception 'NOT_ACTIVE: finish paying for this booking first.';
  end if;

  -- Step 3. At least 2 days before the visit. (date - date = number of days)
  if old_date - today < 2 then
    raise exception 'TOO_LATE: online changes must be made at least 2 days before the visit.';
  end if;

  -- Step 4. Check the new date.
  if p_new_date is null or p_new_date = old_date then
    raise exception 'BAD_DATE: pick a different date.';
  end if;

  if p_new_date - today < 2 then
    raise exception 'BAD_DATE: the new date must be at least 2 days from today.';
  end if;

  if extract(year from p_new_date) <> extract(year from old_date) then
    raise exception 'BAD_DATE: the new date must be on or before Dec 31 of your visit''s year.';
  end if;

  -- Step 5. Move it. The usual checks run here (full day, closed day, area taken, tents).
  update public.bookings
  set visit_date = p_new_date
  where id = this_booking;

  -- Step 6. Write it in the history. The guest did it themselves, so they're already "updated".
  insert into public.cancellations (booking_id, action, reason_category, original_visit_date,
                                    new_visit_date, processed_by, guest_notified_at)
  values (this_booking, 'reschedule', 'guest_request', old_date, p_new_date, null, now());
end;
$$;

revoke execute on function public.guest_reschedule(text, text, text, date) from public;
grant execute on function public.guest_reschedule(text, text, text, date) to anon, authenticated;


-- ---------------------------------------------------------------------
-- 5. The guest cancels their booking. Gives back the refund amount (0 = nothing to refund).
-- ---------------------------------------------------------------------
create function public.guest_cancel(p_reference text, p_email text, p_mobile text, p_reason text)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  this_booking uuid;
  visit_day   date;
  pay_status  text;            -- payment status
  visit       text;            -- attendance status
  timer_ends  timestamptz;
  paid        numeric(10,2);   -- what the guest paid (confirmed)
  waiting     numeric(10,2);   -- what they sent that staff haven't checked yet
  reason      text;
  today       date := (now() at time zone 'Asia/Manila')::date;
begin
  -- Step 1. Find the booking (reference + email + mobile) and lock it.
  this_booking := public.find_guest_booking(p_reference, p_email, p_mobile);
  if this_booking is null then
    raise exception 'NOT_FOUND: the reference number, email and mobile number don''t match a booking.';
  end if;

  select visit_date, payment_status, attendance_status, hold_expires_at, amount_paid
    into visit_day, pay_status, visit, timer_ends, paid
  from public.bookings
  where id = this_booking
  for update;

  -- Step 2. Same rules as rescheduling.
  if visit <> 'upcoming' or pay_status not in ('pending', 'down_payment', 'paid') then
    raise exception 'NOT_ACTIVE: this booking can''t be changed online.';
  end if;

  if pay_status = 'pending' and timer_ends is not null then
    raise exception 'NOT_ACTIVE: finish paying for this booking first.';
  end if;

  if visit_day - today < 2 then
    raise exception 'TOO_LATE: online changes must be made at least 2 days before the visit.';
  end if;

  -- Step 3. How much to refund: what they paid, plus proof staff haven't checked yet.
  select coalesce(sum(amount), 0) into waiting
  from public.payments
  where booking_id = this_booking
    and status = 'pending';

  paid := paid + waiting;
  reason := left(nullif(trim(p_reason), ''), 300);   -- optional, at most 300 characters

  -- Step 4. Cancel the booking (the spot opens for other guests).
  if paid > 0 then
    update public.bookings set attendance_status = 'cancelled', payment_status = 'refunded' where id = this_booking;

    -- the refund waits in staff's "To do" until they send it
    insert into public.cancellations (booking_id, action, reason_category, reason_details,
                                      original_visit_date, refund_amount, refund_status, processed_by)
    values (this_booking, 'refund', 'guest_request', reason, visit_day, paid, 'pending', null);
  else
    update public.bookings set attendance_status = 'cancelled' where id = this_booking;

    -- nothing to refund, nothing for staff to do
    insert into public.cancellations (booking_id, action, reason_category, reason_details,
                                      original_visit_date, processed_by, guest_notified_at)
    values (this_booking, 'cancel', 'guest_request', reason, visit_day, null, now());
  end if;

  return paid;
end;
$$;

revoke execute on function public.guest_cancel(text, text, text, text) from public;
grant execute on function public.guest_cancel(text, text, text, text) to anon, authenticated;

commit;
