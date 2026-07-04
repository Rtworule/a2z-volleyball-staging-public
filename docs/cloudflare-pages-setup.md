# Cloudflare Pages Setup

Use this checklist once the A2Z app code is in this repository.

## Git

Cloudflare Pages deploys automatically from a connected Git repository.

Recommended branch setup:

- Production branch: `main`
- Preview branches: any branch or pull request

## Cloudflare Pages

1. In Cloudflare, open **Workers & Pages**.
2. Select **Create application**.
3. Choose **Pages**.
4. Connect the Git repository for A2Z.
5. Select the `main` branch for production.
6. Set the framework/build settings for the app:
   - Framework preset: `Vite`
   - Build command: `npm run build`
   - Output directory: `dist`
7. Add production environment variables from `.env.production.example`.
8. Deploy.

## Domain

Add both custom domains if you want the bare domain and `www` to work:

- `atozvolleyball.com`
- `www.atozvolleyball.com`

Use one as the canonical domain and redirect the other to it.

## Supabase

Store only the public anonymous key in Cloudflare Pages environment variables.
Never commit service-role keys or database passwords.

Recommended environment variables:

- `NODE_VERSION=22.12.0`
- `VITE_SUPABASE_URL`
- `VITE_SUPABASE_ANON_KEY`

For production, set:

- `VITE_A2Z_ENVIRONMENT=production`
- `VITE_A2Z_AUTH_MODE=supabase`
- `VITE_SUPABASE_URL=https://spevmuqdjxyyfzoosjdz.supabase.co`
- `VITE_SUPABASE_ANON_KEY=<Supabase publishable key>`

For preview deployments, use a separate Supabase staging project if you do not want preview builds touching production data.

## Backups

For production, keep Supabase built-in backups if using Supabase Pro.
For extra safety, add a scheduled `pg_dump` export to external cloud storage.

## Future Agent Tooling

Not needed for the current Pages staging/production setup, but keep this Cloudflare agent setup prompt for future Cloudflare-heavy work:

- https://developers.cloudflare.com/agent-setup/prompt.md

Use it later if the project starts using Cloudflare Workers, D1, Durable Objects, Queues, Agents, or other Cloudflare platform features where Codex would benefit from Cloudflare-specific Skills/MCP setup.
