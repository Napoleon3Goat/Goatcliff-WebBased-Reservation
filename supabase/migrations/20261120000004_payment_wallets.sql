-- =====================================================================
-- Goat Cliff's GCash and Maya details, editable by the Super Admin (Nov 20)
--
-- What this does:
--   * A small table with 2 rows (GCash, Maya): account name, number, QR image, on/off.
--   * Guests can read the ones that are on (the payment page shows them).
--   * Only the Super Admin can change them. Nobody can add or delete rows.
--   * QR images go in a public "payment-qr" bucket (guests need to see them to scan).
--     Only the Super Admin can upload them.
-- =====================================================================

begin;


create table public.payment_wallets (
  id              text primary key check (id in ('gcash', 'maya')),
  name            text not null,                   -- shown to guests: GCash / Maya
  account_name    text not null,                   -- the name on Goat Cliff's account
  account_number  text not null,                   -- the mobile number guests send to
  qr_path         text,                            -- the QR image in the payment-qr bucket (empty = none yet)
  is_active       boolean not null default true,   -- off = guests can't pick it
  updated_at      timestamptz not null default now(),
  updated_by      uuid references public.admin_accounts (id)   -- Super Admin who last changed it
);

create index payment_wallets_updated_by_idx on public.payment_wallets (updated_by);

-- Sample values for the demo. The Super Admin replaces them on the "Payment details" page.
insert into public.payment_wallets (id, name, account_name, account_number) values
  ('gcash', 'GCash', 'GOAT CLIFF ROCK ADVENTURES (sample)', '0900 000 0001'),
  ('maya',  'Maya',  'GOAT CLIFF ROCK ADVENTURES (sample)', '0900 000 0002');


-- ---------------------------------------------------------------------
-- Access rules
-- ---------------------------------------------------------------------
alter table public.payment_wallets enable row level security;

create policy "Guests can see payment details that are on" on public.payment_wallets
  for select to anon, authenticated
  using (is_active);

create policy "Super Admin can see all payment details" on public.payment_wallets
  for select to authenticated
  using (public.current_admin_role() = 'super_admin');

create policy "Super Admin can change payment details" on public.payment_wallets
  for update to authenticated
  using (public.current_admin_role() = 'super_admin')
  with check (public.current_admin_role() = 'super_admin');
-- (no insert or delete rules: there are always exactly these 2 rows)


-- ---------------------------------------------------------------------
-- QR images: public bucket, Super Admin uploads
-- (each upload gets a new file name, so nothing is overwritten)
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-qr', 'payment-qr', true, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "Super Admin can upload payment QR codes" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'payment-qr' and public.current_admin_role() = 'super_admin');

commit;
