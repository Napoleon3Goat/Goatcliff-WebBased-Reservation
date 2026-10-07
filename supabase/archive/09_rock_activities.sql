-- 09_rock_activities.sql

alter table public.activities
  add column viewing_price numeric(10,2) check (viewing_price >= 0),  -- for spectators; null = not offered
  add column min_age       integer check (min_age >= 0);              -- null = all ages

insert into public.activities
  (code, name, type, description, price, price_unit, per_person_price,
   capacity, viewing_price, min_age)
values
  ('ROCK', 'Rock Activities Package', 'rock_activity',
   'Via Ferrata (unlimited rounds), Rappelling (3 rounds), Zipline, Burmese Bridge, and Tyrolean Traverse (unlimited rounds). Safety gear and guide assistance included. Weather dependent: please arrive early.',
   1500, 'per_person', 0,
   50, 250, 10);
