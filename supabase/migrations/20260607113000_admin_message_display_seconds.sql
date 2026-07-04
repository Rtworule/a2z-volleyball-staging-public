ALTER TABLE public.facility_config
  ADD COLUMN IF NOT EXISTS message_display_seconds integer NOT NULL DEFAULT 5 CHECK (message_display_seconds BETWEEN 1 AND 60);

CREATE OR REPLACE FUNCTION public.admin_facility_settings_json()
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'courtCount', config.court_count,
    'trainerCapacity', config.trainer_capacity,
    'slotIntervalMinutes', config.reservation_step_minutes,
    'minBookingMinutes', config.min_reservation_minutes,
    'messageDisplaySeconds', config.message_display_seconds,
    'adminEmail', config.admin_email,
    'emailTemplates', config.email_templates,
    'pricing', jsonb_build_object(
      'courtHourlyRate', config.court_hourly_rate,
      'gymHourlyRate', config.gym_hourly_rate
    ),
    'operatingHours', coalesce((
      SELECT jsonb_object_agg(
        hours.day_of_week::text,
        jsonb_build_object(
          'open', to_char(hours.open_time, 'HH24:MI'),
          'close', to_char(hours.close_time, 'HH24:MI'),
          'closed', hours.is_closed
        )
        ORDER BY hours.day_of_week
      )
      FROM public.operating_hours hours
    ), '{}'::jsonb),
    'closures', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', closure.id,
        'resourceType', closure.resource_type,
        'courtId', CASE WHEN closure.court_number IS NULL THEN NULL ELSE 'court-' || closure.court_number END,
        'start', closure.start_at,
        'end', closure.end_at,
        'reason', closure.reason
      ) ORDER BY closure.start_at)
      FROM public.closures closure
      WHERE closure."Deleted" = 0
    ), '[]'::jsonb),
    'fixedReservations', coalesce((
      SELECT jsonb_agg(jsonb_build_object(
        'id', fixed.id,
        'resourceType', fixed.resource_type,
        'courtId', CASE WHEN fixed.court_number IS NULL THEN NULL ELSE 'court-' || fixed.court_number END,
        'daysOfWeek', fixed.days_of_week,
        'startDate', fixed.start_date,
        'endDate', fixed.end_date,
        'startTime', to_char(fixed.start_time, 'HH24:MI'),
        'endTime', to_char(fixed.end_time, 'HH24:MI'),
        'capacity', fixed.capacity
      ) ORDER BY fixed.start_date, fixed.start_time)
      FROM public.fixed_reservations fixed
      WHERE fixed."Deleted" = 0
    ), '[]'::jsonb)
  )
  FROM public.facility_config config
  WHERE config.id = true;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_facility_config(payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.facility_config
  SET court_count = coalesce((payload->>'courtCount')::integer, court_count),
      trainer_capacity = coalesce((payload->>'trainerCapacity')::integer, trainer_capacity),
      court_hourly_rate = coalesce((payload->>'courtHourlyRate')::numeric, court_hourly_rate),
      gym_hourly_rate = coalesce((payload->>'gymHourlyRate')::numeric, gym_hourly_rate),
      min_reservation_minutes = coalesce((payload->>'minBookingMinutes')::integer, min_reservation_minutes),
      reservation_step_minutes = coalesce((payload->>'slotIntervalMinutes')::integer, reservation_step_minutes),
      message_display_seconds = coalesce((payload->>'messageDisplaySeconds')::integer, message_display_seconds),
      admin_email = coalesce(nullif(payload->>'adminEmail', ''), admin_email),
      email_templates = coalesce(payload->'emailTemplates', email_templates),
      updated_at = now(),
      "updatedDT" = now()
  WHERE id = true;

  RETURN public.admin_get_dashboard();
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_facility_settings_json() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_facility_settings_json() TO authenticated;

REVOKE EXECUTE ON FUNCTION public.admin_update_facility_config(jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_facility_config(jsonb) TO authenticated;
