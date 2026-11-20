-- =====================================================================
-- 08 PHOTOS (file storage)
-- Three "buckets" (folders) in Supabase Storage.
--
-- How it works:
--   * activity-photos: PUBLIC. Anyone can open a photo by its link.
--     Only the Super Admin can upload, replace or remove them.
--   * id-photos: PRIVATE. Guests upload one ID per discounted person
--     (named like GC-XXXXXXXX/senior-1.jpg), but can never open them.
--     Only Super Admin and Staff Admin can open and delete them (after checking).
--   * payment-receipts: PRIVATE. Guests upload their GCash / Maya receipt;
--     only Super Admin and Staff Admin can open them.
--   * All: images only (JPG, PNG, WebP), max 5 MB each.
-- =====================================================================


insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types) values
  ('activity-photos', 'activity-photos', true,  5242880, array['image/jpeg', 'image/png', 'image/webp']),
  ('id-photos',       'id-photos',       false, 5242880, array['image/jpeg', 'image/png', 'image/webp']);


-- ---------------------------------------------------------------------
-- Activity photos: Super Admin only (opening them needs no rule, the bucket is public)
-- ---------------------------------------------------------------------
create policy "Super Admin can upload activity photos" on storage.objects
  for insert to authenticated
  with check (bucket_id = 'activity-photos' and public.current_admin_role() = 'super_admin');

create policy "Super Admin can replace activity photos" on storage.objects
  for update to authenticated
  using (bucket_id = 'activity-photos' and public.current_admin_role() = 'super_admin');

create policy "Super Admin can remove activity photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'activity-photos' and public.current_admin_role() = 'super_admin');


-- ---------------------------------------------------------------------
-- ID photos: guests upload; only managers open and delete
-- ---------------------------------------------------------------------
create policy "Guests can upload ID photos" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'id-photos');

create policy "Managers can view ID photos" on storage.objects
  for select to authenticated
  using (bucket_id = 'id-photos' and public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can delete ID photos" on storage.objects
  for delete to authenticated
  using (bucket_id = 'id-photos' and public.current_admin_role() in ('super_admin', 'staff_admin'));


-- ---------------------------------------------------------------------
-- Receipt screenshots: a private bucket, like the ID photos.
-- Guests upload; only Super Admin and Staff Admin can open them.
-- ---------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('payment-receipts', 'payment-receipts', false, 5242880, array['image/jpeg', 'image/png', 'image/webp']);

create policy "Guests can upload payment receipts" on storage.objects
  for insert to anon, authenticated
  with check (bucket_id = 'payment-receipts');

create policy "Managers can view payment receipts" on storage.objects
  for select to authenticated
  using (bucket_id = 'payment-receipts' and public.current_admin_role() in ('super_admin', 'staff_admin'));
