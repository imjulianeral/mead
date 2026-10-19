import { describe, expect, test } from "vitest";
import { page } from "vitest/browser";
import { COMMANDS, href, luminance, openPage, routeExists } from "./helpers";

describe("landing page", () => {
  test("hero introduces mead and links into the docs", async () => {
    const { doc } = await openPage("/");
    const h1 = doc.querySelector(".hero h1");
    expect(h1?.textContent).toMatch(/Packages, poured\s*straight\s*from the\s*source\./);

    const ctas = [...doc.querySelectorAll<HTMLAnchorElement>(".ctas a")];
    expect(ctas.map((a) => a.getAttribute("href"))).toEqual([href("/guide/quickstart"), href("/cli")]);
    for (const a of ctas) {
      expect(await routeExists(a.getAttribute("href")!), a.href).toBe(true);
    }
  });

  test("the honeycomb has one cell per command, in order, each linking to its page", async () => {
    const { doc } = await openPage("/");
    const cells = [...doc.querySelectorAll<HTMLAnchorElement>(".hive .cell")];
    expect(cells.map((c) => c.querySelector("code")?.textContent)).toEqual([...COMMANDS]);
    expect(doc.querySelectorAll(".hive-row").length).toBe(3);

    for (const cell of cells) {
      const link = cell.getAttribute("href")!;
      expect(link).toBe(href(`/cli/${cell.querySelector("code")?.textContent}`));
      expect(await routeExists(link), link).toBe(true);
    }
  });

  test("the pipeline steps link to existing pages", async () => {
    const { doc } = await openPage("/");
    const steps = [...doc.querySelectorAll<HTMLAnchorElement>(".pipeline a")];
    expect(steps.map((s) => s.querySelector(".file")?.textContent)).toEqual([
      "meade.kdl",
      "mead.lock",
      "deps/",
      ".mead/build/",
    ]);
    for (const step of steps) {
      expect(await routeExists(step.getAttribute("href")!), step.href).toBe(true);
    }
  });

  test("the install line shows the install script", async () => {
    const { doc } = await openPage("/");
    expect(doc.querySelector(".install code")?.textContent).toMatch(
      /^curl -fsSL https:\/\/github\.com\/[^/]+\/[^/]+\/releases\/latest\/download\/install\.sh \| sh$/,
    );
  });

  test.each([1440, 768, 390])("the header and code fit at %ipx", async (width) => {
    const { doc } = await openPage("/", { width });
    const github = doc.querySelector<HTMLAnchorElement>('[data-blume-header] a[href^="https://github.com/"]')!;
    expect(github.textContent?.trim()).toBe("GitHub");
    expect(github.getBoundingClientRect().width).toBeGreaterThan(0);
    expect(github.getBoundingClientRect().right).toBeLessThanOrEqual(width);

    const install = doc.querySelector<HTMLElement>(".install code")!;
    const range = doc.createRange();
    range.selectNodeContents(install);
    expect(range.getClientRects().length).toBe(1);
    if (width >= 768) expect(install.scrollWidth).toBeLessThanOrEqual(install.clientWidth);

    for (const block of doc.querySelectorAll<HTMLElement>(".kdl, .term-body")) {
      expect(block.scrollWidth).toBeLessThanOrEqual(block.clientWidth);
      expect(block.scrollHeight).toBeLessThanOrEqual(block.clientHeight);
    }
    expect(doc.documentElement.scrollWidth).toBeLessThanOrEqual(width);
  });

  test("inline code keeps the space before it", async () => {
    // Regression: Astro once dropped the newline before <code>, printing "Whenmead add".
    const { doc } = await openPage("/");
    const text = doc.querySelector(".teaser-copy")?.textContent?.replace(/\s+/g, " ");
    expect(text).toContain("When mead add edits the file");
  });

  test("the terminal shows every line when motion is reduced", async () => {
    const { doc, win } = await openPage("/");
    const lines = [...doc.querySelectorAll<HTMLElement>(".term-body .l")];
    expect(lines.length).toBeGreaterThan(0);
    for (const line of lines) {
      expect(win.getComputedStyle(line).opacity).toBe("1");
    }
  });

  test("dark mode switches to the cellar palette", async () => {
    const light = await openPage("/", { theme: "light" });
    const lightBg = luminance(light.win, light.win.getComputedStyle(light.doc.body).backgroundColor);

    const dark = await openPage("/", { theme: "dark" });
    const darkBg = luminance(dark.win, dark.win.getComputedStyle(dark.doc.body).backgroundColor);
    const cell = dark.doc.querySelector<HTMLElement>(".cell-inner")!;
    const cellBg = luminance(dark.win, dark.win.getComputedStyle(cell).backgroundColor);

    expect(lightBg).toBeGreaterThan(0.8);
    expect(darkBg).toBeLessThan(0.05);
    expect(cellBg).toBeLessThan(0.05);
  });

  test("on a phone the page fits the width and the honeycomb becomes a grid", async () => {
    const { doc, win } = await openPage("/", { width: 390, height: 900 });
    expect(doc.documentElement.scrollWidth).toBeLessThanOrEqual(doc.documentElement.clientWidth);

    const hive = doc.querySelector<HTMLElement>(".hive")!;
    expect(win.getComputedStyle(hive).display).toBe("grid");
    const cell = doc.querySelector<HTMLElement>(".cell")!;
    expect(win.getComputedStyle(cell).clipPath).toBe("none");
  });
});

describe("landing page screenshots", () => {
  test.each([
    { name: "home-desktop-light", width: 1440, height: 1000, theme: "light" as const },
    { name: "home-desktop-dark", width: 1440, height: 1000, theme: "dark" as const },
    { name: "home-phone-light", width: 390, height: 900, theme: "light" as const },
  ])("$name", async ({ name, width, height, theme }) => {
    const { frame } = await openPage("/", { width, height, theme });
    await expect.element(page.elementLocator(frame)).toMatchScreenshot(name);
  });
});
