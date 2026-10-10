-- A clock the kids can't change. Run once in the Supabase SQL editor (safe to run again).
-- Screen time, store hours and overtime use this instead of the device's clock, so setting the
-- computer's clock back no longer gives free minutes.
create or replace function public.server_time()
returns timestamptz
language sql
stable
as $$ select now() $$;

grant execute on function public.server_time() to anon, authenticated;
