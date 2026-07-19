const PRODUCTION_HOSTS = new Set([
  "atozvolleyball.com",
  "www.atozvolleyball.com"
]);

const currentHost = window.location.hostname.toLowerCase();
const isLocalHost = ["localhost", "127.0.0.1", "::1"].includes(currentHost);
const shouldShowComingSoon =
  PRODUCTION_HOSTS.has(currentHost) ||
  (isLocalHost && new URLSearchParams(window.location.search).has("coming-soon"));

if (shouldShowComingSoon) {
  await import("./coming-soon.css");
  await import("./comingSoon.js");
} else {
  await import("./styles.css");
  await import("./app.js");
}
