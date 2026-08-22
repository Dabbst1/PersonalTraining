// ═══════════════════════════════════════════════════════════════
// CHECK-IN REMINDERS → SCHEDULED SUPABASE EDGE FUNCTION
//
// Runs on a schedule (see SETUP.md) rather than in response to a webhook.
// Finds clients with an active purchase who haven't logged a workout in the
// last INACTIVITY_DAYS days and emails them a nudge.
//
// Won't re-remind someone every single day they stay inactive — once a
// reminder goes out, that client is skipped for REMINDER_COOLDOWN_DAYS
// even if they're still inactive, so someone taking a real break doesn't
// get a daily email for two weeks straight. They'll get reminded again
// after the cooldown if they're still inactive then.
//
// SETUP:
// 1. supabase functions new checkin-reminders
//    Replace the generated index.ts with this file's contents.
// 2. Set secrets (same RESEND_API_KEY as the Stripe webhook — if already
//    set for that function, set it here too. SUPABASE_SERVICE_ROLE_KEY is
//    provided automatically, don't set that one yourself):
//      supabase secrets set RESEND_API_KEY=re_xxxxx
// 3. Deploy: supabase functions deploy checkin-reminders --no-verify-jwt
// 4. Schedule it with Supabase Cron (Dashboard → Edge Functions →
//    checkin-reminders → Cron, or via SQL — see SETUP.md). Once a day,
//    e.g. 9am, is plenty.
// ═══════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2';

const resendApiKey = Deno.env.get('RESEND_API_KEY');
const SITE_URL = 'https://dabbst1.github.io/PersonalTraining'; // update if your site URL changes
const FROM_EMAIL = 'Built For More <hello@yourdomain.com>'; // update after verifying a domain in Resend
const INACTIVITY_DAYS = 3;        // remind after this many days with no check-in
const REMINDER_COOLDOWN_DAYS = 4; // don't remind the same person again within this many days of the last reminder

const supabaseAdmin = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

async function sendReminderEmail(toEmail: string) {
  if (!resendApiKey) {
    console.warn('RESEND_API_KEY not set — skipping reminder email.');
    return false;
  }
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
        subject: "Haven't seen a check-in from you in a few days",
        html: `
          <div style="font-family: sans-serif; max-width: 480px; margin: 0 auto; color: #111;">
            <h2 style="font-family: sans-serif;">Still with us?</h2>
            <p>It's been a few days since your last check-in. Life happens — but a quick log now keeps your streak (and your progress) on track.</p>
            <p style="margin: 24px 0;">
              <a href="${SITE_URL}/checkin.html" style="background:#c8102e; color:#fff; padding:12px 24px; text-decoration:none; font-weight:bold; display:inline-block;">Log Today's Workout</a>
            </p>
          </div>
        `,
      }),
    });
    return true;
  } catch (err) {
    console.error(`Reminder email to ${toEmail} failed:`, err);
    return false;
  }
}

Deno.serve(async (_req) => {
  const inactivityCutoff = new Date();
  inactivityCutoff.setDate(inactivityCutoff.getDate() - INACTIVITY_DAYS);
  const inactivityCutoffStr = inactivityCutoff.toISOString().slice(0, 10);

  const cooldownCutoff = new Date();
  cooldownCutoff.setDate(cooldownCutoff.getDate() - REMINDER_COOLDOWN_DAYS);

  // Every client with an active purchase
  const { data: purchases, error: purchaseErr } = await supabaseAdmin
    .from('purchases')
    .select('user_id')
    .eq('status', 'active');

  if (purchaseErr) {
    console.error('Failed to load purchases:', purchaseErr);
    return new Response('Database error', { status: 500 });
  }

  const uniqueUserIds = [...new Set((purchases || []).map(p => p.user_id))];
  let remindersSent = 0;

  for (const userId of uniqueUserIds) {
    const { data: recentLogs, error: logErr } = await supabaseAdmin
      .from('workout_logs')
      .select('log_date')
      .eq('user_id', userId)
      .gte('log_date', inactivityCutoffStr)
      .limit(1);

    if (logErr) {
      console.error(`Failed to check logs for ${userId}:`, logErr);
      continue;
    }

    // Has a recent check-in — no reminder needed.
    if (recentLogs && recentLogs.length > 0) continue;

    // Still inactive — but skip if we already reminded them recently, so
    // an extended break doesn't turn into a daily email chain.
    const { data: settings } = await supabaseAdmin
      .from('client_settings')
      .select('last_reminder_sent_at')
      .eq('user_id', userId)
      .maybeSingle();

    if (settings?.last_reminder_sent_at && new Date(settings.last_reminder_sent_at) > cooldownCutoff) {
      continue;
    }

    const { data: userData, error: userErr } = await supabaseAdmin.auth.admin.getUserById(userId);
    if (userErr || !userData?.user?.email) continue;

    const sent = await sendReminderEmail(userData.user.email);
    if (sent) {
      remindersSent++;
      await supabaseAdmin
        .from('client_settings')
        .upsert({ user_id: userId, last_reminder_sent_at: new Date().toISOString() }, { onConflict: 'user_id' });
    }
  }

  return new Response(JSON.stringify({ remindersSent }), {
    headers: { 'Content-Type': 'application/json' },
  });
});
