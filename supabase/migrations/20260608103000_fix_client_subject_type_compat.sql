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
