-- ═══════════════════════════════════════════════════════════════
-- BUILT FOR MORE — SUPABASE SCHEMA (v3 — paywall-gated content + purchase-gated signup)
-- Run this once in your Supabase project: Dashboard → SQL Editor → New Query
-- Paste this whole file and click "Run".
--
-- If you already ran an earlier version of this schema, run this file anyway —
-- it drops and recreates the tables involved (no client data exists yet, so
-- this is safe now; if you already have real signups, back up first).
--
-- WHAT'S NEW IN v3: accounts can now only be created by someone who has
-- already completed a purchase. See the "PENDING ACCESS" and "SIGNUP GATE"
-- sections below for how that's enforced.
-- ═══════════════════════════════════════════════════════════════

drop trigger if exists enforce_purchase_before_signup on auth.users;
drop function if exists public.handle_new_user_purchase_check();
drop function if exists public.email_has_pending_purchase(text);
drop function if exists public.is_admin();
drop function if exists public.admin_list_clients();
drop table if exists waiver_acceptances cascade;
drop table if exists workout_logs cascade;
drop table if exists program_content cascade;
drop table if exists purchases cascade;
drop table if exists pending_access cascade;
drop table if exists admins cascade;
drop table if exists programs cascade;

-- PROGRAMS (public — safe for anyone to read)
-- Just enough info to run the pricing page: name, price, description.
-- The ACTUAL workout plan is deliberately NOT in this table — see program_content below.
create table programs (
  id text primary key,                 -- e.g. 'kickstart-4wk'
  name text not null,
  weeks int not null,
  price_cents int not null,
  description text,
  created_at timestamptz default now()
);

-- PROGRAM CONTENT (paywalled — this is the actual workout plan)
-- Kept in a separate table from `programs` on purpose: this is what makes the
-- paywall real at the database level, not just something the front-end pretends
-- to hide. A row here is only ever returned to a user who has a matching
-- active row in `purchases` (enforced by the RLS policy below) — logging in
-- alone is not enough, and neither is knowing the public API key.
create table program_content (
  program_id text primary key references programs(id) on delete cascade,
  content jsonb not null default '[]',
  updated_at timestamptz default now()
);

-- PURCHASES
-- One row per program a client has bought, tied to a real account.
-- Created two ways: (1) directly by the Stripe webhook, if the buyer already
-- had an account when they paid, or (2) automatically from `pending_access`
-- the moment someone creates an account after paying (see the signup gate below).
create table purchases (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  program_id text not null references programs(id),
  stripe_session_id text,
  stripe_payment_intent text,             -- used to match Stripe refund events back to this row
  status text not null default 'active',  -- 'active' | 'refunded'
  created_at timestamptz default now(),
  unique(user_id, program_id)
);

-- PENDING ACCESS
-- Most buyers pay BEFORE they have an account (there's no account to log into
-- until you've bought something — see the signup gate below), so a purchase
-- can't be tied to a user_id yet. The Stripe webhook drops a row here instead,
-- keyed by the email used at checkout. The moment that same email creates an
-- account, a trigger on auth.users converts these rows into real `purchases`
-- rows and deletes them from here. This table is never readable directly by
-- the browser — only through the locked-down function below.
create table pending_access (
  id uuid primary key default gen_random_uuid(),
  email text not null,
  program_id text not null references programs(id),
  stripe_session_id text,
  stripe_payment_intent text,
  created_at timestamptz default now(),
  unique(email, program_id)
);

-- ADMINS
-- Just a list of emails allowed to see the admin view. Add/remove yourself
-- and any staff directly in Table Editor — no code change needed.
create table admins (
  email text primary key
);

-- WAIVER ACCEPTANCES
-- One row every time someone agrees to the liability waiver at account
-- creation. Kept as its own append-only log (never updated or deleted)
-- so there's a timestamped record if you ever need to show someone agreed.
create table waiver_acceptances (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  waiver_version text not null default 'v1',
  accepted_at timestamptz default now()
);

-- WORKOUT LOGS (the check-in calendar)
-- One row per day a client checks in. exercises is a flexible JSON array
-- so each entry can hold name, sets, reps, weight — whatever they log.
create table workout_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  program_id text references programs(id),
  log_date date not null,
  exercises jsonb not null default '[]',  -- [{ "name": "Squat", "sets": 3, "reps": 8, "weight": "135 lb" }, ...]
  notes text,
  created_at timestamptz default now(),
  updated_at timestamptz default now(),
  unique(user_id, log_date)
);

-- ─────────────────────────────────────────────────────────────
-- ROW LEVEL SECURITY
-- This is the actual paywall. It's enforced by the database, not the
-- website, so it holds even if someone bypasses the UI entirely.
-- ─────────────────────────────────────────────────────────────

alter table programs enable row level security;
alter table program_content enable row level security;
alter table purchases enable row level security;
alter table pending_access enable row level security;
alter table workout_logs enable row level security;
alter table admins enable row level security;
alter table waiver_acceptances enable row level security;

-- Helper: is the currently logged-in user an admin? Used by the policies
-- below and safe to call from anywhere — it only ever returns true/false,
-- never the admin list itself.
create or replace function public.is_admin()
returns boolean
language sql
security definer
set search_path = public
stable
as $$
  select exists (
    select 1 from admins
    where lower(email) = lower(coalesce(auth.jwt() ->> 'email', ''))
  );
$$;

grant execute on function public.is_admin() to authenticated;

-- Anyone (even logged out) can view the program catalog — needed for the pricing page.
-- Safe because this table only ever holds name/price/description, never the workout plan.
create policy "Programs are publicly readable"
  on programs for select
  using (true);

