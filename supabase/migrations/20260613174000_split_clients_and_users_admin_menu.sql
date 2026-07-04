UPDATE public.admin_menu_items
SET
  page_order = CASE menu_key
    WHEN 'clients' THEN 1001
    WHEN 'users' THEN 1002
    ELSE page_order
  END,
  updated_at = now()
WHERE menu_key IN ('clients', 'users');

INSERT INTO public.admin_menu_items (
  menu_key,
  name,
  page_order,
  required_role,
  required_permission,
  description
) VALUES
  ('clients', 'Clients', 40, 'admin', 'admin.clients.read', 'Create, edit, disable, and manage clients.'),
  ('users', 'Users', 95, 'admin', 'admin.users.read', 'Review pending, approved, and rejected user accounts.')
ON CONFLICT (menu_key) DO UPDATE SET
  name = excluded.name,
  page_order = excluded.page_order,
  is_active = true,
  required_role = excluded.required_role,
  required_permission = excluded.required_permission,
  description = excluded.description,
  "Deleted" = 0,
  updated_at = now();
