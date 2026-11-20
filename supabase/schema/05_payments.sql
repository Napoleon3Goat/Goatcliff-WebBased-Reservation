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
