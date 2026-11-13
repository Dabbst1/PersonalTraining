-- ═══════════════════════════════════════════════════════════════
-- FIX: SPAM IN COACHING INQUIRIES
--
-- Run this ONCE in Supabase → SQL Editor, AFTER deploying the
-- submit-inquiry edge function (see SETUP.md). Safe to re-run.
--
-- What it does:
--   1. Closes the public insert door. Bots were writing straight into
--      `inquiries` using the public anon key in the page source. After this,
--      the only way in is the submit-inquiry edge function, which filters
--      bots before saving.
--   2. Adds columns the function uses: flagged, spam_reasons, ip_hash.
--   3. Lets admins delete inquiries (for the "Delete" button in the inbox).
--   4. Removes the spam that's already in there.
-- ═══════════════════════════════════════════════════════════════

-- 1. Close the public insert door ────────────────────────────────
drop policy if exists "Anyone can submit a coaching inquiry" on inquiries;
-- With RLS on and no insert policy, the anon key can no longer insert.
-- The edge function uses the service role key, which bypasses RLS.

-- 2. New columns ─────────────────────────────────────────────────
alter table inquiries add column if not exists flagged boolean not null default false;
alter table inquiries add column if not exists spam_reasons text[] not null default '{}';
alter table inquiries add column if not exists ip_hash text; -- hashed, never the raw IP
create index if not exists inquiries_created_at_idx on inquiries (created_at);
create index if not exists inquiries_email_idx on inquiries (email);
create index if not exists inquiries_ip_hash_idx on inquiries (ip_hash);

-- 3. Admins can delete ───────────────────────────────────────────
drop policy if exists "Only admins can delete inquiries" on inquiries;
create policy "Only admins can delete inquiries"
  on inquiries for delete
  using (is_admin());

-- 4. Clean out existing spam ─────────────────────────────────────
-- Same rule the edge function uses: one long word, letters only, mixed
-- case, 3+ capitals after the first letter ("rDxcylKWeyCfMCJqq").
create or replace function looks_like_gibberish(v text) returns boolean
language sql immutable as $$
  select v is not null
     and length(trim(v)) >= 12
     and trim(v) ~ '^[A-Za-z]+$'
     and trim(v) ~ '[a-z]'
     and length(regexp_replace(substr(trim(v), 2), '[^A-Z]', '', 'g')) >= 3;
$$;

-- PREVIEW first — run just this SELECT to see what will be deleted:
-- select full_name, email, goal_importance, already_tried, injuries, created_at
-- from inquiries
-- where (looks_like_gibberish(goal_importance)::int
--      + looks_like_gibberish(already_tried)::int
--      + looks_like_gibberish(injuries)::int) >= 2
-- order by created_at desc;

delete from inquiries
where (looks_like_gibberish(goal_importance)::int
     + looks_like_gibberish(already_tried)::int
     + looks_like_gibberish(injuries)::int) >= 2;
