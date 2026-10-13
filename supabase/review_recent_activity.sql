-- Read-only: lists what happened in the last 4 days across every profile, newest first, so you can spot anything the
-- extra profiles did (new profiles, money approved or fined, chores approved, Home Quest jobs, screen time started).
-- Run it in the Supabase SQL editor. It changes nothing. To look further back, change '4 days' to '10 days'.
-- Note: the app doesn't record WHICH parent approved something, so look for items at the times the kids were on the app.
with since as (select now() - interval '4 days' as t)
select at, what, who, detail, amount, status from (
  select m.created_at as at, 'New profile'::text as what, m.name as who, m.role::text as detail,
         null::numeric as amount, (case when m.archived then 'removed' else 'active' end)::text as status
  from public.members m, since where m.created_at > since.t
  union all
  select coalesce(t.resolved_at, t.created_at), ('Money: ' || t.type)::text, k.name,
         (t.description || coalesce(' (issued by ' || i.name || ')', ''))::text, t.amount, t.status::text
  from public.transactions t
  join public.members k on k.id = t.member_id
  left join public.members i on i.id = t.issued_by, since
  where t.created_at > since.t or t.resolved_at > since.t
  union all
  select coalesce(l.approved_at, l.submitted_at, l.created_at), 'Chore'::text, k.name,
         coalesce(ct.title, 'a chore')::text, null::numeric, l.status::text
  from public.chore_logs l
  join public.members k on k.id = l.assigned_member_id
  left join public.assignment_rules r on r.id = l.assignment_rule_id
  left join public.chore_templates ct on ct.id = r.chore_id, since
  where l.status in ('submitted', 'approved') and coalesce(l.approved_at, l.submitted_at, l.created_at) > since.t
  union all
  select coalesce(h.approved_at, h.submitted_at), 'Home Quest'::text, k.name,
         coalesce(j.title, 'Perfect day bonus')::text, h.xp::numeric, h.status::text
  from public.home_job_logs h
  join public.members k on k.id = h.member_id
  left join public.home_jobs j on j.id = h.job_id, since
  where coalesce(h.approved_at, h.submitted_at) > since.t
  union all
  select s.started_at, 'Screen time'::text, k.name, (s.minutes || ' minutes')::text, null::numeric, s.status::text
  from public.screen_sessions s
  join public.members k on k.id = s.member_id, since
  where s.started_at > since.t
) activity
order by at desc;
