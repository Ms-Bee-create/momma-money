-- Saving goals for the kid wallet. Run once in the Supabase SQL editor (safe to run again).
-- A kid picks one thing in the Shop to save for; the wallet shows a bar filling toward its price.
alter table public.members add column if not exists goal_reward_id uuid references public.reward_items (id) on delete set null;
