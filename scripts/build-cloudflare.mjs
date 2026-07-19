import { build } from "vite";

const branch = process.env.CF_PAGES_BRANCH?.trim();
const mode = branch === "staging" ? "staging" : "production";

console.log(`Building Cloudflare branch "${branch || "local"}" in ${mode} mode.`);
await build({ mode });
