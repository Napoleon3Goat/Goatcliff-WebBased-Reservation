-- Tests for the 5-minute hold and the guest payment proof. Everything is rolled back at the end.
-- I only run this on a PRACTICE database, never on dev or prod.
begin;
create schema t;
create table t.results (n serial, test text, result text);

create function t.try(label text, stmt text) returns void language plpgsql as $$
begin
  begin
    execute stmt;
    insert into t.results (test, result) values (label, 'OK');
  exception when others then
    insert into t.results (test, result) values (label, sqlerrm);
  end;
end $$;

-- runs a statement as a guest (anon)
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
grant usage on schema t to anon;
grant insert on t.results to anon;
grant usage on sequence t.results_n_seq to anon;

-- book(code, ref, date, nights, people, extra) = a guest-style online booking
create function t.book(code text, ref text, d date, nights int, people int, extra text default '') returns text language sql as $$
  select format($f$insert into public.bookings (reference_number, activity_id, visit_date, nights, guest_name, contact_number, email,
      group_size, age_18_24, male_count, total_amount, amount_due, consent_given_at, source, payment_status, attendance_status%s)
    values (%L, (select id from public.activities where code = %L), %L, %s, 'Test', '0917', 'guest@trial.test',
      %s, %s, %s, 1000, 500, now(), 'online', 'pending', 'upcoming'%s)$f$,
    case when extra = '' then '' else ', ' || split_part(extra, '=', 1) end,
    ref, code, d, coalesce(nights::text, 'null'), people, people, people,
    case when extra = '' then '' else ', ' || split_part(extra, '=', 2) end)
$$;

-- pretend 6 minutes passed for one booking
create function t.time_up(ref text) returns void language sql as $$
  update public.bookings set hold_expires_at = now() - interval '1 minute' where reference_number = ref
$$;

create function t.pay(ref text, email text, txn text) returns text language sql as $$
  select format('select public.submit_payment(%L, %L, %L, %L, %L)', ref, email, 'gcash', txn, upper(ref) || '/receipt-1.jpg')
$$;

-- CAMPING
select t.as_guest('guest books LA1 Jun 1-3', t.book('LA1', 'GC-HOLD0001', '2031-06-01', 2, 2));
insert into t.results (test, result)
select 'timer set to about 5 minutes', (extract(epoch from hold_expires_at - now())::int)::text || ' seconds'
from public.bookings where reference_number = 'GC-HOLD0001';
select t.as_guest('2nd guest, same nights, while 1st is paying', t.book('LA1', 'GC-HOLD0002', '2031-06-02', 1, 2));

select t.time_up('GC-HOLD0001');
insert into t.results (test, result)
select 'calendar after time is up (before cleanup)', coalesce(string_agg(visit_date::text, ' '), 'free')
from public.booked_dates((select id from public.activities where code = 'LA1'), '2031-06-01', '2031-06-30');
select t.as_guest('2nd guest tries again after 5 minutes', t.book('LA1', 'GC-HOLD0002', '2031-06-02', 1, 2));
insert into t.results (test, result)
select '1st booking is now', payment_status from public.bookings where reference_number = 'GC-HOLD0001';
select t.as_guest('1st guest sends proof late', t.pay('GC-HOLD0001', 'guest@trial.test', '1111111111111'));

