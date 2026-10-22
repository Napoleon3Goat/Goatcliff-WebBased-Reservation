-- 20261022000001_access_rules.sql
-- Access rules (RLS policies) for guests, Field Staff, Staff Admin and Super Admin.

-- Step 1: "what's my role?" helper used by every admin rule.
-- Returns the logged-in person's role, or nothing for guests and deactivated staff.
create or replace function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.admin_accounts
  where auth_user_id = auth.uid()
    and is_active
$$;

revoke execute on function public.current_admin_role() from public, anon;

-- Step 2: guests.
-- Guests can create a normal online booking only (no "paid", walk-in, override or assigned staff).
-- There is no rule letting guests read bookings, so they cannot see anyone's details.
create policy "Guests can create online bookings"
  on public.bookings
  for insert
  to anon, authenticated
  with check (
    source = 'online'
    and payment_status = 'pending'
    and attendance_status = 'upcoming'
    and amount_paid = 0
    and capacity_override = false
    and assigned_field_staff_id is null
  );

-- The calendar's window into bookings: dates and headcounts only, never names or contact details.
create or replace function public.booked_dates(p_activity_id uuid, p_from date, p_to date)
returns table (visit_date date, nights integer, people integer)
language sql
stable
security definer
set search_path = ''
as $$
  select b.visit_date, b.nights, b.group_size
  from public.bookings b
  where b.activity_id = p_activity_id
    and b.visit_date <= p_to
    and b.visit_date + coalesce(b.nights, 1) > p_from
    and b.payment_status in ('pending', 'down_payment', 'paid')
    and b.attendance_status <> 'cancelled'
$$;

grant execute on function public.booked_dates(uuid, date, date) to anon, authenticated;

-- Step 3: admins.
-- "What's my staff ID?" helper: used only for Field Staff seeing their own assigned groups.
create or replace function public.current_admin_id()
returns uuid
language sql
stable
security definer
set search_path = ''
as $$
  select id from public.admin_accounts
  where auth_user_id = auth.uid() and is_active
$$;

revoke execute on function public.current_admin_id() from public, anon;

-- activities: all admins see everything; only the Super Admin adds or edits (hiding = edit is_active)
create policy "Admins can view all activities" on public.activities
  for select to authenticated
  using (public.current_admin_role() is not null);

create policy "Super Admin can add activities" on public.activities
  for insert to authenticated
  with check (public.current_admin_role() = 'super_admin');

create policy "Super Admin can edit activities" on public.activities
  for update to authenticated
  using (public.current_admin_role() = 'super_admin')
  with check (public.current_admin_role() = 'super_admin');

-- bookings: managers see and change everything; Field Staff only their assigned groups
create policy "Managers can view all bookings" on public.bookings
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Field Staff can view their assigned groups" on public.bookings
  for select to authenticated
  using (public.current_admin_role() = 'field_staff'
         and assigned_field_staff_id = public.current_admin_id());

create policy "Managers can create walk-in bookings" on public.bookings
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can update bookings" on public.bookings
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Field Staff can update their assigned groups" on public.bookings
  for update to authenticated
  using (public.current_admin_role() = 'field_staff'
         and assigned_field_staff_id = public.current_admin_id())
  with check (public.current_admin_role() = 'field_staff'
              and assigned_field_staff_id = public.current_admin_id());

-- payments: managers only
create policy "Managers can view payments" on public.payments
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can record payments" on public.payments
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can update payments" on public.payments
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

-- cancellations: managers only
create policy "Managers can view cancellations" on public.cancellations
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can record cancellations" on public.cancellations
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can update cancellations" on public.cancellations
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

-- date_overrides (closed days, changed caps): managers only
create policy "Managers can view date overrides" on public.date_overrides
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can set date overrides" on public.date_overrides
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));
create policy "Managers can update date overrides" on public.date_overrides
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

-- admin_accounts: everyone sees their own record; only the Super Admin manages staff
create policy "Staff can see their own account" on public.admin_accounts
  for select to authenticated
  using (auth_user_id = auth.uid());

create policy "Super Admin can see all staff" on public.admin_accounts
  for select to authenticated
  using (public.current_admin_role() = 'super_admin');

create policy "Super Admin can add staff" on public.admin_accounts
  for insert to authenticated
  with check (public.current_admin_role() = 'super_admin');

create policy "Super Admin can edit staff" on public.admin_accounts
  for update to authenticated
  using (public.current_admin_role() = 'super_admin')
  with check (public.current_admin_role() = 'super_admin');
