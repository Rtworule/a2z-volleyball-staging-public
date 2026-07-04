# Production Admin Bootstrap

Use Supabase email/password auth for the first production admin account. Social login is intentionally disabled for now.

## Create The First Admin

1. In Supabase, open **Authentication > Users**.
2. Create one user with the admin email address and a strong password.
3. Copy the new auth user's UUID.
4. Run this SQL in Supabase SQL Editor, replacing the placeholder values:

```sql
insert into public.profiles (
  id,
  username,
  email,
  display_name,
  team_name,
  account_role,
  approval_status
) values (
  '<AUTH_USER_UUID>',
  'owner',
  '<ADMIN_EMAIL>',
  'A2Z Admin',
  'Operations',
  'admin',
  'approved'
)
on conflict (id) do update set
  username = excluded.username,
  email = excluded.email,
  display_name = excluded.display_name,
  team_name = excluded.team_name,
  account_role = excluded.account_role,
  approval_status = excluded.approval_status;
```

After that, production login uses that admin email and password.
