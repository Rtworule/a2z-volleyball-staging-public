-- Add a "Camps & Clinics" selection to the players-attending options for
-- private/coach bookings. It carries its own hourly rate via
-- lesson_bracket_prices (bracket = 'camps'); until an admin sets that rate,
-- bookings fall back to the facility default rate like any other bracket.

-- 1) Widen the allowed bracket values -------------------------------------------------
ALTER TABLE public.reservations
  DROP CONSTRAINT IF EXISTS reservations_lesson_player_bracket_check;
ALTER TABLE public.reservations
  ADD CONSTRAINT reservations_lesson_player_bracket_check
  CHECK (lesson_player_bracket IS NULL OR lesson_player_bracket IN ('1-2', '3', '4', '5+', 'camps'));

ALTER TABLE public.lesson_bracket_prices
  DROP CONSTRAINT IF EXISTS lesson_bracket_prices_bracket_check;
ALTER TABLE public.lesson_bracket_prices
  ADD CONSTRAINT lesson_bracket_prices_bracket_check
  CHECK (bracket IN ('1-2', '3', '4', '5+', 'camps'));

-- 2) Update every function that validates the bracket list ---------------------------
-- (member_create_reservation, member_update_reservation,
--  admin_set_lesson_players, admin_set_lesson_bracket_price)
DO $do$
DECLARE
  rec record;
  fn text;
BEGIN
  FOR rec IN
    SELECT oid, proname
    FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('member_create_reservation', 'member_update_reservation',
                      'admin_set_lesson_players', 'admin_set_lesson_bracket_price')
  LOOP
    fn := pg_get_functiondef(rec.oid);
    IF fn LIKE '%(''1-2'', ''3'', ''4'', ''5+'')%' THEN
      fn := replace(fn, '(''1-2'', ''3'', ''4'', ''5+'')', '(''1-2'', ''3'', ''4'', ''5+'', ''camps'')');
      EXECUTE fn;
    END IF;
  END LOOP;
END;
$do$;

-- 3) Friendlier error text mentioning the new option ----------------------------------
DO $do$
DECLARE
  rec record;
  fn text;
BEGIN
  FOR rec IN
    SELECT oid FROM pg_proc
    WHERE pronamespace = 'public'::regnamespace
      AND proname IN ('member_create_reservation', 'member_update_reservation')
  LOOP
    fn := pg_get_functiondef(rec.oid);
    IF fn LIKE '%Player count must be 1-2, 3, 4, or 5+%' THEN
      fn := replace(fn, 'Player count must be 1-2, 3, 4, or 5+',
                        'Players attending must be 1-2, 3, 4, 5+, or camps');
      EXECUTE fn;
    END IF;
  END LOOP;
END;
$do$;
