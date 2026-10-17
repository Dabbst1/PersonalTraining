// ═══════════════════════════════════════════════════════════════
// EMAIL ALERTS — emails you when someone submits the coaching form
// or a client sends you a message on the site. Also sends every new
// applicant your welcome email automatically (skipped for flagged spam).
//
// Sends from your own Gmail, to your own Gmail — no extra services.
// Needs one Supabase secret: GMAIL_APP_PASSWORD (a Google app password).
// ═══════════════════════════════════════════════════════════════
const MY_EMAIL = 'thephenomregime@gmail.com';

// Alerts are delivered to this "+alerts" version of your address. It still lands
// in the same Gmail inbox, but Gmail treats it as incoming mail instead of
// filing it only under Sent (which happens when you email yourself).
const ALERT_TO = 'thephenomregime+alerts@gmail.com';

const SITE_URL = 'https://thephenomregime.com';

import { createClient } from 'npm:@supabase/supabase-js@2';
import nodemailer from 'npm:nodemailer@6.9.16';

const gmailAppPassword = (Deno.env.get('GMAIL_APP_PASSWORD') || '').replace(/\s/g, '');

// Port 465 — Supabase blocks the other common email ports.
const mailer = nodemailer.createTransport({
  host: 'smtp.gmail.com',
  port: 465,
  secure: true,
  auth: { user: MY_EMAIL, pass: gmailAppPassword }
});
const supabase = createClient(
  Deno.env.get('SUPABASE_URL')!,
  Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!
);

