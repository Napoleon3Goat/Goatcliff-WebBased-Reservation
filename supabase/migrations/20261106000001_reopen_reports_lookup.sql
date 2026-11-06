-- 20261106000001_reopen_reports_lookup.sql
-- My Nov 6 fixes. I ran these in dev through the SQL Editor; I run them on prod at release.
-- (I left out the dev-only hold clearing: prod has no test bookings.)

-- Reopening a closed day: I allow is_closed = false with no limit (a normal day). I keep the rows.
alter table public.date_overrides drop constraint date_overrides_check;

-- Reports: discounts given, per visit month (I count people here, not pesos).
create view public.report_monthly_discounts with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       sum(senior_count) as seniors, sum(pwd_count) as pwds,
       sum(child_count) as children_7_below, sum(local_count) as atok_locals,
       count(*) filter (where is_organizer) as organizer_bookings,
       coalesce(sum(group_size) filter (where is_organizer), 0) as organizer_people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1;

-- Reports: walk-in vs online (and Messenger, phone), per visit month.
create view public.report_monthly_sources with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month, source,
       count(*) as bookings, sum(group_size) as people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;

-- I don't want guests reading the reports.
revoke select on public.report_monthly_discounts, public.report_monthly_sources from anon;

-- "Check my booking": the reference number + email both have to match; it shows only that booking.
create or replace function public.lookup_booking(p_reference text, p_email text)
returns table (reference_number text, activity text, visit_date date, nights int, group_size int,
               total_amount numeric, amount_due numeric, amount_paid numeric,
               payment_status text, attendance_status text)
language sql stable security definer set search_path = ''
as $$
  select b.reference_number, a.name, b.visit_date, b.nights, b.group_size,
         b.total_amount, b.amount_due, b.amount_paid, b.payment_status, b.attendance_status
  from public.bookings b join public.activities a on a.id = b.activity_id
  where b.reference_number = upper(trim(p_reference))
    and lower(b.email) = lower(trim(p_email))
$$;
grant execute on function public.lookup_booking(text, text) to anon, authenticated;
