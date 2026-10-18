// Search and social checks over the built site. These read dist/ from disk, so they
// cover every page, including ones added later, without opening a browser.
import { existsSync, readdirSync, readFileSync, statSync } from "node:fs";
import { join, relative } from "node:path";
import { describe, expect, test } from "vitest";

const DIST = new URL("../dist/", import.meta.url).pathname;
const BASE = process.env.DOCS_BASE ?? "/mead";
const ORIGIN = process.env.DOCS_SITE || "https://owner.github.io";
const SITE = `${ORIGIN}${BASE}`;

/** The absolute URL of a route. The home page at a domain root keeps its slash: https://example.org/. */
function urlFor(route: string): string {
  return route === "/" ? (BASE ? SITE : `${SITE}/`) : `${SITE}${route}`;
}

interface Page {
  route: string;
  html: string;
}

function htmlFiles(dir: string): string[] {
  return readdirSync(dir).flatMap((name) => {
    const path = join(dir, name);
    if (statSync(path).isDirectory()) return name.startsWith("_") || name === "api" ? [] : htmlFiles(path);
    return name === "index.html" ? [path] : [];
  });
}

const pages: Page[] = htmlFiles(DIST).map((file) => {
  const dir = relative(DIST, file).replace(/\/?index\.html$/, "");
  return { route: dir ? `/${dir}` : "/", html: readFileSync(file, "utf8") };
});

function decode(text: string): string {
  return text
    .replace(/&amp;/g, "&")
    .replace(/&#39;|&#x27;/g, "'")
    .replace(/&quot;/g, '"')
    .replace(/&lt;/g, "<")
    .replace(/&gt;/g, ">");
}

/** The content of a <meta> tag, whichever order its attributes come in. */
function meta(html: string, key: string): string | undefined {
  for (const tag of html.match(/<meta\b[^>]*>/g) ?? []) {
    if (new RegExp(`(?:name|property)="${key}"`).test(tag)) {
      return decode(/content="([^"]*)"/.exec(tag)?.[1] ?? "");
    }
  }
  return undefined;
}

function title(html: string): string {
  return decode(/<title>([^<]*)<\/title>/.exec(html)?.[1] ?? "");
}

