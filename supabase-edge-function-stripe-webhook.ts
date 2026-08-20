// ═══════════════════════════════════════════════════════════════
// STRIPE WEBHOOK → SUPABASE EDGE FUNCTION
//
// This is the piece that automatically unlocks a program the moment
// someone pays, revokes it on refund or subscription cancellation, and
// sends a welcome email pointing them to create their account. It can't
// run on GitHub Pages (that's static hosting only) — it runs on Supabase's
// own servers instead, which is included free.
//
// Handles both one-time programs (4-Week Kickstart, Built For More, The
// Phenom Regime) and recurring ones (Custom Coaching 1:1 — monthly
// subscription). Stripe events handled:
//  - checkout.session.completed → grants access (directly if the buyer was
//    already logged in, otherwise via pending_access — see supabase-schema.sql).
//    For a subscription purchase, also stores the subscription id, customer
//    id, and current billing period end. Sends the welcome email either way.
//  - charge.refunded → (one-time programs) finds the matching purchase by
//    payment intent and marks it 'refunded'. RLS then blocks that program's
//    content immediately — no separate step needed. If the refund happens
//    before the buyer ever created an account, clears the pending_access
//    row instead so it can never be claimed.
//  - customer.subscription.updated → (recurring programs) keeps
//    cancel_at_period_end and current_period_end in sync — covers both a
//    cancellation made through cancel-subscription (this project's own
//    function) and any change made directly in Stripe's dashboard.
//  - customer.subscription.deleted → (recurring programs) fires once a
//    canceled subscription's paid period actually ends. Marks the purchase
//    'canceled', which blocks that program's content the same way a refund
//    does on a one-time program.
//
// IMPORTANT: make sure each Stripe Payment Link has email collection turned
// on (it's on by default) so `session.customer_details.email` is always present.
//
// EMAIL: uses Resend (resend.com) — free tier covers a small client list.
// Sign up, verify a sending domain (or use their test domain while testing),
// grab an API key, and set it as a secret (see SETUP.md).
//
// SETUP (see SETUP.md for the full walkthrough):
// 1. Install the Supabase CLI, then from your project folder:
//      supabase functions new stripe-webhook
//    Replace the generated index.ts with this file's contents.
// 2. Set secrets:
//      supabase secrets set STRIPE_SECRET_KEY=sk_live_xxx
//      supabase secrets set STRIPE_WEBHOOK_SECRET=whsec_xxx
//      supabase secrets set SUPABASE_SERVICE_ROLE_KEY=xxx
//      supabase secrets set RESEND_API_KEY=re_xxx
// 3. Deploy:
//      supabase functions deploy stripe-webhook --no-verify-jwt
// 4. In Stripe Dashboard → Developers → Webhooks → Add endpoint, use the
//    deployed function URL, and subscribe to ALL FOUR of:
//      checkout.session.completed
//      charge.refunded
//      customer.subscription.updated
//      customer.subscription.deleted
// 5. Map each Stripe Price/Product to a program_id below in PRICE_TO_PROGRAM.
// 6. Update SITE_URL and FROM_EMAIL below.
// ═══════════════════════════════════════════════════════════════

import Stripe from 'npm:stripe@14';
import { createClient } from 'npm:@supabase/supabase-js@2';

const stripe = new Stripe(Deno.env.get('STRIPE_SECRET_KEY')!, {
  apiVersion: '2023-10-16',
});
const webhookSecret = Deno.env.get('STRIPE_WEBHOOK_SECRET')!;
const resendApiKey = Deno.env.get('RESEND_API_KEY');

const supabaseAdmin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')! // service role bypasses RLS — never expose this key in the browser
);

// Map each Stripe Price ID to the matching program_id in your Supabase "programs" table.
// Find Price IDs in Stripe Dashboard → Product catalog → click a product → copy the Price ID (starts with "price_").
const PRICE_TO_PROGRAM: Record<string, string> = {
  'price_XXXXXXXXXXXXXX_KICKSTART': 'kickstart-4wk',
  'price_XXXXXXXXXXXXXX_BUILTFORMORE': 'built-for-more-6wk',
  'price_XXXXXXXXXXXXXX_PHENOM': 'phenom-regime-8wk',
  'price_XXXXXXXXXXXXXX_COACHING': 'coaching-1on1', // this one should be your RECURRING (monthly) price
};

