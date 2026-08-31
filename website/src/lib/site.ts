/**
 * Everything the page says about the product, in one place.
 *
 * The copy here is rendered by the page and also feeds the JSON-LD, which is
 * what stops the structured data from describing something the visible page
 * does not say.
 */

/**
 * The canonical origin, with no trailing slash. Every absolute URL on the site
 * derives from it: the canonical tag, `og:url`, the sitemap, and the JSON-LD.
 * Change it here and nowhere else when the domain is settled.
 */
export const SITE_URL = "https://container.gussekloo.com"

export const REPO_URL = "https://github.com/Bramgus12/container-gui"
export const RELEASES_URL = `${REPO_URL}/releases`
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`
export const TROUBLESHOOTING_URL = `${REPO_URL}/blob/main/docs/TROUBLESHOOTING.md`
export const APPLE_CONTAINER_URL = "https://github.com/apple/container"

export const APP_NAME = "Container GUI"
/** The lowercase wordmark the design uses in the header and the footer. */
export const WORDMARK = "container-gui"

/**
 * The latest published release, refreshed from the GitHub releases API at the
 * start of every build by `scripts/fetch-version.ts`. Re-exported here so the
 * rest of the site has one place to import product facts from.
 */
export { APP_VERSION } from "./version"

/**
 * The h1, as plain text, for the social-card alt text.
 *
 * The hero renders the same words as markup rather than from this constant,
 * because "apple/container" needs a nowrap span to stop the browser breaking
 * the line at the slash. Keep the two in step.
 */
export const HEADLINE = "Every apple/container command, none of the typing."

export const DESCRIPTION =
  "Container GUI is a free, open-source native macOS app for Apple's container CLI. Run containers, build images, follow logs and manage Linux machines without the terminal."

export const SCREENSHOT = {
  /** Base name shared by every derivative in `public/`. */
  base: "/container-gui-containers-inspector",
  width: 1200,
  height: 778,
  alt: "Container GUI on macOS showing the Containers list with the inspector open on a running container, with live memory, CPU, network and block I/O statistics and streaming logs.",
} as const

/** Cycled through by the typing animation in the hero terminal. */
export const TYPED_COMMANDS = [
  "container ls --all",
  "container run -d -p 8080:80 nginx:1.27",
  "container machine create alpine:3.22",
  "container system dns create test",
  "container logs -f --boot alpine-3.22",
] as const

/** The scrolling band under the hero. */
export const MARQUEE_COMMANDS = [
  "container run",
  "container ls",
  "container logs",
  "container exec",
  "container build",
  "container images pull",
  "container volume create",
  "container network ls",
  "container machine create",
  "container machine set",
  "container system dns create",
  "container inspect",
] as const

export type Principle = {
  index: string
  title: string
  body: string
}

export const PRINCIPLES: Array<Principle> = [
  {
    index: "01",
    title: "Same binary",
    body: "No daemon of its own, no reimplementation. The app runs the container binary already on your Mac — directly, never through a shell — and parses what comes back.",
  },
  {
    index: "02",
    title: "Command receipts",
    body: "Every sheet shows the exact invocation it will run, in a copyable line at the bottom. Learn the CLI by using the GUI, or paste it into a script.",
  },
  {
    index: "03",
    title: "Nothing hidden",
    body: "Machines, DNS domains, kernel paths, boot config that only applies after restart. The awkward parts of the runtime get a surface instead of a footnote.",
  },
]

export type Destination = {
  index: string
  name: string
  body: string
  commands: string
}

export const DESTINATIONS: Array<Destination> = [
  {
    index: "01",
    name: "Containers",
    body: "Run, stop, exec and inspect. Live logs and stats per container, state filters, and a run sheet that assembles ports, mounts, env and networks.",
    commands: "run · ls · logs",
  },
  {
    index: "02",
    name: "Machines",
    body: "The VMs the CLI filters out of every container list. Default selection, boot configuration split into running vs. after-restart, boot and stdio logs.",
    commands: "machine *",
  },
  {
    index: "03",
    name: "Images",
    body: "Pull with progress per layer, build from a Dockerfile with build args and platform, tag and prune. Digests stay visible.",
    commands: "images · build",
  },
  {
    index: "04",
    name: "Volumes",
    body: "Create, inspect and delete, with the containers currently mounting each one listed before you remove it.",
    commands: "volume *",
  },
  {
    index: "05",
    name: "Networks",
    body: "Subnets, attached containers and addresses, in the one place the CLI makes you cross-reference by hand.",
    commands: "network *",
  },
  {
    index: "06",
    name: "System",
    body: "Service status, builder resources, local DNS domains and the registry defaults — plus disk housekeeping with reclaimable space called out.",
    commands: "system · dns",
  },
]

/**
 * The command-receipt sample, as tokens so the highlighting is markup rather
 * than a pre-coloured image.
 */
export const COMMAND_RECEIPT: Array<
  Array<{ text: string; tone?: "cmd" | "flag" }>
> = [
  [
    { text: "container", tone: "cmd" },
    { text: " run " },
    { text: "-d", tone: "flag" },
  ],
  [{ text: "--name", tone: "flag" }, { text: " nginx-prod \\" }],
  [
    { text: "-p", tone: "flag" },
    { text: " 8080:80 " },
    { text: "-p", tone: "flag" },
    { text: " 8443:443 \\" },
  ],
  [
    { text: "-v", tone: "flag" },
    { text: " site-content:/usr/share/nginx/html:ro \\" },
  ],
  [{ text: "--env-file", tone: "flag" }, { text: " .env.local \\" }],
  [{ text: "nginx:1.27" }],
]
