-- Tests for guests rescheduling / cancelling online. Everything is rolled back at the end.
-- I only run this on a PRACTICE database, never on dev or prod.
-- (Dates are counted from today, so run it before mid-December or the "same year" tests shift.)
begin;
create schema t;
create table t.results (n serial, test text, result text);
grant usage on schema t to anon;
grant insert on t.results to anon;
grant usage on sequence t.results_n_seq to anon;

create function t.as_guest(label text, stmt text) returns void language plpgsql as $$
begin
  execute 'set local role anon';
  begin
    execute stmt;
    insert into t.results (test, result) values (label, 'OK');
  exception when others then
    insert into t.results (test, result) values (label, sqlerrm);
  end;
  execute 'reset role';
end $$;

-- a staff-entered booking (no 5-minute timer); d = days from today
create function t.add(ref text, act text, d int, nights int, people int, pay text, paid numeric) returns void language sql as $$
  insert into public.bookings (reference_number, activity_id, visit_date, nights, guest_name, contact_number, email,
    group_size, age_18_24, male_count, total_amount, amount_due, amount_paid, payment_status, consent_given_at, source)
  values (ref, (select id from public.activities where code = act), (now() at time zone 'Asia/Manila')::date + d,
    nights, 'Guest', '09171234567', 'g@trial.test', people, people, people, 1000, 500, paid, pay, now(), 'messenger')
$$;

create function t.day(d int) returns date language sql as $$ select (now() at time zone 'Asia/Manila')::date + d $$;

select t.add('GC-CHG00001', 'LA1', 10, 2, 2, 'down_payment', 500);
select t.add('GC-CHG00002', 'LA1', 25, 2, 2, 'down_payment', 500);
select t.add('GC-CHG00003', 'LA2', 1, 1, 2, 'down_payment', 500);
select t.add('GC-CHG00004', 'ROCK', 12, null, 79, 'down_payment', 500);
select t.add('GC-CHG00005', 'ROCK', 14, null, 5, 'down_payment', 500);
select t.add('GC-CHG00006', 'CA1', 9, 1, 2, 'pending', 0);
insert into public.payments (booking_id, amount, purpose, method, status, transaction_reference)
values ((select id from public.bookings where reference_number = 'GC-CHG00006'), 250, 'down_payment', 'gcash', 'pending', '5555555555555');

-- RESCHEDULE
select t.as_guest('wrong mobile', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09990000000', t.day(20)));
select t.as_guest('move LA1 to day +20 (mobile with spaces)', format('select public.guest_reschedule(%L, %L, %L, %L)', 'gc-chg00001', 'G@trial.test', '0917 123 4567', t.day(20)));
insert into t.results (test, result)
select '  history row', action || ' / by ' || coalesce(processed_by::text, 'guest') || ' / updated: ' || (guest_notified_at is not null)
from public.cancellations where booking_id = (select id from public.bookings where reference_number = 'GC-CHG00001');
select t.as_guest('move into next year', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09171234567', make_date(extract(year from t.day(20))::int + 1, 1, 5)));
select t.as_guest('move to tomorrow', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09171234567', t.day(1)));
select t.as_guest('move onto nights someone else has', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09171234567', t.day(24)));
select t.as_guest('move one night later (overlaps only itself)', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09171234567', t.day(21)));
select t.as_guest('visit is tomorrow: too late', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00003', 'g@trial.test', '09171234567', t.day(15)));
select t.as_guest('rock 5 onto a day with 79', format('select public.guest_reschedule(%L, %L, %L, %L)', 'GC-CHG00005', 'g@trial.test', '09171234567', t.day(12)));

-- CANCEL
select t.as_guest('cancel paid booking, no refund account', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00002', 'g@trial.test', '09171234567', null, null, null));
select t.as_guest('cancel paid booking, bad refund number', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00002', 'g@trial.test', '09171234567', null, 'gcash', '12345'));
select t.as_guest('cancel paid LA1 booking', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00002', 'g@trial.test', '09171234567', '  Family emergency  ', 'gcash', '0918 765 4321'));
insert into t.results (test, result)
select '  booking now', attendance_status || ' / ' || payment_status from public.bookings where reference_number = 'GC-CHG00002';
insert into t.results (test, result)
select '  history row', action || ' / ' || refund_amount || ' ' || refund_status || ' / by ' || coalesce(processed_by::text, 'guest') || ' / ' || reason_details || ' / to ' || refund_to_method || ' ' || refund_to_account
from public.cancellations where booking_id = (select id from public.bookings where reference_number = 'GC-CHG00002');
select t.as_guest('cancel it again', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00002', 'g@trial.test', '09171234567', null, 'gcash', '09187654321'));
select t.as_guest('cancel booking with unchecked proof (250)', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00006', 'g@trial.test', '09171234567', null, 'maya', '09181112222'));
insert into t.results (test, result)
select '  refund for it', refund_amount::text from public.cancellations where booking_id = (select id from public.bookings where reference_number = 'GC-CHG00006');

-- a guest still inside the 5-minute timer
insert into public.bookings (reference_number, activity_id, visit_date, nights, guest_name, contact_number, email,
  group_size, age_18_24, male_count, total_amount, amount_due, consent_given_at, source)
values ('GC-CHG00007', (select id from public.activities where code = 'CA2'), t.day(9), 1, 'Guest', '09171234567', 'g@trial.test', 2, 2, 2, 1000, 500, now(), 'online');
select t.as_guest('cancel while still paying', format('select public.guest_cancel(%L, %L, %L, %L, %L, %L)', 'GC-CHG00007', 'g@trial.test', '09171234567', null, null, null));

-- OTHER RULES
select t.as_guest('guest calls the helper directly', format('select public.find_guest_booking(%L, %L, %L)', 'GC-CHG00001', 'g@trial.test', '09171234567'));
select t.as_guest('check my booking gives the activity code', 'insert into t.results (test, result) select ''  code'', activity_code from public.lookup_booking(''GC-CHG00001'', ''g@trial.test'')');
-- (as the database owner, so the access rules don't stop it first)
do $$
begin
  insert into public.cancellations (booking_id, action, reason_category, original_visit_date, processed_by)
  values ((select id from public.bookings where reference_number = 'GC-CHG00003'), 'cancel', 'weather', current_date, null);
  insert into t.results (test, result) values ('history row with no staff and reason "weather"', 'OK');
exception when others then
  insert into t.results (test, result) values ('history row with no staff and reason "weather"', sqlerrm);
end $$;

select n, test, result from t.results order by n;
rollback;
