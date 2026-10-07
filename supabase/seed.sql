-- seed.sql: Goatcliff's starting data (official price list).
-- Run AFTER the migrations. Contains no personal data.

insert into public.activities
  (code, name, type, area_group, description, price, price_unit, per_person_price)
values
  ('LA1', 'Lower Area 1',      'camping', 'Lower Area',       '30 ft x 29 ft', 2000, 'per_night', 100),
  ('LA2', 'Lower Area 2',      'camping', 'Lower Area',       '37 ft x 26 ft', 2000, 'per_night', 100),
  ('LA3', 'Lower Area 3',      'camping', 'Lower Area',       '28 ft x 21 ft', 1500, 'per_night', 100),
  ('LA4', 'Lower Area 4',      'camping', 'Lower Area',       'Front 29 ft, back 21 ft, right 14 ft, left 21 ft', 1000, 'per_night', 100),
  ('UA1', 'Upper Area 1',      'camping', 'Upper Area',       '16 ft x 14 ft', 1500, 'per_night', 100),
  ('UA2', 'Upper Area 2',      'camping', 'Upper Area',       '18 ft x 12 ft', 1000, 'per_night', 100),
  ('UA3', 'Upper Area 3',      'camping', 'Upper Area',       '26 ft x 8 ft',   500, 'per_night', 100),
  ('UA4', 'Upper Area 4',      'camping', 'Upper Area',       '33 ft x 8 ft',   500, 'per_night', 100),
  ('UA5', 'Upper Area 5',      'camping', 'Upper Area',       '43 ft x 14 ft', 1500, 'per_night', 100),
  ('UT',  'Under the Tree',    'camping', 'Under the Tree',   '13 ft x 12 ft',  500, 'per_night', 100),
  ('CA1', 'Car Camping Area 1','camping', 'Car Camping Area', '20 ft x 28 ft', 2000, 'per_night', 100),
  ('CA2', 'Car Camping Area 2','camping', 'Car Camping Area', '20 ft x 28 ft', 2000, 'per_night', 100),
  ('CA3', 'Car Camping Area 3','camping', 'Car Camping Area', '20 ft x 28 ft', 1500, 'per_night', 100),
  ('CA4', 'Car Camping Area 4','camping', 'Car Camping Area', '20 ft x 28 ft', 1000, 'per_night', 100);

insert into public.activities
  (code, name, type, description, price, price_unit, per_person_price,
   capacity, daily_capacity, viewing_price, min_age)
values
  ('ROCK', 'Rock Activities Package', 'rock_activity',
   'Via Ferrata (unlimited rounds), Rappelling (3 rounds), Zipline, Burmese Bridge, and Tyrolean Traverse (unlimited rounds). Safety gear and guide assistance included. Weather dependent: please arrive early.',
   1500, 'per_person', 0, 50, 150, 250, 10);
