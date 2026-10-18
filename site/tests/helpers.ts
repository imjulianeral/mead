import { page } from "vitest/browser";

declare const __DOCS_BASE__: string;

/** The path the site is served under, such as `/mead` (set in vitest.config.ts). */
export const BASE: string = __DOCS_BASE__;

/** The href a page uses for a site route: `/cli/add` becomes `/mead/cli/add`. */
export function href(route: string): string {
  return `${BASE}${route}`;
}

export interface OpenOptions {
  width?: number;
  height?: number;
  theme?: "light" | "dark";
}

export interface OpenedPage {
  frame: HTMLIFrameElement;
  doc: Document;
  win: Window;
}

/**
 * Loads a built page from dist/ into an iframe of the given size. The iframe is
 * same-origin, so tests can read its DOM and computed styles directly.
 */
export async function openPage(path: string, options: OpenOptions = {}): Promise<OpenedPage> {
  const { width = 1440, height = 1000, theme = "light" } = options;
  await page.viewport(width, height);
  // Blume's head script reads the reader's saved choice before first paint.
  localStorage.setItem("blume-theme", theme);
  document.body.replaceChildren();
  document.body.style.margin = "0";

  const frame = document.createElement("iframe");
  frame.style.cssText = `border:0;display:block;width:${width}px;height:${height}px`;
  const loaded = new Promise<void>((resolve, reject) => {
    frame.addEventListener("load", () => resolve(), { once: true });
    frame.addEventListener("error", () => reject(new Error(`failed to load ${path}`)), { once: true });
  });
  frame.src = toFile(path);
  document.body.append(frame);
  await loaded;

  const doc = frame.contentDocument;
  const win = frame.contentWindow;
  if (!doc || !win) throw new Error(`${path} did not produce a document`);
  await doc.fonts.ready;
  return { frame, doc, win };
}

/** Maps a site route such as `/cli/add` to the URL of its built file under the base path. */
export function toFile(route: string): string {
  const [path, hash = ""] = route.split("#");
  const file = path === "/" ? "/index.html" : `${path.replace(/\/$/, "")}/index.html`;
  return `${BASE}${hash ? `${file}#${hash}` : file}`;
}

/** Whether a site route, or an href that already includes the base path, exists in the build. */
export async function routeExists(route: string): Promise<boolean> {
  const bare = BASE && route.startsWith(`${BASE}/`) ? route.slice(BASE.length) : route;
  const res = await fetch(toFile(bare), { method: "HEAD" });
  return res.ok;
}

/** Relative luminance (0–1) of a computed CSS color, which may be rgb() or oklch(). */
export function luminance(win: Window, color: string): number {
  // Let the browser convert any color syntax to sRGB through a canvas.
  const canvas = win.document.createElement("canvas");
  canvas.width = canvas.height = 1;
  const ctx = canvas.getContext("2d");
  if (!ctx) throw new Error("no 2d context");
  ctx.fillStyle = color;
  ctx.fillRect(0, 0, 1, 1);
  const [r, g, b] = Array.from(ctx.getImageData(0, 0, 1, 1).data).map((v) => {
    const c = v / 255;
    return c <= 0.03928 ? c / 12.92 : ((c + 0.055) / 1.055) ** 2.4;
  });
  return 0.2126 * r + 0.7152 * g + 0.0722 * b;
}

// The project commands, in the order the landing page's honeycomb shows them.
export const COMMANDS = [
  "init",
  "versions",
  "add",
  "install",
  "update",
  "build",
  "run",
  "exec",
  "tree",
  "env",
] as const;

// Every command with a CLI reference page. `upgrade` manages mead itself, so the honeycomb leaves it out.
export const CLI_PAGES = [...COMMANDS, "upgrade"] as const;