-- THE PAYWALL: a user can read a program's content only if they have a
-- matching row in `purchases` with status = 'active'. No purchase, no rows
-- returned — Supabase enforces this on every query, regardless of what the
-- front-end code does or doesn't check.
create policy "Content is only readable with an active purchase"
  on program_content for select
  using (
    exists (
      select 1 from purchases
      where purchases.user_id = auth.uid()
        and purchases.program_id = program_content.program_id
        and purchases.status = 'active'
    )
    or is_admin()
  );

-- Users can see their own purchases; admins can see everyone's (needed for the admin view).
create policy "Users can view their own purchases, admins can view all"
  on purchases for select
  using (auth.uid() = user_id or is_admin());

-- Purchases are only ever inserted/updated by the Stripe webhook (using the
-- service role key, which bypasses RLS) — no client-side write policy, so
-- clients can't grant or revoke access themselves.

-- `pending_access` intentionally has NO policies at all — not even for its own
-- rows. Nobody can read or write it directly from the browser, logged in or
-- not. The only way in or out is the SECURITY DEFINER function and trigger
-- below, and the Stripe webhook (which uses the service role key and bypasses
-- RLS entirely).

-- Users can view, create, and update only their own workout logs; admins can view all.
create policy "Users can view their own workout logs, admins can view all"
  on workout_logs for select
  using (auth.uid() = user_id or is_admin());

create policy "Users can insert their own workout logs"
  on workout_logs for insert
  with check (auth.uid() = user_id);

create policy "Users can update their own workout logs"
  on workout_logs for update
  using (auth.uid() = user_id);

create policy "Users can delete their own workout logs"
  on workout_logs for delete
  using (auth.uid() = user_id);

-- `admins` — nobody can read or write this from the browser, not even
-- admins themselves. Manage it directly in Table Editor. is_admin() above
-- is the only way anything checks it, and that function never exposes the
-- list itself.

-- Users can see only their own waiver acceptance; admins can see all (proof of agreement if ever needed).
create policy "Users can view their own waiver acceptance, admins can view all"
  on waiver_acceptances for select
  using (auth.uid() = user_id or is_admin());

create policy "Users can record their own waiver acceptance"
  on waiver_acceptances for insert
  with check (auth.uid() = user_id);

-- ─────────────────────────────────────────────────────────────
-- SIGNUP GATE — accounts can only be created by someone who already paid
--
-- Two parts:
--  1. email_has_pending_purchase() — a function the SIGNUP FORM calls first,
--     to show a friendly "we couldn't find a purchase for that email" message
--     before even attempting to create the account. This is just for a good
--     user experience — on its own it wouldn't stop anyone determined to call
--     the signup API directly.
--  2. The actual enforcement: a trigger on auth.users that runs on every new
--     account, no matter how it's created. If there's no matching row in
--     pending_access for that email, it raises an error and the account is
--     never created — Postgres rolls back the whole insert. If there IS a
--     match, the trigger both creates the account AND grants access in the
--     same step, then clears the pending_access row so it can't be reused.
-- ─────────────────────────────────────────────────────────────

-- Callable by anyone (even logged out) — but only ever returns true/false,
-- never the actual contents of pending_access.
create or replace function public.email_has_pending_purchase(check_email text)
returns boolean
language plpgsql
security definer
set search_path = public
as $$
begin
  return exists (
    select 1 from pending_access
    where lower(email) = lower(check_email)
  );
end;
$$;

grant execute on function public.email_has_pending_purchase(text) to anon, authenticated;

-- Runs right after a new row is inserted into auth.users (by signup form or
-- any other path). If there's no purchase on file for that email, raises an
-- exception — which rolls back the entire signup, including the account
-- itself, so account creation is fully aborted, not just left unfinished.
create or replace function public.handle_new_user_purchase_check()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
declare
  matched record;
  match_count int;
begin
  select count(*) into match_count
  from pending_access
  where lower(email) = lower(new.email);

  if match_count = 0 then
    raise exception 'No purchase found for this email. Buy a program first, then create your account with the same email.';
  end if;

  -- Grant access for every program this email has paid for, then clear those
  -- pending rows so they can't be replayed into a second account later.
  for matched in
    select * from pending_access where lower(email) = lower(new.email)
  loop
    insert into purchases (user_id, program_id, stripe_session_id, stripe_payment_intent, status)
    values (new.id, matched.program_id, matched.stripe_session_id, matched.stripe_payment_intent, 'active')
    on conflict (user_id, program_id) do nothing;
  end loop;

  delete from pending_access where lower(email) = lower(new.email);

  return new;
end;
$$;

-- Fires right after a new row lands in auth.users. (Not "before insert" —
-- that seems like it should work for granting access, but it doesn't: at
-- that point the user row isn't actually saved yet, so any attempt to insert
-- into `purchases` — which references auth.users(id) via foreign key —
-- fails immediately. Raising an exception from an AFTER trigger still rolls
-- back the entire signup, so the "reject non-purchasers" behavior is unchanged.)
drop trigger if exists enforce_purchase_before_signup on auth.users;
create trigger enforce_purchase_before_signup
  after insert on auth.users
  for each row execute function public.handle_new_user_purchase_check();

-- ─────────────────────────────────────────────────────────────
-- ADMIN VIEW DATA
-- One function that returns everything the admin page needs in one call:
-- every client, which program(s) they've bought, and their check-in
-- activity. Restricted to admins only — anyone else gets an empty result.
-- ─────────────────────────────────────────────────────────────

