CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  requested_username text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  requested_display_name text := nullif(trim(new.raw_user_meta_data->>'display_name'), '');
  requested_team_name text := nullif(trim(new.raw_user_meta_data->>'team_name'), '');
BEGIN
  INSERT INTO public.profiles (
    id,
    username,
    email,
    display_name,
    team_name,
    account_role,
    approval_status
  ) VALUES (
    new.id,
    coalesce(requested_username, split_part(new.email, '@', 1)),
    new.email,
    coalesce(requested_display_name, split_part(new.email, '@', 1)),
    requested_team_name,
    'user',
    'pending'
  )
  ON CONFLICT (id) DO NOTHING;

  RETURN new;
END;
$$;

DROP TRIGGER IF EXISTS on_auth_user_created_create_profile ON auth.users;

CREATE TRIGGER on_auth_user_created_create_profile
  AFTER INSERT ON auth.users
  FOR EACH ROW EXECUTE FUNCTION public.handle_new_auth_user();

CREATE OR REPLACE FUNCTION public.admin_profile_json(profile public.profiles)
RETURNS jsonb
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = public
AS $$
  SELECT jsonb_build_object(
    'id', profile.id,
    'username', profile.username,
    'email', profile.email,
    'name', profile.display_name,
    'team', profile.team_name,
    'role', profile.account_role,
    'approvalStatus', profile.approval_status,
    'approved', profile.approval_status = 'approved',
    'authenticated', true
  );
$$;

CREATE OR REPLACE FUNCTION public.admin_get_dashboard()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  actor_id uuid := public.admin_require_approved();
  config_row public.facility_config%ROWTYPE;
  settings_json jsonb;
  users_json jsonb;
  pending_json jsonb;
  bookings_json jsonb;
  subjects_json jsonb;
  operations_json jsonb;
BEGIN
  SELECT *
  INTO config_row
  FROM public.facility_config
  WHERE id = true;

  SELECT jsonb_build_object(
    'courtCount', config_row.court_count,
    'trainerCapacity', config_row.trainer_capacity,
    'slotIntervalMinutes', config_row.reservation_step_minutes,
    'minBookingMinutes', config_row.min_reservation_minutes,
    'pricing', jsonb_build_object(
      'courtHourlyRate', config_row.court_hourly_rate,
      'gymHourlyRate', config_row.gym_hourly_rate
    ),
    'operatingHours', coalesce((
      SELECT jsonb_object_agg(
        hours.day_of_week::text,
        jsonb_build_object(
          'open', to_char(hours.open_time, 'HH24:MI'),
          'close', to_char(hours.close_time, 'HH24:MI'),
          'closed', hours.is_closed
        )
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
  INTO settings_json;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile.approval_status, profile."createdDT"), '[]'::jsonb)
  INTO users_json
  FROM public.profiles profile
  WHERE profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_profile_json(profile) ORDER BY profile."createdDT"), '[]'::jsonb)
  INTO pending_json
  FROM public.profiles profile
  WHERE profile.approval_status = 'pending'
    AND profile."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_reservation_json(reservation) ORDER BY reservation.start_at), '[]'::jsonb)
  INTO bookings_json
  FROM public.reservations reservation
  WHERE reservation."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_subject_json(subject) ORDER BY subject.display_name), '[]'::jsonb)
  INTO subjects_json
  FROM public.admin_subjects subject
  WHERE subject."Deleted" = 0;

  SELECT coalesce(jsonb_agg(public.admin_bulk_operation_json(operation) ORDER BY operation."createdDT"), '[]'::jsonb)
  INTO operations_json
  FROM public.admin_bulk_operations operation
  WHERE operation."Deleted" = 0;

  RETURN jsonb_build_object(
    'settings', settings_json,
    'users', users_json,
    'pendingUsers', pending_json,
    'bookings', bookings_json,
    'adminSubjects', subjects_json,
    'bulkOperations', operations_json,
    'actorId', actor_id
  );
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_reject_profile(p_profile_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  profile public.profiles%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  UPDATE public.profiles
  SET approval_status = 'rejected',
      updated_at = now()
  WHERE id = p_profile_id
    AND "Deleted" = 0
  RETURNING * INTO profile;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_profile_json(profile);
END;
$$;

CREATE OR REPLACE FUNCTION public.admin_update_profile(p_profile_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  profile public.profiles%ROWTYPE;
  next_role text := coalesce(nullif(payload->>'accountRole', ''), 'user');
BEGIN
  PERFORM public.admin_require_approved();

  IF next_role NOT IN ('user', 'admin') THEN
    RAISE EXCEPTION 'Account role must be user or admin' USING ERRCODE = '22023';
  END IF;

  UPDATE public.profiles
  SET display_name = coalesce(nullif(payload->>'displayName', ''), display_name),
      team_name = nullif(payload->>'teamName', ''),
      account_role = next_role,
      updated_at = now()
  WHERE id = p_profile_id
    AND "Deleted" = 0
  RETURNING * INTO profile;

  IF profile.id IS NULL THEN
    RAISE EXCEPTION 'Profile not found' USING ERRCODE = '22023';
  END IF;

  RETURN public.admin_profile_json(profile);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.handle_new_auth_user() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_profile_json(public.profiles) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_reject_profile(uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION public.admin_update_profile(uuid, jsonb) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION public.admin_reject_profile(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION public.admin_update_profile(uuid, jsonb) TO authenticated;
