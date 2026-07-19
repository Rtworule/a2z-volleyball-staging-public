const STAGING_URL = "https://staging.a2z-volleyball.pages.dev";
const LEGACY_STAGING_URL = "https://staging-a2z-volleyball.pages.dev";
const STAGING_PROJECT_REF = "spevmuqdjxyyfzoosjdz";

function check(condition, message) {
  if (!condition) {
    throw new Error(message);
  }
}

async function readText(url, options = {}) {
  const response = await fetch(url, { cache: "no-store", ...options });
  const body = await response.text();
  return { response, body };
}

async function main() {
  const legacyPath = "/oauth-smoke";
  const legacy = await fetch(`${LEGACY_STAGING_URL}${legacyPath}`, {
    cache: "no-store",
    redirect: "manual"
  });
  check(legacy.status === 301, `Legacy staging returned HTTP ${legacy.status}, expected 301.`);
  check(
    legacy.headers.get("location") === `${STAGING_URL}${legacyPath}`,
    "Legacy staging does not redirect to the real staging site."
  );

  const { response: siteResponse, body: html } = await readText(STAGING_URL);
  check(siteResponse.status === 200, `Staging returned HTTP ${siteResponse.status}.`);
  check(html.includes('<div id="app"></div>'), "Staging HTML is missing the app container.");
  check(!html.includes('src="/src/'), "Staging HTML references source files instead of bundled assets.");

  const entryPath = html.match(/src="(\/assets\/[^\"]+\.js)"/)?.[1];
  check(entryPath, "Could not find the bundled staging entry script.");

  const { body: entrySource } = await readText(`${STAGING_URL}${entryPath}`);
  const appFile = entrySource.match(/\.\/(app-[A-Za-z0-9_-]+\.js)/)?.[1];
  check(appFile, "Could not find the staging app bundle.");

  const { body: appSource } = await readText(`${STAGING_URL}/assets/${appFile}`);
  const supabaseUrl = appSource.match(/https:\/\/[a-z]{20}\.supabase\.co/)?.[0];
  const publishableKey = appSource.match(/sb_publishable_[A-Za-z0-9_-]+/)?.[0];
  check(supabaseUrl && publishableKey, "Could not find the public Supabase configuration.");

  const projectRef = new URL(supabaseUrl).hostname.split(".")[0];
  check(
    projectRef === STAGING_PROJECT_REF,
    `Staging bundle uses Supabase project ${projectRef}, expected ${STAGING_PROJECT_REF}.`
  );

  const headers = {
    apikey: publishableKey,
    Authorization: `Bearer ${publishableKey}`,
    "Content-Type": "application/json"
  };

  const settingsResponse = await fetch(`${supabaseUrl}/auth/v1/settings`, {
    cache: "no-store",
    headers
  });
  check(settingsResponse.status === 200, `Supabase auth settings returned HTTP ${settingsResponse.status}.`);
  const settings = await settingsResponse.json();
  check(settings.external?.google === true, "Google OAuth is not enabled in staging Supabase.");

  const authorizeUrl = new URL(`${supabaseUrl}/auth/v1/authorize`);
  authorizeUrl.searchParams.set("provider", "google");
  authorizeUrl.searchParams.set("redirect_to", STAGING_URL);
  const authorizeResponse = await fetch(authorizeUrl, {
    cache: "no-store",
    headers,
    redirect: "manual"
  });
  check(authorizeResponse.status === 302, `Google authorize returned HTTP ${authorizeResponse.status}.`);
  const authorizeLocation = authorizeResponse.headers.get("location");
  check(authorizeLocation, "Google authorize did not return a redirect location.");
  check(
    new URL(authorizeLocation).hostname === "accounts.google.com",
    "Google authorize did not redirect to accounts.google.com."
  );

  const facilityResponse = await fetch(`${supabaseUrl}/rest/v1/rpc/public_get_facility_info`, {
    body: "{}",
    cache: "no-store",
    headers,
    method: "POST"
  });
  check(facilityResponse.status === 200, `Facility RPC returned HTTP ${facilityResponse.status}.`);
  const facility = await facilityResponse.json();
  check(facility?.courtCount === 9, `Facility RPC returned ${facility?.courtCount} courts, expected 9.`);

  console.log("Staging smoke test passed:");
  console.log(`- Legacy URL redirects to ${STAGING_URL}`);
  console.log(`- Bundle uses Supabase ${STAGING_PROJECT_REF}`);
  console.log("- Google OAuth redirects to accounts.google.com");
  console.log("- Facility RPC returns 9 courts");
}

main().catch((error) => {
  console.error(`Staging smoke test failed: ${error.message}`);
  process.exitCode = 1;
});
