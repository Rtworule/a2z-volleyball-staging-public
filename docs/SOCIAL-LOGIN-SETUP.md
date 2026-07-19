# Google login setup (Supabase OAuth)

The login and account-creation screens use Supabase Google OAuth. New Google
users enter the same pending approval flow as email/password users.

## Staging project

- Supabase project ref: `spevmuqdjxyyfzoosjdz`
- Supabase callback URL:
  `https://spevmuqdjxyyfzoosjdz.supabase.co/auth/v1/callback`
- Application URL: `https://staging.a2z-volleyball.pages.dev`

Staging does not currently have a Supabase custom domain or vanity subdomain.
Until one is activated, Google can display `spevmuqdjxyyfzoosjdz.supabase.co`
during sign-in. This hostname cannot be replaced by frontend code.

## Google Cloud

1. Open Google Cloud Console and choose the OAuth project.
2. In Google Auth Platform, open Branding and set the staging app name to
   `A to Z Volleyball Staging`, plus the support email, logo, homepage, and
   privacy-policy URL. Google requires brand verification before the name and
   logo replace the project identity for all users.
3. Create a Web application OAuth client.
4. Add `https://staging.a2z-volleyball.pages.dev` as an authorized JavaScript
   origin.
5. Add the Supabase callback URL above as an authorized redirect URI.

## Supabase

1. Open Authentication, then Providers, then Google.
2. Enter the Google client ID and client secret.
3. Turn Google on and save.
4. Under Authentication, then URL Configuration, add
   `https://staging.a2z-volleyball.pages.dev/**` to Redirect URLs.

## Branded Auth Domain

Google's `continue to ...` hostname comes from the Supabase Auth callback
domain. To replace it, configure either a Supabase custom domain such as
`auth-staging.a2z-volleyball.com` or a vanity subdomain, then:

1. Add the new `https://<auth-domain>/auth/v1/callback` URI to the existing
   Google OAuth web client before activating the domain.
2. Activate the domain in Supabase.
3. Change `VITE_SUPABASE_URL` in the matching Cloudflare Pages environment to
   the new Auth domain.
4. Rebuild, deploy, and run the complete Google sign-in flow.

The current staging organization does not have the Custom Domain add-on, so a
custom `a2z-volleyball.com` Auth hostname cannot be activated yet.

## Production Launch Requirement

Production must use a separate Google Cloud OAuth project and Supabase project.
Before enabling production Google login:

1. Set the verified Google app name to `A to Z Volleyball Center`.
2. Configure the verified homepage, privacy policy, support email, and A2Z logo.
3. Activate `auth.a2z-volleyball.com` (or the final approved Auth hostname).
4. Add its Supabase callback URI to the production Google OAuth client.
5. Point the production `VITE_SUPABASE_URL` to that branded Auth domain.
6. Verify sign-up, pending approval, approval, login, and logout end to end.

## Verification

The public provider setting must return `google: true`, and the authorize
endpoint must redirect to Google instead of returning HTTP 400:

```bash
curl -sS "https://spevmuqdjxyyfzoosjdz.supabase.co/auth/v1/settings" \
  -H "apikey: <staging-anon-key>"
```

After provider setup, use both Google buttons:

1. Log in with an existing Google-linked account.
2. Create a new Google account and confirm it appears as pending in Admin.
3. Approve the account, sign in again, and confirm scheduling is available.

Do not put the Google client secret in this repository. Production needs its
own Google provider setup and redirect allowlist when production login opens.
