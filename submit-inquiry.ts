// ═══════════════════════════════════════════════════════════════
// SUBMIT INQUIRY → SUPABASE EDGE FUNCTION
//
// The ONLY way a coaching application gets into the `inquiries` table.
// The public "Anyone can submit" insert policy is removed (see
// fix-inquiry-spam.sql), so bots can no longer write to the table directly
// with the public anon key — everything has to come through here, and this
// function decides what's real before saving it with the service role key.
//
// What it checks, in order:
//   1. Honeypot  — a hidden field humans never see. Filled in = bot.
//   2. Time trap — submitted less than 4 seconds after the page loaded = bot.
//   3. Turnstile — Cloudflare's invisible CAPTCHA (only once you've set
//                  TURNSTILE_SECRET_KEY; until then this step is skipped).
//   4. Valid answers — dropdown answers must be real options from the form.
//   5. Gibberish — random-letter answers like "rDxcylKWeyCfMCJqq".
//   6. Rate limit — max 3 applications per email or device per hour.
//
// Obvious bots get a fake "success" so they don't learn what tripped them.
// Borderline submissions are SAVED but marked `flagged`, so a real lead is
// never silently lost — they show up in a "Possible spam" section of the
// admin inbox instead of the main list.
//
// SETUP (see SETUP.md, "Spam protection for coaching applications"):
//   supabase functions new submit-inquiry
//   (replace the generated index.ts with this file's contents)
//   supabase secrets set SUPABASE_SERVICE_ROLE_KEY=xxx      (if not already set)
//   supabase secrets set TURNSTILE_SECRET_KEY=0x4AAA...     (optional, recommended)
//   supabase functions deploy submit-inquiry --no-verify-jwt
// ═══════════════════════════════════════════════════════════════

import { createClient } from 'npm:@supabase/supabase-js@2';

const supabaseUrl = Deno.env.get('SUPABASE_URL')!;
const serviceRoleKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!;
const turnstileSecret = Deno.env.get('TURNSTILE_SECRET_KEY') || '';

const admin = createClient(supabaseUrl, serviceRoleKey);

const ALLOWED_ORIGINS = [
  'https://thephenomregime.com',
  'https://www.thephenomregime.com',
  'https://dabbst1.github.io',
];

// Must match the <option> text in index.html exactly. A bot posting straight
// to this function with made-up values gets rejected.
const ALLOWED = {
  main_goal: [
    'Lose weight & reduce body fat', 'Gain strength & muscle', 'Improve endurance & conditioning',
    'Stay consistent year-round', 'Prepare for an event or race',
  ],
  biggest_obstacle: [
    'Consistency & discipline', 'Time & schedule', 'Nutrition & food habits', 'Confusion about what to do',
    'Injuries or physical limitations', 'Lack of accountability or structure', 'Motivation',
  ],
  days_per_week: ['2 days', '3 days', '4 days', '5 days', '6+ days'],
  training_location: ['Commercial gym', 'Home gym', 'Apartment gym', 'Outdoors', 'Mixed setup'],
  coaching_support: [
    'Program only', 'Program + accountability check-ins', 'Full 1-on-1 coaching',
    'Exercise technique feedback', 'Nutrition guidance', "Not sure yet — let's talk",
  ],
  ready_to_invest: [
    "Yes — I'm committed and ready to start", 'Yes — but I need to understand costs first', 'Still figuring it out',
  ],
} as const;

const FREE_TEXT = ['goal_importance', 'already_tried', 'injuries'] as const;

// "rDxcylKWeyCfMCJqq" → true. "WeightWatchers", "MyFitnessPal", "NOTHING WORKED" → false.
// One long word, letters only, mixed case, with 3+ capitals after the first letter.
function looksLikeGibberish(value: string | null): boolean {
  if (!value) return false;
  const v = value.trim();
  if (v.length < 12 || !/^[A-Za-z]+$/.test(v) || !/[a-z]/.test(v)) return false;
  const innerCaps = (v.slice(1).match(/[A-Z]/g) || []).length;
  return innerCaps >= 3;
}

// Bots stuff Gmail addresses with dots ("s.zm.c.r.2.lvp.ar.keremily@gmail.com")
// because Gmail ignores them, letting one inbox look like thousands.
function dottedGmail(email: string): boolean {
  const [local, domain] = email.toLowerCase().split('@');
  if (!domain || !['gmail.com', 'googlemail.com'].includes(domain)) return false;
  return (local.match(/\./g) || []).length >= 3;
}

async function sha256(text: string): Promise<string> {
  const buf = await crypto.subtle.digest('SHA-256', new TextEncoder().encode(text));
  return Array.from(new Uint8Array(buf)).map(b => b.toString(16).padStart(2, '0')).join('');
}

