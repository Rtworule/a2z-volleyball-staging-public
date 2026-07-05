-- Harden handle_new_auth_user for social (OAuth) signups:
-- 1) OAuth providers send no custom username -> derive from email, and on a
--    UNIQUE collision append a short numeric suffix instead of failing the
--    whole signup.
-- 2) Use the provider's full_name / name metadata for display_name when present.
-- Approval flow is unchanged: every new account starts as pending.

CREATE OR REPLACE FUNCTION public.handle_new_auth_user()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public
AS $$
DECLARE
  requested_username text := nullif(trim(new.raw_user_meta_data->>'username'), '');
  requested_display_name text := coalesce(
    nullif(trim(new.raw_user_meta_data->>'display_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'full_name'), ''),
    nullif(trim(new.raw_user_meta_data->>'name'), '')
  );
  requested_team_name text := nullif(trim(new.raw_user_meta_data->>'team_name'), '');
  base_username text := coalesce(requested_username, split_part(new.email, '@', 1));
  candidate_username text := base_username;
  attempt integer := 0;
BEGIN
  WHILE EXISTS (SELECT 1 FROM public.profiles WHERE username = candidate_username) AND attempt < 20 LOOP
    attempt := attempt + 1;
    candidate_username := base_username || '-' || attempt::text;
  END LOOP;

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
    candidate_username,
    new.email,
    coalesce(requested_display_name, split_part(new.email, '@', 1)),
    requested_team_name,
    'user',
    'pending'
  )
  ON CONFLICT (id) DO NOTHING;

  PERFORM public.link_profile_to_subjects_by_email(new.id, new.email);

  RETURN new;
END;
$$;
