-- ============================================================================
-- Momma Money — v1 Supabase schema
-- Household economy app: one anonymous auth identity per household device
-- (the "household owner"), with multiple in-app member profiles (Banker +
-- Kids) switched via a lightweight PIN — not separate Supabase Auth users.
-- Kids sharing one tablet is the expected v1 usage, so all RLS is scoped to
-- the household owner (auth.uid()), and member-level access control (who can
-- see/approve what) is enforced in the app UI, same trust model as a single
-- shared family device.
-- ============================================================================

create extension if not exists "pgcrypto";

-- ----------------------------------------------------------------------------
-- households — one row per anonymous auth identity, holds shared settings.
-- ----------------------------------------------------------------------------
create table if not exists public.households (
  id uuid primary key references auth.users (id) on delete cascade,
  screen_time_rate numeric(10,2) not null default 5, -- minutes per $1 — sets the price when a kid buys screen time in the Shop
  created_at timestamptz not null default now()
);

-- ----------------------------------------------------------------------------
-- members — Banker (parent) and Kid profiles within one household.
-- pin is a plain 4-digit string; this is a low-stakes household-device
-- convenience lock, not a security boundary (real access control is RLS on
-- household_id = auth.uid()).
-- ----------------------------------------------------------------------------
create table if not exists public.members (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  name text not null,
  role text not null check (role in ('banker', 'kid')),
  avatar_emoji text not null default '🙂',
  pin text,
  current_balance numeric(10,2) not null default 0,
  bankrupt boolean not null default false,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists members_household_idx on public.members (household_id);

-- ----------------------------------------------------------------------------
-- chore_templates — the earning catalog.
-- ----------------------------------------------------------------------------
create table if not exists public.chore_templates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  title text not null,
  category text not null check (category in ('Cleaning', 'Care & Kindness', 'Hygiene', 'Learning', 'Family Help', 'Finch')),
  default_payout numeric(10,2) not null default 0,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists chore_templates_household_idx on public.chore_templates (household_id);

-- ----------------------------------------------------------------------------
-- assignment_rules — who owes which chore, how often.
-- ----------------------------------------------------------------------------
create table if not exists public.assignment_rules (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  chore_id uuid not null references public.chore_templates (id) on delete cascade,
  assigned_member_id uuid not null references public.members (id) on delete cascade,
  frequency_type text not null check (frequency_type in ('daily', 'weekly_days', 'interval')),
  days_of_week int[] not null default '{}',   -- 0=Sun..6=Sat, used when frequency_type='weekly_days'
  interval_days int,                           -- used when frequency_type='interval'
  active boolean not null default true,
  created_at timestamptz not null default now()
);

create index if not exists assignment_rules_household_idx on public.assignment_rules (household_id);
create index if not exists assignment_rules_member_idx on public.assignment_rules (assigned_member_id);

-- ----------------------------------------------------------------------------
-- chore_logs — one row per due occurrence of an assignment.
-- ----------------------------------------------------------------------------
create table if not exists public.chore_logs (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  assignment_rule_id uuid not null references public.assignment_rules (id) on delete cascade,
  assigned_member_id uuid not null references public.members (id) on delete cascade,
  due_date date not null,
  status text not null default 'pending' check (status in ('pending', 'submitted', 'approved', 'rejected')),
  submitted_at timestamptz,
  approved_at timestamptz,
  created_at timestamptz not null default now(),
  unique (assignment_rule_id, due_date)
);

create index if not exists chore_logs_household_idx on public.chore_logs (household_id);
create index if not exists chore_logs_member_idx on public.chore_logs (assigned_member_id, due_date);

-- ----------------------------------------------------------------------------
-- fine_templates — house rules / deduction catalog.
-- ----------------------------------------------------------------------------
create table if not exists public.fine_templates (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  title text not null,
  tier text not null check (tier in ('Big', 'Medium', 'Standard')),
  amount numeric(10,2) not null,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists fine_templates_household_idx on public.fine_templates (household_id);

-- ----------------------------------------------------------------------------
-- reward_items — the shopping menu.
-- ----------------------------------------------------------------------------
create table if not exists public.reward_items (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  title text not null,
  category text not null check (category in ('Screen & Media', 'Food & Treats', 'Privileges & Fun', 'Tangible Rewards')),
  cost numeric(10,2) not null,
  archived boolean not null default false,
  created_at timestamptz not null default now()
);

create index if not exists reward_items_household_idx on public.reward_items (household_id);

-- ----------------------------------------------------------------------------
-- transactions — the ledger. Every balance change is one row here; a
-- member's current_balance on the members table is a maintained cache for
-- fast display, kept in sync when a transaction is approved.
-- ----------------------------------------------------------------------------
create table if not exists public.transactions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  type text not null check (type in ('earn', 'fine', 'spend', 'adjustment')),
  amount numeric(10,2) not null,
  description text not null,
  status text not null default 'pending' check (status in ('pending', 'approved', 'rejected')),
  chore_log_id uuid references public.chore_logs (id) on delete set null,
  reward_item_id uuid references public.reward_items (id) on delete set null,
  created_at timestamptz not null default now(),
  resolved_at timestamptz
);

create index if not exists transactions_household_idx on public.transactions (household_id);
create index if not exists transactions_member_idx on public.transactions (member_id, created_at);

-- Screen-time-specific fields, added after v1. A transaction with
-- screen_minutes set is a screen-time purchase — on approval, those
-- minutes get credited to the member's banked balance (below) rather
-- than being usable immediately, since starting the timer is a separate
-- action the kid (or Banker) takes once they're actually about to use it.
alter table public.transactions add column if not exists screen_minutes integer;
alter table public.members add column if not exists screen_minutes_balance integer not null default 0;

-- ----------------------------------------------------------------------------
-- screen_sessions — one row per "screen time started" countdown. Storing
-- ends_at (not just a duration) means the countdown is computed the same
-- way on every device/reload from a single source of truth, so the kid's
-- screen and the Banker's screen never drift or disagree about how much
-- time is left — the whole point of this table existing.
-- ----------------------------------------------------------------------------
create table if not exists public.screen_sessions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households (id) on delete cascade,
  member_id uuid not null references public.members (id) on delete cascade,
  minutes integer not null,
  started_at timestamptz not null default now(),
  ends_at timestamptz not null,
  status text not null default 'active' check (status in ('active', 'completed', 'cancelled')),
  created_at timestamptz not null default now()
);

