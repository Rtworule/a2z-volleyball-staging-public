DO $$
DECLARE
  function_sql text;
BEGIN
  SELECT pg_get_functiondef('public.admin_create_subject(jsonb)'::regprocedure)
  INTO function_sql;

  function_sql := replace(
    function_sql,
    'lower(client_type.name),',
    'CASE WHEN coalesce(client_type.have_teams, false) THEN ''team'' ELSE ''coach'' END,'
  );

  EXECUTE function_sql;

  SELECT pg_get_functiondef('public.admin_update_subject(uuid, jsonb)'::regprocedure)
  INTO function_sql;

  function_sql := replace(
    function_sql,
    'subject_type = lower(client_type.name),',
    'subject_type = CASE WHEN coalesce(client_type.have_teams, false) THEN ''team'' ELSE ''coach'' END,'
  );

  EXECUTE function_sql;
END $$;

CREATE OR REPLACE FUNCTION public.admin_enable_subject(p_subject_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  before_json jsonb;
  subject public.admin_subjects%ROWTYPE;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT public.admin_subject_json(existing)
  INTO before_json
  FROM public.admin_subjects existing
  WHERE existing.id = p_subject_id
    AND existing."Deleted" = 0;

  UPDATE public.subjects
  SET disabled_at = NULL,
      disabled_by = NULL,
      disabled_reason = NULL,
      updated_at = now()
  WHERE id = p_subject_id
    AND "Deleted" = 0
  RETURNING id, subject_type, display_name, contact_name, contact_email, contact_phone, notes, created_by, "Deleted", created_at, updated_at
  INTO subject;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  SELECT * INTO subject FROM public.admin_subjects WHERE id = subject.id;

  PERFORM public.audit_log('enable', 'client', subject.id, subject.display_name, before_json, public.admin_subject_json(subject));

  RETURN public.admin_subject_json(subject);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_enable_subject(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_enable_subject(uuid) TO authenticated;