function canonical(html: string): string | undefined {
  return /<link\b[^>]*rel="canonical"[^>]*href="([^"]*)"|<link\b[^>]*href="([^"]*)"[^>]*rel="canonical"/
    .exec(html)
    ?.slice(1)
    .find(Boolean);
}

/** The file in dist/ that a URL on the site maps to. */
function distFile(url: string): string {
  const path = new URL(url, SITE).pathname;
  expect(path.startsWith(`${BASE}/`) || path === BASE, `${url} is outside ${BASE}`).toBe(true);
  return join(DIST, decodeURIComponent(path.slice(BASE.length)));
}

function pngSize(file: string): { width: number; height: number } {
  const data = readFileSync(file);
  expect(data.subarray(1, 4).toString(), `${file} is a PNG`).toBe("PNG");
  return { width: data.readUInt32BE(16), height: data.readUInt32BE(20) };
}

const indexable = pages.filter((p) => !/<meta\b[^>]*noindex/.test(p.html));

describe("every page", () => {
  test("the build has pages", () => {
    expect(indexable.length).toBeGreaterThan(30);
  });

  test.each(indexable.map((p) => [p.route, p]))("%s has a focused title and description", (_route, page) => {
    const t = title(page.html);
    expect(t.length, t).toBeGreaterThanOrEqual(15);
    expect(t.length, t).toBeLessThanOrEqual(65);

    const description = meta(page.html, "description") ?? "";
    expect(description.length, description).toBeGreaterThanOrEqual(70);
    expect(description.length, description).toBeLessThanOrEqual(160);

    expect(page.html).toMatch(/<html\b[^>]*\blang="en"/);
    expect(page.html.match(/<h1[\s>]/g)?.length, "exactly one h1").toBe(1);
  });

  test("titles and descriptions are unique", () => {
    const titles = indexable.map((p) => title(p.html));
    const descriptions = indexable.map((p) => meta(p.html, "description"));
    expect(titles.filter((t, i) => titles.indexOf(t) !== i)).toEqual([]);
    expect(descriptions.filter((d, i) => descriptions.indexOf(d) !== i)).toEqual([]);
  });

  test.each(indexable.map((p) => [p.route, p]))("%s has a canonical URL and a social card", (route, page) => {
    const url = urlFor(route);
    expect(canonical(page.html)).toBe(url);
    expect(meta(page.html, "og:url")).toBe(url);
    expect(meta(page.html, "og:title")).toBeTruthy();
    expect(meta(page.html, "og:description")).toBeTruthy();

    const image = meta(page.html, "og:image") ?? "";
    expect(image.startsWith(`${SITE}/`), image).toBe(true);
    expect(meta(page.html, "twitter:image")).toBe(image);
    expect(meta(page.html, "twitter:card")).toBe("summary_large_image");
    expect(meta(page.html, "og:image:alt")).toBeTruthy();
    expect(meta(page.html, "og:image:width")).toBe("1200");
    expect(meta(page.html, "og:image:height")).toBe("630");

    const file = distFile(image);
    expect(existsSync(file), `${image} is in the build`).toBe(true);
    expect(pngSize(file)).toEqual({ width: 1200, height: 630 });
  });

  test.each(indexable.map((p) => [p.route, p]))("%s has valid structured data", (_route, page) => {
    const blocks = [...page.html.matchAll(/<script type="application\/ld\+json">([\s\S]*?)<\/script>/g)];
    expect(blocks.length).toBeGreaterThan(0);
    for (const [, json] of blocks) {
      expect(() => JSON.parse(json)).not.toThrow();
    }
  });

  test.each(pages.map((p) => [p.route, p]))("%s links only to pages and files that exist", (_route, page) => {
    const missing: string[] = [];
    for (const [, link] of page.html.matchAll(/\b(?:href|src)="(\/[^"#?]*)/g)) {
      if (!link.startsWith(`${BASE}/`) && link !== BASE) {
        missing.push(`${link} (missing the ${BASE} base path)`);
        continue;
      }
      const file = distFile(link);
      if (!existsSync(file) && !existsSync(join(file, "index.html"))) missing.push(link);
    }
    expect(missing).toEqual([]);
  });
});

describe("home page", () => {
  const home = pages.find((p) => p.route === "/")!;

  test("uses its own share card", () => {
    const image = meta(home.html, "og:image");
    expect(image).toBe(`${SITE}/social/home.png`);
    expect(pngSize(distFile(image!))).toEqual({ width: 1200, height: 630 });
  });

  test("names what mead is in its title", () => {
    expect(title(home.html)).toMatch(/package manager for Odin/);
  });

  test("describes mead as software in structured data", () => {
    expect(home.html).toContain('"@type":"SoftwareApplication"');
  });
});

describe("crawler files", () => {
  const sitemap = readFileSync(join(DIST, "sitemap.xml"), "utf8");
  const listed = [...sitemap.matchAll(/<loc>([^<]+)<\/loc>/g)].map((m) => m[1]);

  test("the sitemap lists every indexable page, and nothing else", () => {
    const expected = indexable.map((p) => urlFor(p.route));
    expect([...listed].sort()).toEqual([...expected].sort());
  });

  test("robots.txt points to the sitemap", () => {
    expect(readFileSync(join(DIST, "robots.txt"), "utf8")).toContain(`Sitemap: ${SITE}/sitemap.xml`);
  });

  test("the 404 page is not indexed", () => {
    const notFound = readFileSync(join(DIST, "404.html"), "utf8");
    expect(meta(notFound, "robots")).toContain("noindex");
    expect(listed.some((url) => url.includes("404"))).toBe(false);
  });

  test("GitHub Pages serves the underscore directories", () => {
    // Without .nojekyll, a Jekyll build on Pages drops _astro/, which holds every stylesheet and script.
    expect(existsSync(join(DIST, ".nojekyll"))).toBe(true);
  });
});
