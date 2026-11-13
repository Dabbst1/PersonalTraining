// ═══════════════════════════════════════════════════════════════
// CANCEL SUBSCRIPTION → SUPABASE EDGE FUNCTION
//
// Lets a logged-in client cancel (or undo canceling) their own recurring
// program — currently just Custom Coaching (1:1) — from account.html.
// Cancels "at period end": they keep access through whatever they've
// already paid for, and it simply doesn't renew, rather than losing access
// the instant they click the button.
//
// Unlike the other two functions in this project, this one DOES require a
// valid logged-in session to call — it's deployed WITHOUT --no-verify-jwt,
// so Supabase checks the caller is a real logged-in user before this code
// even runs. Ownership is verified again inside the function itself (the
// query below uses the caller's own Supabase client, which respects the
// same "Users can view their own purchases" RLS rule as everywhere else on
// the site) — so nobody can cancel a subscription that isn't theirs.
//
// SETUP (see SETUP.md for the full walkthrough):
// 1. supabase functions new cancel-subscription
//    Replace the generated index.ts with this file's contents.
// 2. Set secrets (same STRIPE_SECRET_KEY and SUPABASE_SERVICE_ROLE_KEY as
//    the webhook — if your CLI setup scopes secrets per-function, set them
//    here too):
//      supabase secrets set STRIPE_SECRET_KEY=sk_live_xxx
//      supabase secrets set SUPABASE_SERVICE_ROLE_KEY=xxx
// 3. Deploy WITHOUT --no-verify-jwt (this is the one function in this
//    project that should require a valid login):
//      supabase functions deploy cancel-subscription
// ═══════════════════════════════════════════════════════════════

import Stripe from 'npm:stripe@14';
import { createClient } from 'npm:@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2023-10-16',
});

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const supabaseAnonKey = Deno.env.get('SUPABASE_ANON_KEY')!; // set automatically by Supabase for every function — no need to add this one yourself
const supabaseServiceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;

Deno.serve(async (req) => {
  if (req.method !== 'POST') {
    return new Response('Method not allowed', { status: 405 });
  }

  const authHeader = req.headers.get('Authorization');
  if (!authHeader) {
    return new Response(JSON.stringify({ error: 'Not logged in.' }), { status: 401 });
  }

  // A client scoped to whoever is calling this — RLS applies exactly as it
  // would anywhere else on the site, so this can only ever see (and act on)
  // that person's own purchases, never anyone else's.
  const supabaseAsUser = createClient(supabaseUrl, supabaseAnonKey, {
    global: { headers: { Authorization: authHeader } },
  });

  const { data: { user }, error: userErr } = await supabaseAsUser.auth.getUser();
  if (userErr || !user) {
    return new Response(JSON.stringify({ error: 'Not logged in.' }), { status: 401 });
  }

  let payload: { program_id?: string; action?: 'cancel' | 'resume' };
  try {
    payload = await req.json();
  } catch {
    return new Response(JSON.stringify({ error: 'Invalid request body.' }), { status: 400 });
  }

  const programId = payload.program_id;
  const action = payload.action === 'resume' ? 'resume' : 'cancel'; // default to cancel
  if (!programId) {
    return new Response(JSON.stringify({ error: 'Missing program_id.' }), { status: 400 });
  }

  const { data: purchase, error: purchaseErr } = await supabaseAsUser
    .from('purchases')
    .select('id, stripe_subscription_id, status')
    .eq('program_id', programId)
    .eq('status', 'active')
    .single();

  if (purchaseErr || !purchase) {
    return new Response(JSON.stringify({ error: 'No active subscription found for this program.' }), { status: 404 });
  }

  if (!purchase.stripe_subscription_id) {
    return new Response(JSON.stringify({ error: 'This program isn\'t set up as a subscription.' }), { status: 400 });
  }

  try {
    const updated = await stripe.subscriptions.update(purchase.stripe_subscription_id, {
      cancel_at_period_end: action === 'cancel',
    });

    // Optimistic local update — the webhook's "customer.subscription.updated"
    // handler will also confirm this shortly after, so this is redundant but
    // harmless, and means the UI reflects the change immediately rather than
    // waiting on the webhook round-trip.
    const supabaseAdmin = createClient(supabaseUrl, supabaseServiceRoleKey);
    await supabaseAdmin
      .from('purchases')
      .update({
        cancel_at_period_end: updated.cancel_at_period_end,
        current_period_end: new Date(updated.current_period_end * 1000).toISOString(),
      })
      .eq('id', purchase.id);

    return new Response(JSON.stringify({
      success: true,
      cancel_at_period_end: updated.cancel_at_period_end,
      current_period_end: new Date(updated.current_period_end * 1000).toISOString(),
    }), { headers: { 'Content-Type': 'application/json' } });
  } catch (err) {
    console.error('Stripe subscription update failed:', err);
    return new Response(JSON.stringify({ error: 'Could not update your subscription — please try again or contact support.' }), { status: 500 });
  }
});
