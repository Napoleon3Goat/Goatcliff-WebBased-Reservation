-- =====================================================================
-- 05 PAYMENTS
-- Each payment is its own row: the down payment, the balance, even failed tries.
--
-- How it works:
--   * Super Admin and Staff Admin record payments (GCash, cash ...).
--   * A "confirmed" payment must have the time it was paid.
--   * For now the admin site also updates the booking's amount_paid and payment_status
--     (an automatic sync is planned for January).
--   * Guests and Field Staff can't see payments at all.
--   * Guests send their GCash / Maya proof only through submit_payment (below),
--     within the 5-minute hold. It waits as "pending" until staff check it.
-- =====================================================================


create table public.payments (
  id                     uuid primary key default gen_random_uuid(),
  booking_id             uuid not null references public.bookings (id),
  amount                 numeric(10,2) not null check (amount > 0),
  purpose                text not null check (purpose in ('down_payment', 'balance')),
  method                 text not null check (method in ('qrph', 'gcash', 'maya', 'card', 'bank_transfer', 'cash')),
  status                 text not null default 'pending' check (status in ('pending', 'confirmed', 'failed')),
  transaction_reference  text unique,                                  -- e.g. the GCash reference number
  recorded_by            uuid references public.admin_accounts (id),   -- staff who recorded it
  paid_at                timestamptz,
  created_at             timestamptz not null default now(),
  receipt_path           text,                                         -- guest's receipt screenshot (payment-receipts bucket)

  -- a confirmed payment must say when it was paid
  check (status <> 'confirmed' or paid_at is not null)
);

create index payments_booking_id_idx  on public.payments (booking_id);
create index payments_recorded_by_idx on public.payments (recorded_by);


-- ---------------------------------------------------------------------
-- Access rules: managers only (Super Admin + Staff Admin).
-- ---------------------------------------------------------------------
alter table public.payments enable row level security;

create policy "Managers can view payments" on public.payments
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can record payments" on public.payments
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can update payments" on public.payments
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));


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
