# Momma Money

A household economy app — not a chore chart. Kids earn Momma Money ($) by
completing chores, spend it in a Rewards Menu, and pay fines for broken house
rules, all approved by a parent "Banker." The goal is real-world financial
literacy: kids manage a balance, do their own mental math, and learn that
money is earned, spent, and sometimes lost.

Separate app from [The Cracks App](../mom-ops) and the Thankful Mama Co
recipe system — different audience, different product, deliberately not
merged. See the project conversation for the reasoning.

## Core loop

Kid completes a chore → submits it → Banker approves it → balance goes up.
Kid requests a reward from the Shopping Menu → Banker approves it → balance
goes down. Banker can also charge a fine instantly for a broken house rule.

## How it's built

Single-file static app (`index.html`) — vanilla HTML/CSS/JS, no build step,
same approach as Cracks. Supabase (Postgres + anonymous auth) is the backend;
schema and RLS policies live in `supabase/schema.sql`.

**Auth model:** one anonymous Supabase identity per household device (the
"household owner"). Kids don't get their own Supabase Auth accounts — they're
just profile rows in the `members` table, switched via an in-app PIN pad.
This matches the real usage pattern (one shared tablet/phone, whoever's
home taps their own name). The PIN is a household-device convenience lock,
not a security boundary — all real access control is Postgres RLS scoped to
the household owner's `auth.uid()`.

## Data model

- `households` — one row per anonymous auth identity
- `members` — Banker + Kid profiles within a household (name, avatar, PIN, balance, bankrupt flag)
- `chore_templates` — the earning catalog, grouped by category
- `assignment_rules` / `chore_logs` — recurring or one-off chore assignments and their due/status per occurrence
- `fine_templates` — house rules and their deduction amounts, by tier
- `reward_items` — the shopping menu, grouped by category
- `transactions` — the ledger; every earn/fine/spend is one row, `pending` until the Banker approves it

Full schema, seed data, and RLS policies: `supabase/schema.sql`.

## Key rules

- **$1 = 5 minutes of screen time** is a reference rate only — the app never
  auto-converts or displays this math to kids. They do it themselves.
- **Bankruptcy Protection**: a kid's balance can't go below $0. Hitting $0
  locks the Shopping Menu until an approved chore brings the balance back
  above zero.
- **Banker's decisions are final** — fines are charged immediately, no
  approval queue (the Banker is the one issuing them). Chore earnings and
  reward requests do sit in a pending queue for Banker approval.

## Status

**Phase 1 — built:**
- Profile picker with PIN-protected switching (Banker + multiple Kids)
- Kid view: My Chores, Earn More (ad-hoc catalog), Shop, Activity history
- Banker view: Approvals queue, Issue Fine, Household overview
- Full seed data from the v1 spec (chores, fines, rewards)
- Bankruptcy protection logic (floor at $0, auto-clears on positive balance)

**Not yet built:**
- Recurring chore schedules (daily/weekly/interval) — v1 supports one-off
  assignments only; the schema supports recurrence, the UI doesn't expose it yet
- Banker-side catalog management (add/edit/archive chores, fines, rewards from the UI — currently seed-only, edit via Supabase directly)
- Multi-household / invite flow (currently one household per device/browser)
