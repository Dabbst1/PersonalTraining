// ═══════════════════════════════════════════════════════════════
// STRIPE PAYMENT LINKS — single point of edit
//
// Once Stripe is set up:
// 1. Stripe Dashboard → Payment links → New, one per program
// 2. Paste each URL below (must exactly match the program ids used
//    in Supabase's "programs" table)
// 3. IMPORTANT: after payment, Stripe needs to tell your database who
//    bought what. See supabase-edge-function-stripe-webhook.ts and
//    SETUP.md for the one-time webhook setup that makes that automatic.
// ═══════════════════════════════════════════════════════════════

const STRIPE_PAYMENT_LINKS = {
  'kickstart-4wk':        'https://buy.stripe.com/28E00kgAneRY7XV48WdQQ00',
  'built-for-more-6wk':   'https://buy.stripe.com/8x228s5VJh063HF5d0dQQ01',
  'phenom-regime-8wk':    'https://buy.stripe.com/4gM00kesf9xE3bBodQQ02',
  'coaching-1on1':        '' // e.g. 'https://buy.stripe.com/xxxxxxxx' — create this product + Payment Link the same way as the other three
};
