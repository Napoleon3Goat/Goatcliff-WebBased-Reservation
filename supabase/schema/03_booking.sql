-- =====================================================================
-- 03 BOOKING
-- One row = one booking: one camping area for some nights, or the rock for one day.
--
-- How it works:
--   * Guests book online; staff enter walk-in, Messenger and phone bookings.
--   * The table itself refuses bad data (negative amounts, counts that don't add up ...).
--   * The database writes down which staff member entered a booking (created_by).
--   * Guests can only ADD an online, unpaid booking. They can't read bookings back,
--     except their own one through "Check my booking" (reference number + email).
--   * Nothing is ever deleted; staff change the status instead.
--   (The "no double booking" and "daily limit" rules are in 04_availability.)
-- =====================================================================


create table public.bookings (
  id                 uuid primary key default gen_random_uuid(),
  reference_number   text not null unique default 'GC-' || upper(substr(md5(random()::text), 1, 8)),

  -- what and when
  activity_id        uuid not null references public.activities (id),
  time_slot_id       uuid references public.activity_time_slots (id),   -- not used by Goatcliff
  visit_date         date not null,
  nights             integer check (nights >= 1),                          -- camping only; empty for rock

  -- who
  guest_name         text not null,
  companions_names   text[],                                               -- a list of names
  contact_number     text not null,
  email              text not null,
  guest_account_id   uuid references public.guest_accounts (id),           -- for January (customer logins)

  -- the group
  group_size         integer not null check (group_size >= 1),
  viewing_count      integer not null default 0 check (viewing_count >= 0),  -- rock: people who only watch

  -- discounts (how many people get each one)
  senior_count       integer not null default 0 check (senior_count >= 0),
  pwd_count          integer not null default 0 check (pwd_count >= 0),
  child_count        integer not null default 0 check (child_count >= 0),
  local_count        integer not null default 0 check (local_count >= 0),     -- Atok locals
  is_organizer       boolean not null default false,                           -- organizer group: 20% off

  -- money (the website calculates these)
  total_amount       numeric(10,2) not null check (total_amount >= 0),
  amount_due         numeric(10,2) not null check (amount_due >= 0),           -- the 50% down payment
  amount_paid        numeric(10,2) not null default 0 check (amount_paid >= 0),

  -- status
  payment_status     text not null default 'pending'
                     check (payment_status in ('pending', 'down_payment', 'paid', 'expired', 'refunded')),
  attendance_status  text not null default 'upcoming'
                     check (attendance_status in ('upcoming', 'done', 'failed_to_show', 'cancelled')),
  hold_expires_at    timestamptz,                                              -- 15-minute hold (Capstone 2)

  -- where the booking came from
  source             text not null default 'online'
                     check (source in ('online', 'walk_in', 'messenger', 'phone')),
  capacity_override  boolean not null default false,   -- staff accept more people on a full day

  created_at         timestamptz not null default now(),
  consent_given_at   timestamptz not null,             -- when they ticked the privacy notice (required)
  created_by         uuid references public.admin_accounts (id),   -- staff who entered it; empty = online

  -- extra details from the interview
  province                  text,
  found_us                  text check (found_us in ('tiktok', 'facebook', 'friends_family', 'google', 'other')),
  emergency_contact_name    text,
  emergency_contact_number  text,

  -- how many people in each age group, and male / female
  age_0_7       integer not null default 0 check (age_0_7 >= 0),
  age_8_17      integer not null default 0 check (age_8_17 >= 0),
  age_18_24     integer not null default 0 check (age_18_24 >= 0),
  age_25_34     integer not null default 0 check (age_25_34 >= 0),
  age_35_44     integer not null default 0 check (age_35_44 >= 0),
  age_45_59     integer not null default 0 check (age_45_59 >= 0),
  age_60_up     integer not null default 0 check (age_60_up >= 0),
  male_count    integer not null default 0 check (male_count >= 0),
  female_count  integer not null default 0 check (female_count >= 0),

  -- tent rental (camping only): 5 tents good for 4, 3 tents good for 2
  tents_for_4   integer not null default 0 check (tents_for_4 between 0 and 5),
  tents_for_2   integer not null default 0 check (tents_for_2 between 0 and 3),


  -- ----- rules that look at more than one column -----

  -- each discount count can't be bigger than the group
  check (senior_count <= group_size and pwd_count <= group_size
         and child_count <= group_size and local_count <= group_size),

  -- a booking has nights (camping) or a time slot, never both
  check (nights is null or time_slot_id is null),

  -- one discount per person: all discounts together can't be more than the group
  constraint one_discount_per_person
    check (senior_count + pwd_count + child_count + local_count <= group_size),

  -- viewers are part of the group
  constraint viewing_within_group
    check (viewing_count <= group_size),

  -- only staff-entered bookings may go over the daily limit
  constraint override_staff_entered_only
    check (capacity_override = false or source <> 'online'),

  -- the age groups must add up to the group size
  constraint ages_match_group
    check (age_0_7 + age_8_17 + age_18_24 + age_25_34 + age_35_44 + age_45_59 + age_60_up = group_size),

  -- male + female must add up to the group size
  constraint sexes_match_group
    check (male_count + female_count = group_size),

  -- tents only on camping bookings (camping bookings have nights)
  constraint tents_camping_only
    check ((tents_for_4 = 0 and tents_for_2 = 0) or nights is not null)
);


-- Indexes for the common searches.
create index bookings_activity_id_visit_date_idx on public.bookings (activity_id, visit_date);  -- "who is booked on this day?"
create index bookings_time_slot_id_idx           on public.bookings (time_slot_id);
create index bookings_guest_account_id_idx       on public.bookings (guest_account_id);
create index bookings_created_by_idx             on public.bookings (created_by);


-- ---------------------------------------------------------------------
-- Write down which staff member entered the booking.
-- Before a booking is saved, I look up who is logged in.
-- A guest isn't staff, so it stays empty (= booked online).
-- I overwrite whatever the website sent, so nobody can fake it.
-- ---------------------------------------------------------------------
create function public.set_booking_created_by()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  new.created_by := (select id from public.admin_accounts where auth_user_id = auth.uid());
  return new;
end;
$$;

revoke execute on function public.set_booking_created_by() from public, anon, authenticated;

create trigger set_created_by
  before insert on public.bookings
  for each row execute function public.set_booking_created_by();


-- ---------------------------------------------------------------------
-- "Check my booking": the guest types the reference number + email.
-- Both must match. It shows only that one booking, with no contact details.
-- ---------------------------------------------------------------------
create function public.lookup_booking(p_reference text, p_email text)
returns table (reference_number text, activity text, visit_date date, nights int, group_size int,
               total_amount numeric, amount_due numeric, amount_paid numeric,
               payment_status text, attendance_status text)
language sql
stable
security definer
set search_path = ''
as $$
  select b.reference_number, a.name, b.visit_date, b.nights, b.group_size,
         b.total_amount, b.amount_due, b.amount_paid, b.payment_status, b.attendance_status
  from public.bookings b
  join public.activities a on a.id = b.activity_id
  where b.reference_number = upper(trim(p_reference))
    and lower(b.email) = lower(trim(p_email))
$$;

grant execute on function public.lookup_booking(text, text) to anon, authenticated;


-- ---------------------------------------------------------------------
-- Access rules
-- managers = Super Admin + Staff Admin
-- ---------------------------------------------------------------------
alter table public.bookings enable row level security;

-- Guests (and anyone) may only ADD an online, unpaid booking with no special settings.
create policy "Guests can create online bookings" on public.bookings
  for insert to anon, authenticated
  with check (source = 'online'
              and payment_status = 'pending'
              and attendance_status = 'upcoming'
              and amount_paid = 0
              and capacity_override = false
              and is_organizer = false);

-- Managers can see, add (walk-in, Messenger, phone) and change bookings.
create policy "Managers can view all bookings" on public.bookings
  for select to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can create walk-in bookings" on public.bookings
  for insert to authenticated
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

create policy "Managers can update bookings" on public.bookings
  for update to authenticated
  using (public.current_admin_role() in ('super_admin', 'staff_admin'))
  with check (public.current_admin_role() in ('super_admin', 'staff_admin'));

-- Field Staff can see every booking (they only mark attendance; see 06).
create policy "Field Staff can view all bookings" on public.bookings
  for select to authenticated
  using (public.current_admin_role() = 'field_staff');
