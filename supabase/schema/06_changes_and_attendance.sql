-- =====================================================================
-- 06 CHANGES AND ATTENDANCE
-- Reschedules, refunds, cancellations, and who showed up.
--
-- How it works:
--   * Every reschedule, refund or cancellation is written down as its own row,
--     with the reason and the staff member who did it. The booking itself is kept.
--   * A new date must be on or before Dec 31 of the original visit's year.
--   * A refund marked "processed" must say how it was sent (GCash, cash, bank).
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
  processed_by         uuid not null references public.admin_accounts (id),   -- staff who did it
  guest_notified_at    timestamptz,                                   -- when the guest was told
  created_at           timestamptz not null default now(),
  refund_method        text check (refund_method in ('gcash', 'cash', 'bank')),

  -- a reschedule needs a new date ...
  check (action <> 'reschedule' or new_visit_date is not null),
  -- ... and only a reschedule has one
  check (action = 'reschedule' or new_visit_date is null),
  -- a refund needs an amount and a refund status
  check (action <> 'refund' or (refund_amount is not null and refund_status <> 'not_applicable')),

  -- a processed refund must say how it was sent
  constraint processed_refund_needs_method
    check (refund_status <> 'processed' or refund_method is not null),

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
