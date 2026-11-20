-- =====================================================================
-- 01 USERS AND ACCESS
-- Who can log in, what role they have, and the helper every access rule uses.
--
-- How it works:
--   * Staff log in with Supabase Auth (the built-in auth.users table).
--   * My admin_accounts table links each login to ONE role:
--     super_admin, staff_admin or field_staff.
--   * current_admin_role() answers "what role is the person logged in right now?"
--     Every access rule in the other files asks this question.
--   * There must always be at least one active Super Admin.
-- =====================================================================


-- ---------------------------------------------------------------------
-- Staff accounts
-- ---------------------------------------------------------------------
create table public.admin_accounts (
  id            uuid primary key default gen_random_uuid(),
  auth_user_id  uuid not null unique references auth.users (id) on delete cascade,  -- the login
  name          text not null,
  role          text not null check (role in ('super_admin', 'staff_admin', 'field_staff')),
  is_active     boolean not null default true,   -- false = turned off, can't do anything
  created_at    timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- Guest accounts (for January: customer logins). Not used yet, but I keep the table.
-- ---------------------------------------------------------------------
create table public.guest_accounts (
  id                uuid primary key default gen_random_uuid(),
  auth_user_id      uuid unique references auth.users (id) on delete set null,
  name              text not null,
  email             text not null unique,
  contact_number    text,
  consent_given_at  timestamptz not null,
  created_at        timestamptz not null default now()
);


-- ---------------------------------------------------------------------
-- Helper: "what role is the logged-in person?"
-- Gives back super_admin / staff_admin / field_staff, or nothing for guests
-- and for staff who were turned off.
-- security definer so it can read admin_accounts (that table is locked).
-- ---------------------------------------------------------------------
create function public.current_admin_role()
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select role
  from public.admin_accounts
  where auth_user_id = auth.uid()   -- auth.uid() = whoever's logged in
    and is_active
$$;

-- Guests never need this; logged-in users do (the access rules call it).
revoke execute on function public.current_admin_role() from public, anon;


-- ---------------------------------------------------------------------
-- Rule: always keep at least one active Super Admin.
-- Before a staff row is changed or deleted, I check:
--   is this person an active Super Admin, and would this change remove that?
--   if yes, and nobody else is an active Super Admin, I refuse.
-- ---------------------------------------------------------------------
create function public.keep_one_super_admin()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- Step 1. Was this person an active Super Admin? If not, there's nothing to protect.
  if old.role = 'super_admin' and old.is_active then

    -- Step 2. Does this change take that away? (deleted, demoted, or turned off)
    if tg_op = 'DELETE' or new.role <> 'super_admin' or not new.is_active then

      -- Step 3. Is somebody else still an active Super Admin? If not, I refuse.
      if not exists (select 1 from public.admin_accounts
                     where role = 'super_admin'
                       and is_active
                       and id <> old.id) then
        raise exception 'LAST_SUPER_ADMIN: add or activate another Super Admin first.';
      end if;

    end if;
  end if;

  -- Step 4. Let the change through.
  --         (delete returns the old row, update returns the new one)
  if tg_op = 'DELETE' then
    return old;
  end if;
  return new;
end;
$$;

-- Only the database runs this (as a trigger), never the website.
revoke execute on function public.keep_one_super_admin() from public, anon, authenticated;

create trigger keep_one_super_admin
  before update or delete on public.admin_accounts
  for each row execute function public.keep_one_super_admin();


-- ---------------------------------------------------------------------
-- Access rules
-- Every table starts locked; each policy opens one door for one role.
-- guest_accounts has no rules yet, so it stays fully locked.
-- ---------------------------------------------------------------------
alter table public.admin_accounts enable row level security;
alter table public.guest_accounts enable row level security;

-- Every staff member can see their own account (the login page needs this).
create policy "Staff can see their own account" on public.admin_accounts
  for select to authenticated
  using (auth_user_id = auth.uid());

-- Only the Super Admin can see, add and edit all staff.
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
