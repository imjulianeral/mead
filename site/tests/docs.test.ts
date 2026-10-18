import { describe, expect, test } from "vitest";
import { page } from "vitest/browser";
import { CLI_PAGES, href, openPage, routeExists } from "./helpers";

describe("CLI reference", () => {
  test.each(CLI_PAGES)("mead %s has a synopsis, an errors section, and a sidebar entry", async (cmd) => {
    const { doc } = await openPage(`/cli/${cmd}`);

    const synopsis = doc.querySelector(".synopsis code");
    expect(synopsis, "synopsis").not.toBeNull();
    expect(synopsis?.querySelector(".t-cmd")?.textContent).toBe("mead");
    expect(synopsis?.querySelector(".t-sub")?.textContent).toBe(cmd);

    const headings = [...doc.querySelectorAll("h2")].map((h) => h.textContent?.trim());
    expect(headings).toContain("Errors");

    const sidebar = [...doc.querySelectorAll<HTMLAnchorElement>("aside a, nav a")].map((a) =>
      a.getAttribute("href"),
    );
    for (const other of CLI_PAGES) {
      expect(sidebar).toContain(href(`/cli/${other}`));
    }
  });

  test("the synopsis colours each kind of token", async () => {
    const { doc } = await openPage("/cli/add");
    const [dependency] = doc.querySelectorAll(".synopsis code");
    const kinds = (cls: string) => [...dependency.querySelectorAll(cls)].map((t) => t.textContent);

    expect(kinds(".t-ph")).toEqual(["<git-url>", "<name>", "<tag>", "<branch>", "<commit>", "<tag>", "<dir>"]);
    expect(kinds(".t-flag")).toEqual(["--as", "--tag", "--branch", "--rev", "--release", "--path"]);
    expect(kinds(".t-punct")).toEqual(["[", "]", "(", "|", "|", "|", ")", "[", "]"]);
  });

  test("pass-through arguments render as a dash token", async () => {
    const { doc } = await openPage("/cli/run");
    const code = doc.querySelector(".synopsis code")!;
    expect(code.querySelector(".t-dash")?.textContent).toBe("--");
    expect([...code.querySelectorAll(".t-word")].map((t) => t.textContent)).toEqual(["target", "args"]);
    expect([...code.querySelectorAll(".t-punct")].map((t) => t.textContent)).toEqual(["[", "]", "[", "...", "]"]);
  });

  test("long synopses wrap instead of widening the page on a phone", async () => {
    const { doc } = await openPage("/cli/add", { width: 390, height: 900 });
    expect(doc.documentElement.scrollWidth).toBeLessThanOrEqual(doc.documentElement.clientWidth);
  });
});

describe("section tabs", () => {
  test.each(["/guide", "/cli", "/manifest", "/reference"])("%s exists", async (route) => {
    expect(await routeExists(route)).toBe(true);
  });
});

describe("docs screenshots", () => {
  test.each([
    { name: "cli-add-light", route: "/cli/add", theme: "light" as const },
    { name: "cli-add-dark", route: "/cli/add", theme: "dark" as const },
    { name: "manifest-validation-light", route: "/manifest/validation", theme: "light" as const },
  ])("$name", async ({ name, route, theme }) => {
    const { frame } = await openPage(route, { theme });
    await expect.element(page.elementLocator(frame)).toMatchScreenshot(name);
  });
});
