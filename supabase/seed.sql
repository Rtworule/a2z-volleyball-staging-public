INSERT INTO public.facility_config (
  id,
  court_count,
  trainer_capacity,
  court_hourly_rate,
  gym_hourly_rate,
  min_reservation_minutes,
  reservation_step_minutes,
  timezone
) VALUES (
  true,
  9,
  2,
  75,
  110,
  60,
  30,
  'America/New_York'
) ON CONFLICT (id) DO UPDATE SET
  court_count = excluded.court_count,
  trainer_capacity = excluded.trainer_capacity,
  court_hourly_rate = excluded.court_hourly_rate,
  gym_hourly_rate = excluded.gym_hourly_rate,
  min_reservation_minutes = excluded.min_reservation_minutes,
  reservation_step_minutes = excluded.reservation_step_minutes,
  timezone = excluded.timezone;

INSERT INTO public.operating_hours (day_of_week, open_time, close_time, is_closed) VALUES
  (0, '08:00', '21:00', false),
  (1, '10:00', '23:00', false),
  (2, '10:00', '23:00', false),
  (3, '10:00', '23:00', false),
  (4, '10:00', '23:00', false),
  (5, '10:00', '23:00', false),
  (6, '08:00', '21:00', false)
ON CONFLICT (day_of_week) DO UPDATE SET
  open_time = excluded.open_time,
  close_time = excluded.close_time,
  is_closed = excluded.is_closed;

INSERT INTO public.auth_provider_options (provider, enabled, display_name) VALUES
  ('google', false, 'Google'),
  ('apple', false, 'Apple'),
  ('facebook', false, 'Facebook')
ON CONFLICT (provider) DO UPDATE SET
  enabled = excluded.enabled,
  display_name = excluded.display_name;

INSERT INTO public.resources (resource_type, court_number, name, is_active)
SELECT 'court', generate_series(1, 9), 'Court ' || generate_series(1, 9), true
ON CONFLICT (resource_type, court_number) DO UPDATE SET
  name = excluded.name,
  is_active = excluded.is_active;

INSERT INTO public.resources (resource_type, court_number, name, is_active)
SELECT 'trainer', null, 'Trainer gym', true
WHERE NOT EXISTS (
  SELECT 1 FROM public.resources WHERE resource_type = 'trainer'
);

UPDATE public.resources
SET name = 'Trainer gym',
    is_active = true
WHERE resource_type = 'trainer';

INSERT INTO public.profiles (
  id,
  username,
  email,
  display_name,
  team_name,
  account_role,
  approval_status
) VALUES
  ('00000000-0000-4000-8000-000000000001', 'member', 'member@a2z.local', 'Jordan Lee', 'Riverside 16U', 'user', 'approved'),
  ('00000000-0000-4000-8000-000000000002', 'pending', 'pending@a2z.local', 'Sam Patel', 'Adult open play', 'user', 'pending'),
  ('00000000-0000-4000-8000-000000000003', 'owner', 'owner@a2z.local', 'Maya Rivera', 'Operations', 'admin', 'approved')
ON CONFLICT (id) DO UPDATE SET
  username = excluded.username,
  email = excluded.email,
  display_name = excluded.display_name,
  team_name = excluded.team_name,
  account_role = excluded.account_role,
  approval_status = excluded.approval_status;

INSERT INTO public.subjects (
  id,
  subject_type,
  display_name,
  contact_name,
  contact_email,
  contact_phone,
  notes,
  created_by
) VALUES
  ('40000000-0000-4000-8000-000000000001', 'team', 'Storm Elite', null, null, null, 'Temporary team record for admin-created reservations.', '00000000-0000-4000-8000-000000000003'),
  ('40000000-0000-4000-8000-000000000002', 'coach', 'Coach rental', null, null, null, 'Temporary coach record for admin-created reservations.', '00000000-0000-4000-8000-000000000003')
