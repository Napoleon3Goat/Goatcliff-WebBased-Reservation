-- 08_cancellations.sql
-- History of every reschedule, refund, and cancellation (who, why, when).

create table public.cancellations (
  id                   uuid primary key default gen_random_uuid(),
  booking_id           uuid not null references public.bookings(id),
  action               text not null check (action in ('reschedule', 'refund', 'cancel')),
  reason_category      text not null
                         check (reason_category in ('weather', 'health_emergency', 'death',
                                                    'guest_request', 'other')),
  reason_details       text,                     -- free text, e.g. "Typhoon Signal No. 2"
  original_visit_date  date not null,            -- saved before the booking's date changes
  new_visit_date       date,                     -- reschedule only
  refund_amount        numeric(10,2) check (refund_amount >= 0),  -- refund only
  refund_status        text not null default 'not_applicable'
                         check (refund_status in ('not_applicable', 'pending', 'processed')),
  processed_by         uuid not null references public.admin_accounts(id),
  guest_notified_at    timestamptz,              -- filled in when the email or SMS is sent
  created_at           timestamptz not null default now(),

  -- If-then rules
  check (action <> 'reschedule' or new_visit_date is not null),          -- reschedule needs a new date
  check (action = 'reschedule' or new_visit_date is null),               -- only reschedules have one
  check (action <> 'refund' or (refund_amount is not null
                                and refund_status <> 'not_applicable')), -- refund needs amount + status
  check (new_visit_date is null
         or new_visit_date <= original_visit_date + interval '6 months') -- Goatcliff's 6-month rule
);

alter table public.cancellations enable row level security;
