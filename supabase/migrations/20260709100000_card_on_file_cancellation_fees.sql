-- Private-lesson billing rules:
--  * Private coach bookings require a credit card on file (stored at the card
--    processor; only the processor customer id + brand/last4 live here) UNLESS
--    the coach has been granted monthly billing terms by an admin.
--  * Cancellation fees for private lessons: free more than 36h before start,
--    50% between 36h and 24h, 100% within 24h. Fees are recorded on the
--    reservation for the office to charge to the card on file (or add to the
--    monthly invoice for monthly-terms coaches).

-- 1) Subject billing fields --------------------------------------------------------
ALTER TABLE public.subjects
  ADD COLUMN IF NOT EXISTS billing_terms text NOT NULL DEFAULT 'card_on_file'
    CHECK (billing_terms IN ('card_on_file', 'monthly')),
  ADD COLUMN IF NOT EXISTS card_processor_customer_id text,
  ADD COLUMN IF NOT EXISTS card_brand text,
  ADD COLUMN IF NOT EXISTS card_last4 text CHECK (card_last4 IS NULL OR card_last4 ~ '^[0-9]{4}$'),
  ADD COLUMN IF NOT EXISTS card_on_file_at timestamptz;

COMMENT ON COLUMN public.subjects.billing_terms IS
  'card_on_file (default): private lessons require a stored card. monthly: trusted coaches invoiced at month end.';
COMMENT ON COLUMN public.subjects.card_processor_customer_id IS
  'Customer id at the card processor (e.g. Stripe cus_...). Card numbers are never stored here.';

-- 2) Reservation cancellation-fee fields -------------------------------------------
ALTER TABLE public.reservations
  ADD COLUMN IF NOT EXISTS cancellation_fee_percent integer
    CHECK (cancellation_fee_percent IS NULL OR cancellation_fee_percent IN (0, 50, 100)),
  ADD COLUMN IF NOT EXISTS cancellation_fee_amount numeric(8, 2),
  ADD COLUMN IF NOT EXISTS cancellation_fee_status text
    CHECK (cancellation_fee_status IS NULL OR cancellation_fee_status IN ('none', 'pending_charge', 'charged', 'invoiced', 'waived'));

-- 3) Admin RPCs: billing terms + card on file ---------------------------------------
CREATE OR REPLACE FUNCTION public.admin_set_subject_billing(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.subjects%ROWTYPE;
  v_terms text := payload->>'billingTerms';
BEGIN
  IF v_terms NOT IN ('card_on_file', 'monthly') THEN
    RAISE EXCEPTION 'billingTerms must be card_on_file or monthly' USING ERRCODE = '22023';
  END IF;
  UPDATE public.subjects
  SET billing_terms = v_terms
  WHERE id = (payload->>'subjectId')::uuid AND "Deleted" = 0
  RETURNING * INTO subject;
  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = '22023';
  END IF;
  PERFORM public.audit_log('update', 'subject', subject.id, subject.display_name,
    NULL, jsonb_build_object('billingTerms', v_terms), jsonb_build_object('source', 'admin-billing-terms'));
  RETURN jsonb_build_object('id', subject.id, 'billingTerms', subject.billing_terms);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_subject_card(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  subject public.subjects%ROWTYPE;
BEGIN
  UPDATE public.subjects
  SET card_processor_customer_id = nullif(payload->>'processorCustomerId', ''),
      card_brand = nullif(payload->>'cardBrand', ''),
      card_last4 = nullif(payload->>'cardLast4', ''),
      card_on_file_at = CASE WHEN nullif(payload->>'processorCustomerId', '') IS NULL THEN NULL ELSE now() END
  WHERE id = (payload->>'subjectId')::uuid AND "Deleted" = 0
  RETURNING * INTO subject;
  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client not found' USING ERRCODE = '22023';
  END IF;
  PERFORM public.audit_log('update', 'subject', subject.id, subject.display_name,
    NULL, jsonb_build_object('cardOnFile', subject.card_processor_customer_id IS NOT NULL, 'cardLast4', subject.card_last4),
    jsonb_build_object('source', 'admin-card-on-file'));
  RETURN jsonb_build_object('id', subject.id, 'cardOnFile', subject.card_processor_customer_id IS NOT NULL,
    'cardBrand', subject.card_brand, 'cardLast4', subject.card_last4);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_set_cancellation_fee_status(p_reservation_id uuid, p_status text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  reservation public.reservations%ROWTYPE;
BEGIN
  IF p_status NOT IN ('pending_charge', 'charged', 'invoiced', 'waived') THEN
    RAISE EXCEPTION 'status must be pending_charge, charged, invoiced, or waived' USING ERRCODE = '22023';
  END IF;
  UPDATE public.reservations SET cancellation_fee_status = p_status
  WHERE id = p_reservation_id AND "Deleted" = 0
  RETURNING * INTO reservation;
  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;
  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    NULL, jsonb_build_object('cancellationFeeStatus', p_status), jsonb_build_object('source', 'admin-cancel-fee'));
  RETURN jsonb_build_object('id', reservation.id, 'cancellationFeeStatus', reservation.cancellation_fee_status);
END;
$$;

-- 4) Portal: expose billing readiness to the booking UI ------------------------------
CREATE OR REPLACE FUNCTION public.member_get_portal(
  p_start_date date DEFAULT current_date,
  p_days integer DEFAULT 14
)
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
AS $$
  WITH base AS (
    SELECT public.member_get_portal_base(p_start_date, p_days) AS j
  )
  SELECT jsonb_set(
           j,
           '{contexts}',
           coalesce((
             SELECT jsonb_agg(
               ctx || jsonb_build_object(
                 'billingTerms', s.billing_terms,
                 'cardOnFile', s.card_processor_customer_id IS NOT NULL,
                 'cardLast4', s.card_last4
               )
             )
             FROM jsonb_array_elements(j->'contexts') AS ctx
             JOIN public.subjects s ON s.id = (ctx->>'subjectId')::uuid
           ), '[]'::jsonb)
         )
         || jsonb_build_object('bracketPrices', public.member_get_bracket_prices())
  FROM base;
$$;

-- 5) member_create_reservation: require billing readiness for private lessons --------
-- Identical to the previous version plus the card/monthly check after authorization.
DO $do$
DECLARE
  fn text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO fn
  FROM pg_proc
  WHERE proname = 'member_create_reservation'
    AND pronamespace = 'public'::regnamespace;

  fn := replace(fn,
    $q$  SELECT * INTO client_type FROM public.client_types WHERE id = subject.client_type_id;$q$,
    $q$  SELECT * INTO client_type FROM public.client_types WHERE id = subject.client_type_id;

  IF booking_type = 'private'
     AND subject.billing_terms = 'card_on_file'
     AND subject.card_processor_customer_id IS NULL THEN
    RAISE EXCEPTION 'A credit card on file is required for private lessons. Please contact the front desk to add one.' USING ERRCODE = '42501';
  END IF;$q$);

  EXECUTE fn;
