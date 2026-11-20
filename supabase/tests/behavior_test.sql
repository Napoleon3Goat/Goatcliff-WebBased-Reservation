-- Runs the same booking scenarios and records what happens. Everything is rolled back at the end.
-- I only run this on a PRACTICE database, never on dev or prod.
begin;
create schema t;
create table t.results (n serial, test text, result text);

-- try(sql): run one statement, write down OK or the error message
create function t.try(label text, stmt text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
    insert into t.results (test, result) values (label, 'OK');
  exception when others then
    insert into t.results (test, result) values (label, sqlerrm);
  end;
end $$;

-- book(code, date, nights, people, extra columns) builds a valid booking insert
create function t.book(code text, d date, nights int, people int, extra text default '') returns text language sql as $$
  select format($f$insert into public.bookings (activity_id, visit_date, nights, guest_name, contact_number, email,
      group_size, age_18_24, male_count, total_amount, amount_due, consent_given_at%s)
    values ((select id from public.activities where code = %L), %L, %s, 'Test', '0917', 'test@trial.test',
      %s, %s, %s, 100, 50, now()%s)$f$,
    case when extra = '' then '' else ', ' || split_part(extra, '=', 1) end,
    code, d, coalesce(nights::text, 'null'), people, people, people,
    case when extra = '' then '' else ', ' || split_part(extra, '=', 2) end)
$$;

-- people
insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000aa01', 'sa1@trial.test'),
  ('00000000-0000-0000-0000-00000000aa02', 'sa2@trial.test'),
  ('00000000-0000-0000-0000-00000000aa03', 'fs@trial.test');
insert into public.admin_accounts (id, auth_user_id, name, role) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000aa01', 'SA One', 'super_admin'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000aa02', 'SA Two', 'super_admin'),
  ('00000000-0000-0000-0000-0000000000b3', '00000000-0000-0000-0000-00000000aa03', 'Field', 'field_staff');

-- ROCK daily limit (80)
select t.try('rock 70 people', t.book('ROCK', '2030-06-10', null, 70));
select t.try('rock +15 (85 > 80)', t.book('ROCK', '2030-06-10', null, 15));
select t.try('rock +10 (exactly 80)', t.book('ROCK', '2030-06-10', null, 10));
select t.try('rock +10 with override (walk-in)', t.book('ROCK', '2030-06-10', null, 10, 'capacity_override,source=true,''walk_in'''));
select t.try('rock +5 online, override not allowed', t.book('ROCK', '2030-06-10', null, 5, 'capacity_override=true'));

-- changed limit for one day
insert into public.date_overrides (activity_id, override_date, daily_capacity, reason, set_by)
  values ((select id from public.activities where code = 'ROCK'), '2030-06-13', 5, 'test', '00000000-0000-0000-0000-0000000000b1');
select t.try('rock 6 on a day limited to 5', t.book('ROCK', '2030-06-13', null, 6));
select t.try('rock 5 on a day limited to 5', t.book('ROCK', '2030-06-13', null, 5));

-- expired hold doesn't count, empty hold does
select t.try('rock 70 pending, hold already ended', t.book('ROCK', '2030-06-14', null, 70));
-- the database sets the timer itself, so I end it by hand (like 5 minutes passing)
update public.bookings set hold_expires_at = now() - interval '1 hour' where visit_date = '2030-06-14';
select t.try('rock 70 more (old hold ended)', t.book('ROCK', '2030-06-14', null, 70));
select t.try('rock 20 more (now 90)', t.book('ROCK', '2030-06-14', null, 20));

-- cancelled bookings don't count
select t.try('rock 80 cancelled', t.book('ROCK', '2030-06-15', null, 80, 'attendance_status=''cancelled'''));
select t.try('rock 80 after a cancelled 80', t.book('ROCK', '2030-06-15', null, 80));

-- closed days
insert into public.date_overrides (activity_id, override_date, is_closed, reason, set_by)
  values ((select id from public.activities where code = 'LA2'), '2030-06-12', true, 'test', '00000000-0000-0000-0000-0000000000b1');
select t.try('LA2 Jun 11-13 (Jun 12 closed)', t.book('LA2', '2030-06-11', 2, 4));
select t.try('LA2 Jun 13 (open)', t.book('LA2', '2030-06-13', 1, 4));
select t.try('LA2 Jun 11-12 after reopening', (select 'update public.date_overrides set is_closed = false where override_date = ''2030-06-12''')) ;
select t.try('LA2 Jun 11-13 after reopening', t.book('LA2', '2030-06-11', 2, 4));
insert into public.date_overrides (activity_id, override_date, is_closed, reason, set_by)
  values ((select id from public.activities where code = 'CA2'), '2030-06-12', true, 'test', '00000000-0000-0000-0000-0000000000b1');
select t.try('CA2 closed day, walk-in with override', t.book('CA2', '2030-06-12', 1, 4, 'capacity_override,source=true,''walk_in'''));

-- double booking
select t.try('LA1 Jun 20-23', t.book('LA1', '2030-06-20', 3, 4, 'tents_for_4=4'));
select t.try('LA1 Jun 21 (overlap)', t.book('LA1', '2030-06-21', 1, 2));
select t.try('LA1 Jun 23 (they left that morning)', t.book('LA1', '2030-06-23', 1, 2));

