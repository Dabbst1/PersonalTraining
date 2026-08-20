# Built For More — Client Accounts Setup Guide

This adds the following to your existing site:
- **auth.html** — sign up / log in / forgot password — accounts can only be created after a purchase (see below)
- **reset-password.html** — where a password-reset email link lands
- **account.html** — clients update their own email/password
- **dashboard.html** — the protected "My Program" page, with a switcher if someone owns more than one program and a renewal banner near the end of a program
- **checkin.html** — the protected "Check In" calendar, with a streak counter and weekly progress chart
- **admin.html** — a client list for you only: who bought what, check-in activity, refund status
- **index.html** — same site as before, "Buy This Program" goes straight to Stripe checkout

None of this requires learning to code — just creating a few free accounts and copying/pasting some keys.

**The purchase order matters here: buy first, then create an account.** Someone has to complete a purchase before they can create a login at all — this is enforced by the database itself (see Part 1), not just by hiding a button.

---

## Part 1 — Supabase (accounts + database) — ~15 minutes

1. Go to **supabase.com** → sign up → **New Project**. Pick any name/region, save the database password somewhere safe.
2. Once the project loads: **SQL Editor** (left sidebar) → **New Query**. Open `supabase-schema.sql` from this folder, paste the whole thing in, click **Run**. This creates your tables, loads your three full programs, and sets up the purchase-gated signup, admin access, and waiver tracking described below.
3. **Project Settings → API** (left sidebar, gear icon). Copy:
   - **Project URL**
   - **anon public** key (NOT the `service_role` key — keep that one private, it's used only in Part 3)
4. Open `supabase-config.js` in this folder and paste those two values in at the top.
5. **Authentication → Settings** → turn off "Confirm email" so new accounts (and the waiver acceptance that happens right after signup) work in one step. **Authentication → URL Configuration** → add your site's `reset-password.html` URL (e.g. `https://dabbst1.github.io/PersonalTraining/reset-password.html`) to the Redirect URLs allowlist — password reset emails won't work without this.
6. **Make yourself an admin:** Table Editor → `admins` table → insert a row with your own email (the same one you'll use to log into the site). Add any staff the same way. This table controls who can see `admin.html` — nobody else can, even if they guess the URL.

**How the paywall actually works:** the real workout plans live in a separate database table (`program_content`) that is locked down at the database level — Supabase will only ever return a row from it to someone who has a matching *active* purchase on file. A refund flips that status and access disappears immediately (see Part 3).

**How the purchase-gated signup works:** most people pay before they have an account, so the Stripe webhook stores their purchase under their checkout email in a holding table called `pending_access`. The moment someone tries to create an account, a database trigger checks that table first — no matching email, no account, enforced by Postgres itself. If there IS a match, the same trigger creates the account and instantly converts the pending purchase into real access.

---

## Part 2 — Stripe (payments) — ~15 minutes

1. Go to **stripe.com** → sign up (or log in if you already have an account).
2. **Product catalog** → **Add product**, one for each program (4-Week Kickstart $49, Built For More $79, The Phenom Regime $149). For each product, note the **Price ID** (starts with `price_...`).
3. **Payment links** (left sidebar) → **New**, one per product. Make sure **"Collect customer email"** is on (default). Recommended: under **Custom fields**, add a required checkbox — *"I have read and agree to the liability waiver"* — as a second layer of waiver confirmation right at checkout, in addition to the one built into account creation (Part 1). Copy each Payment Link URL.
4. Open `stripe-config.js` in this folder and paste each Payment Link into the matching program id.

At this point, "Buy This Program" sends people to real Stripe checkout. Part 3 connects the database.

---

## Part 3 — The Stripe webhook (purchases + refunds + welcome email) — ~20 minutes

1. Install the Supabase CLI: **supabase.com/docs/guides/cli**.
2. In a terminal, inside a folder for this project:
   ```
   supabase login
   supabase link --project-ref YOUR_PROJECT_REF   (found in Project Settings → General)
   supabase functions new stripe-webhook
   ```
3. Replace the generated `supabase/functions/stripe-webhook/index.ts` with `supabase-edge-function-stripe-webhook.ts` from this folder.
4. In that file, fill in `PRICE_TO_PROGRAM` with your real Stripe Price IDs, and update `SITE_URL` / `FROM_EMAIL` near the top.
5. Set secrets:
   ```
   supabase secrets set STRIPE_SECRET_KEY=sk_live_xxxxx
   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=xxxxx
   supabase secrets set RESEND_API_KEY=re_xxxxx
   ```
   (`STRIPE_SECRET_KEY`: Stripe Dashboard → Developers → API keys. `SUPABASE_SERVICE_ROLE_KEY`: Supabase → Project Settings → API — never put this one in any file that goes on GitHub Pages. `RESEND_API_KEY`: see Part 5 below for getting this.)
6. Deploy:
   ```
   supabase functions deploy stripe-webhook --no-verify-jwt
   ```
   This prints a URL — copy it.
7. Stripe Dashboard → **Developers → Webhooks → Add endpoint**. Paste the URL, and select **both** `checkout.session.completed` **and** `charge.refunded`. Save, then copy the **Signing secret** it shows you:
   ```
   supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxxxx
   ```

**Test the purchase flow:** buy a program using Stripe's test mode. Check `pending_access` in Supabase (Table Editor) — a row should appear. Create an account with that email on your site — the row should move into `purchases`, and `dashboard.html` should show the program. You should also receive the welcome email (once Part 5 is set up).

**Test the refund flow:** refund that test purchase in Stripe. Within a few seconds, `purchases.status` for that row should flip to `refunded` in Supabase, and the program should disappear from `dashboard.html` on refresh.

---

## Part 4 — Admin view

Nothing to deploy — `admin.html` is already wired to a database function that only returns data to emails listed in the `admins` table (Part 1, step 6). Log in with an admin email and the "Admin" link appears in the nav automatically. It lists every client, their program(s), purchase status, check-in count, and last check-in date (flagged red if stale).

---

## Part 5 — Email (welcome messages + check-in reminders) — ~15 minutes

Both the webhook (Part 3) and the reminder function below use **Resend** (resend.com) to send email — it has a free tier that comfortably covers a small client list.

1. Sign up at **resend.com**.
2. **Domains** → add and verify your domain (follow their DNS instructions), so email comes from your own address. While testing, you can skip this and send from Resend's shared test domain instead.
3. **API Keys** → create one, copy it.
4. Use that key as `RESEND_API_KEY` in Part 3, step 5 above.
5. Update `FROM_EMAIL` in both `supabase-edge-function-stripe-webhook.ts` and `supabase-edge-function-checkin-reminders.ts` to an address on your verified domain.

### Check-in reminders (scheduled)

This one runs on a timer instead of reacting to an event, so it needs one extra step:

1. ```
   supabase functions new checkin-reminders
   ```
   Replace the generated file with `supabase-edge-function-checkin-reminders.ts` from this folder.
2. Set the same secrets as the webhook (`SUPABASE_SERVICE_ROLE_KEY`, `RESEND_API_KEY`) for this function too, if your CLI setup scopes secrets per-function.
3. Deploy:
   ```
   supabase functions deploy checkin-reminders --no-verify-jwt
   ```
4. Schedule it: Supabase Dashboard → **Edge Functions → checkin-reminders → Cron**, and set it to run once daily (e.g. 9:00 AM in your timezone). If your project's dashboard doesn't show a Cron tab, use the SQL Editor instead:
   ```sql
   select cron.schedule(
     'daily-checkin-reminders',
     '0 9 * * *',
     $$ select net.http_post(
       url := 'https://YOUR_PROJECT_REF.supabase.co/functions/v1/checkin-reminders',
       headers := '{"Authorization": "Bearer YOUR_ANON_KEY"}'::jsonb
     ) $$
   );
   ```
   (Requires the `pg_cron` and `pg_net` extensions — Database → Extensions → enable both first.)

---

## Part 6 — Recurring coaching subscriptions — ~15 minutes

Custom Coaching (1:1) is the one program that renews monthly instead of being a one-time purchase. It needs a couple of things the other three don't.

1. **Create it as a RECURRING price in Stripe** — Product catalog → your Custom Coaching product → when adding the price, make sure **"Recurring"** is selected (not "One time"), billing period **Monthly**. This is the one setting that makes it a subscription instead of a single charge — everything else (Payment Link, redirect URL) works exactly like your other three programs.
2. **Subscribe your webhook to two more events** — Stripe Dashboard → Developers → Webhooks → your endpoint → make sure it's subscribed to all four: `checkout.session.completed`, `charge.refunded`, `customer.subscription.updated`, `customer.subscription.deleted`. The last two are new — they're what let a cancellation actually take effect at the right time.
3. **Deploy the cancel-subscription function** — this is the one your clients use to cancel (or undo canceling) from their Account page:
   ```
   supabase functions new cancel-subscription
   ```
   Replace the generated file with `supabase-edge-function-cancel-subscription.ts` from this folder, then set secrets (same values as the webhook — only needed here if your CLI scopes secrets per-function):
   ```
   supabase secrets set STRIPE_SECRET_KEY=sk_live_xxxxx
   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=xxxxx
   ```
   Deploy it — **without** `--no-verify-jwt` this time, unlike the other two functions. This one should only work for someone who's actually logged in:
   ```
   supabase functions deploy cancel-subscription
   ```

**How cancellation actually works:** when a client clicks "Cancel" on their Account page, they don't lose access immediately — the subscription is marked to end at their next billing date, and Stripe simply won't renew it. They keep full access until then. If they change their mind, "Resume Subscription" undoes it with the same one click.

**Test it:** buy the coaching program yourself in Stripe test mode, confirm the "Coaching Subscription" card shows up on your Account page, click Cancel, and confirm it flips to "set to end on [date]" with a Resume option. In Stripe's dashboard, that subscription should show `Cancels on` the same date.

---

## Files in this folder

| File | What it is | Do you edit it? |
|---|---|---|
| `index.html` | Your main site (Programs section + account nav) | Only for content/copy changes |
| `auth.html` | Login / signup / forgot-password — signup blocked without a purchase, waiver required | No |
| `reset-password.html` | Where password-reset email links land | No |
| `account.html` | Clients update their own email/password, and manage their coaching subscription if they have one | No |
| `dashboard.html` | Protected "My Program" view, with program switcher + renewal banner | No |
| `checkin.html` | Protected check-in calendar, with streak + progress chart | No |
| `admin.html` | Client list — visible only to emails in the `admins` table | No |
| `admin-messages.html` | Admin inbox — client messages + coaching inquiries | No |
| `messages.html` | Client-facing chat with their coach | No |
| `site.css` | Shared styling for all account pages | No |
| `supabase-config.js` | Your Supabase URL + key | **Yes — paste your keys here (Part 1)** |
| `stripe-config.js` | Your Stripe Payment Link URLs | **Yes — paste your links here (Part 2)** |
| `supabase-schema.sql` | Full database setup — tables, paywall, signup gate, admin access, waiver log, subscriptions | Run once in Supabase SQL Editor |
| `supabase-edge-function-stripe-webhook.ts` | Grants access on purchase, revokes on refund/cancellation, sends welcome email | Deploy once via Supabase CLI (Part 3) |
| `supabase-edge-function-checkin-reminders.ts` | Emails clients who've gone quiet | Deploy + schedule once (Part 5) |
| `supabase-edge-function-cancel-subscription.ts` | Lets a client cancel/resume their coaching subscription | Deploy once via Supabase CLI (Part 6) |

## Updating the actual workout plan content

Supabase → **Table Editor → program_content** → click a program's row → edit the `content` column (JSON). Each program is a list of weeks, each week a list of days, each day a title + exercises (plus optional `focus`, `warmup`, `finisher`). Saves apply instantly — no redeploy needed.

## The liability waiver

Two layers, both optional to use together:
1. **At checkout** (Stripe custom field, Part 2) — a lightweight first pass.
2. **At account creation** (built in) — a required checkbox on `auth.html`; each acceptance is logged with a timestamp in the `waiver_acceptances` table, viewable in Table Editor or by an admin.

The waiver text itself is a placeholder right now (search `auth.html` for "full waiver text goes here") — swap in your actual waiver, ideally reviewed by a lawyer, before launch.

## Deploying

Upload all files except `SETUP.md` and the two `.ts` edge function files (those deploy separately via the Supabase CLI, not GitHub Pages) to your Dabbst1/PersonalTraining repo and push.
