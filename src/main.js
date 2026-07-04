const PRODUCTION_HOSTS = new Set([
  "atozvolleyball.com",
  "www.atozvolleyball.com"
]);

const shouldShowComingSoon = PRODUCTION_HOSTS.has(window.location.hostname.toLowerCase());

if (shouldShowComingSoon) {
  await import("./coming-soon.css");
  await import("./comingSoon.js");
} else {
  await import("./styles.css");
  await import("./app.js");
}
