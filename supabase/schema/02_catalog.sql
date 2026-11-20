-- =====================================================================
-- 02 CATALOG
-- What guests can book: the camping areas and the rock activities package.
--
-- How it works:
--   * One row per thing guests can book (LA1, CA2, ROCK ...).
--   * type tells the system how it is booked:
--       camping       = per night, one group per area per night
--       rock_activity = per person, per day, with a daily limit
--   * Guests only see active rows. Staff see everything.
--   * Only the Super Admin can add, edit or hide (is_active = false). Nothing is deleted.
-- =====================================================================


create table public.activities (
  id                     uuid primary key default gen_random_uuid(),
  code                   text not null unique,        -- short code like LA1, ROCK
  name                   text not null,
  type                   text not null check (type in ('camping', 'rock_activity')),
  area_group             text,                         -- Lower Area, Upper Area ...
  description            text,
  price                  numeric(10,2) not null check (price >= 0),
  price_unit             text not null check (price_unit in ('per_night', 'per_person')),
  per_person_price       numeric(10,2) not null default 0 check (per_person_price >= 0),  -- camping: ₱100 per person
  capacity               integer check (capacity > 0),                 -- rock: people at one time (gear sets)
  requires_down_payment  boolean not null default true,
  down_payment_percent   numeric(5,2) not null default 50 check (down_payment_percent >= 0 and down_payment_percent <= 100),
  advance_notice_days    integer not null default 2 check (advance_notice_days >= 0),
  is_active              boolean not null default true,  -- false = hidden from guests
  created_at             timestamptz not null default now(),
  viewing_price          numeric(10,2) check (viewing_price >= 0),     -- rock: price for people who only watch
  min_age                integer check (min_age >= 0),                 -- rock: 10 and up
  daily_capacity         integer check (daily_capacity > 0),           -- rock: max people per day (80)
  category               text,                                          -- label the Super Admin types
  image_url              text                                           -- link to the activity photo
);


-- Time slots: not used by Goatcliff (rock is booked by date only). I keep the table for later.
create table public.activity_time_slots (
  id           uuid primary key default gen_random_uuid(),
  activity_id  uuid not null references public.activities (id),
  start_time   time not null,
  end_time     time not null,
  capacity     integer check (capacity > 0),
  is_active    boolean not null default true,
  created_at   timestamptz not null default now(),
  check (end_time > start_time),
  unique (activity_id, start_time)
);


-- ---------------------------------------------------------------------
-- Access rules
-- ---------------------------------------------------------------------
alter table public.activities enable row level security;
alter table public.activity_time_slots enable row level security;   -- no rules = fully locked

-- Everyone (guests too) can see the activities that are not hidden.
create policy "Public can view active activities" on public.activities
  for select to anon, authenticated
  using (is_active = true);

-- Any staff member can also see hidden ones.
create policy "Admins can view all activities" on public.activities
  for select to authenticated
  using (public.current_admin_role() is not null);

-- Only the Super Admin can add and edit.
create policy "Super Admin can add activities" on public.activities
  for insert to authenticated
  with check (public.current_admin_role() = 'super_admin');

create policy "Super Admin can edit activities" on public.activities
  for update to authenticated
  using (public.current_admin_role() = 'super_admin')
  with check (public.current_admin_role() = 'super_admin');


-- ---------------------------------------------------------------------
-- Goatcliff's price list (only for a NEW, empty database; dev already has it)
-- Camping: area price per night + ₱100 per person.
-- Rock: ₱1,500 per person, 50 at a time, 80 per day, viewing ₱250, ages 10 and up.
-- ---------------------------------------------------------------------
insert into public.activities (code, name, type, area_group, description, price, price_unit, per_person_price) values
  ('LA1', 'Lower Area 1',       'camping', 'Lower Area',       '30 ft x 29 ft', 2000, 'per_night', 100),
  ('LA2', 'Lower Area 2',       'camping', 'Lower Area',       '37 ft x 26 ft', 2000, 'per_night', 100),
  ('LA3', 'Lower Area 3',       'camping', 'Lower Area',       '28 ft x 21 ft', 1500, 'per_night', 100),
  ('LA4', 'Lower Area 4',       'camping', 'Lower Area',       'Front 29 ft, back 21 ft, right 14 ft, left 21 ft', 1000, 'per_night', 100),
  ('UA3', 'Upper Area 3',       'camping', 'Upper Area',       '26 ft x 8 ft',   500, 'per_night', 100),
  ('UA4', 'Upper Area 4',       'camping', 'Upper Area',       '33 ft x 8 ft',   500, 'per_night', 100),
  ('UA5', 'Upper Area 5',       'camping', 'Upper Area',       '43 ft x 14 ft', 1500, 'per_night', 100),
  ('UT',  'Under the Tree',     'camping', 'Under the Tree',   '13 ft x 12 ft',  500, 'per_night', 100),
  ('CA1', 'Car Camping Area 1', 'camping', 'Car Camping Area', '20 ft x 28 ft', 2000, 'per_night', 100),
  ('CA2', 'Car Camping Area 2', 'camping', 'Car Camping Area', '20 ft x 28 ft', 2000, 'per_night', 100),
  ('CA3', 'Car Camping Area 3', 'camping', 'Car Camping Area', '20 ft x 28 ft', 1500, 'per_night', 100),
  ('CA4', 'Car Camping Area 4', 'camping', 'Car Camping Area', '20 ft x 28 ft', 1000, 'per_night', 100);

insert into public.activities (code, name, type, description, price, price_unit, per_person_price,
                               capacity, daily_capacity, viewing_price, min_age) values
  ('ROCK', 'Rock Activities Package', 'rock_activity',
   'Via Ferrata (unlimited rounds), Rappelling (3 rounds), Zipline, Burmese Bridge, and Tyrolean Traverse (unlimited rounds). Safety gear and guide assistance included. Weather dependent: please arrive early.',
   1500, 'per_person', 0, 50, 80, 250, 10);
