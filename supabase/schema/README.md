# Goatcliff database: schema files

The whole Goatcliff database, one file per part. Each file starts with a short
"How it works" note, and I commented the code step by step.

## What's in each file

| File | What it covers |
|---|---|
| 01_users_and_access.sql | Admin accounts, guest accounts, "what's my role?", keep one Super Admin |
| 02_catalog.sql | Activities (camping areas + rock), prices, time slots |
| 03_booking.sql | The bookings table, who entered it, "Check my booking" |
| 04_availability.sql | Closed days / changed limits, double-booking block, daily limit, tents |
| 05_payments.sql | Payments (GCash / cash / bank) |
| 06_changes_and_attendance.sql | Reschedules, refunds, cancellations, marking attendance |
| 07_reports.sql | The 7 monthly report views |
| 08_photos.sql | Activity photos + ID photos (storage) |
| undo_update_dev.sql | Undo for migration 20261120000001, if anything goes wrong |

Related files elsewhere in `supabase/`:

| File | What it is |
|---|---|
| ../functions/create-staff/index.ts | The Edge Function that lets the Super Admin add staff logins |
| ../migrations/20261120000001_function_updates.sql | Updates dev's 9 functions + 2 report views to match these files |
| ../tests/behavior_test.sql | My test scenarios (practice database only) |

## Order

Run them 01 → 08. Booking (03) comes before Availability (04) because the
availability checks are attached to the bookings table, so the table has to exist first.

## When to use it

- To study and explain the backend (manuscript, defense).
- As the build for prod (on an EMPTY database).
- NOT on dev or prod as they are now. They already have all of this,
  and running it again would fail ("already exists").

## Not included

- `rls_auto_enable()`: a Supabase setting function that's in dev but isn't part of our system.
- The ROCK4 "treeclimbing" row: test data in dev.
- The 13 activity rows in 02 are only for a brand-new database. Prod gets its real prices separately.

Note: the -- comments on tables and access rules exist only in these files.
Supabase doesn't store them, so the dashboard shows tables and rules in its own format.
The comments inside functions are stored, so those show in Supabase.

## How I tested it

1. **Structure:** I built these files on a practice database and checked them against dev.

   | Piece | Count |
   |---|---|
   | Columns | 115 |
   | Constraints | 92 |
   | Indexes | 26 |
   | Access rules | 28 |
   | Triggers | 4 |
   | Report views | 7 |
   | Photo buckets | 2 |
   | Functions | 9 |

   Everything matched, with the same permissions.
2. **Behavior:** I ran 49 scenarios (tests/behavior_test.sql) and checked every result,
   including the error messages.
3. **The migration:** on a practice copy of dev, migration 20261120000001 made it
   match these files, and undo_update_dev.sql put it back.

The scenarios cover:
- The 80-person daily limit.
- A changed limit for one day.
- Expired vs active holds.
- Cancelled bookings.
- Closed and reopened days.
- Double booking.
- Tent stock.
- The calendar.
- "Check my booking".
- Who entered a booking.
- Attendance.
- The last Super Admin.
- Reports: messy province spellings and organizer counts.
