-- Instant alerts for the Banker: tell Supabase to push changes to Home Quest jobs and requests as they happen.
-- Run once in the Supabase SQL editor. Safe to run again.
do $$
begin
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'home_job_logs') then
    alter publication supabase_realtime add table public.home_job_logs;
  end if;
  if not exists (select 1 from pg_publication_tables where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'transactions') then
    alter publication supabase_realtime add table public.transactions;
  end if;
end $$;
