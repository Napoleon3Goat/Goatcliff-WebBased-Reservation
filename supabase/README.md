# Goatcliff database

## Rebuild the database from scratch
1. Run `migrations/` files in order (oldest first) in the Supabase SQL Editor.
2. Run `seed.sql`.
3. Create admin logins in Authentication → Users, then add them to `admin_accounts`.

## Rules
- Every database change = a NEW file in `migrations/` named `YYYYMMDDHHMMSS_short_name.sql`.
- Never edit a migration that has already been run.
- Try every change on the DEV project first, then on production.
- Never commit passwords, connection strings, or guest data.

## Folders
- `archive/` = the original step-by-step build files (reference only, do NOT run).
- `next-semester/` = chatbot tables, not yet run.

## Backups
Weekly and before every demo, with pg_dump (schema + data). Stored outside GitHub.
