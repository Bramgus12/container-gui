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
export const SITE_URL = "https://cargodeck.gussekloo.com"

export const REPO_URL = "https://github.com/Bramgus12/CargoDeck"
export const RELEASES_URL = `${REPO_URL}/releases`
export const LICENSE_URL = `${REPO_URL}/blob/main/LICENSE`
export const TROUBLESHOOTING_URL = `${REPO_URL}/blob/main/docs/TROUBLESHOOTING.md`
export const APPLE_CONTAINER_URL = "https://github.com/apple/container"

export const APP_NAME = "CargoDeck"

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
 * because the line has to break in a particular place at display size. Keep
 * the two in step.
 */
export const HEADLINE = "A window for Apple's container runtime."

export const DESCRIPTION =
  "CargoDeck is a free, open-source native macOS app for Apple's container CLI. Run containers, build and pull images, follow logs and live stats, and manage Linux machines without the terminal."

/** The hero deck, directly under the headline. */
export const DECK =
  "A native macOS app for the container CLI. It runs the same binary already on your Mac and gives it lists, forms, inspectors and live logs — with the exact command on screen before anything runs."

export const SCREENSHOT = {
  /** Base name shared by every derivative in `public/`. */
  base: "/cargodeck-containers-inspector",
  width: 1200,
  height: 778,
  alt: "CargoDeck on macOS showing the Containers list with the inspector open on a running container, with live memory, CPU, network and block I/O statistics and streaming logs.",
} as const

/**
 * The hero's requirements plate: the facts a reader needs before they click
 * download, laid out the way the app's own inspector lays out a key and a
 * value. Data, not decoration — which is why there is no eyebrow above the
 * headline saying the same things in tracked capitals.
 */
export const REQUIREMENTS: Array<{ label: string; value: string }> = [
  { label: "macOS", value: "26 or later" },
  { label: "Chip", value: "Apple silicon" },
  { label: "container CLI", value: "0.12.3 to 1.x" },
  { label: "License", value: "GPL-3.0" },
]

export type Screen = {
  /** Matches the app's own sidebar labels. */
  name: string
  /** What the app's sidebar shows next to the label; `null` where it shows none. */
  count: string | null
  body: string
  /** The subcommands this screen wraps, as the CLI spells them. */
  commands: Array<string>
  /** What the app's status bar reports having run for this screen. */
  status: string
}

export const SCREENS: Array<Screen> = [
  {
    name: "Containers",
    count: "2",
    body: "Run, stop, signal and inspect. Live logs and per-container CPU, memory, network and block I/O, state filters, and a run sheet that assembles ports, mounts, environment and networks for you.",
    commands: ["run", "ls", "logs -f", "exec", "inspect"],
    status: "container ls --all",
  },
  {
    name: "Machines",
    count: "1",
    body: "The Linux VMs the CLI leaves out of every container list. Choose the default, open a real login shell, and edit boot configuration as a running-versus-after-restart pair, because the CLI only applies those changes on the next boot.",
    commands: ["machine create", "machine ls", "machine set"],
    status: "container machine ls",
  },
  {
    name: "Images",
    count: "4",
    body: "Pull with progress per layer, build from a Dockerfile with build args and platform, then tag, push, save and load. Digests stay visible, and a delete names what still depends on the image before it runs.",
    commands: ["images pull", "build", "images push"],
    status: "container images ls",
  },
  {
    name: "Volumes",
    count: "0",
    body: "Create, inspect and delete persistent volumes, with the containers currently mounting one listed before you remove it.",
    commands: ["volume create", "volume ls", "volume rm"],
    status: "container volume ls",
  },
  {
    name: "Networks",
    count: "2",
    body: "Subnets, attached containers and addresses in one place, instead of cross-referencing two commands by hand. Create, inspect, delete and prune.",
    commands: ["network create", "network ls", "network inspect"],
    status: "container network ls",
  },
  {
    name: "System",
    count: null,
    body: "Service, builder and DNS status with the controls to start and stop each one, local resolver domains written for you, registry logins, disk housekeeping with reclaimable space called out, and a redacted support report.",
    commands: ["system start", "system dns create", "registry login"],
    status: "container system status",
  },
]

/**
 * The run sheet as the reader would have filled it in.
 *
 * Every field here has to be traceable in the command beside it — that pairing
 * is the whole point of the section, so the two are edited together.
 */
export const RUN_SHEET: Array<{
  label: string
  value: string
  /** Booleans render as the app's switch rather than as the word "Yes". */
  kind?: "switch"
}> = [
  { label: "Name", value: "nginx-prod" },
  { label: "Image", value: "nginx:1.27" },
  { label: "Publish", value: "8080:80, 8443:443" },
  { label: "Mount", value: "site-content \u2192 /usr/share/nginx/html" },
  { label: "Read only", value: "On", kind: "switch" },
  { label: "Env file", value: ".env.local" },
  { label: "Detached", value: "On", kind: "switch" },
]

/**
 * The command that sheet produces, as tokens so the highlighting is markup
 * rather than a pre-coloured image, and so the plain text stays copyable.
 */
export const RUN_COMMAND: Array<
  Array<{ text: string; tone?: "cmd" | "flag" }>
> = [
  [
    { text: "container", tone: "cmd" },
    { text: " run " },
    { text: "-d", tone: "flag" },
    { text: " \\" },
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

/** The same command as one string, for the copy button. */
export const RUN_COMMAND_TEXT = RUN_COMMAND.map((line, index) =>
  (index === 0 ? "" : "  ").concat(line.map((token) => token.text).join(""))
).join("\n")
