import { defineConfig } from "blume";

/*
  The site is published to GitHub Pages as a project site, https://<owner>.github.io/mead.
  The docs workflow passes the real origin and path from actions/configure-pages, so a
  fork or a custom domain needs no edits here. Local builds use the placeholder owner.
*/
const site = process.env.DOCS_SITE || "https://owner.github.io";
const base = process.env.DOCS_BASE ?? "/mead";
const [owner, repo] = (process.env.GITHUB_REPOSITORY || "imjulianeral/mead").split("/");

const description =
  "A package manager for Odin that installs dependencies straight from their authors' Git repositories. No registry, no account, exact commits.";

export default defineConfig({
  title: "mead",
  description,
  deployment: { site, base },
  ...(owner && repo ? { github: { owner, repo, dir: "site" } } : {}),
  logo: {
    image: "/logo.svg",
    text: "mead",
  },
  banner: {
    content: "mead 0.1.0 implements design milestones 1–3 on Linux.",
    link: { text: "See what's built", href: "/reference/status" },
    dismissible: true,
    id: "v0.1.0",
  },
  content: {
    root: "content",
  },
  theme: {
    accent: { light: "#b26a00", dark: "#f6b73c" },
    radius: "md",
    mode: "system",
    fonts: {
      display: { name: "Fraunces", weights: [400, 600, 700] },
      body: "figtree",
      mono: "jetbrains-mono",
    },
  },
  navigation: {
    cta: { label: "GitHub", href: `https://github.com/${owner}/${repo}` },
    sidebar: { display: "flat" },
    tabs: [
      { label: "Guide", path: "/guide", icon: "book-open" },
      { label: "CLI", path: "/cli", icon: "terminal" },
      { label: "Manifest", path: "/manifest", icon: "file-code" },
      { label: "Reference", path: "/reference", icon: "library" },
    ],
  },
  toc: { minHeadingLevel: 2, maxHeadingLevel: 3 },
  seo: {
    og: {
      // The social cards use the dark "cellar" palette from theme.css, which stands out in light and dark feeds.
      logo: "/og-logo.svg",
      palette: {
        accent: "#f6b73c",
        background: "#1c1610",
        foreground: "#f3ead9",
        muted: "#b9a88c",
        border: "#3a2f22",
      },
      titles: { "/": "A Git-native package manager for Odin" },
      description,
    },
    structuredData: true,
    software: {
      name: "mead",
      applicationCategory: "DeveloperApplication",
      operatingSystem: "Linux",
      price: 0,
    },
    metatags: {
      "theme-color": "#1c1610",
    },
  },
  footer: {
    links: [
      { label: "Quickstart", href: "/guide/quickstart" },
      { label: "CLI", href: "/cli" },
      { label: "meade.kdl", href: "/manifest" },
      { label: "KDL v2", href: "https://kdl.dev" },
      { label: "Odin", href: "https://odin-lang.org" },
    ],
  },
});
