# A2Z Project Instructions

## Canonical Working Folder

- Use `/Users/rtworule/Projects/a2z-volleyball` as the only working folder for A2Z.
- Do not edit `/Users/rtworule/AI/Projects/A-to-Z-Volleyball-Center` as a separate copy. That path should point back to the canonical repo.
- Before changing files, confirm the Git repo root with:

```bash
git rev-parse --show-toplevel
```

Expected output:

```text
/Users/rtworule/Projects/a2z-volleyball
```

## Supabase Environment Safety

- Keep the Supabase CLI linked to staging by default: `giciqacwootxxargvtjm`.
- Link to production only when R2 explicitly asks to update the production database, schema, or config.
- Do not delete production data unless R2 confirms the exact destructive action after seeing: `ARE YOU SURE YOU WANT TO DELETE PRODUCTION DATA?`
- After any required production database work, relink the CLI back to staging.
- For staging cleanup requests like "delete everything except admin users", also preserve `admin_menu_items`. Treat admin menu rows as required configuration, not disposable test data.

## Pre-Push Production Security Gate

Before every push, treat the code as production-bound for Cloudflare and run:

```bash
npm audit --audit-level=moderate
npm test
rg -n -g '!node_modules/**' -g '!package-lock.json' "(sb_secret_|service_role|SECRET|PRIVATE KEY|postgresql://postgres:postgres|Access Key|Secret Key)"
git diff --cached --name-only | grep -E 'node_modules|supabase/\\.temp|supabase/\\.branches'
```

Push only when:

- `npm audit` reports 0 vulnerabilities at moderate or higher.
- Tests pass.
- Secret scan returns no hits.
- No `node_modules`, Supabase temp metadata, or local-only generated files are staged.
- Demo authentication remains disabled outside localhost/file previews.

## Post-Deployment Smoke Test

After every Cloudflare Pages deployment, smoke test the deployed URL before telling R2 it is done.

Required checks:

```bash
curl -sS <deployed-url> | sed -n '1,80p'
```

- The deployed HTML must reference bundled `/assets/...` files, not source files like `./src/main.js`.
- Open the deployed URL in a browser and verify visible page text renders.
- Check that `#app` is not empty and the page is not a blank screen.
- If the smoke test fails, fix or roll back before reporting completion.
