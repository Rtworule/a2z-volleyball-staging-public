-- The Weight Training & Stretching Room is space & equipment rental only,
-- and only instructors (coach clients booking privately) may rent it.
-- Club/team bookings must use courts. Front-desk/admin tools are unaffected.
DO $do$
DECLARE
  fn text;
BEGIN
  SELECT pg_get_functiondef(oid) INTO fn
  FROM pg_proc
  WHERE proname = 'member_create_reservation'
    AND pronamespace = 'public'::regnamespace;

  IF fn NOT LIKE '%space & equipment rental%' THEN
    fn := replace(fn,
      $q$  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;$q$,
      $q$  IF resource NOT IN ('court', 'trainer') THEN
    RAISE EXCEPTION 'resourceType must be court or trainer' USING ERRCODE = '22023';
  END IF;
  IF resource = 'trainer' AND booking_type <> 'private' THEN
    RAISE EXCEPTION 'The Weight Training & Stretching Room is space & equipment rental for instructors only. Team practices use courts.' USING ERRCODE = '42501';
  END IF;$q$);
    EXECUTE fn;
  END IF;
END;
$do$;
