DO $$
DECLARE
  function_sql text;
BEGIN
  SELECT pg_get_functiondef('public.admin_update_team_season_price(uuid, jsonb)'::regprocedure)
  INTO function_sql;

  function_sql := replace(function_sql, 'UPDATE public.team_season_prices price', 'UPDATE public.team_season_prices target_price');
  function_sql := replace(function_sql, 'WHERE price.id = p_price_id', 'WHERE target_price.id = p_price_id');
  function_sql := replace(function_sql, 'AND price."Deleted" = 0', 'AND target_price."Deleted" = 0');
  function_sql := replace(function_sql, 'RETURNING price.* INTO price', 'RETURNING target_price.* INTO price');

  EXECUTE function_sql;
END $$;