const PROGRAM_NAMES: Record<string, string> = {
  'kickstart-4wk': '4-Week Kickstart',
  'built-for-more-6wk': 'Built For More (6-Week)',
  'phenom-regime-8wk': 'The Phenom Regime (8-Week)',
  'coaching-1on1': 'Custom Coaching (1:1)',
};

const SITE_URL = 'https://dabbst1.github.io/PersonalTraining'; // update if your site URL changes
const FROM_EMAIL = 'Built For More <hello@yourdomain.com>'; // update after verifying a domain in Resend

async function sendWelcomeEmail(toEmail: string, programId: string) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set — skipping welcome email.');
    return;
  }
  const programName = PROGRAM_NAMES[programId] || 'your program';
  try {
    await fetch('https://api.resend.com/emails', {
      method: 'POST',
      headers: {
        'Authorization': `Bearer ${resendApiKey}`,
        'Content-Type': 'application/json',
      },
      body: JSON.stringify({
        from: FROM_EMAIL,
        to: toEmail,
        subject: `You're in — access ${programName} now`,
        html: `
          <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; color: #111;">
            <h2 style="font-family: sans-serif;">Welcome to Built For More</h2>
            <p>Your purchase of <strong>${programName}</strong> is confirmed.</p>
            <p>One last step: create your account using this same email address (${toEmail}) to unlock your program and start checking in your workouts.</p>
            <p style="margin: 24px 0;">
              <a href="${SITE_URL}/auth.html" style="background:#c8102e; color:#fff; padding:12px 24px; text-decoration:none; font-weight:bold; display:inline-block;">Create Your Account</a>
            </p>
            <p style="color:#666; font-size:13px;">If you already have an account, just log in — this program will already be unlocked.</p>
          </div>
        `,
      }),
    });
  } catch (err) {
    console.error('Welcome email failed to send:', err);
    // Don't fail the whole webhook over an email problem — access has already been granted.
  }
}

