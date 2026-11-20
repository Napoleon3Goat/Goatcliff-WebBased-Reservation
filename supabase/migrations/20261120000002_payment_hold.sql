-- =====================================================================
-- 5-minute payment hold + guest payment proof (Nov 20)
--
-- What this does:
--   * "Confirm and pay" holds the spot for 5 minutes (the database sets the timer).
--   * The guest sends the GCash / Maya reference + receipt screenshot within 5 minutes.
--     Then the timer stops and the booking waits for staff to check it (no expiry).
--   * No proof in 5 minutes? The hold ends and the spot opens again. Late proof is refused.
--   * Each booking also saves its discount in pesos (for the monthly report).
--   * No tables removed, no data deleted.
-- =====================================================================

begin;


-- ---------------------------------------------------------------------
-- New columns
-- ---------------------------------------------------------------------
alter table public.bookings
  add column discount_amount numeric(10,2) not null default 0 check (discount_amount >= 0);  -- pesos off

alter table public.payments
  add column receipt_path text;   -- the guest's receipt screenshot (payment-receipts bucket)


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

create trigger free_expired_holds
  before insert or update of visit_date, nights, activity_id
  on public.bookings
  for each row execute function public.free_expired_holds();


-- ---------------------------------------------------------------------
-- Tents: don't count unpaid holds whose 5 minutes are up.
-- (Same as before, plus the line marked NEW.)
-- ---------------------------------------------------------------------
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


-- ---------------------------------------------------------------------
-- Guest calendar: ended holds don't show as taken.
-- (Same as before, plus the line marked NEW.)
-- ---------------------------------------------------------------------
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
    and (b.hold_expires_at is null or b.hold_expires_at > now())   -- NEW: skip holds whose time is up
$$;


-- ---------------------------------------------------------------------
-- The guest sends their payment proof (within the 5 minutes).
-- They can't read or change bookings directly, so this function does it for them,
-- and only after the reference number AND email match.
-- ---------------------------------------------------------------------
create function public.submit_payment(p_reference text, p_email text, p_method text,
                                      p_transaction_reference text, p_receipt_path text)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  booking_id   uuid;            -- the guest's booking
  booking_ref  text;            -- its GC- reference number
  status       text;            -- pending / down_payment / paid / expired / refunded
  timer_ends   timestamptz;     -- when its 5 minutes are up (empty = no timer)
  down_payment numeric(10,2);   -- the amount they had to pay
begin
  -- Step 1. Find the booking. The reference number AND the email must both match.
  --         "for update" locks it, so the same proof can't be sent twice at once.
  select id, reference_number, payment_status, hold_expires_at, amount_due
    into booking_id, booking_ref, status, timer_ends, down_payment
  from public.bookings
  where reference_number = upper(trim(p_reference))
    and lower(email) = lower(trim(p_email))
  for update;

  if booking_id is null then
    raise exception 'NOT_FOUND: no booking with that reference and email.';
  end if;

  -- Step 2. Too late? I refuse late proof, so the timer means something.
  if status = 'expired' then
    raise exception 'TIME_UP: the 5 minutes to pay are over.';
  end if;

  if status = 'pending' and timer_ends < now() then
    raise exception 'TIME_UP: the 5 minutes to pay are over.';
  end if;

  -- Step 3. Proof already sent? (no timer = already sent, or a staff-entered booking)
  if status <> 'pending' or timer_ends is null then
    raise exception 'ALREADY_SENT: this booking already has its payment proof.';
  end if;

  -- Step 4. Check what they typed.
  -- (Goat Cliff only receives through GCash or Maya)
  if p_method not in ('gcash', 'maya') then
    raise exception 'BAD_METHOD: pay to Goat Cliff''s GCash or Maya.';
  end if;

  if p_transaction_reference is null or trim(p_transaction_reference) = '' then
    raise exception 'NO_REFERENCE: enter the reference number from your receipt.';
  end if;

  -- (GCash references are 13 digits; I allow up to 40 so a slightly different format still fits)
  if length(trim(p_transaction_reference)) > 40 then
    raise exception 'BAD_REFERENCE: that reference number is too long.';
  end if;

  -- the screenshot must be in this booking's folder ("GC-XXXXXXXX/...")
  if p_receipt_path is not null and p_receipt_path not like booking_ref || '/%' then
    raise exception 'BAD_RECEIPT: the receipt must be saved under this booking.';
  end if;

  -- Step 5. Save the proof as a payment waiting for staff to check.
  --         (A reference that was already used is refused: transaction_reference is unique.)
  insert into public.payments (booking_id, amount, purpose, method, status, transaction_reference, receipt_path)
  values (booking_id, down_payment, 'down_payment', p_method, 'pending', trim(p_transaction_reference), p_receipt_path);

  -- Step 6. Stop the timer. The spot now stays held until staff confirm or release it.
  update public.bookings
  set hold_expires_at = null
  where id = booking_id;
end;
$$;

revoke execute on function public.submit_payment(text, text, text, text, text) from public;
grant execute on function public.submit_payment(text, text, text, text, text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- Receipt screenshots: a private bucket, like the ID photos.
-- Guests upload; only Super Admin and Staff Admin can open them.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "Guests can upload payment receipts" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'payment-receipts');

create policy "Managers can view payment receipts" on storage.objects
  for select to authenticated
  using (bucket_id = 'payment-receipts' and public.current_admin_role() in ('super_admin', 'staff_admin'));

commit;
