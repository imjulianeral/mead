import { playwright } from "@vitest/browser-playwright";
import { defineConfig, type Plugin } from "vitest/config";

// The site is built under the same base path as on GitHub Pages (see blume.config.ts).
const base = process.env.DOCS_BASE ?? "/mead";
const site = process.env.DOCS_SITE || "https://owner.github.io";

// Serves dist/ under the base path, the way GitHub Pages serves the project site.
const serveUnderBase: Plugin = {
  name: "serve-dist-under-base",
  configureServer(server) {
    server.middlewares.use((req, _res, next) => {
      if (base && req.url && (req.url === base || req.url.startsWith(`${base}/`))) {
        req.url = req.url.slice(base.length) || "/";
      }
      next();
    });
  },
};

// The tests read the built site (`dist/`), so run `nub run build` first
// (`nub run test` does this for you).
export default defineConfig({
  publicDir: "dist",
  plugins: [serveUnderBase],
  define: {
    __DOCS_BASE__: JSON.stringify(base),
  },
  test: {
    env: { DOCS_BASE: base, DOCS_SITE: site },
    projects: [
      {
        // Renders pages in Chromium: layout, links, theming, and screenshots.
        extends: true,
        test: {
          name: "browser",
          include: ["tests/**/*.test.ts"],
          exclude: ["tests/seo.test.ts"],
          browser: {
            enabled: true,
            headless: true,
            provider: playwright({
              // The landing page honours reduced motion, which keeps the terminal
              // animation out of screenshots.
              contextOptions: { reducedMotion: "reduce" },
            }),
            instances: [{ browser: "chromium" }],
            viewport: { width: 1440, height: 1000 },
          },
        },
      },
      {
        // Reads the built HTML, sitemap, and images from disk.
        extends: true,
        test: {
          name: "seo",
          include: ["tests/seo.test.ts"],
          environment: "node",
        },
      },
    ],
  },
});