create or replace function public.admin_list_clients()
returns table (
  user_id uuid,
  email text,
  full_name text,
  program_id text,
  program_name text,
  purchase_status text,
  purchased_at timestamptz,
  checkin_count bigint,
  last_checkin date
)
language plpgsql
security definer
set search_path = public
as $$
begin
  if not is_admin() then
    return; -- empty result for anyone who isn't an admin
  end if;

  return query
    select
      u.id as user_id,
      u.email::text,
      (u.raw_user_meta_data ->> 'full_name')::text as full_name,
      p.program_id,
      pr.name as program_name,
      p.status as purchase_status,
      p.created_at as purchased_at,
      count(wl.id) as checkin_count,
      max(wl.log_date) as last_checkin
    from purchases p
    join auth.users u on u.id = p.user_id
    join programs pr on pr.id = p.program_id
    left join workout_logs wl on wl.user_id = p.user_id
    group by u.id, u.email, u.raw_user_meta_data, p.program_id, pr.name, p.status, p.created_at
    order by p.created_at desc;
end;
$$;

grant execute on function public.admin_list_clients() to authenticated;

-- ─────────────────────────────────────────────────────────────
-- SEED DATA — public program info
-- ─────────────────────────────────────────────────────────────

insert into programs (id, name, weeks, price_cents, description) values
(
  'kickstart-4wk',
  '4-Week Kickstart',
  4,
  4900,
  'Build strength, build capacity, build momentum. A 4-week strength + conditioning program, 4 training days per week.'
),
(
  'built-for-more-6wk',
  'Built For More (6-Week)',
  6,
  7900,
  'The full Built For More training experience: progressive strength, conditioning, work capacity, and real-world performance.'
),
(
  'phenom-regime-8wk',
  'The Phenom Regime (8-Week)',
  8,
  14900,
  'The complete 8-week transformation: advanced programming, deep conditioning blocks, and long-range progression tracking.'
)
on conflict (id) do nothing;

-- ─────────────────────────────────────────────────────────────
-- SEED DATA — protected program content (the actual workout plans)
-- Edit any time in Table Editor → program_content → click the row → edit "content".
-- ─────────────────────────────────────────────────────────────

