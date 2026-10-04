-- Forge Academy pets in the Shop.
-- Run once in the Supabase SQL editor. Safe to run again: it never adds the same pet twice.
--
-- A pet or accessory is an ordinary reward item with a "grants" tag. When a kid buys one and the
-- Banker approves it, Forge Academy sees the approved purchase and unlocks it on their school page.
-- Sparkle, Pip, Byte and Disk are free starter pets in Forge Academy; here they are listed so the
-- other kid can buy them too. Change names and prices any time from the Banker catalog.

alter table public.reward_items add column if not exists grants text;

alter table public.reward_items drop constraint if exists reward_items_category_check;
alter table public.reward_items add constraint reward_items_category_check
  check (category in ('Screen & Media', 'Food & Treats', 'Privileges & Fun', 'Tangible Rewards', 'Pets & Accessories'));

insert into public.reward_items (household_id, title, category, cost, grants)
select h.id, v.title, 'Pets & Accessories', v.cost, v.grants
from public.households h
cross join (values
    ('Pet: Sparkle the Unicorn', 4, 'pet:uni'),
    ('Pet: Pip the Kitten', 4, 'pet:cat'),
    ('Pet: Byte the PC', 4, 'pet:pc'),
    ('Pet: Disk the Floppy', 4, 'pet:disk'),
    ('Pet: Rainbow Girl', 8, 'pet:girl'),
    ('Pet: Rainbow Dragon', 6, 'pet:dragon'),
    ('Pet: Fluffy Bunny', 4, 'pet:bunny'),
    ('Pet: Waddles the Penguin', 4, 'pet:penguin'),
    ('Pet: Bolt the Robot', 5, 'pet:bot'),
    ('Pet: Orbit the Orb Bot', 6, 'pet:orbit'),
    ('Pet: Roomie the Roomba', 4, 'pet:roomba'),
    ('Pet: Flaggy 95', 5, 'pet:flag95'),
    ('Pet: Flaggy 98', 5, 'pet:flag98'),
    ('Pet: Flaggy XP', 6, 'pet:flagxp'),
    ('Pet: Orby', 6, 'pet:orb'),
    ('Pet: Paney 10', 6, 'pet:pane10'),
    ('Pet: Paney 11', 8, 'pet:pane11'),
    ('Accessory: Party hat', 1, 'acc:partyhat'),
    ('Accessory: Big bow', 1, 'acc:bow'),
    ('Accessory: Gold crown', 2, 'acc:crown'),
    ('Accessory: Cool shades', 2, 'acc:shades')
) as v(title, cost, grants)
where not exists (
  select 1 from public.reward_items r where r.household_id = h.id and r.grants = v.grants
);
