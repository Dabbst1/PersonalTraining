// ═══════════════════════════════════════════════════════════════
// EMAIL ALERTS — emails you when someone submits the coaching form
// or a client sends you a message on the site.
//
// Sends from your own Gmail, to your own Gmail — no extra services.
// Needs one Supabase secret: GMAIL_APP_PASSWORD (a Google app password).
// ═══════════════════════════════════════════════════════════════
const MY_EMAIL = 'thephenomregime@gmail.com';

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

async function sendEmail(subject: string, html: string, replyTo?: string) {
  try {
    await mailer.sendMail({
      from: `Built For More Alerts <${MY_EMAIL}>`,
      to: MY_EMAIL,
      subject,
      html,
      ...(replyTo ? { replyTo } : {})
    });
  } catch (err) {
    console.error('Gmail send failed:', err);
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
    return new Response('missing key');
  }

  let payload: any = {};
  try { payload = await req.json(); } catch { return new Response('bad request', { status: 400 }); }
  if (payload.type !== 'INSERT') return new Response('ignored');

  // ── New coaching application ──
  if (payload.table === 'inquiries') {
    const r = await loadFreshRow('inquiries', payload.record?.id);
    if (!r) return new Response('ignored');
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
    await sendEmail(`New application — ${r.full_name}`, html, r.email);
    return new Response('ok');
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
    await sendEmail(`New message from ${name}`, html);
    return new Response('ok');
  }

  return new Response('ignored');
});
