// ═══════════════════════════════════════════════════════════════
// SUPABASE CONFIG — single point of edit
//
// 1. Create a free project at https://supabase.com
// 2. Go to Project Settings → API
// 3. Copy "Project URL" and the "anon public" key (NOT the service_role key —
//    that one must never appear in this file or anywhere in the browser)
// 4. Paste them below
// ═══════════════════════════════════════════════════════════════

const SUPABASE_URL = 'https://mlzbtykmhaeickmbiudy.supabase.co'; // e.g. 'https://xxxxxxxxxxxx.supabase.co'
const SUPABASE_ANON_KEY = 'sb_publishable_ZJ2kc8DaegSNchAAts7rGg_Qe_eZFb5'; // the "anon public" key from Project Settings → API

const supabaseClient = (SUPABASE_URL && SUPABASE_ANON_KEY)
  ? window.supabase.createClient(SUPABASE_URL, SUPABASE_ANON_KEY)
  : null;

if (!supabaseClient) {
  console.warn('Supabase is not configured yet — edit supabase-config.js with your project URL and anon key.');
}

// ═══════════════════════════════════════════════════════════════
// CLOUDFLARE TURNSTILE (spam protection for the coaching application form)
// Optional but recommended. Get a free site key at dash.cloudflare.com →
// Turnstile → Add widget (add thephenomregime.com as the domain). Paste the
// SITE key here (it's public). The SECRET key goes into Supabase instead:
//   supabase secrets set TURNSTILE_SECRET_KEY=...
// Leave this empty until both are set — the form works without it.
// ═══════════════════════════════════════════════════════════════
const TURNSTILE_SITE_KEY = '';