async function verifyTurnstile(token: string, ip: string): Promise<boolean> {
  if (!turnstileSecret) return true; // not set up yet — skip this layer
  if (!token) return false;
  const form = new FormData();
  form.append('secret', turnstileSecret);
  form.append('response', token);
  if (ip) form.append('remoteip', ip);
  try {
    const res = await fetch('https://challenges.cloudflare.com/turnstile/v0/siteverify', { method: 'POST', body: form });
    const data = await res.json();
    return data.success === true;
  } catch {
    return false;
  }
}

function cleanText(v: unknown, max = 2000): string | null {
  if (typeof v !== 'string') return null;
  const t = v.trim().slice(0, max);
  return t || null;
}

Deno.serve(async (req) => {
  const origin = req.headers.get('Origin') || '';
  const cors = {
    'Access-Control-Allow-Origin': ALLOWED_ORIGINS.includes(origin) ? origin : ALLOWED_ORIGINS[0],
    'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
    'Access-Control-Allow-Methods': 'POST, OPTIONS',
    'Vary': 'Origin',
  };
  const reply = (body: Record<string, unknown>) =>
    new Response(JSON.stringify(body), { status: 200, headers: { ...cors, 'Content-Type': 'application/json' } });
  // Fake success for obvious bots — they think it worked and move on.
  const silentDrop = () => reply({ ok: true });

  if (req.method === 'OPTIONS') return new Response('ok', { headers: cors });
  if (req.method !== 'POST') return new Response('Method not allowed', { status: 405, headers: cors });

  let body: Record<string, unknown>;
  try {
    body = await req.json();
  } catch {
    return reply({ ok: false, message: 'Something went wrong — please try again.' });
  }

  // 1. Honeypot
  if (cleanText(body.website)) return silentDrop();

  // 2. Time trap
  const elapsedMs = Number(body.elapsed_ms);
  if (!Number.isFinite(elapsedMs) || elapsedMs < 4000) return silentDrop();

  // 3. Turnstile
  const ip = (req.headers.get('x-forwarded-for') || '').split(',')[0].trim();
  if (!(await verifyTurnstile(cleanText(body.turnstile_token) || '', ip))) {
    return reply({ ok: false, message: 'Please complete the verification check and submit again.' });
  }

  // Required fields
  const fullName = cleanText(body.full_name, 120);
  const email = cleanText(body.email, 200)?.toLowerCase() || null;
  if (!fullName || !email || !/^[^\s@",()]+@[^\s@",()]+\.[^\s@",()]+$/.test(email)) {
    return reply({ ok: false, message: 'Please enter your full name and a valid email.' });
  }

  // 4. Dropdown answers must be real options
  const row: Record<string, string | null | boolean | string[]> = { full_name: fullName, email };
  for (const [field, options] of Object.entries(ALLOWED)) {
    const v = cleanText(body[field], 200);
    if (v && !(options as readonly string[]).includes(v)) return silentDrop();
    row[field] = v;
  }
  for (const field of FREE_TEXT) row[field] = cleanText(body[field]);

  // 5. Gibberish / bot-pattern scoring
  const reasons: string[] = [];
  const gibberishCount = FREE_TEXT.filter(f => looksLikeGibberish(row[f] as string | null)).length;
  if (gibberishCount >= 2) return silentDrop(); // every spam submission so far had all three
  if (gibberishCount === 1) reasons.push('Random-letter answer');
  if (dottedGmail(email)) reasons.push('Dot-stuffed Gmail address');
  if (looksLikeGibberish(fullName.replace(/\s+/g, ''))) reasons.push('Random-letter name');

  // 6. Rate limit — 3 per email or device per hour
  const ipHash = ip ? await sha256(`phenom-inquiry:${ip}`) : null;
  const since = new Date(Date.now() - 60 * 60 * 1000).toISOString();
  const orFilter = ipHash ? `email.eq."${email}",ip_hash.eq.${ipHash}` : `email.eq."${email}"`;
  const { count } = await admin
    .from('inquiries')
    .select('id', { count: 'exact', head: true })
    .gte('created_at', since)
    .or(orFilter);
  if ((count ?? 0) >= 3) {
    return reply({ ok: false, message: "You've already sent an application recently — we'll be in touch soon." });
  }

  row.ip_hash = ipHash;
  row.flagged = reasons.length > 0;
  row.spam_reasons = reasons;

  const { error } = await admin.from('inquiries').insert(row);
  if (error) {
    console.error('Insert failed:', error);
    return reply({ ok: false, message: 'Something went wrong submitting your application — please try again.' });
  }

  return reply({ ok: true });
});
