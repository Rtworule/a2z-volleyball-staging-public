import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { defineConfig } from "vite";

const BRAND_LOGO_MODULE_ID = "virtual:a2z-brand-logo";
const RESOLVED_BRAND_LOGO_MODULE_ID = `\0${BRAND_LOGO_MODULE_ID}`;
const brandLogoPath = fileURLToPath(new URL("./public/favicon.png", import.meta.url));
const brandLogoDataUrl = `data:image/png;base64,${readFileSync(brandLogoPath).toString("base64")}`;

export default defineConfig({
  plugins: [
    {
      name: "a2z-inline-brand-logo",
      resolveId(id) {
        return id === BRAND_LOGO_MODULE_ID ? RESOLVED_BRAND_LOGO_MODULE_ID : null;
      },
      load(id) {
        if (id !== RESOLVED_BRAND_LOGO_MODULE_ID) {
          return null;
        }

        return `export default ${JSON.stringify(brandLogoDataUrl)};`;
      }
    },
    {
      name: "a2z-html-entry",
      transformIndexHtml: {
        order: "pre",
        handler(html) {
          return html
            .replace(
              '<link rel="icon" type="image/png" href="/favicon.png">',
              `<link rel="icon" type="image/png" href="${brandLogoDataUrl}">`
            )
            .replace(
              "  </head>",
              '    <meta name="a2z-vite-entry" content="true">\n  </head>'
            )
            .replace(
              "  </body>",
              '    <script type="module" src="/src/main.js?v=20260613-admin-menu"></script>\n  </body>'
            );
        }
      }
    }
  ],
  build: {
    outDir: "dist",
    emptyOutDir: true
  },
  server: {
    host: "127.0.0.1",
    port: 4173
  },
  preview: {
    host: "127.0.0.1",
    port: 4173
  }
});
