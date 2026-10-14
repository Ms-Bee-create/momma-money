-- Screen time hours you can change from the app (Manage tab). Run once in the Supabase SQL editor. Safe to run again.
-- Without it the app uses its built-in hours: weekdays 7pm-8:30pm, Saturdays 11am-6pm, Sundays 12pm-5pm.
alter table public.households add column if not exists screen_hours jsonb;
