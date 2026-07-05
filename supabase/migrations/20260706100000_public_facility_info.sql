-- Public facility info for the logged-out home page, without exposing
-- admin_email / email_templates. The old blanket SELECT policy on
-- facility_config let anyone read every column via PostgREST; direct table
-- reads are revoked and replaced with a column-safe RPC.

CREATE OR REPLACE FUNCTION public.public_get_facility_info()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path = public
STABLE
AS $$
  SELECT jsonb_build_object(
    'courtCount', config.court_count,
    'trainerCapacity', config.trainer_capacity,
    'courtHourlyRate', config.court_hourly_rate,
    'gymHourlyRate', config.gym_hourly_rate,
    'minReservationMinutes', config.min_reservation_minutes,
    'reservationStepMinutes', config.reservation_step_minutes,
    'timezone', config.timezone,
    'operatingHours', coalesce((
      SELECT jsonb_object_agg(hours.day_of_week::text, jsonb_build_object(
        'open', to_char(hours.open_time, 'HH24:MI'),
        'close', to_char(hours.close_time, 'HH24:MI'),
        'closed', hours.is_closed
      ))
      FROM public.operating_hours hours
    ), '{}'::jsonb)
  )
  FROM public.facility_config config
  WHERE config.id = true;
$$;

REVOKE EXECUTE ON FUNCTION public.public_get_facility_info() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.public_get_facility_info() TO anon;
GRANT EXECUTE ON FUNCTION public.public_get_facility_info() TO authenticated;

-- Close the column leak: nobody reads facility_config directly from the client
-- anymore (public page uses the RPC above; members and admins use SECURITY
-- DEFINER RPCs). Operating hours stay readable — they contain nothing sensitive.
REVOKE SELECT ON public.facility_config FROM anon;
REVOKE SELECT ON public.facility_config FROM authenticated;
REVOKE ALL ON public.facility_config FROM PUBLIC;

COMMENT ON FUNCTION public.public_get_facility_info() IS
  'Column-safe facility info (rates, capacity, hours) for the public home page. Excludes admin_email and email_templates.';