create index if not exists screen_sessions_household_idx on public.screen_sessions (household_id);
create index if not exists screen_sessions_member_idx on public.screen_sessions (member_id, status);

alter table public.screen_sessions enable row level security;
create policy "screen_sessions_select_own" on public.screen_sessions for select using (auth.uid() = household_id);
create policy "screen_sessions_insert_own" on public.screen_sessions for insert with check (auth.uid() = household_id);
create policy "screen_sessions_update_own" on public.screen_sessions for update using (auth.uid() = household_id);
create policy "screen_sessions_delete_own" on public.screen_sessions for delete using (auth.uid() = household_id);

-- ============================================================================
-- Row Level Security — every table scoped strictly to the household owner
-- (auth.uid()). Member-level permissions (kid vs banker) are enforced in the
-- app, not the database, matching the shared-device trust model.
-- ============================================================================

alter table public.households enable row level security;
alter table public.members enable row level security;
alter table public.chore_templates enable row level security;
alter table public.assignment_rules enable row level security;
alter table public.chore_logs enable row level security;
alter table public.fine_templates enable row level security;
alter table public.reward_items enable row level security;
alter table public.transactions enable row level security;

create policy "households_select_own" on public.households for select using (auth.uid() = id);
create policy "households_insert_own" on public.households for insert with check (auth.uid() = id);
create policy "households_update_own" on public.households for update using (auth.uid() = id);

create policy "members_select_own" on public.members for select using (auth.uid() = household_id);
create policy "members_insert_own" on public.members for insert with check (auth.uid() = household_id);
create policy "members_update_own" on public.members for update using (auth.uid() = household_id);
create policy "members_delete_own" on public.members for delete using (auth.uid() = household_id);

