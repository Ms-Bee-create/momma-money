-- PINs checked on the server. Run once in the Supabase SQL editor (safe to run again).
--
-- Before: every PIN was stored as plain text in the members table, so the app downloaded all of them to
-- every device. Anyone who opened the browser's developer tools could read a parent's PIN.
-- After: PINs are stored scrambled (bcrypt) in a table nobody can read from the app. The app asks the
-- server "is this the right PIN?" and gets back only yes or no. Five wrong tries lock that PIN for 5 minutes.
--
-- Note: this protects the PIN. A kid who knows how to call the database directly can still change money
-- or settings, because all profiles share one household login. Stage 2 (separate kid and parent logins)
-- is what closes that.

create extension if not exists pgcrypto with schema extensions;

alter table public.members add column if not exists has_pin boolean not null default false;

create table if not exists public.member_pins (
  member_id uuid primary key references public.members (id) on delete cascade,
  household_id uuid not null references public.households (id) on delete cascade,
  pin_hash text not null,
  fail_count int not null default 0,
  locked_until timestamptz,
  updated_at timestamptz not null default now()
);
alter table public.member_pins enable row level security;   -- no policies: the app can never read or write it directly
revoke all on public.member_pins from anon, authenticated;

-- Keep members.has_pin honest, and make sure a plain-text PIN can never be stored again.
create or replace function public.members_sync_has_pin()
returns trigger language plpgsql security definer set search_path = public as $$
begin
  new.pin := null;
  new.has_pin := exists (select 1 from public.member_pins where member_id = new.id);
  return new;
end $$;
drop trigger if exists members_has_pin_sync on public.members;
create trigger members_has_pin_sync before insert or update on public.members
  for each row execute function public.members_sync_has_pin();

-- Move today's plain PINs into the scrambled table, then erase the plain copies.
insert into public.member_pins (member_id, household_id, pin_hash)
select id, household_id, extensions.crypt(pin, extensions.gen_salt('bf'))
from public.members
where pin is not null and pin ~ '^[0-9]{4}$'
on conflict (member_id) do nothing;
update public.members set pin = null where pin is not null;      -- the trigger also refreshes has_pin on every row

-- Is this the right PIN? Counts wrong tries and locks after 5 for 5 minutes.
create or replace function public.pin_matches(p_member uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare r public.member_pins%rowtype;
begin
  select * into r from public.member_pins
   where member_id = p_member and household_id = auth.uid() for update;
  if not found then return jsonb_build_object('ok', false, 'error', 'no_pin'); end if;
  if r.locked_until is not null and r.locked_until > now() then
    return jsonb_build_object('ok', false, 'error', 'locked',
      'locked_seconds', ceil(extract(epoch from (r.locked_until - now())))::int);
  end if;
  if p_pin is not null and r.pin_hash = extensions.crypt(p_pin, r.pin_hash) then
    update public.member_pins set fail_count = 0, locked_until = null where member_id = p_member;
    return jsonb_build_object('ok', true);
  end if;
  update public.member_pins
     set fail_count = case when fail_count + 1 >= 5 then 0 else fail_count + 1 end,
         locked_until = case when fail_count + 1 >= 5 then now() + interval '5 minutes' else null end
   where member_id = p_member;
  return jsonb_build_object('ok', false, 'error', 'wrong_pin',
    'tries_left', greatest(0, 5 - (r.fail_count + 1)),
    'locked_seconds', case when r.fail_count + 1 >= 5 then 300 else 0 end);
end $$;

-- The profile picker uses this: right PIN, or this profile has no PIN.
create or replace function public.check_member_pin(p_member uuid, p_pin text)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.members where id = p_member and household_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if not exists (select 1 from public.member_pins where member_id = p_member) then
    return jsonb_build_object('ok', true, 'no_pin', true);
  end if;
  return public.pin_matches(p_member, p_pin);
end $$;

-- Is this a parent's PIN (or, for changing your own, that profile's own PIN)?
create or replace function public.pin_authorized(p_member uuid, p_auth text)
returns boolean language plpgsql security definer set search_path = public, extensions as $$
declare b record;
begin
  if p_auth is null or p_auth = '' then return false; end if;
  if exists (select 1 from public.member_pins where member_id = p_member)
     and (public.pin_matches(p_member, p_auth)->>'ok')::boolean then return true; end if;
  for b in select m.id from public.members m
            where m.household_id = auth.uid() and m.role = 'banker' and m.archived = false and m.id <> p_member
              and exists (select 1 from public.member_pins p where p.member_id = m.id) loop
    if (public.pin_matches(b.id, p_auth)->>'ok')::boolean then return true; end if;
  end loop;
  return false;
end $$;

-- Set or change a PIN. A profile that already has a PIN needs a parent's PIN (or its own) to change it.
create or replace function public.set_member_pin(p_member uuid, p_new text, p_auth text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
declare m public.members%rowtype;
begin
  select * into m from public.members where id = p_member and household_id = auth.uid();
  if not found then return jsonb_build_object('ok', false, 'error', 'not_found'); end if;
  if p_new is null or p_new !~ '^[0-9]{4}$' then return jsonb_build_object('ok', false, 'error', 'invalid'); end if;
  if exists (select 1 from public.member_pins where member_id = p_member)
     and not public.pin_authorized(p_member, p_auth) then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;
  insert into public.member_pins (member_id, household_id, pin_hash)
  values (p_member, auth.uid(), extensions.crypt(p_new, extensions.gen_salt('bf')))
  on conflict (member_id) do update
    set pin_hash = excluded.pin_hash, fail_count = 0, locked_until = null, updated_at = now();
  update public.members set name = name where id = p_member;     -- refreshes has_pin
  return jsonb_build_object('ok', true);
end $$;

-- Remove a PIN (needs a parent's PIN or its own).
create or replace function public.clear_member_pin(p_member uuid, p_auth text default null)
returns jsonb language plpgsql security definer set search_path = public, extensions as $$
begin
  if not exists (select 1 from public.members where id = p_member and household_id = auth.uid()) then
    return jsonb_build_object('ok', false, 'error', 'not_found');
  end if;
  if exists (select 1 from public.member_pins where member_id = p_member)
     and not public.pin_authorized(p_member, p_auth) then
    return jsonb_build_object('ok', false, 'error', 'bad_pin');
  end if;
  delete from public.member_pins where member_id = p_member;
  update public.members set name = name where id = p_member;
  return jsonb_build_object('ok', true);
end $$;

revoke all on function public.pin_matches(uuid, text), public.pin_authorized(uuid, text) from public, anon, authenticated;
revoke all on function public.check_member_pin(uuid, text), public.set_member_pin(uuid, text, text), public.clear_member_pin(uuid, text) from public, anon;
grant execute on function public.check_member_pin(uuid, text), public.set_member_pin(uuid, text, text), public.clear_member_pin(uuid, text) to authenticated;
