// Renders scripts/og-home.html to public/social/home.png, the home page's share card.
// Run it with `nub run og:home` after changing the card; the PNG is committed.
import { mkdir } from "node:fs/promises";
import { chromium } from "playwright";

const html = new URL("./og-home.html", import.meta.url);
const out = new URL("../public/social/home.png", import.meta.url);

const browser = await chromium.launch();
try {
  const page = await browser.newPage({ viewport: { width: 1200, height: 630 }, deviceScaleFactor: 1 });
  await page.goto(html.href, { waitUntil: "networkidle" });
  await page.evaluate(() => document.fonts.ready);
  await mkdir(new URL(".", out), { recursive: true });
  await page.screenshot({ path: out.pathname, type: "png" });
  console.log(`wrote ${out.pathname}`);
} finally {
  await browser.close();
}