create policy "chore_templates_select_own" on public.chore_templates for select using (auth.uid() = household_id);
create policy "chore_templates_insert_own" on public.chore_templates for insert with check (auth.uid() = household_id);
create policy "chore_templates_update_own" on public.chore_templates for update using (auth.uid() = household_id);
create policy "chore_templates_delete_own" on public.chore_templates for delete using (auth.uid() = household_id);

create policy "assignment_rules_select_own" on public.assignment_rules for select using (auth.uid() = household_id);
create policy "assignment_rules_insert_own" on public.assignment_rules for insert with check (auth.uid() = household_id);
create policy "assignment_rules_update_own" on public.assignment_rules for update using (auth.uid() = household_id);
create policy "assignment_rules_delete_own" on public.assignment_rules for delete using (auth.uid() = household_id);

create policy "chore_logs_select_own" on public.chore_logs for select using (auth.uid() = household_id);
create policy "chore_logs_insert_own" on public.chore_logs for insert with check (auth.uid() = household_id);
create policy "chore_logs_update_own" on public.chore_logs for update using (auth.uid() = household_id);
create policy "chore_logs_delete_own" on public.chore_logs for delete using (auth.uid() = household_id);

create policy "fine_templates_select_own" on public.fine_templates for select using (auth.uid() = household_id);
create policy "fine_templates_insert_own" on public.fine_templates for insert with check (auth.uid() = household_id);
create policy "fine_templates_update_own" on public.fine_templates for update using (auth.uid() = household_id);
create policy "fine_templates_delete_own" on public.fine_templates for delete using (auth.uid() = household_id);

create policy "reward_items_select_own" on public.reward_items for select using (auth.uid() = household_id);
create policy "reward_items_insert_own" on public.reward_items for insert with check (auth.uid() = household_id);
create policy "reward_items_update_own" on public.reward_items for update using (auth.uid() = household_id);
create policy "reward_items_delete_own" on public.reward_items for delete using (auth.uid() = household_id);

create policy "transactions_select_own" on public.transactions for select using (auth.uid() = household_id);
create policy "transactions_insert_own" on public.transactions for insert with check (auth.uid() = household_id);
create policy "transactions_update_own" on public.transactions for update using (auth.uid() = household_id);
create policy "transactions_delete_own" on public.transactions for delete using (auth.uid() = household_id);

-- ============================================================================
-- New-household bootstrap: household row + default Banker profile + full
-- seed catalog (chores, fines, rewards) from the v1 spec.
-- ============================================================================
create or replace function public.handle_new_household()
returns trigger as $$
declare
  hh_id uuid := new.id;