insert into program_content (program_id, content) values
(
  'kickstart-4wk',
  $json$[
    {
      "week": 1,
      "focus": "Foundation — learn the movements. Leave 2–3 reps in reserve on every set. Goal: establish your starting point.",
      "days": [
        {
          "day": "Monday",
          "title": "Lower Body Strength",
          "warmup": "5–8 min: 3 min brisk cardio, 10 bodyweight squats, 10 reverse lunges, 10 glute bridges, 10 arm circles each way, 10 band pull-aparts, 5 inchworms",
          "exercises": [
            "Goblet Squat — 3x8-10, rest 90s",
            "Dumbbell Romanian Deadlift — 3x8-10, rest 90s",
            "Reverse Lunge — 3x8/leg, rest 60-90s",
            "Dumbbell Hip Thrust — 3x10-12",
            "Standing Calf Raise — 3x12-15"
          ],
          "finisher": "8 min: alternate 1 min of 10 kettlebell swings / 1 min brisk incline walk, 4 rounds"
        },
        {
          "day": "Tuesday",
          "title": "Upper Body Strength",
          "warmup": "Same general warm-up as Monday",
          "exercises": [
            "Dumbbell Bench Press — 3x8-10, rest 90s",
            "One-Arm Dumbbell Row — 3x10/side",
            "Dumbbell Shoulder Press — 3x8-10",
            "Lat Pulldown — 3x10-12",
            "Dumbbell Hammer Curl — 2x10-12",
            "Rope Triceps Pushdown — 2x10-12"
          ],
          "finisher": "Bike/rower/treadmill: 20s hard / 40s easy, 8 rounds"
        },
        {
          "day": "Wednesday",
          "title": "Recovery",
          "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]
        },
        {
          "day": "Thursday",
          "title": "Full Body Strength + Conditioning",
          "exercises": [
            "Trap-Bar Deadlift — 3x6-8, rest 2 min (alt: kettlebell deadlift)",
            "Dumbbell Incline Press — 3x8-10",
            "Bulgarian Split Squat — 3x8/leg (beginner: standard split squat)",
            "Seated Cable Row — 3x10",
            "Farmer Carry — 3x30-40s"
          ],
          "finisher": "Conditioning circuit, 3 rounds: 10 kettlebell swings, 10 push-ups, 12 reverse lunges, 30s mountain climbers, 250m row or 1 min fast walk — rest 60-90s between rounds"
        },
        {
          "day": "Friday",
          "title": "Recovery",
          "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]
        },
        {
          "day": "Saturday",
          "title": "Athletic Conditioning",
          "exercises": [
            "Circuit A x4 rounds: Step-Ups 10/leg, Push-Ups 10-15, Kettlebell Deadlift 12, Battle Ropes 30s — rest 60s between rounds",
            "Circuit B: cardio intervals (treadmill/bike/rower/elliptical), 1 min moderate-hard / 1 min easy for 10 min",
            "Core finisher x2 rounds: Dead Bug 8/side, Front Plank 30-45s, Side Plank 20-30s/side"
          ]
        },
        {
          "day": "Sunday",
          "title": "Recovery",
          "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]
        }
      ]
    },
    {
      "week": 2,
      "focus": "Build — same exercises. Add 1–2 reps where the rep range allows it. Goal: increase total quality work.",
      "days": [
        {"day": "Monday", "title": "Lower Body Strength", "exercises": ["Goblet Squat — 3x8-10, rest 90s", "Dumbbell Romanian Deadlift — 3x8-10, rest 90s", "Reverse Lunge — 3x8/leg, rest 60-90s", "Dumbbell Hip Thrust — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "8 min: alternate 1 min of 10 kettlebell swings / 1 min brisk incline walk, 4 rounds"},
        {"day": "Tuesday", "title": "Upper Body Strength", "exercises": ["Dumbbell Bench Press — 3x8-10, rest 90s", "One-Arm Dumbbell Row — 3x10/side", "Dumbbell Shoulder Press — 3x8-10", "Lat Pulldown — 3x10-12", "Dumbbell Hammer Curl — 2x10-12", "Rope Triceps Pushdown — 2x10-12"], "finisher": "Bike/rower/treadmill: 20s hard / 40s easy, 8 rounds"},
        {"day": "Wednesday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Thursday", "title": "Full Body Strength + Conditioning", "exercises": ["Trap-Bar Deadlift — 3x6-8, rest 2 min", "Dumbbell Incline Press — 3x8-10", "Bulgarian Split Squat — 3x8/leg", "Seated Cable Row — 3x10", "Farmer Carry — 3x30-40s"], "finisher": "Conditioning circuit, 3 rounds: 10 kettlebell swings, 10 push-ups, 12 reverse lunges, 30s mountain climbers, 250m row or 1 min fast walk"},
        {"day": "Friday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Saturday", "title": "Athletic Conditioning", "exercises": ["Circuit A x4 rounds: Step-Ups 10/leg, Push-Ups 10-15, Kettlebell Deadlift 12, Battle Ropes 30s", "Circuit B: cardio intervals, 1 min moderate-hard / 1 min easy for 10 min", "Core finisher x2 rounds: Dead Bug 8/side, Front Plank 30-45s, Side Plank 20-30s/side"]},
        {"day": "Sunday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]}
      ]
    },
    {
      "week": 3,
      "focus": "Push — if you hit the top of the rep range on every set with good form, increase the weight (a small increase is enough). Don't sacrifice technique for load.",
      "days": [
        {"day": "Monday", "title": "Lower Body Strength", "exercises": ["Goblet Squat — 3x8-10, rest 90s", "Dumbbell Romanian Deadlift — 3x8-10, rest 90s", "Reverse Lunge — 3x8/leg, rest 60-90s", "Dumbbell Hip Thrust — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "8 min: alternate 1 min of 10 kettlebell swings / 1 min brisk incline walk, 4 rounds"},
        {"day": "Tuesday", "title": "Upper Body Strength", "exercises": ["Dumbbell Bench Press — 3x8-10, rest 90s", "One-Arm Dumbbell Row — 3x10/side", "Dumbbell Shoulder Press — 3x8-10", "Lat Pulldown — 3x10-12", "Dumbbell Hammer Curl — 2x10-12", "Rope Triceps Pushdown — 2x10-12"], "finisher": "Bike/rower/treadmill: 20s hard / 40s easy, 8 rounds"},
        {"day": "Wednesday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Thursday", "title": "Full Body Strength + Conditioning", "exercises": ["Trap-Bar Deadlift — 3x6-8, rest 2 min", "Dumbbell Incline Press — 3x8-10", "Bulgarian Split Squat — 3x8/leg", "Seated Cable Row — 3x10", "Farmer Carry — 3x30-40s"], "finisher": "Conditioning circuit, 3 rounds: 10 kettlebell swings, 10 push-ups, 12 reverse lunges, 30s mountain climbers, 250m row or 1 min fast walk"},
        {"day": "Friday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Saturday", "title": "Athletic Conditioning", "exercises": ["Circuit A x4 rounds: Step-Ups 10/leg, Push-Ups 10-15, Kettlebell Deadlift 12, Battle Ropes 30s", "Circuit B: cardio intervals, 1 min moderate-hard / 1 min easy for 10 min", "Core finisher x2 rounds: Dead Bug 8/side, Front Plank 30-45s, Side Plank 20-30s/side"]},
        {"day": "Sunday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]}
      ]
    },
    {
      "week": 4,
      "focus": "Perform — your strongest week. Try to beat Week 3 through slightly more weight, more reps, better technique, or better conditioning output. You don't need all four at once — small improvements compound.",
      "days": [
        {"day": "Monday", "title": "Lower Body Strength", "exercises": ["Goblet Squat — 3x8-10, rest 90s", "Dumbbell Romanian Deadlift — 3x8-10, rest 90s", "Reverse Lunge — 3x8/leg, rest 60-90s", "Dumbbell Hip Thrust — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "8 min: alternate 1 min of 10 kettlebell swings / 1 min brisk incline walk, 4 rounds"},
        {"day": "Tuesday", "title": "Upper Body Strength", "exercises": ["Dumbbell Bench Press — 3x8-10, rest 90s", "One-Arm Dumbbell Row — 3x10/side", "Dumbbell Shoulder Press — 3x8-10", "Lat Pulldown — 3x10-12", "Dumbbell Hammer Curl — 2x10-12", "Rope Triceps Pushdown — 2x10-12"], "finisher": "Bike/rower/treadmill: 20s hard / 40s easy, 8 rounds"},
        {"day": "Wednesday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Thursday", "title": "Full Body Strength + Conditioning", "exercises": ["Trap-Bar Deadlift — 3x6-8, rest 2 min", "Dumbbell Incline Press — 3x8-10", "Bulgarian Split Squat — 3x8/leg", "Seated Cable Row — 3x10", "Farmer Carry — 3x30-40s"], "finisher": "Conditioning circuit, 3 rounds: 10 kettlebell swings, 10 push-ups, 12 reverse lunges, 30s mountain climbers, 250m row or 1 min fast walk"},
        {"day": "Friday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]},
        {"day": "Saturday", "title": "Athletic Conditioning", "exercises": ["Circuit A x4 rounds: Step-Ups 10/leg, Push-Ups 10-15, Kettlebell Deadlift 12, Battle Ropes 30s", "Circuit B: cardio intervals, 1 min moderate-hard / 1 min easy for 10 min", "Core finisher x2 rounds: Dead Bug 8/side, Front Plank 30-45s, Side Plank 20-30s/side"]},
        {"day": "Sunday", "title": "Recovery", "exercises": ["20–30 min walk, light mobility, easy cycling, stretching, or complete rest"]}
      ]
    }
  ]$json$::jsonb
),
(
  'built-for-more-6wk',
  $json$[
  {"week": 1, "focus": "Establish — find appropriate working weights. Target 3 RIR. Conditioning intervals: 6 rounds.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power", "exercises": ["Box Jump — 3x3-5, rest 60-90s", "Back Squat — 4x5-6, rest 2-3 min", "Romanian Deadlift — 4x6-8, rest 2 min", "Bulgarian Split Squat — 3x8/leg", "Seated or Lying Leg Curl — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "Sled Push — 5 rounds x20-30m, rest 45-60s (alt: 30s hard bike / 60s easy x5)"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy", "exercises": ["Barbell Bench Press — 4x5-6, rest 2-3 min", "Pull-Up / Assisted Pull-Up — 4x6-8", "Dumbbell Incline Press — 3x8-10", "Chest-Supported Row — 3x8-10", "Dumbbell Lateral Raise — 3x12-15", "Superset: Dumbbell Curl 3x10-12 + Rope Triceps Pushdown 3x10-12, rest 60s after both"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min steady cardio at 5-6/10 effort", "Intervals: 30s hard / 60s easy — 6 rounds", "Mobility flow: 90/90 Hip Switch 2x8/dir, Half-Kneeling Hip Flexor Stretch 2x30s/side, World's Greatest Stretch 2x5/side, Thoracic Rotation 2x8/side, Ankle Rocks 2x10/side"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Leg Press — 4x8-12", "Dumbbell Romanian Deadlift — 3x10-12", "Walking Lunge — 3x10/leg", "Leg Extension — 3x12-15", "Seated Leg Curl — 3x12-15", "Seated Calf Raise — 4x12-15"], "finisher": "Core circuit x3 rounds: Hanging Knee Raise 10-12, Pallof Press 10/side, Plank 45s — rest ~45s"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning", "exercises": ["Dumbbell Bench Press — 4x8-10", "Lat Pulldown — 4x8-12", "Seated Dumbbell Shoulder Press — 3x8-10", "Seated Cable Row — 3x10-12", "Superset: Cable Lateral Raise 3x12-15 + Face Pull 3x12-15", "Superset: Hammer Curl 3x10-12 + Overhead Cable Triceps Extension 3x10-12"], "finisher": "Conditioning finisher x4 rounds: 10 kettlebell swings, 10 push-ups, 12 reverse lunges, 250m row or 60s hard bike, 30s farmer carry — rest 60-90s"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement (walk, easy cycling, swimming, light hiking) at 3-4/10", "Recovery mobility x1-2 rounds: Couch Stretch 45s/side, 90/90 Hip Stretch 45s/side, Child's Pose w/ Lat Reach 45s/side, Adductor Rock Back 10/side, Open Book Rotation 8/side, Calf Stretch 30-45s/side"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training. Walk if you want, stretch if it feels good — otherwise recover."]}
  ]},
  {"week": 2, "focus": "Control — try to increase repetitions while improving technique. Target 2-3 RIR. Conditioning intervals: 6 rounds.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power", "exercises": ["Box Jump — 3x3-5, rest 60-90s", "Back Squat — 4x5-6, rest 2-3 min", "Romanian Deadlift — 4x6-8, rest 2 min", "Bulgarian Split Squat — 3x8/leg", "Seated or Lying Leg Curl — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "Sled Push — 5 rounds x20-30m, rest 45-60s"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy", "exercises": ["Barbell Bench Press — 4x5-6, rest 2-3 min", "Pull-Up / Assisted Pull-Up — 4x6-8", "Dumbbell Incline Press — 3x8-10", "Chest-Supported Row — 3x8-10", "Dumbbell Lateral Raise — 3x12-15", "Superset: Dumbbell Curl 3x10-12 + Rope Triceps Pushdown 3x10-12"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min steady cardio at 5-6/10 effort", "Intervals: 30s hard / 60s easy — 6 rounds", "Mobility flow (same as Week 1)"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Leg Press — 4x8-12", "Dumbbell Romanian Deadlift — 3x10-12", "Walking Lunge — 3x10/leg", "Leg Extension — 3x12-15", "Seated Leg Curl — 3x12-15", "Seated Calf Raise — 4x12-15"], "finisher": "Core circuit x3 rounds"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning", "exercises": ["Dumbbell Bench Press — 4x8-10", "Lat Pulldown — 4x8-12", "Seated Dumbbell Shoulder Press — 3x8-10", "Seated Cable Row — 3x10-12", "Superset: Cable Lateral Raise + Face Pull, 3x12-15 each", "Superset: Hammer Curl + Overhead Cable Triceps Extension, 3x10-12 each"], "finisher": "Conditioning finisher x4 rounds"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement at 3-4/10", "Recovery mobility x1-2 rounds"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training."]}
  ]},
  {"week": 3, "focus": "Build — increase resistance on movements where you've reached the top of the rep range. Target ~2 RIR. Conditioning intervals: 8 rounds.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power", "exercises": ["Box Jump — 3x3-5, rest 60-90s", "Back Squat — 4x5-6, rest 2-3 min", "Romanian Deadlift — 4x6-8, rest 2 min", "Bulgarian Split Squat — 3x8/leg", "Seated or Lying Leg Curl — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "Sled Push — 5 rounds x20-30m"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy", "exercises": ["Barbell Bench Press — 4x5-6, rest 2-3 min", "Pull-Up / Assisted Pull-Up — 4x6-8", "Dumbbell Incline Press — 3x8-10", "Chest-Supported Row — 3x8-10", "Dumbbell Lateral Raise — 3x12-15", "Superset: Dumbbell Curl + Rope Triceps Pushdown, 3x10-12 each"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min steady cardio at 5-6/10 effort", "Intervals: 30s hard / 60s easy — 8 rounds", "Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Leg Press — 4x8-12", "Dumbbell Romanian Deadlift — 3x10-12", "Walking Lunge — 3x10/leg", "Leg Extension — 3x12-15", "Seated Leg Curl — 3x12-15", "Seated Calf Raise — 4x12-15"], "finisher": "Core circuit x3 rounds"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning", "exercises": ["Dumbbell Bench Press — 4x8-10", "Lat Pulldown — 4x8-12", "Seated Dumbbell Shoulder Press — 3x8-10", "Seated Cable Row — 3x10-12", "Superset: Cable Lateral Raise + Face Pull", "Superset: Hammer Curl + Overhead Cable Triceps Extension"], "finisher": "Conditioning finisher x4 rounds"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement at 3-4/10", "Recovery mobility x1-2 rounds"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training."]}
  ]},
  {"week": 4, "focus": "Pressure — try to outperform Week 3 through additional reps or modest weight increases. Target 1-2 RIR. Conditioning intervals: 8 rounds.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power", "exercises": ["Box Jump — 3x3-5", "Back Squat — 4x5-6, rest 2-3 min", "Romanian Deadlift — 4x6-8", "Bulgarian Split Squat — 3x8/leg", "Seated or Lying Leg Curl — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "Sled Push — 5 rounds x20-30m"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy", "exercises": ["Barbell Bench Press — 4x5-6", "Pull-Up / Assisted Pull-Up — 4x6-8", "Dumbbell Incline Press — 3x8-10", "Chest-Supported Row — 3x8-10", "Dumbbell Lateral Raise — 3x12-15", "Superset: Dumbbell Curl + Rope Triceps Pushdown"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min at 5-6/10", "Intervals: 30s hard / 60s easy — 8 rounds", "Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Leg Press — 4x8-12", "Dumbbell Romanian Deadlift — 3x10-12", "Walking Lunge — 3x10/leg", "Leg Extension — 3x12-15", "Seated Leg Curl — 3x12-15", "Seated Calf Raise — 4x12-15"], "finisher": "Core circuit x3 rounds"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning", "exercises": ["Dumbbell Bench Press — 4x8-10", "Lat Pulldown — 4x8-12", "Seated Dumbbell Shoulder Press — 3x8-10", "Seated Cable Row — 3x10-12", "Superset: Cable Lateral Raise + Face Pull", "Superset: Hammer Curl + Overhead Cable Triceps Extension"], "finisher": "Conditioning finisher x4 rounds"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement at 3-4/10", "Recovery mobility x1-2 rounds"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training."]}
  ]},
  {"week": 5, "focus": "Performance — your hardest week. Attack your working sets without sacrificing technique. Target ~1 RIR on final sets. Conditioning intervals: 10 rounds. Don't confuse hard training with sloppy training.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power", "exercises": ["Box Jump — 3x3-5", "Back Squat — 4x5-6, rest 2-3 min", "Romanian Deadlift — 4x6-8", "Bulgarian Split Squat — 3x8/leg", "Seated or Lying Leg Curl — 3x10-12", "Standing Calf Raise — 3x12-15"], "finisher": "Sled Push — 5 rounds x20-30m"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy", "exercises": ["Barbell Bench Press — 4x5-6", "Pull-Up / Assisted Pull-Up — 4x6-8", "Dumbbell Incline Press — 3x8-10", "Chest-Supported Row — 3x8-10", "Dumbbell Lateral Raise — 3x12-15", "Superset: Dumbbell Curl + Rope Triceps Pushdown"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min at 5-6/10", "Intervals: 30s hard / 60s easy — 10 rounds", "Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Leg Press — 4x8-12", "Dumbbell Romanian Deadlift — 3x10-12", "Walking Lunge — 3x10/leg", "Leg Extension — 3x12-15", "Seated Leg Curl — 3x12-15", "Seated Calf Raise — 4x12-15"], "finisher": "Core circuit x3 rounds"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning", "exercises": ["Dumbbell Bench Press — 4x8-10", "Lat Pulldown — 4x8-12", "Seated Dumbbell Shoulder Press — 3x8-10", "Seated Cable Row — 3x10-12", "Superset: Cable Lateral Raise + Face Pull", "Superset: Hammer Curl + Overhead Cable Triceps Extension"], "finisher": "Conditioning finisher x4 rounds"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement at 3-4/10", "Recovery mobility x1-2 rounds"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training."]}
  ]},
  {"week": 6, "focus": "Consolidate — reduce working sets ~25-35% (e.g. 4 sets → 3, 3 sets → 2) while maintaining training quality. Keep normal weights or reduce slightly. Train around 3 RIR. Conditioning intervals return to 6 rounds. Goal: dissipate fatigue while maintaining fitness.", "days": [
    {"day": "Monday", "title": "Lower Strength + Power (reduced volume)", "exercises": ["Box Jump — 2-3x3-5", "Back Squat — 3x5-6, rest 2-3 min", "Romanian Deadlift — 3x6-8", "Bulgarian Split Squat — 2x8/leg", "Seated or Lying Leg Curl — 2x10-12", "Standing Calf Raise — 2x12-15"], "finisher": "Sled Push — 3-4 rounds x20-30m"},
    {"day": "Tuesday", "title": "Upper Strength + Hypertrophy (reduced volume)", "exercises": ["Barbell Bench Press — 3x5-6", "Pull-Up / Assisted Pull-Up — 3x6-8", "Dumbbell Incline Press — 2x8-10", "Chest-Supported Row — 2x8-10", "Dumbbell Lateral Raise — 2x12-15", "Superset: Dumbbell Curl + Rope Triceps Pushdown, 2x10-12 each"]},
    {"day": "Wednesday", "title": "Conditioning + Mobility", "exercises": ["Zone 2: 20 min at 5-6/10", "Intervals: 30s hard / 60s easy — 6 rounds", "Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy (reduced volume)", "exercises": ["Leg Press — 3x8-12", "Dumbbell Romanian Deadlift — 2x10-12", "Walking Lunge — 2x10/leg", "Leg Extension — 2x12-15", "Seated Leg Curl — 2x12-15", "Seated Calf Raise — 3x12-15"], "finisher": "Core circuit x2 rounds"},
    {"day": "Friday", "title": "Upper Hypertrophy + Conditioning (reduced volume)", "exercises": ["Dumbbell Bench Press — 3x8-10", "Lat Pulldown — 3x8-12", "Seated Dumbbell Shoulder Press — 2x8-10", "Seated Cable Row — 2x10-12", "Superset: Cable Lateral Raise + Face Pull, 2x12-15 each", "Superset: Hammer Curl + Overhead Cable Triceps Extension, 2x10-12 each"], "finisher": "Conditioning finisher x3 rounds"},
    {"day": "Saturday", "title": "Active Recovery", "exercises": ["20-40 min easy movement at 3-4/10", "Recovery mobility x1-2 rounds"]},
    {"day": "Sunday", "title": "Full Recovery", "exercises": ["No structured training. Program complete — retest your Week 1 benchmarks."]}
  ]}
]$json$::jsonb
),
(
  'phenom-regime-8wk',
  $json$[
  {"week": 1, "focus": "Accumulation — build volume and establish working loads. Main lifts: 2-3 RIR. Accessories: 1-3 RIR. Conditioning stays moderate (5 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7, rest 2-3 min", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m, rest 60-90s (alt: bike sprint 15s hard/75s easy x6)"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5, rest 3 min", "Weighted Pull-Up — 4x4-6 (alt: heavy neutral-grip pulldown)", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8 (alt: close-grip bench press)", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 5 rounds", "Block C — Mobility: 90/90 Hip Rotation 2x8/dir, Cossack Squat 2x6/side, Half-Kneeling Hip Flexor Stretch 2x30-45s/side, Thoracic Rotation 2x8/side, Wall Ankle Mobilization 2x10/ankle"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"], "finisher": "Optional intensifier on final leg extension or leg curl set only: drop weight 20-25%, continue 6-10 more controlled reps"},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension, 3x10-12 each"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min: min1 12 kettlebell swings, min2 10 burpees, min3 12 cal bike/row — 5 rounds", "Carry series x4 rounds: Farmer carry 40m, Front-rack carry 30m, Suitcase carry 20m/side, rest 60-90s"], "finisher": "Core work (2x/week): Ab Wheel Rollout 3x8-12, Hanging Leg Raise 3x8-12, Pallof Press 3x10/side, Weighted Carry 2x40m"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 2, "focus": "Accumulation — build volume and establish working loads. Main lifts: 2-3 RIR. Accessories: 1-3 RIR. Conditioning stays moderate (5 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5, rest 3 min", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 5 rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"]},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds"], "finisher": "Core work"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 3, "focus": "Intensification — increase loading on major lifts. Main lifts: 1-2 RIR. Accessory volume stays high. Conditioning becomes more demanding (6 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 6 rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"]},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds"], "finisher": "Core work"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 4, "focus": "Intensification — increase loading on major lifts. Main lifts: 1-2 RIR. Accessory volume stays high. Conditioning becomes more demanding (6 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 6 rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"]},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds"], "finisher": "Core work"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 5, "focus": "Overload — push strength and hypertrophy performance. Main lifts: ~1 RIR. Selected accessories may reach 0-1 RIR on the final set. Conditioning intensity climbs (7 threshold rounds). Optional arm intensifier (mechanical drop set) becomes available this week.", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 7 rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"], "finisher": "Optional intensifier on final leg extension or leg curl set (once per session)"},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"], "finisher": "Optional arm intensifier: mechanical drop set — Incline Curl → Standing DB Curl → Hammer Curl, each to ~1 RIR (once per workout)"},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds", "Optional performance finisher (highly conditioned lifters only): Assault Bike 10s max / 50s easy x6"], "finisher": "Core work"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 6, "focus": "Overload — push strength and hypertrophy performance. Main lifts: ~1 RIR. Selected accessories may reach 0-1 RIR on the final set. Conditioning intensity climbs (7 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 7 rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"]},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds"], "finisher": "Core work"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 7, "focus": "Performance — highest-quality training week. Outperform previous weeks through load, repetitions, execution, or work capacity — not reckless failure. Conditioning peaks (8 threshold rounds).", "days": [
    {"day": "Monday", "title": "Lower Strength", "exercises": ["Back Squat — 5x3-5, rest 3-4 min", "Romanian Deadlift — 4x5-7", "Front-Foot Elevated Split Squat — 3x6-8/leg", "Barbell Hip Thrust — 4x6-8", "Seated Leg Curl — 3x8-10", "Standing Calf Raise — 4x8-12"], "finisher": "Heavy Sled Push — 6 rounds x20m"},
    {"day": "Tuesday", "title": "Upper Strength", "exercises": ["Barbell Bench Press — 5x3-5", "Weighted Pull-Up — 4x4-6", "Standing Overhead Press — 4x5-6", "Pendlay Row — 4x5-7", "Weighted Dip — 3x6-8", "Face Pull — 3x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility", "exercises": ["Block A — Aerobic base: 20-30 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 8 rounds", "Block C — Mobility flow", "Performance test: retest Week 1 conditioning benchmark (2,000m row / 1-mile run / 10-min bike distance / 20-min avg row pace)"]},
    {"day": "Thursday", "title": "Lower Hypertrophy", "exercises": ["Hack Squat — 4x8-10", "Romanian Deadlift — 3x8-10", "Walking Dumbbell Lunge — 3x10-12/leg", "Leg Press — 3x12-15", "Leg Extension — 3x12-15", "Lying Leg Curl — 3x10-15", "Seated Calf Raise — 4x12-15"]},
    {"day": "Friday", "title": "Upper Hypertrophy", "exercises": ["Incline Dumbbell Press — 4x8-12", "Chest-Supported Row — 4x8-12", "Machine Chest Press — 3x10-12", "Neutral-Grip Lat Pulldown — 3x10-12", "Cable Lateral Raise — 4x12-20", "Reverse Pec Deck — 3x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension"]},
    {"day": "Saturday", "title": "Full Body Power + Advanced Conditioning", "exercises": ["Power: Box Jump 4x3, Trap-Bar Deadlift 5x3, Push Press 4x4-6", "EMOM 15 min — 5 rounds", "Carry series x4 rounds"], "finisher": "Core work. Also retest Week 1 main lift numbers this week (back squat, bench press, weighted pull-up)."},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required."]}
  ]},
  {"week": 8, "focus": "Deload + Consolidation — mandatory. Reduce working sets ~40-50% (e.g. 5 sets → 3, 4 sets → 2). Keep ~3-4 RIR. Reduce conditioning intensity. No intensity techniques, no drop sets, no grinders. Let fatigue dissipate before the next block.", "days": [
    {"day": "Monday", "title": "Lower Strength (deload)", "exercises": ["Back Squat — 3x3-5, rest 3-4 min", "Romanian Deadlift — 2x5-7", "Front-Foot Elevated Split Squat — 2x6-8/leg", "Barbell Hip Thrust — 2x6-8", "Seated Leg Curl — 2x8-10", "Standing Calf Raise — 2x8-12"], "finisher": "Sled Push — 3 rounds x20m, light"},
    {"day": "Tuesday", "title": "Upper Strength (deload)", "exercises": ["Barbell Bench Press — 3x3-5", "Weighted Pull-Up — 2x4-6 (light or bodyweight)", "Standing Overhead Press — 2x5-6", "Pendlay Row — 2x5-7", "Weighted Dip — 2x6-8", "Face Pull — 2x12-15"]},
    {"day": "Wednesday", "title": "Advanced Conditioning + Mobility (reduced)", "exercises": ["Block A — Aerobic base: 20 min at 5-6/10", "Block B — Threshold intervals: 2 min hard / 1 min easy — 4 easy-moderate rounds", "Block C — Mobility flow"]},
    {"day": "Thursday", "title": "Lower Hypertrophy (deload)", "exercises": ["Hack Squat — 2x8-10", "Romanian Deadlift — 2x8-10", "Walking Dumbbell Lunge — 2x10-12/leg", "Leg Press — 2x12-15", "Leg Extension — 2x12-15", "Lying Leg Curl — 2x10-15", "Seated Calf Raise — 2x12-15"], "exercises_note": "No intensifiers this week"},
    {"day": "Friday", "title": "Upper Hypertrophy (deload)", "exercises": ["Incline Dumbbell Press — 2x8-12", "Chest-Supported Row — 2x8-12", "Machine Chest Press — 2x10-12", "Neutral-Grip Lat Pulldown — 2x10-12", "Cable Lateral Raise — 2x12-20", "Reverse Pec Deck — 2x12-15", "Superset: Incline Dumbbell Curl + Rope Triceps Extension, 2x10-12 each"]},
    {"day": "Saturday", "title": "Full Body Power + Conditioning (reduced)", "exercises": ["Power: Box Jump 3x3, Trap-Bar Deadlift 3x3 (light), Push Press 3x4-6", "EMOM 10 min — reduced rounds", "Carry series x2 rounds"], "finisher": "Light core work only"},
    {"day": "Sunday", "title": "Recovery", "exercises": ["No structured training required. Block complete — reassess before starting the next training cycle."]}
  ]}
]$json$::jsonb
)
on conflict (program_id) do update set content = excluded.content, updated_at = now();
