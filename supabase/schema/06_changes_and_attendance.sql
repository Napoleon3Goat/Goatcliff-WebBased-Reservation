-- =====================================================================
-- 06 CHANGES AND ATTENDANCE
-- Reschedules, refunds, cancellations, and who showed up.
--
-- How it works:
--   * Every reschedule, refund or cancellation is written down as its own row,
--     with the reason and the staff member who did it. The booking itself is kept.
--   * A new date must be on or before Dec 31 of the original visit's year.
--   * A refund marked "processed" must say how it was sent (GCash, Maya, cash, bank).
--   * Guests can reschedule or cancel online themselves (guest_reschedule / guest_cancel, below),
--     at least 2 days before the visit, with their reference + email + mobile number.
--     Staff don't have the 2-day rule.
--   * Any staff member can mark a group "done" or "failed to show", but Field Staff
--     can ONLY do that (through mark_attendance); they can't change anything else.
-- =====================================================================


create table public.cancellations (
  id                   uuid primary key default gen_random_uuid(),
  booking_id           uuid not null references public.bookings (id),
  action               text not null check (action in ('reschedule', 'refund', 'cancel')),
  reason_category      text not null check (reason_category in ('weather', 'health_emergency', 'death', 'guest_request', 'other')),
  reason_details       text,
  original_visit_date  date not null,
  new_visit_date       date,                                          -- reschedules only
  refund_amount        numeric(10,2) check (refund_amount >= 0),
  refund_status        text not null default 'not_applicable'
                       check (refund_status in ('not_applicable', 'pending', 'processed')),
  processed_by         uuid references public.admin_accounts (id),   -- staff who did it (empty = the guest, online)
  guest_notified_at    timestamptz,                                   -- when the guest was told
  created_at           timestamptz not null default now(),
  refund_method        text check (refund_method in ('gcash', 'maya', 'cash', 'bank')),   -- how staff sent the refund
  refund_to_method     text check (refund_to_method in ('gcash', 'maya')),   -- where the guest wants the refund (online)
  refund_to_account    text check (refund_to_account ~ '^09[0-9]{9}$'),     -- their GCash / Maya number

  -- a reschedule needs a new date ...
  check (action <> 'reschedule' or new_visit_date is not null),
  -- ... and only a reschedule has one
  check (action = 'reschedule' or new_visit_date is null),
  -- a refund needs an amount and a refund status
  check (action <> 'refund' or (refund_amount is not null and refund_status <> 'not_applicable')),

  -- a processed refund must say how it was sent
  constraint processed_refund_needs_method
    check (refund_status <> 'processed' or refund_method is not null),

  -- empty processed_by (done by the guest online) is only allowed for a guest request
  constraint guest_changes_are_guest_requests
    check (processed_by is not null or reason_category = 'guest_request'),

  -- the new date must be on or before Dec 31 of the original visit's year
  constraint reschedule_by_year_end
    check (new_visit_date is null
           or new_visit_date <= make_date(extract(year from original_visit_date)::int, 12, 31))
);

create index cancellations_booking_id_idx   on public.cancellations (booking_id);
create index cancellations_processed_by_idx on public.cancellations (processed_by);


-- ---------------------------------------------------------------------
-- Mark attendance: the ONE thing Field Staff may change.
-- I check that the person is staff, and that the status is done or failed_to_show.
-- ---------------------------------------------------------------------
create function public.mark_attendance(p_booking_id uuid, p_status text)
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

revoke execute on function public.mark_attendance(uuid, text) from public, anon;
grant execute on function public.mark_attendance(uuid, text) to authenticated;


-- ---------------------------------------------------------------------
-- Access rules: managers only (Super Admin + Staff Admin).
-- ---------------------------------------------------------------------
alter table public.cancellations enable row level security;

create policy "Managers can view cancellations" on public.cancellations
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can record cancellations" on public.cancellations
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can update cancellations" on public.cancellations
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));


-- ---------------------------------------------------------------------
-- Helper: find the guest's booking. The reference, email AND mobile number must all match.
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
-- The guest moves their booking to a new date.
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
-- The guest cancels their booking. Gives back the refund amount (0 = nothing to refund).
-- If there's money to refund, they must say where to send it (GCash or Maya + number).
-- ---------------------------------------------------------------------
create function public.guest_cancel(p_reference text, p_email text, p_mobile text, p_reason text,
                                    p_refund_method text, p_refund_account text)
returns numeric
language plpgsql
security definer
set search_path = ''
as $$
declare
  this_booking   uuid;
  visit_day      date;
  pay_status     text;            -- payment status
  visit          text;            -- attendance status
  timer_ends     timestamptz;
  paid           numeric(10,2);   -- what the guest paid (confirmed)
  waiting        numeric(10,2);   -- what they sent that staff haven't checked yet
  reason         text;
  refund_number  text;            -- their GCash / Maya number, digits only
  today          date := (now() at time zone 'Asia/Manila')::date;
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
    -- 4a. There's a refund, so I need to know where to send it.
    refund_number := regexp_replace(coalesce(p_refund_account, ''), '[^0-9]', '', 'g');

    if p_refund_method is null or p_refund_method not in ('gcash', 'maya') then
      raise exception 'NO_REFUND_ACCOUNT: choose GCash or Maya for your refund.';
    end if;

    if refund_number !~ '^09[0-9]{9}$' then
      raise exception 'BAD_REFUND_ACCOUNT: enter your 11-digit GCash / Maya number (09...).';
    end if;

    update public.bookings set attendance_status = 'cancelled', payment_status = 'refunded' where id = this_booking;

    -- 4b. The refund waits in staff's "To do" until they send it
    insert into public.cancellations (booking_id, action, reason_category, reason_details,
                                      original_visit_date, refund_amount, refund_status, processed_by,
                                      refund_to_method, refund_to_account)
    values (this_booking, 'refund', 'guest_request', reason, visit_day, paid, 'pending', null,
            p_refund_method, refund_number);
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

revoke execute on function public.guest_cancel(text, text, text, text, text, text) from public;
grant execute on function public.guest_cancel(text, text, text, text, text, text) to anon, authenticated;