begin
  insert into public.households (id) values (hh_id) on conflict (id) do nothing;

  insert into public.members (household_id, name, role, avatar_emoji)
  values (hh_id, 'Banker', 'banker', '👑')
  on conflict do nothing;

  insert into public.chore_templates (household_id, title, category, default_payout) values
    (hh_id, 'Unload dishwasher', 'Cleaning', 3),
    (hh_id, 'Load dishwasher', 'Cleaning', 3),
    (hh_id, 'Wipe counters', 'Cleaning', 2),
    (hh_id, 'Sweep floors', 'Cleaning', 3),
    (hh_id, 'Mop floors', 'Cleaning', 4),
    (hh_id, 'Clean bathroom', 'Cleaning', 5),
    (hh_id, 'Clean toilet', 'Cleaning', 6),
    (hh_id, 'Clean shower', 'Cleaning', 4),
    (hh_id, 'Wash & fold clothes', 'Cleaning', 5),
    (hh_id, 'Take out trash', 'Cleaning', 2),
    (hh_id, 'Wipe walls', 'Cleaning', 3),
    (hh_id, 'Pick up toys', 'Cleaning', 4),
    (hh_id, 'Make bed', 'Cleaning', 2),
    (hh_id, 'Make mom''s bed', 'Cleaning', 3),
    (hh_id, 'Sweep mom''s room', 'Cleaning', 2),
    (hh_id, 'Pick up dirty clothes in mom''s room', 'Cleaning', 3),
    (hh_id, 'Wipe kitchen table', 'Cleaning', 2),
    (hh_id, 'Organize shoes', 'Cleaning', 2),
    (hh_id, 'Vacuum living room', 'Cleaning', 4),
    (hh_id, 'Help carry groceries', 'Cleaning', 2),
    (hh_id, 'Say one kind thing to your sibling', 'Care & Kindness', 1),
    (hh_id, 'Help entertain your sibling kindly', 'Care & Kindness', 3),
    (hh_id, 'Help a sibling clean up', 'Care & Kindness', 3),
    (hh_id, 'Feed pets', 'Care & Kindness', 3),
    (hh_id, 'Change clothes', 'Hygiene', 1),
    (hh_id, 'Brush teeth', 'Hygiene', 3),
    (hh_id, 'Take a shower', 'Hygiene', 3),
    (hh_id, 'Listen the first time mom or dad speaks', 'Hygiene', 8),
    (hh_id, 'Read for 15 minutes + answer 3 questions', 'Learning', 5),
    (hh_id, 'Do 5 math problems', 'Learning', 4),
    (hh_id, 'Write a 5-sentence story', 'Learning', 6),
    (hh_id, 'Memorize a Bible verse', 'Learning', 5),
    (hh_id, 'Give daddy a foot massage', 'Family Help', 4),
    (hh_id, 'Water plants', 'Family Help', 5),
    (hh_id, 'Any Finch task not listed', 'Finch', 2);

  insert into public.fine_templates (household_id, title, tier, amount) values
    (hh_id, 'Backtalk / Disrespect', 'Big', 1.50),
    (hh_id, 'Physical Aggression', 'Big', 2.00),
    (hh_id, 'Dishonesty', 'Big', 2.00),
    (hh_id, 'Device Violation', 'Big', 1.50),
    (hh_id, 'The "Nagging" Fee', 'Medium', 0.50),
    (hh_id, 'Sloppy Work', 'Medium', 0.75),
    (hh_id, 'Holding Up the Team', 'Medium', 0.50),
    (hh_id, 'The Clutter Tax (per item)', 'Medium', 0.25),
    (hh_id, 'Leaving Lights/TV On', 'Standard', 0.25),
    (hh_id, 'Lost Personal Item', 'Standard', 1.00),
    (hh_id, '"Room Service" Fee', 'Standard', 3.00);

  insert into public.reward_items (household_id, title, category, cost) values
    (hh_id, 'Video Game Pass - 1 hr console', 'Screen & Media', 15),
    (hh_id, 'DJ for the Car', 'Screen & Media', 5),
    (hh_id, 'Choose Family Movie', 'Screen & Media', 20),
    (hh_id, 'Pick Dessert', 'Food & Treats', 10),
    (hh_id, 'Choose Lunch', 'Food & Treats', 15),
    (hh_id, 'Small Treat', 'Food & Treats', 5),
    (hh_id, 'Breakfast in Bed', 'Food & Treats', 20),
    (hh_id, 'Fast Food Upgrade', 'Food & Treats', 10),
    (hh_id, 'Stay up 15 minutes late', 'Privileges & Fun', 15),
    (hh_id, 'Pick the Board Game', 'Privileges & Fun', 10),
    (hh_id, 'Mom or Dad Date 10-15 min', 'Privileges & Fun', 25),
    (hh_id, 'Skip a Daily Chore', 'Privileges & Fun', 30),
    (hh_id, 'First Choice of Seating', 'Privileges & Fun', 5),
    (hh_id, 'The Mystery Box', 'Tangible Rewards', 15),
    (hh_id, 'Cash-Out: $50 fake = $5 real', 'Tangible Rewards', 50);

  return new;
end;
$$ language plpgsql security definer set search_path = public;

drop trigger if exists on_auth_user_created_household on auth.users;
create trigger on_auth_user_created_household
  after insert on auth.users
  for each row execute function public.handle_new_household();
