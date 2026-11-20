-- Tests for the GCash / Maya details. Everything is rolled back at the end.
-- I only run this on a PRACTICE database, never on dev or prod.
begin;
create schema t;
create table t.results (n serial, test text, result text);
grant usage on schema t to anon, authenticated;
grant insert on t.results to anon, authenticated;
grant usage on sequence t.results_n_seq to anon, authenticated;

-- run a statement as a guest (uid null) or as a logged-in person (uid)
create function t.run(label text, uid text, stmt text) returns void language plpgsql as $$
declare rows_hit int;
begin
  if uid is null then
    execute 'set local role anon';
  else
    perform set_config('request.jwt.claims', json_build_object('sub', uid, 'role', 'authenticated')::text, true);
    execute 'set local role authenticated';
  end if;
  begin
    execute stmt;
    get diagnostics rows_hit = row_count;
    insert into t.results (test, result) values (label, 'OK, rows: ' || rows_hit);
  exception when others then
    insert into t.results (test, result) values (label, sqlerrm);
  end;
  execute 'reset role';
end $$;

insert into auth.users (id, email) values
  ('00000000-0000-0000-0000-00000000aa01', 'sa@trial.test'),
  ('00000000-0000-0000-0000-00000000aa02', 'staff@trial.test');
insert into public.admin_accounts (id, auth_user_id, name, role) values
  ('00000000-0000-0000-0000-0000000000b1', '00000000-0000-0000-0000-00000000aa01', 'SA', 'super_admin'),
  ('00000000-0000-0000-0000-0000000000b2', '00000000-0000-0000-0000-00000000aa02', 'Staff', 'staff_admin');

select t.run('guest reads details', null, 'insert into t.results (test, result) select ''  guest sees'', string_agg(id, '','' order by id) from public.payment_wallets');
select t.run('guest changes the number', null, 'update public.payment_wallets set account_number = ''0999'' where id = ''gcash''');
select t.run('Staff Admin changes the number', '00000000-0000-0000-0000-00000000aa02', 'update public.payment_wallets set account_number = ''0999'' where id = ''gcash''');
select t.run('Super Admin changes the number', '00000000-0000-0000-0000-00000000aa01', 'update public.payment_wallets set account_number = ''0917 111 2222'' where id = ''gcash''');
select t.run('Super Admin turns Maya off', '00000000-0000-0000-0000-00000000aa01', 'update public.payment_wallets set is_active = false where id = ''maya''');
select t.run('guest reads details again', null, 'insert into t.results (test, result) select ''  guest sees'', string_agg(id || '' '' || account_number, '','' order by id) from public.payment_wallets');
select t.run('Super Admin still sees Maya', '00000000-0000-0000-0000-00000000aa01', 'insert into t.results (test, result) select ''  super admin sees'', string_agg(id, '','' order by id) from public.payment_wallets');
select t.run('Super Admin adds a 3rd wallet', '00000000-0000-0000-0000-00000000aa01', 'insert into public.payment_wallets (id, name, account_name, account_number) values (''gcash2'', ''X'', ''X'', ''X'')');
select t.run('Super Admin deletes GCash', '00000000-0000-0000-0000-00000000aa01', 'delete from public.payment_wallets where id = ''gcash''');
select t.run('guest uploads a QR', null, 'insert into storage.objects (bucket_id, name) values (''payment-qr'', ''fake.png'')');
select t.run('Staff Admin uploads a QR', '00000000-0000-0000-0000-00000000aa02', 'insert into storage.objects (bucket_id, name) values (''payment-qr'', ''staff.png'')');
select t.run('Super Admin uploads a QR', '00000000-0000-0000-0000-00000000aa01', 'insert into storage.objects (bucket_id, name) values (''payment-qr'', ''gcash-1.png'')');

select n, test, result from t.results order by n;
rollback;
