# A2Z Volleyball

Commercial scheduling application for atozvolleyball.com.

## Implemented rules

- Public visitors see general facility information, pictures, programs, and login only.
- Pending or unapproved accounts cannot view schedules or reservation controls.
- Approved non-admin users can view availability, reserve courts, and view their bookings.
- Admin users can access the admin command center for approvals, payments, hours, rates, and capacity.
- Production admin writes use Supabase RPC functions that verify the caller is an approved admin before mutating data.
- Admin bulk reservation tools support preview, save, apply, soft delete, undo, conflict handling, and paid-flag propagation.
- 9 individually bookable volleyball courts.
- Trainer gym bookings use pooled capacity and allow 2 simultaneous coaching slots.
- Reservations must be at least 1 hour.
- Reservation starts and ends must land on 30-minute intervals.
- Operating hours and hourly rates are configurable through admin-only settings.
- Supabase migrations and seed data define profiles, resources, reservations, operating hours, facility config, closures, fixed reservations, temporary admin subjects, bulk transactions, and auth provider options.

## Verify

```bash
npm run build
npm test
npm audit --audit-level=moderate
```

`npm test` covers the production app only. Older Hermes feature slices are kept under
`docs/archive/hermes-feature-slices/` for reference and can be checked separately with
`npm run test:archive`.

## Local Development

```bash
npm run supabase:start
npm run supabase:reset
npm run dev:local
```

Use `npm run dev:demo` for the browser-only demo login. Use `npm run dev:staging` or `npm run dev:production` only when the matching ignored environment file exists.

Use `npm run supabase:restart` if Docker Desktop shows Supabase containers split across
networks or stuck restarting. The Supabase scripts pin the local network to
`supabase-local-a2z` so the DB hostname resolves consistently.

## Deployment

This repo is intended to deploy through Cloudflare Pages from a Git provider.

Recommended production flow:

1. Push changes to the `main` branch.
2. Cloudflare Pages runs `npm run build` and deploys `dist`.
3. Preview branches create non-production preview deployments.

See [docs/cloudflare-pages-setup.md](docs/cloudflare-pages-setup.md) for the one-time Cloudflare setup checklist.
See [docs/supabase-environments.md](docs/supabase-environments.md) for local, staging, and production database switching.
See [docs/production-admin-bootstrap.md](docs/production-admin-bootstrap.md) to create the first production admin account.
