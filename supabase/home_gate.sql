-- Shop lock: the Shop (buying) and starting screen time stay locked until a kid's morning and
-- after-school Home Quest jobs are done, and then only during store hours.
-- Run once in the Supabase SQL editor. Safe to run again.
alter table public.households add column if not exists home_gate boolean not null default true;
alter table public.households add column if not exists home_gate_open_day date;