Deno.serve(async (req) => {
  const signature = req.headers.get('stripe-signature');
  const body = await req.text();

  let event: Stripe.Event;
  try {
    event = await stripe.webhooks.constructEventAsync(body, signature!, webhookSecret);
  } catch (err) {
    return new Response(`Webhook signature verification failed: ${err.message}`, { status: 400 });
  }

  // ── PURCHASE (one-time OR the first payment of a subscription) ──
  if (event.type === 'checkout.session.completed') {
    const session = event.data.object as Stripe.Checkout.Session;

    const lineItems = await stripe.checkout.sessions.listLineItems(session.id, { limit: 1 });
    const priceId = lineItems.data[0]?.price?.id;
    const programId = priceId ? PRICE_TO_PROGRAM[priceId] : null;

    if (!programId) {
      console.error('Unrecognized price ID:', priceId, '— add it to PRICE_TO_PROGRAM.');
      return new Response('Unrecognized program', { status: 400 });
    }

    const paymentIntentId = typeof session.payment_intent === 'string' ? session.payment_intent : session.payment_intent?.id;
    const userId = session.client_reference_id; // present only if the buyer was already logged in (buying an additional program)
    const email = session.customer_details?.email;

    // Subscription-specific fields — only present when session.mode === 'subscription'
    // (i.e. a recurring program like Custom Coaching, not a one-time program).
    let subscriptionId: string | null = null;
    let customerId: string | null = null;
    let currentPeriodEnd: string | null = null;

    if (session.mode === 'subscription' && session.subscription) {
      subscriptionId = typeof session.subscription === 'string' ? session.subscription : session.subscription.id;
      customerId = typeof session.customer === 'string' ? session.customer : session.customer?.id ?? null;
      const subscription = await stripe.subscriptions.retrieve(subscriptionId);
      currentPeriodEnd = new Date(subscription.current_period_end * 1000).toISOString();
    }

    if (userId) {
      // Already has an account — credit the purchase directly.
      const { error } = await supabaseAdmin
        .from('purchases')
        .upsert({
          user_id: userId,
          program_id: programId,
          stripe_session_id: session.id,
          stripe_payment_intent: paymentIntentId,
          stripe_subscription_id: subscriptionId,
          stripe_customer_id: customerId,
          current_period_end: currentPeriodEnd,
          cancel_at_period_end: false,
          status: 'active',
        }, { onConflict: 'user_id,program_id' });

      if (error) {
        console.error('Failed to record purchase:', error);
        return new Response('Database error', { status: 500 });
      }
    } else {
      // First purchase, no account yet. Stripe collects the email at checkout —
      // stash it in pending_access. The moment this email creates an account
      // (see the signup gate in supabase-schema.sql), it's automatically
      // converted into a real purchase and this row is cleared.
      if (!email) {
        console.error('No email on checkout session — cannot grant pending access.');
        return new Response('Missing email', { status: 400 });
      }

      const { error } = await supabaseAdmin
        .from('pending_access')
        .upsert({
          email: email.toLowerCase(),
          program_id: programId,
          stripe_session_id: session.id,
          stripe_payment_intent: paymentIntentId,
          stripe_subscription_id: subscriptionId,
          stripe_customer_id: customerId,
        }, { onConflict: 'email,program_id' });

      if (error) {
        console.error('Failed to record pending access:', error);
        return new Response('Database error', { status: 500 });
      }
      // Note: current_period_end isn't stored on pending_access — it gets
      // set the moment the subscription's next "customer.subscription.updated"
      // event arrives after the purchase row exists, which happens naturally
      // within the first billing cycle. Access itself isn't affected either way.
    }

    if (email) {
      await sendWelcomeEmail(email, programId);
    }
  }

  // ── REFUND (one-time programs) ──
  // Revokes access the moment you refund someone in Stripe. Covers both a
  // refund on an existing account (flip purchases.status to 'refunded' —
  // RLS then blocks program_content immediately) and a refund that happens
  // before the buyer ever created an account (delete the pending_access row
  // so it can never be claimed).
  if (event.type === 'charge.refunded') {
    const charge = event.data.object as Stripe.Charge;
    const paymentIntentId = typeof charge.payment_intent === 'string' ? charge.payment_intent : charge.payment_intent?.id;

    if (!paymentIntentId) {
      console.error('No payment_intent on refunded charge — cannot match to a purchase.');
      return new Response('Missing payment_intent', { status: 400 });
    }

    const { data: updated, error: purchaseErr } = await supabaseAdmin
      .from('purchases')
      .update({ status: 'refunded' })
      .eq('stripe_payment_intent', paymentIntentId)
      .select();

    if (purchaseErr) {
      console.error('Failed to mark purchase refunded:', purchaseErr);
      return new Response('Database error', { status: 500 });
    }

    if (!updated || updated.length === 0) {
      // No account existed yet — clear the pending grant instead.
      const { error: pendingErr } = await supabaseAdmin
        .from('pending_access')
        .delete()
        .eq('stripe_payment_intent', paymentIntentId);

      if (pendingErr) {
        console.error('Failed to clear pending access on refund:', pendingErr);
      }
    }
  }

  // ── SUBSCRIPTION UPDATED (recurring programs) ──
  // Fires whenever a subscription changes — including right after someone
  // uses the cancel-subscription function (this project's own), or if you
  // change something directly in the Stripe dashboard. Keeps the client's
  // "canceling on [date]" status in the app accurate either way.
  if (event.type === 'customer.subscription.updated') {
    const subscription = event.data.object as Stripe.Subscription;

    const { error } = await supabaseAdmin
      .from('purchases')
      .update({
        cancel_at_period_end: subscription.cancel_at_period_end,
        current_period_end: new Date(subscription.current_period_end * 1000).toISOString(),
      })
      .eq('stripe_subscription_id', subscription.id);

    if (error) {
      console.error('Failed to sync subscription update:', error);
      return new Response('Database error', { status: 500 });
    }
  }

  // ── SUBSCRIPTION DELETED (recurring programs) ──
  // Fires once a canceled subscription's paid period actually ends (not the
  // moment someone clicks "Cancel" — that just schedules it via
  // cancel_at_period_end, see the event above). This is when access actually
  // goes away, the same way a refund does for a one-time program.
  if (event.type === 'customer.subscription.deleted') {
    const subscription = event.data.object as Stripe.Subscription;

    const { error } = await supabaseAdmin
      .from('purchases')
      .update({ status: 'canceled' })
      .eq('stripe_subscription_id', subscription.id);

    if (error) {
      console.error('Failed to mark subscription canceled:', error);
      return new Response('Database error', { status: 500 });
    }
  }

  return new Response(JSON.stringify({ received: true }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
