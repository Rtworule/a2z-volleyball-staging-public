-- Keep newly linked environments usable without loading demo seed data.
-- Existing facility settings, hours, and resources are left unchanged.

INSERT INTO public.facility_config (id)
VALUES (true)
ON CONFLICT (id) DO NOTHING;

INSERT INTO public.operating_hours (day_of_week, open_time, close_time, is_closed)
VALUES
  (0, '08:00', '21:00', false),
  (1, '10:00', '23:00', false),
  (2, '10:00', '23:00', false),
  (3, '10:00', '23:00', false),
  (4, '10:00', '23:00', false),
  (5, '10:00', '23:00', false),
  (6, '08:00', '21:00', false)
ON CONFLICT (day_of_week) DO NOTHING;

INSERT INTO public.resources (resource_type, court_number, name, is_active)
SELECT 'court', court_number, 'Court ' || court_number, true
FROM generate_series(1, 9) AS court_number
ON CONFLICT (resource_type, court_number) DO NOTHING;

INSERT INTO public.resources (resource_type, court_number, name, is_active)
SELECT 'trainer', null, 'Trainer gym', true
WHERE NOT EXISTS (
  SELECT 1
  FROM public.resources
  WHERE resource_type = 'trainer'
);
