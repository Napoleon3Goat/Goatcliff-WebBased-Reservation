-- 07_payments.sql
-- Every payment attempt for a booking (online or cash), including failures.

create table public.payments (
  id                     uuid primary key default gen_random_uuid(),
  booking_id             uuid not null references public.bookings(id),
  amount                 numeric(10,2) not null check (amount > 0),
  purpose                text not null check (purpose in ('down_payment', 'balance')),
  method                 text not null
                           check (method in ('qrph', 'gcash', 'maya', 'card', 'bank_transfer', 'cash')),
  status                 text not null default 'pending'
                           check (status in ('pending', 'confirmed', 'failed')),
  transaction_reference  text unique,          -- PayMongo's payment ID; empty for cash
  recorded_by            uuid references public.admin_accounts(id),  -- admin who logged a cash payment
  paid_at                timestamptz,          -- filled in when confirmed
  created_at             timestamptz not null default now(),

  -- a confirmed payment must say when it was paid
  check (status <> 'confirmed' or paid_at is not null)
);

alter table public.payments enable row level security;
