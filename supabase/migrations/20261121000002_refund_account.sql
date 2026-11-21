-- =====================================================================
-- Guests say where to send their refund when they cancel online (Nov 21)
--
-- What this does:
--   * Two new fields on the Requests history: refund_to_method (GCash or Maya)
--     and refund_to_account (the GCash / Maya number, 09XXXXXXXXX).
--   * guest_cancel now asks for them. They're required when there's money to refund.
--   * Staff see them on the Requests page, so they know where to send the refund.
--   * Staff can now also mark a refund as sent by Maya (before: GCash, cash or bank only).
-- =====================================================================

begin;


alter table public.cancellations
  add column refund_to_method  text check (refund_to_method in ('gcash', 'maya')),   -- where the guest wants it
  add column refund_to_account text check (refund_to_account ~ '^09[0-9]{9}$');      -- their GCash / Maya number


-- refunds can also be sent by Maya
alter table public.cancellations drop constraint cancellations_refund_method_check;
alter table public.cancellations
  add constraint cancellations_refund_method_check
  check (refund_method in ('gcash', 'maya', 'cash', 'bank'));


-- guest_cancel gets 2 more inputs, so I drop the old one and make it again
drop function public.guest_cancel(text, text, text, text);

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

commit;
