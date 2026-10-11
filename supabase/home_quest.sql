-- Home Quest: a daily house routine with times and places, XP, and a level-up payout.
-- Run once in the Supabase SQL editor. Safe to run again (it never doubles the starter jobs).

-- Settings and each kid's progress ----------------------------------------------------------
alter table public.households add column if not exists home_auto_approve boolean not null default false;
alter table public.households add column if not exists home_xp_per_level int not null default 100;
alter table public.households add column if not exists home_level_bonus numeric(10,2) not null default 3;
alter table public.members add column if not exists home_xp int not null default 0;
alter table public.members add column if not exists home_level_paid int not null default 1;

-- The jobs ------------------------------------------------------------------------------------
create table if not exists public.home_jobs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  title text not null,
  emoji text not null default '⭐',
  place text,
  time_label text,
  slot text not null default 'morning' check (slot in ('morning', 'after_school', 'evening', 'weekend')),
  days int[] not null default '{1,2,3,4,5}',
  xp int not null default 5,
  sort int not null default 0,
  active boolean not null default true,
  created_at timestamptz not null default now()
);
create index if not exists home_jobs_household_idx on public.home_jobs (household_id);

-- One row each time a kid finishes a job (job_id is empty for the "perfect day" bonus) ---------
create table if not exists public.home_job_logs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  job_id uuid references public.home_jobs (id) on delete cascade,
  day date not null,
  note text,
  xp int not null default 0,
  status text not null default 'submitted' check (status in ('submitted', 'approved', 'rejected')),
  submitted_at timestamptz not null default now(),
  approved_at timestamptz,
  unique (job_id, day)
);
create index if not exists home_job_logs_household_idx on public.home_job_logs (household_id, day);
create unique index if not exists home_bonus_once on public.home_job_logs (member_id, day, note) where note is not null;

-- Same household-only access as every other table ----------------------------------------------
alter table public.home_jobs enable row level security;
alter table public.home_job_logs enable row level security;
drop policy if exists "home_jobs_select_own" on public.home_jobs;
drop policy if exists "home_jobs_insert_own" on public.home_jobs;
drop policy if exists "home_jobs_update_own" on public.home_jobs;
drop policy if exists "home_jobs_delete_own" on public.home_jobs;
create policy "home_jobs_select_own" on public.home_jobs for select using (auth.uid() = household_id);
create policy "home_jobs_insert_own" on public.home_jobs for insert with check (auth.uid() = household_id);
create policy "home_jobs_update_own" on public.home_jobs for update using (auth.uid() = household_id);
create policy "home_jobs_delete_own" on public.home_jobs for delete using (auth.uid() = household_id);
drop policy if exists "home_job_logs_select_own" on public.home_job_logs;
drop policy if exists "home_job_logs_insert_own" on public.home_job_logs;
drop policy if exists "home_job_logs_update_own" on public.home_job_logs;
drop policy if exists "home_job_logs_delete_own" on public.home_job_logs;
create policy "home_job_logs_select_own" on public.home_job_logs for select using (auth.uid() = household_id);
create policy "home_job_logs_insert_own" on public.home_job_logs for insert with check (auth.uid() = household_id);
create policy "home_job_logs_update_own" on public.home_job_logs for update using (auth.uid() = household_id);
create policy "home_job_logs_delete_own" on public.home_job_logs for delete using (auth.uid() = household_id);

-- Starter routine (edit any of it later in Manage, Home Quest). Matches kids named Anna and Ryan. --
insert into public.home_jobs (household_id, member_id, title, emoji, place, time_label, slot, days, xp, sort)
select m.household_id, m.id, v.title, v.emoji, v.place, v.time_label, v.slot, v.days, v.xp, v.sort
from public.members m
join (values
  ('anna', 'Make my bed',                         '🛏️', 'My room',     '7:45 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  10),
  ('anna', 'Get dressed and brush my teeth',      '🪥', 'Bathroom',    '7:50 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  20),
  ('anna', 'Feed the pets',                       '🐾', 'Pet spot',    '8:00 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  30),
  ('anna', 'Breakfast dishes to the sink',        '🍽️', 'Kitchen',     '8:15 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  40),
  ('anna', 'Shoes and backpack in their place',   '🎒', 'By the door', '1:45 pm',  'after_school', '{1,2,3,4,5}'::int[],     5,  50),
  ('anna', 'Tidy my room (10 minutes)',           '🧸', 'My room',     '2:00 pm',  'after_school', '{1,2,3,4,5}'::int[],     10, 60),
  ('anna', 'Set the table',                       '🍴', 'Kitchen',     '5:00 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  70),
  ('anna', 'Help wash the vegetables',            '🥕', 'Kitchen',     '5:15 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  80),
  ('anna', 'Clear my plate and wipe the table',   '🧽', 'Kitchen',     '6:15 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  90),
  ('anna', 'Get tomorrow ready (clothes and bag)','🌙', 'My room',     '7:30 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  100),
  ('anna', 'Saturday Reset: match and put away socks', '🧦', 'Laundry area', '10:00 am', 'weekend', '{6}'::int[], 5, 110),
  ('anna', 'Saturday Reset: wipe the bathroom sink',   '🚰', 'Bathroom',     '10:10 am', 'weekend', '{6}'::int[], 5, 120),
  ('anna', 'Saturday Reset: water the plants',         '🪴', 'Around the house', '10:20 am', 'weekend', '{6}'::int[], 5, 130),
  ('ryan', 'Make my bed',                         '🛏️', 'My room',     '7:45 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  10),
  ('ryan', 'Get dressed and brush my teeth',      '🪥', 'Bathroom',    '7:50 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  20),
  ('ryan', 'Unload the dishwasher',               '🧼', 'Kitchen',     '8:00 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 10, 30),
  ('ryan', 'Breakfast dishes in the dishwasher',  '🍽️', 'Kitchen',     '8:15 am',  'morning',      '{0,1,2,3,4,5,6}'::int[], 5,  40),
  ('ryan', 'Shoes and backpack in their place',   '🎒', 'By the door', '1:45 pm',  'after_school', '{1,2,3,4,5}'::int[],     5,  50),
  ('ryan', 'Living room reset (sweep or vacuum)', '🧹', 'Living room', '2:00 pm',  'after_school', '{1,2,3,4,5}'::int[],     10, 60),
  ('ryan', 'Take out the trash',                  '🗑️', 'Kitchen',     '5:00 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  70),
  ('ryan', 'Help cook one part of dinner',        '🍳', 'Kitchen',     '5:15 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 10, 80),
  ('ryan', 'Clear my plate and load the dishwasher', '🧽', 'Kitchen',  '6:15 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 10, 90),
  ('ryan', 'Get tomorrow ready (clothes and bag)','🌙', 'My room',     '7:30 pm',  'evening',      '{0,1,2,3,4,5,6}'::int[], 5,  100),
  ('ryan', 'Saturday Reset: fold and put away my laundry', '👕', 'My room',      '10:00 am', 'weekend', '{6}'::int[], 10, 110),
  ('ryan', 'Saturday Reset: clean the bathroom mirror',    '🪞', 'Bathroom',     '10:15 am', 'weekend', '{6}'::int[], 5,  120),
  ('ryan', 'Saturday Reset: bins to the curb',             '♻️', 'Outside',      '10:25 am', 'weekend', '{6}'::int[], 10, 130)
) as v(who, title, emoji, place, time_label, slot, days, xp, sort) on lower(m.name) like v.who || '%'
where m.role = 'kid' and not exists (select 1 from public.home_jobs);
