-- =====================================================================
-- 07 REPORTS
-- Saved queries (views) that the Reports page reads like tables. One row per month.
--
-- How it works:
--   * security_invoker = true: each view follows the reader's access rules:
--     managers see everything, Field Staff get no income (they can't read payments),
--     and guests can't read reports at all.
--   * Cancelled and expired bookings are left out of the guest numbers.
--   * date_trunc('month', ...) = first day of the month, so all of November
--     groups together. ::date drops the time.
--   * count(*) filter (where X) = only count rows where X is true.
--   * group by 1, 2 = one row per (1st column, 2nd column), e.g. per month + activity.
-- =====================================================================


-- Bookings, people, cancellations and no-shows per month and activity
create view public.report_monthly_bookings with (security_invoker = true) as
select date_trunc('month', b.visit_date)::date as month,
       a.name as activity,
       count(*) as bookings,
       sum(b.group_size) as people,
       count(*) filter (where b.attendance_status = 'cancelled') as cancelled,
       count(*) filter (where b.attendance_status = 'failed_to_show') as failed_to_show
from public.bookings b
join public.activities a on a.id = b.activity_id
where b.payment_status <> 'expired'
group by 1, 2;

-- Age groups and male / female per month
create view public.report_monthly_guests with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       sum(age_0_7)   as age_0_7,
       sum(age_8_17)  as age_8_17,
       sum(age_18_24) as age_18_24,
       sum(age_25_34) as age_25_34,
       sum(age_35_44) as age_35_44,
       sum(age_45_59) as age_45_59,
       sum(age_60_up) as age_60_up,
       sum(male_count)   as male,
       sum(female_count) as female
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1;

-- Where guests come from (typed text tidied: "pangasinan" = "Pangasinan"; blank = "Not given")
create view public.report_monthly_provinces with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       case
         when province is null or trim(province) = '' then 'Not given'   -- left blank
         else initcap(trim(province))                                     -- "pangasinan " -> "Pangasinan"
       end as province,
       count(*) as bookings,
       sum(group_size) as people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;

-- How guests found Goatcliff
create view public.report_monthly_found_us with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       coalesce(found_us, 'not_given') as found_us,
       count(*) as bookings
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;

-- Income: confirmed payments, by the month they were paid (Philippine time)
create view public.report_monthly_income with (security_invoker = true) as
select date_trunc('month', paid_at at time zone 'Asia/Manila')::date as month,
       count(*) as payments,
       sum(amount) as income
from public.payments
where status = 'confirmed'
group by 1;

-- Discounts given (number of people, not pesos)
create view public.report_monthly_discounts with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       sum(senior_count) as seniors,
       sum(pwd_count)    as pwds,
       sum(child_count)  as children_7_below,
       sum(local_count)  as atok_locals,
       count(*) filter (where is_organizer) as organizer_bookings,                -- count only organizer bookings
       sum(case when is_organizer then group_size else 0 end) as organizer_people  -- their people (0 if none)
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1;

-- Walk-in vs online (and Messenger, phone)
create view public.report_monthly_sources with (security_invoker = true) as
select date_trunc('month', visit_date)::date as month,
       source,
       count(*) as bookings,
       sum(group_size) as people
from public.bookings
where payment_status <> 'expired' and attendance_status <> 'cancelled'
group by 1, 2;


-- Guests never read reports.
revoke select on public.report_monthly_bookings,
                 public.report_monthly_guests,
                 public.report_monthly_provinces,
                 public.report_monthly_found_us,
                 public.report_monthly_income,
                 public.report_monthly_discounts,
                 public.report_monthly_sources
from anon;