-- PROOF
select t.as_guest('proof with wrong email', t.pay('GC-HOLD0002', 'other@trial.test', '2222222222222'));
select t.as_guest('proof in time (gibberish allowed)', t.pay('GC-HOLD0002', 'GUEST@trial.test', 'abc123'));
insert into t.results (test, result)
select 'after proof: timer / status', coalesce(hold_expires_at::text, 'no timer') || ' / ' || payment_status
from public.bookings where reference_number = 'GC-HOLD0002';
insert into t.results (test, result)
select 'payment saved', amount || ' ' || method || ' ' || status || ' ' || transaction_reference || ' ' || receipt_path
from public.payments where transaction_reference = 'abc123';
select t.as_guest('proof sent twice', t.pay('GC-HOLD0002', 'guest@trial.test', '3333333333333'));
select t.as_guest('3rd guest overlaps a booking waiting for check', t.book('LA1', 'GC-HOLD0003', '2031-06-02', 1, 2));
select t.as_guest('4th guest books LA2', t.book('LA2', 'GC-HOLD0004', '2031-06-02', 1, 2));
select t.as_guest('4th guest reuses a reference', t.pay('GC-HOLD0004', 'guest@trial.test', 'abc123'));
select t.as_guest('receipt saved under another booking', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-HOLD0004', 'guest@trial.test', 'maya', '4444444444444', 'GC-HOLD0002/receipt-1.jpg'));
select t.as_guest('pay with cash online', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-HOLD0004', 'guest@trial.test', 'cash', '4444444444444', null));
select t.as_guest('reference too long', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-HOLD0004', 'guest@trial.test', 'maya', repeat('9', 41), null));
select t.as_guest('4th guest pays with Maya, no screenshot', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-HOLD0004', 'guest@trial.test', 'maya', '4444444444444', null));

select t.as_guest('5th guest books CA3', t.book('CA3', 'GC-BANK0001', '2031-06-02', 1, 2));
select t.as_guest('5th guest picks bank_transfer (not allowed)', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-BANK0001', 'guest@trial.test', 'bank_transfer', 'BDO-778812', null));
select t.as_guest('5th guest, longer reference', format('select public.submit_payment(%L, %L, %L, %L, %L)', 'GC-BANK0001', 'guest@trial.test', 'gcash', '20261120BDOB1234567890123', 'GC-BANK0001/receipt-1.png'));

-- ROCK (80 a day)
select t.as_guest('rock 75 online', t.book('ROCK', 'GC-ROCK0001', '2031-07-04', null, 75));
select t.as_guest('rock 10 more while 75 are paying', t.book('ROCK', 'GC-ROCK0002', '2031-07-04', null, 10));
select t.time_up('GC-ROCK0001');
select t.as_guest('rock 10 more after the 75 ran out of time', t.book('ROCK', 'GC-ROCK0002', '2031-07-04', null, 10));

-- TENTS (5 good-for-4)
select t.as_guest('LA3 with all 5 good-for-4 tents', t.book('LA3', 'GC-TENT0001', '2031-08-01', 1, 4, 'tents_for_4=5'));
select t.as_guest('LA4 wants 1 tent while LA3 is paying', t.book('LA4', 'GC-TENT0002', '2031-08-01', 1, 4, 'tents_for_4=1'));
select t.time_up('GC-TENT0001');
select t.as_guest('LA4 wants 1 tent after LA3 ran out of time', t.book('LA4', 'GC-TENT0002', '2031-08-01', 1, 4, 'tents_for_4=1'));

-- STAFF-ENTERED and permissions
insert into public.bookings (reference_number, activity_id, visit_date, nights, guest_name, contact_number, email,
  group_size, age_18_24, male_count, total_amount, amount_due, consent_given_at, source)
values ('GC-WALK0001', (select id from public.activities where code = 'CA1'), '2031-09-01', 1, 'Walk', '0917', 'w@trial.test', 2, 2, 2, 100, 50, now(), 'walk_in');
insert into t.results (test, result)
select 'walk-in timer', coalesce(hold_expires_at::text, 'no timer') from public.bookings where reference_number = 'GC-WALK0001';
select t.as_guest('guest calls release_expired_holds', 'select public.release_expired_holds()');
select t.as_guest('guest tries to set a long timer', t.book('CA2', 'GC-LONG0001', '2031-09-01', 1, 2, 'hold_expires_at=now() + interval ''1 day'''));
insert into t.results (test, result)
select 'long timer request became', (extract(epoch from hold_expires_at - now())::int)::text || ' seconds'
from public.bookings where reference_number = 'GC-LONG0001';
insert into t.results (test, result)
select 'discount_amount default', discount_amount::text from public.bookings where reference_number = 'GC-WALK0001';

select n, test, result from t.results order by n;
rollback;
