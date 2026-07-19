CREATE OR REPLACE FUNCTION public.admin_update_team_season_price(p_price_id uuid, payload jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  subject public.admin_subjects%ROWTYPE;
  updated_price public.team_season_prices%ROWTYPE;
  before_json jsonb;
BEGIN
  PERFORM public.admin_require_approved();

  SELECT public.admin_team_season_price_json(existing)
  INTO before_json
  FROM public.team_season_prices existing
  WHERE existing.id = p_price_id
    AND existing."Deleted" = 0;

  SELECT *
  INTO subject
  FROM public.admin_subjects
  WHERE id = (payload->>'subjectId')::uuid
    AND "Deleted" = 0;

  IF subject.id IS NULL THEN
    RAISE EXCEPTION 'Client record not found' USING ERRCODE = '22023';
  END IF;

  UPDATE public.team_season_prices AS target_price
  SET subject_id = subject.id,
      season_id = selected_season.id,
      season = selected_season.display_name,
      season_year = selected_season.start_year,
      hourly_rate = (payload->>'hourlyRate')::numeric,
      documents_received = coalesce((payload->>'documentsReceived')::boolean, target_price.documents_received),
      deposit = coalesce(nullif(payload->>'deposit', '')::numeric, target_price.deposit),
      updated_at = now()
  FROM public.seasons AS selected_season
  WHERE target_price.id = p_price_id
    AND selected_season.id = (payload->>'seasonId')::uuid
    AND target_price."Deleted" = 0
    AND selected_season."Deleted" = 0
  RETURNING target_price.* INTO updated_price;

  IF updated_price.id IS NULL THEN
    RAISE EXCEPTION 'Club season not found' USING ERRCODE = '22023';
  END IF;

  PERFORM public.audit_log(
    'update',
    'club_season',
    updated_price.id,
    subject.display_name,
    before_json,
    public.admin_team_season_price_json(updated_price)
  );

  RETURN public.admin_team_season_price_json(updated_price);
END;
$$;

REVOKE EXECUTE ON FUNCTION public.admin_update_team_season_price(uuid, jsonb) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION public.admin_update_team_season_price(uuid, jsonb) TO authenticated;