END;
$do$;

-- 6) member_cancel_reservation: tiered fees replace the 36h lockout ------------------
CREATE OR REPLACE FUNCTION public.member_cancel_reservation(p_reservation_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  caller uuid := public.member_require_approved();
  reservation public.reservations%ROWTYPE;
  subject public.subjects%ROWTYPE;
  caller_email text;
  hours_out numeric;
  fee_percent integer;
  fee_amount numeric(8, 2);
  fee_status text;
BEGIN
  SELECT * INTO reservation
  FROM public.reservations
  WHERE id = p_reservation_id AND user_id = caller AND "Deleted" = 0;

  IF reservation.id IS NULL THEN
    RAISE EXCEPTION 'Reservation not found' USING ERRCODE = '22023';
  END IF;
  IF reservation.status = 'cancelled' THEN
    RETURN jsonb_build_object('id', reservation.id, 'status', 'cancelled');
  END IF;
  IF reservation.lesson_player_bracket IS NULL THEN
    RAISE EXCEPTION 'Team practices can only be changed by the front desk.' USING ERRCODE = '42501';
  END IF;
  IF reservation.start_at <= now() THEN
    RAISE EXCEPTION 'This lesson has already started. Contact the front desk.' USING ERRCODE = '22023';
  END IF;
  IF reservation.payment_status = 'paid' THEN
    RAISE EXCEPTION 'Paid reservations must be cancelled by the front desk.' USING ERRCODE = '22023';
  END IF;

  hours_out := extract(epoch FROM reservation.start_at - now()) / 3600.0;
  fee_percent := CASE
    WHEN hours_out > 36 THEN 0
    WHEN hours_out > 24 THEN 50
    ELSE 100
  END;
  fee_amount := round(coalesce(reservation.amount, 0) * fee_percent / 100.0, 2);

  SELECT * INTO subject FROM public.subjects WHERE id = reservation.subject_id;
  fee_status := CASE
    WHEN fee_percent = 0 THEN 'none'
    WHEN subject.billing_terms = 'monthly' THEN 'invoiced'
    ELSE 'pending_charge'
  END;

  UPDATE public.reservations
  SET status = 'cancelled',
      cancellation_fee_percent = fee_percent,
      cancellation_fee_amount = fee_amount,
      cancellation_fee_status = fee_status
  WHERE id = reservation.id
  RETURNING * INTO reservation;

  PERFORM public.audit_log('update', 'reservation', reservation.id, reservation.team_name,
    jsonb_build_object('status', 'confirmed'),
    jsonb_build_object('status', 'cancelled', 'cancellationFeePercent', fee_percent,
      'cancellationFeeAmount', fee_amount, 'cancellationFeeStatus', fee_status),
    jsonb_build_object('source', 'member-cancel'));

  SELECT email INTO caller_email FROM public.profiles WHERE id = caller;
  PERFORM public.queue_reservation_notification('reservation_cancelled', reservation, caller_email);

  RETURN jsonb_build_object(
    'id', reservation.id,
    'status', 'cancelled',
    'cancellationFeePercent', fee_percent,
    'cancellationFeeAmount', fee_amount,
    'cancellationFeeStatus', fee_status
  );
END;
$$;

-- Grants ------------------------------------------------------------------------------
REVOKE EXECUTE ON FUNCTION public.admin_set_subject_billing(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_subject_card(jsonb) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_set_cancellation_fee_status(uuid, text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_get_portal(date, integer) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_set_subject_billing(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_subject_card(jsonb) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_set_cancellation_fee_status(uuid, text) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_get_portal(date, integer) TO authenticated;
GRANT EXECUTE ON FUNCTION public.member_cancel_reservation(uuid) TO authenticated;
