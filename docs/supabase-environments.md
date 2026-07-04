# Supabase Environments

A2Z uses environment files to switch between demo, local, staging, and production without code changes.

## Environment Files

Tracked examples:

- `.env.demo.example`, browser-only demo mode.
- `.env.development.example`, local Supabase on this Mac.
- `.env.staging.example`, separate Supabase cloud project for staging.
- `.env.production.example`, production Supabase cloud project.

Ignored real files on this machine:

- `.env.demo.local`
- `.env.development.local`
- `.env.staging.local`
- `.env.production.local`

Only publishable Supabase keys belong in Vite env files. Never put service-role keys, database passwords, or storage secret keys in Vite env files.

Do not use a universal `.env.local` for this project. Vite loads `.env.local` for every mode, which can accidentally point staging or production builds at the wrong database.

## Commands

```bash
npm run dev:demo        # no Supabase, local demo users
npm run dev:local       # local Supabase at 127.0.0.1
npm run dev:staging     # staging Supabase cloud project
npm run dev:production  # production Supabase cloud project, use carefully
```

Build commands:

```bash
npm run build:local
npm run build:staging
npm run build:production
```

Cloudflare Pages should use `npm run build` and set production environment variables in Cloudflare.

## Local Supabase On This Mac

Start or check the local stack:

```bash
npm run supabase:start
npm run supabase:status
```

Apply migrations and seed data:

```bash
npm run supabase:reset
```

Local Supabase URLs:

- API: `http://127.0.0.1:54321`
- Studio: `http://127.0.0.1:54323`
- Mailpit: `http://127.0.0.1:54324`

Local start should report the Supabase stack as running, with Storage healthy in Docker.

## Local Admin User

Because local mode uses real Supabase Auth, demo credentials do not work in `npm run dev:local`.

1. Open local Studio: `http://127.0.0.1:54323`.
2. Go to **Authentication > Users**.
3. Create an admin user with an email and password.
4. Copy the auth user's UUID.
5. Run the admin bootstrap SQL from `docs/production-admin-bootstrap.md`, replacing the UUID and email.

Use the same pattern for staging and production.

## Separate Supabase Cloud Staging Project

If you want a second Supabase cloud database before production:

1. Create a new Supabase project named `A2Z Staging`.
2. Copy its Project URL and publishable key.
3. Create `.env.staging.local` from `.env.staging.example`.
4. Link the CLI to staging when you are ready to push schema:

```bash
supabase link --project-ref <STAGING_PROJECT_REF>
npm run supabase:push
```

5. Create the staging admin user and run the admin bootstrap SQL.

Do not link/push to production unless you intend to change production schema.
