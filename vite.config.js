import { defineConfig } from "vite";

export default defineConfig({
  plugins: [
    {
      name: "a2z-html-entry",
      transformIndexHtml: {
        order: "pre",
        handler(html) {
          return html
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
