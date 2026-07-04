DO $$
DECLARE
  function_sql text;
BEGIN
  SELECT pg_get_functiondef('public.admin_bulk_preview_items(jsonb)'::regprocedure)
  INTO function_sql;

  function_sql := replace(
    function_sql,
    'requested_court integer := nullif(replace(coalesce(payload->>''courtId'', ''''), ''court-'', ''''), '''')::integer;
  avoid_court_one boolean := coalesce(payload->>''courtId'', '''') = ''auto_except_1'';',
    'requested_court integer;
  avoid_court_one boolean := coalesce(payload->>''courtId'', '''') = ''auto_except_1'';'
  );

  function_sql := replace(
    function_sql,
    'IF resource NOT IN (''court'', ''trainer'') THEN
    RAISE EXCEPTION ''resourceType must be court or trainer'' USING ERRCODE = ''22023'';
  END IF;',
    'IF resource NOT IN (''court'', ''trainer'') THEN
    RAISE EXCEPTION ''resourceType must be court or trainer'' USING ERRCODE = ''22023'';
  END IF;

  IF coalesce(payload->>''courtId'', '''') ~ ''^court-[0-9]+$'' THEN
    requested_court := replace(payload->>''courtId'', ''court-'', '''')::integer;
  END IF;'
  );

  EXECUTE function_sql;
END $$;
