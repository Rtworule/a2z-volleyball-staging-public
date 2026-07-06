# Card on file for private lessons

Card numbers are NEVER stored in Supabase. The card lives at your card
processor (Stripe recommended); the database keeps only the processor's
customer id plus brand/last4 for display. This document covers the interim
manual workflow (works today) and the self-serve upgrade path.

## What the system enforces (already live after migration 20260709)
- Private lesson bookings are rejected unless the coach's client record has a
  card on file OR the admin has granted `monthly` billing terms.
- Cancellation fees are computed automatically when a coach cancels online:
  free > 36h before start · 50% between 36h and 24h · 100% within 24h.
  The fee lands on the reservation as `cancellation_fee_percent / _amount`
  with status `pending_charge` (card coaches) or `invoiced` (monthly coaches).

## Interim workflow (no code needed)
1. Create a Stripe account (https://stripe.com), complete business setup.
2. When a coach wants to book private lessons: in the Stripe Dashboard ->
   Customers -> Add customer (name + email), then Payment methods -> Add ->
   card (Stripe emails them a secure link with "Request payment details" —
   the coach types the card into Stripe's page, never into yours).
3. Copy the customer id (cus_...) and record it in the app database via SQL
   editor (or ask me to add a small admin UI):

       select admin_set_subject_card('{"subjectId":"<uuid>",
         "processorCustomerId":"cus_...","cardBrand":"Visa","cardLast4":"4242"}');

4. Charging a cancellation fee: reservations with
   `cancellation_fee_status = 'pending_charge'` are your work queue. Charge
   the saved card in Stripe (Customers -> ... -> Charge payment method,
   amount = cancellation_fee_amount, off_session), then mark it:

       select admin_set_cancellation_fee_status('<reservation-uuid>', 'charged');

   Use 'waived' to forgive a fee; monthly coaches' fees arrive as 'invoiced'
   and simply join their month-end invoice.

## Monthly billing accounts (trusted coaches)
    select admin_set_subject_billing('{"subjectId":"<uuid>","billingTerms":"monthly"}');
They can book without a card; all sessions and any cancellation fees are
billed on their month-end invoice. Switch back with "card_on_file".

## Self-serve upgrade path (later)
Add an Edge Function that creates a Stripe SetupIntent and a "Add a card"
button in the member portal (Stripe Elements). On success, a webhook stores
the customer id via admin_set_subject_card. A second function can auto-charge
pending_charge fees nightly with PaymentIntents (off_session confirm) and
mark charged/failed. Ask when ready — roughly a day of work including tests,
and requires your Stripe API keys as Supabase secrets (never in the repo).
