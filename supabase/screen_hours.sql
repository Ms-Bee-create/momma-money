-- Screen time hours you can change from the app (Manage tab). Run once in the Supabase SQL editor. Safe to run again.
-- Without it the app uses its built-in hours: weekdays 7pm-8:30pm, Saturdays 3pm-6pm, Sundays 7pm-8:30pm, and a limit of 2 hours a day.
alter table public.households add column if not exists screen_hours jsonb;
