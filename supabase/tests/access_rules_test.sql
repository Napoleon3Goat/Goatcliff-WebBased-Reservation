-- access_rules_test.sql
-- Proves the access rules work for each role. Run in the DEV project's SQL Editor.
-- Each round creates pretend staff and bookings, "logs in" as one person, tries actions,
-- then ends with "TRIAL UNDONE >> ..." which undoes everything. That error is intentional:
-- read the results after ">>". Nothing is left behind.

-- ROUND 1: Field Staff A
-- Expected: sees 1 booking | own group done: 1 row | B's group: 0 rows | reassign: REFUSED | payment: REFUSED
do $$
declare
  u_super uuid := '00000000-0000-0000-0000-0000000000a1';
  u_staff uuid := '00000000-0000-0000-0000-0000000000a2';
  u_fa    uuid := '00000000-0000-0000-0000-0000000000a3';
  u_fb    uuid := '00000000-0000-0000-0000-0000000000a4';
  a_fa uuid; a_fb uuid; b1 uuid; b2 uuid;
  n int; res text := '';
begin
  insert into auth.users (id, email) values
    (u_super, 'super@trial.test'), (u_staff, 'staff@trial.test'),
    (u_fa, 'fielda@trial.test'), (u_fb, 'fieldb@trial.test');
  insert into public.admin_accounts (auth_user_id, name, role) values
    (u_super, 'Trial Super Admin', 'super_admin'), (u_staff, 'Trial Staff Admin', 'staff_admin');
  insert into public.admin_accounts (auth_user_id, name, role) values (u_fa, 'Trial Field Staff A', 'field_staff') returning id into a_fa;
  insert into public.admin_accounts (auth_user_id, name, role) values (u_fb, 'Trial Field Staff B', 'field_staff') returning id into a_fb;
  insert into public.bookings (activity_id, visit_date, nights, guest_name, contact_number, email, group_size, total_amount, amount_due, assigned_field_staff_id)
    values ((select id from public.activities where code = 'LA1'), '2026-12-10', 1, 'Group of A', '0917', 'a@trial.test', 3, 2300, 1150, a_fa) returning id into b1;
  insert into public.bookings (activity_id, visit_date, nights, guest_name, contact_number, email, group_size, total_amount, amount_due, assigned_field_staff_id)
    values ((select id from public.activities where code = 'LA2'), '2026-12-10', 1, 'Group of B', '0918', 'b@trial.test', 2, 2200, 1100, a_fb) returning id into b2;

  perform set_config('request.jwt.claims', json_build_object('sub', u_fa, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into n from public.bookings;
  res := res || '1) Sees ' || n || ' booking(s) | ';
  update public.bookings set attendance_status = 'done' where id = b1;
  get diagnostics n = row_count;
  res := res || '2) Mark OWN group done: ' || n || ' row changed | ';
  update public.bookings set attendance_status = 'done' where id = b2;
  get diagnostics n = row_count;
  res := res || '3) Mark B''s group done: ' || n || ' rows changed | ';
  begin
    update public.bookings set assigned_field_staff_id = a_fb where id = b1;
    res := res || '4) Reassign own group to B: ALLOWED | ';
  exception when others then
    res := res || '4) Reassign own group to B: REFUSED (' || sqlerrm || ') | ';
  end;
  begin
    insert into public.payments (booking_id, amount, purpose, method) values (b1, 1150, 'down_payment', 'cash');
    res := res || '5) Record a payment: ALLOWED';
  exception when others then
    res := res || '5) Record a payment: REFUSED (' || sqlerrm || ')';
  end;

  execute 'reset role';
  raise exception 'TRIAL UNDONE >> %', res;
end $$;

-- ROUND 2: Staff Admin
-- Expected: sees 2 bookings | payment: ALLOWED | add activity: REFUSED | sees 1 staff account
do $$
declare
  u_super uuid := '00000000-0000-0000-0000-0000000000a1';
  u_staff uuid := '00000000-0000-0000-0000-0000000000a2';
  u_fa    uuid := '00000000-0000-0000-0000-0000000000a3';
  u_fb    uuid := '00000000-0000-0000-0000-0000000000a4';
  a_fa uuid; a_fb uuid; b1 uuid; b2 uuid;
  n int; res text := '';
begin
  insert into auth.users (id, email) values
    (u_super, 'super@trial.test'), (u_staff, 'staff@trial.test'),
    (u_fa, 'fielda@trial.test'), (u_fb, 'fieldb@trial.test');
  insert into public.admin_accounts (auth_user_id, name, role) values
    (u_super, 'Trial Super Admin', 'super_admin'), (u_staff, 'Trial Staff Admin', 'staff_admin');
  insert into public.admin_accounts (auth_user_id, name, role) values (u_fa, 'Trial Field Staff A', 'field_staff') returning id into a_fa;
  insert into public.admin_accounts (auth_user_id, name, role) values (u_fb, 'Trial Field Staff B', 'field_staff') returning id into a_fb;
  insert into public.bookings (activity_id, visit_date, nights, guest_name, contact_number, email, group_size, total_amount, amount_due, assigned_field_staff_id)
    values ((select id from public.activities where code = 'LA1'), '2026-12-10', 1, 'Group of A', '0917', 'a@trial.test', 3, 2300, 1150, a_fa) returning id into b1;
  insert into public.bookings (activity_id, visit_date, nights, guest_name, contact_number, email, group_size, total_amount, amount_due, assigned_field_staff_id)
    values ((select id from public.activities where code = 'LA2'), '2026-12-10', 1, 'Group of B', '0918', 'b@trial.test', 2, 2200, 1100, a_fb) returning id into b2;

  perform set_config('request.jwt.claims', json_build_object('sub', u_staff, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  select count(*) into n from public.bookings;
  res := res || '1) Sees ' || n || ' booking(s) | ';
  begin
    insert into public.payments (booking_id, amount, purpose, method, status, paid_at) values (b1, 1150, 'down_payment', 'gcash', 'confirmed', now());
    res := res || '2) Record a payment: ALLOWED | ';
  exception when others then
    res := res || '2) Record a payment: REFUSED (' || sqlerrm || ') | ';
  end;
  begin
    insert into public.activities (code, name, type, price, price_unit) values ('PICNIC', 'Picnic Area', 'camping', 300, 'per_night');
    res := res || '3) Add an activity: ALLOWED | ';
  exception when others then
    res := res || '3) Add an activity: REFUSED (' || sqlerrm || ') | ';
  end;
  select count(*) into n from public.admin_accounts;
  res := res || '4) Sees ' || n || ' staff account(s)';

  execute 'reset role';
  raise exception 'TRIAL UNDONE >> %', res;
end $$;

-- ROUND 3: Super Admin
-- Expected: add activity: ALLOWED | hide it: 1 row | sees 4 staff accounts
do $$
declare
  u_super uuid := '00000000-0000-0000-0000-0000000000a1';
  u_staff uuid := '00000000-0000-0000-0000-0000000000a2';
  u_fa    uuid := '00000000-0000-0000-0000-0000000000a3';
  u_fb    uuid := '00000000-0000-0000-0000-0000000000a4';
  n int; res text := '';
begin
  insert into auth.users (id, email) values
    (u_super, 'super@trial.test'), (u_staff, 'staff@trial.test'),
    (u_fa, 'fielda@trial.test'), (u_fb, 'fieldb@trial.test');
  insert into public.admin_accounts (auth_user_id, name, role) values
    (u_super, 'Trial Super Admin', 'super_admin'), (u_staff, 'Trial Staff Admin', 'staff_admin'),
    (u_fa, 'Trial Field Staff A', 'field_staff'), (u_fb, 'Trial Field Staff B', 'field_staff');

  perform set_config('request.jwt.claims', json_build_object('sub', u_super, 'role', 'authenticated')::text, true);
  execute 'set local role authenticated';

  begin
    insert into public.activities (code, name, type, price, price_unit) values ('PICNIC', 'Picnic Area', 'camping', 300, 'per_night');
    res := res || '1) Add an activity: ALLOWED | ';
  exception when others then
    res := res || '1) Add an activity: REFUSED (' || sqlerrm || ') | ';
  end;
  update public.activities set is_active = false where code = 'PICNIC';
  get diagnostics n = row_count;
  res := res || '2) Hide that activity: ' || n || ' row changed | ';
  select count(*) into n from public.admin_accounts;
  res := res || '3) Sees ' || n || ' staff account(s)';

  execute 'reset role';
  raise exception 'TRIAL UNDONE >> %', res;
end $$;
