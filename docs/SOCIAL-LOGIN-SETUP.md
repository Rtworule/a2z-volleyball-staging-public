# Social login setup (Supabase OAuth)

The app already shows Google and Facebook buttons; each provider works as soon
as it is enabled in Supabase. For every provider below you will need your
project's callback URL, shown in **Supabase dashboard -> Authentication ->
Providers -> (provider)**. It looks like:

    https://<project-ref>.supabase.co/auth/v1/callback

Use your staging project's URL for staging and the production project's URL for
production. Also make sure **Authentication -> URL Configuration** lists your
site URLs (staging Pages URL and https://atozvolleyball.com) under Redirect URLs.

## 1. Google
1. Go to https://console.cloud.google.com -> create (or pick) a project.
2. APIs & Services -> OAuth consent screen: choose External, fill app name,
   support email, and your domain; add scopes `email` and `profile`; publish.
3. APIs & Services -> Credentials -> Create credentials -> OAuth client ID ->
   Web application.
   - Authorized JavaScript origins: your site URLs.
   - Authorized redirect URIs: the Supabase callback URL above.
4. Copy the Client ID and Client secret into Supabase -> Providers -> Google,
   toggle Enabled, save.

## 2. Facebook
1. Go to https://developers.facebook.com -> My Apps -> Create App -> type
   "Consumer" (or "Authenticate and request data from users").
2. Add the **Facebook Login** product -> Settings -> Valid OAuth Redirect URIs:
   the Supabase callback URL.
3. App settings -> Basic: copy App ID and App Secret into Supabase ->
   Providers -> Facebook, enable, save.
4. Switch the Facebook app from Development to Live mode (requires a privacy
   policy URL) or only test users can log in.

## 3. Apple (recommended if many iPhone users)
1. Requires a paid Apple Developer account (https://developer.apple.com).
2. Certificates, Identifiers & Profiles -> Identifiers -> add an **App ID**,
   then a **Services ID** (this becomes the client id); enable "Sign in with
   Apple" on it and set the Supabase callback URL as the Return URL.
3. Keys -> create a key with "Sign in with Apple" enabled; download the .p8.
4. In Supabase -> Providers -> Apple enter the Services ID, Team ID, Key ID,
   and the .p8 key contents; enable, save.
5. Frontend: add an Apple button by duplicating a social button with
   `data-provider="apple"` (the handler already accepts it).

## 4. Microsoft (Azure) — useful for school/club accounts
1. https://portal.azure.com -> Microsoft Entra ID -> App registrations -> New.
2. Supported account types: "Accounts in any organizational directory and
   personal Microsoft accounts".
3. Redirect URI (Web): the Supabase callback URL.
4. Certificates & secrets -> New client secret; copy its Value immediately.
5. Supabase -> Providers -> Azure: paste Application (client) ID and the
   secret; enable, save. Frontend button: `data-provider="azure"` (add
   "azure" to the allowed list in `signInWithProvider`).

## Notes
- New social accounts follow the same approval flow: a pending profile is
  created; an admin approves and links it to a coach/club before booking works.
- Usernames are derived from the email prefix; collisions get `-1`, `-2`, ...
- Do each provider twice: once with the staging Supabase project, once with
  production (separate credentials per environment is cleanest).