const esc = (v: unknown) =>
  String(v ?? '').replace(/[&<>"']/g, c =>
    ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;' }[c]!));

function row(label: string, value: unknown) {
  const v = String(value ?? '').trim();
  if (!v) return '';
  return `<tr>
    <td style="padding:8px 12px 8px 0;color:#888;font-size:13px;vertical-align:top;white-space:nowrap">${esc(label)}</td>
    <td style="padding:8px 0;color:#111;font-size:14px;white-space:pre-wrap">${esc(v)}</td>
  </tr>`;
}

function wrap(title: string, inner: string, buttonText: string) {
  return `<div style="font-family:Arial,sans-serif;max-width:560px;margin:0 auto;padding:24px">
    <div style="border-top:4px solid #c8102e;padding-top:16px">
      <h2 style="margin:0 0 16px;font-size:20px;color:#111">${esc(title)}</h2>
      ${inner}
      <p style="margin:24px 0 0">
        <a href="${SITE_URL}/admin-messages.html" style="background:#c8102e;color:#fff;text-decoration:none;padding:12px 20px;font-weight:bold;display:inline-block">${esc(buttonText)}</a>
      </p>
    </div>
  </div>`;
}

async function sendEmail(subject: string, html: string, replyTo?: string): Promise<string> {
  try {
    const info = await mailer.sendMail({
      from: `Built For More Alerts <${MY_EMAIL}>`,
      to: ALERT_TO,
      subject,
      html,
      ...(replyTo ? { replyTo } : {})
    });
    return 'sent: ' + (info.response || 'ok');
  } catch (err) {
    console.error('Gmail send failed:', err);
    return 'GMAIL ERROR: ' + String((err as any)?.message || err) +
      ` | login: ${MY_EMAIL} | saved password length: ${gmailAppPassword.length} (should be 16)`;
  }
}

// ── Welcome email sent automatically to every new applicant ──────
// Edit the text below to change it. {{first_name}} is filled in with the
// first name they typed into the application form.
const WELCOME_SUBJECT = 'Welcome to The Phenom Regime — Your Next Steps';
const WELCOME_EMAIL = `Hi {{first_name}},

First, thank you for taking the time to complete your coaching application and welcome to The Phenom Regime.

You've already taken the hardest step—getting started.

At The Phenom Regime, we believe lasting results come from structure, consistency, and a program built specifically for you, not a generic workout downloaded from the internet.

Here's what happens next:

✓ We'll review your application
Our team will go through the information you submitted so we can better understand your goals, experience level, and what you're looking to accomplish.

✓ We'll contact you within the next 48 hours
You'll receive an email or phone call to schedule your FREE 15-minute consultation.

During this consultation, we'll discuss:
• Your fitness goals
• Current challenges
• Training experience
• Lifestyle and schedule
• The best path forward to help you succeed

✓ We'll build your custom program
After your consultation, we'll begin designing a personalized training program tailored specifically to your goals, fitness level, and lifestyle.

No cookie-cutter workouts.
No one-size-fits-all plans.

Every recommendation is built around helping you make consistent progress.

WHILE YOU WAIT
Start thinking about the goals you want to accomplish over the next 8–12 weeks.

Ask yourself:
• What do I want to achieve?
• What's been holding me back?
• What would success look like three months from now?

The more clarity you have, the more effective your coaching experience will be.

Thank you again for trusting The Phenom Regime.

We're excited to help you build more than just a stronger body—we're here to help you build stronger habits, greater confidence, and a mindset that lasts long after the workouts are over.

We'll be in touch within 48 hours.

See you soon,

David Taylor
Founder | The Phenom Regime
Instagram: @Daviid.a.taylor | @ThePhenomRegime`;

function firstName(fullName: unknown) {
  const first = String(fullName ?? '').trim().split(/\s+/)[0] || 'there';
  return first.charAt(0).toUpperCase() + first.slice(1);
}

async function sendWelcome(r: any): Promise<string> {
  if (r.flagged) return 'welcome skipped (flagged as possible spam)';
  if (!r.email) return 'welcome skipped (no email)';
  try {
    await mailer.sendMail({
      from: `David Taylor | The Phenom Regime <${MY_EMAIL}>`,
      to: r.email,
      subject: WELCOME_SUBJECT,
      text: WELCOME_EMAIL.replace(/\{\{first_name\}\}/g, firstName(r.full_name))
    });
    return 'welcome sent';
  } catch (err) {
    console.error('Welcome email failed:', err);
    return 'WELCOME ERROR: ' + String((err as any)?.message || err);
  }
}

// Only email about rows that really exist and are brand new — so nobody can
// trigger fake alerts by calling this function directly.
async function loadFreshRow(table: string, id: string) {
  if (!id) return null;
  const { data } = await supabase.from(table).select('*').eq('id', id).maybeSingle();
  if (!data) return null;
  const ageMs = Date.now() - new Date(data.created_at).getTime();
  return ageMs < 10 * 60 * 1000 ? data : null;
}

Deno.serve(async (req) => {
  if (!gmailAppPassword) {
    console.error('GMAIL_APP_PASSWORD secret is missing.');
    return new Response('GMAIL ERROR: GMAIL_APP_PASSWORD secret is missing');
  }

  let payload: any = {};
  try { payload = await req.json(); } catch { return new Response('bad request', { status: 400 }); }
  if (payload.type !== 'INSERT') return new Response('ignored');

  // ── New coaching application ──
  if (payload.table === 'inquiries') {
    const r = await loadFreshRow('inquiries', payload.record?.id);
    if (!r) return new Response('ignored: row not found or too old');
    const html = wrap(
      `New coaching application: ${r.full_name}`,
      `<table style="border-collapse:collapse;width:100%">
        ${row('Name', r.full_name)}
        ${row('Email', r.email)}
        ${row('Main goal', r.main_goal)}
        ${row('Why it matters', r.goal_importance)}
        ${row('Already tried', r.already_tried)}
        ${row('Biggest obstacle', r.biggest_obstacle)}
        ${row('Days / week', r.days_per_week)}
        ${row('Location', r.training_location)}
        ${row('Injuries', r.injuries)}
        ${row('Support wanted', r.coaching_support)}
        ${row('Ready to invest', r.ready_to_invest)}
      </table>
      <p style="color:#888;font-size:13px;margin-top:16px">Hit reply to email ${esc(r.full_name)} directly.</p>`,
      'Open Admin Inbox'
    );
    const alertResult = await sendEmail(`New application — ${r.full_name}`, html, r.email);
    const welcomeResult = await sendWelcome(r);
    return new Response(`${alertResult} | ${welcomeResult}`);
  }

  // ── New message from a client (your own replies are skipped) ──
  if (payload.table === 'messages') {
    const r = await loadFreshRow('messages', payload.record?.id);
    if (!r || r.sender_id !== r.client_id) return new Response('ignored');
    const { data } = await supabase.auth.admin.getUserById(r.client_id);
    const email = data?.user?.email || 'a client';
    const name = data?.user?.user_metadata?.full_name || email;
    const html = wrap(
      `New message from ${name}`,
      `<div style="background:#f5f5f5;border-left:3px solid #c8102e;padding:14px 16px;font-size:15px;color:#111;white-space:pre-wrap">${esc(r.body)}</div>
      <p style="color:#888;font-size:13px;margin-top:16px">Reply on the site so it stays in their message thread.</p>`,
      'Reply on the Site'
    );
    return new Response(await sendEmail(`New message from ${name}`, html));
  }

  return new Response('ignored');
});