ON CONFLICT (id) DO UPDATE SET
  subject_type = excluded.subject_type,
  display_name = excluded.display_name,
  contact_name = excluded.contact_name,
  contact_email = excluded.contact_email,
  contact_phone = excluded.contact_phone,
  notes = excluded.notes,
  "Deleted" = 0;

INSERT INTO public.reservations (
  id,
  user_id,
  team_name,
  subject_id,
  resource_type,
  court_number,
  start_at,
  end_at,
  status,
  payment_status,
  amount,
  created_by
) VALUES
  ('10000000-0000-4000-8000-000000000301', '00000000-0000-4000-8000-000000000001', 'Riverside 16U', null, 'court', 1, '2026-06-01T17:00:00-04:00', '2026-06-01T19:00:00-04:00', 'confirmed', 'paid', 150, '00000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-000000000302', null, 'Storm Elite', '40000000-0000-4000-8000-000000000001', 'court', 5, '2026-05-05T18:00:00-04:00', '2026-05-05T20:00:00-04:00', 'confirmed', 'due', 150, '00000000-0000-4000-8000-000000000003'),
  ('10000000-0000-4000-8000-000000000303', null, 'Storm Elite', '40000000-0000-4000-8000-000000000001', 'court', 6, '2026-05-12T18:00:00-04:00', '2026-05-12T20:00:00-04:00', 'confirmed', 'due', 150, '00000000-0000-4000-8000-000000000003'),
  ('10000000-0000-4000-8000-000000000304', '00000000-0000-4000-8000-000000000001', null, null, 'trainer', null, '2026-05-06T18:30:00-04:00', '2026-05-06T19:30:00-04:00', 'confirmed', 'due', 110, '00000000-0000-4000-8000-000000000001'),
  ('10000000-0000-4000-8000-000000000305', null, 'Coach rental', '40000000-0000-4000-8000-000000000002', 'trainer', null, '2026-05-07T20:00:00-04:00', '2026-05-07T21:00:00-04:00', 'confirmed', 'due', 110, '00000000-0000-4000-8000-000000000003'),
  ('10000000-0000-4000-8000-000000000306', null, 'Coach rental', '40000000-0000-4000-8000-000000000002', 'court', 3, '2026-05-14T19:00:00-04:00', '2026-05-14T21:00:00-04:00', 'confirmed', 'due', 150, '00000000-0000-4000-8000-000000000003')
ON CONFLICT (id) DO UPDATE SET
  payment_status = excluded.payment_status,
  amount = excluded.amount,
  subject_id = excluded.subject_id,
  team_name = excluded.team_name,
  status = excluded.status;

INSERT INTO public.closures (
  id,
  resource_type,
  court_number,
  start_at,
  end_at,
  reason
) VALUES (
  '20000000-0000-4000-8000-000000000001',
  'court',
  7,
  '2026-06-01T15:00:00-04:00',
  '2026-06-01T18:00:00-04:00',
  'Floor maintenance'
) ON CONFLICT (id) DO UPDATE SET
  resource_type = excluded.resource_type,
  court_number = excluded.court_number,
  start_at = excluded.start_at,
  end_at = excluded.end_at,
  reason = excluded.reason;

INSERT INTO public.fixed_reservations (
  id,
  title,
  resource_type,
  court_number,
  days_of_week,
  start_date,
  end_date,
  start_time,
  end_time,
  capacity
) VALUES
  ('30000000-0000-4000-8000-000000000001', '14U season block', 'court', 4, ARRAY[1, 3], '2026-06-01', '2026-08-31', '18:00', '20:00', 1),
  ('30000000-0000-4000-8000-000000000002', 'Trainer partial block', 'trainer', null, ARRAY[1], '2026-06-01', '2026-07-31', '19:00', '20:00', 1)
ON CONFLICT (id) DO UPDATE SET
  title = excluded.title,
  resource_type = excluded.resource_type,
  court_number = excluded.court_number,
  days_of_week = excluded.days_of_week,
  start_date = excluded.start_date,
  end_date = excluded.end_date,
  start_time = excluded.start_time,
  end_time = excluded.end_time,
  capacity = excluded.capacity;
