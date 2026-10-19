-- 20261019000001_indexes_and_function_permissions.sql
-- Phase C, group 1: C1 (indexes) + C8 (function permissions)

-- C1. Indexes on foreign keys (PostgreSQL does not create these automatically).
-- Flagged by the Performance Advisor as "unindexed foreign keys".
create index if not exists bookings_time_slot_id_idx            on public.bookings (time_slot_id);
create index if not exists bookings_assigned_field_staff_id_idx on public.bookings (assigned_field_staff_id);
create index if not exists bookings_guest_account_id_idx        on public.bookings (guest_account_id);
create index if not exists payments_booking_id_idx              on public.payments (booking_id);
create index if not exists payments_recorded_by_idx             on public.payments (recorded_by);
create index if not exists cancellations_booking_id_idx         on public.cancellations (booking_id);
create index if not exists cancellations_processed_by_idx       on public.cancellations (processed_by);
create index if not exists date_overrides_set_by_idx            on public.date_overrides (set_by);

-- C1. Index for the most common lookup: "bookings for this activity on this date"
-- (calendar, rock daily cap, admin dashboard).
create index if not exists bookings_activity_id_visit_date_idx  on public.bookings (activity_id, visit_date);

-- C8. Trigger functions should run only as triggers, never be called through the API.
-- Removing this permission does not stop the triggers: PostgreSQL checks it only
-- when a trigger is created, not each time it fires.
revoke execute on function public.check_booking_availability() from public, anon, authenticated;
revoke execute on function public.rls_auto_enable()             from public, anon, authenticated;