-- tents
select t.try('LA3 Jun 22, 2 more good-for-4 (4+2 > 5)', t.book('LA3', '2030-06-22', 1, 4, 'tents_for_4=2'));
select t.try('LA3 Jun 22, 1 more good-for-4 (5)', t.book('LA3', '2030-06-22', 1, 4, 'tents_for_4=1'));
select t.try('LA4 Jun 23, 2 good-for-4', t.book('LA4', '2030-06-23', 1, 4, 'tents_for_4=2'));
select t.try('UA3 Jun 20, 3 good-for-2', t.book('UA3', '2030-06-20', 2, 4, 'tents_for_2=3'));
select t.try('UA4 Jun 21, 1 good-for-2 (3+1 > 3)', t.book('UA4', '2030-06-21', 1, 2, 'tents_for_2=1'));
select t.try('tents on a rock booking', t.book('ROCK', '2030-06-25', null, 2, 'tents_for_2=1'));

-- calendar functions
insert into t.results (test, result)
select 'booked_dates LA1 June', string_agg(visit_date || '/' || nights || '/' || people, ' ' order by visit_date)
from public.booked_dates((select id from public.activities where code = 'LA1'), '2030-06-01', '2030-06-30');
insert into t.results (test, result)
select 'booked_dates ROCK Jun 14', string_agg(visit_date || '/' || coalesce(nights::text, '-') || '/' || people, ' ' order by people)
from public.booked_dates((select id from public.activities where code = 'ROCK'), '2030-06-14', '2030-06-14');
update public.date_overrides set is_closed = true where override_date = '2030-06-12';
insert into t.results (test, result)
select 'closed_dates LA2 June', coalesce(string_agg(closed_date::text, ' '), 'none')
from public.closed_dates((select id from public.activities where code = 'LA2'), '2030-06-01', '2030-06-30');

-- check my booking
update public.bookings set reference_number = 'GC-TEST0001' where visit_date = '2030-06-20' and nights = 3;
insert into t.results (test, result)
select 'lookup right email', count(*)::text from public.lookup_booking(' gc-test0001 ', 'TEST@trial.test');
insert into t.results (test, result)
select 'lookup wrong email', count(*)::text from public.lookup_booking('GC-TEST0001', 'other@trial.test');

-- who entered it (created_by) and attendance, as staff
create function t.as_user(uid text, stmt text, label text) returns void language plpgsql as $$
begin
  perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';
  begin
    execute stmt;
    insert into t.results (test, result) values (label, 'OK');
  exception when others then
    insert into t.results (test, result) values (label, sqlerrm);
  end;
  execute 'reset role';
end $$;
grant usage on schema t to authenticated;
grant insert, select on t.results to authenticated;
grant usage on sequence t.results_n_seq to authenticated;

select t.as_user('00000000-0000-0000-0000-00000000aa01',
  t.book('CA1', '2030-07-01', 1, 2, 'source=''messenger''') , 'Super Admin enters a Messenger booking');
insert into t.results (test, result)
select 'created_by of that booking', coalesce(created_by::text, 'empty') from public.bookings where visit_date = '2030-07-01';
insert into t.results (test, result)
select 'created_by of a guest-style booking', coalesce(created_by::text, 'empty') from public.bookings where visit_date = '2030-06-13' and nights = 1;

select t.as_user('00000000-0000-0000-0000-00000000aa03',
  format('select public.mark_attendance(%L, %L)', (select id from public.bookings where visit_date = '2030-07-01'), 'done'), 'Field Staff marks done');
select t.as_user('00000000-0000-0000-0000-00000000aa03',
  format('select public.mark_attendance(%L, %L)', (select id from public.bookings where visit_date = '2030-07-01'), 'cancelled'), 'Field Staff marks cancelled');
select t.as_user('00000000-0000-0000-0000-00000000ffff',
  format('select public.mark_attendance(%L, %L)', (select id from public.bookings where visit_date = '2030-07-01'), 'failed_to_show'), 'Not staff tries to mark attendance');
insert into t.results (test, result)
select 'attendance now', attendance_status from public.bookings where visit_date = '2030-07-01';

-- keep one Super Admin
select t.try('turn off EVERY super admin', 'update public.admin_accounts set is_active = false where role = ''super_admin''');
select t.try('demote SA One (SA Two still active)', 'update public.admin_accounts set role = ''staff_admin'' where name = ''SA One''');
select t.try('delete Field Staff row', 'delete from public.admin_accounts where name = ''Field''');

-- reports: messy provinces and organizer counts
select t.try('province spaced lowercase', t.book('ROCK', '2030-08-01', null, 2, 'province='' pangasinan  '''));
select t.try('province blank',            t.book('ROCK', '2030-08-02', null, 3, 'province='''''));
select t.try('province upper',            t.book('ROCK', '2030-08-03', null, 4, 'province=''BAGUIO city'''));
select t.try('organizer booking',         t.book('ROCK', '2030-08-04', null, 5, 'is_organizer=true'));
select t.try('organizer booking 2',       t.book('ROCK', '2030-09-04', null, 1, 'is_organizer=true'));
insert into t.results (test, result)
select 'report provinces', string_agg(month || ' ' || province || ' ' || bookings || '/' || people, '; ' order by month, province)
from public.report_monthly_provinces;
insert into t.results (test, result)
select 'report discounts', string_agg(month || ' org ' || organizer_bookings || '/' || organizer_people || ' sen ' || coalesce(seniors::text,'-'), '; ' order by month)
from public.report_monthly_discounts;
insert into t.results (test, result)
select 'report column types', string_agg(attrelid::regclass || '.' || attname || ':' || format_type(atttypid, atttypmod), ' ' order by attrelid::regclass::text, attnum)
from pg_attribute where attrelid in ('public.report_monthly_provinces'::regclass, 'public.report_monthly_discounts'::regclass) and attnum > 0;

select n, test, result from t.results order by n;
rollback;
