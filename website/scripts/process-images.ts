/**
 * Derives every image the site serves from two committed-elsewhere sources:
 * the app screenshot in `screenshots/` and the app icon in `../docs/`.
 *
 * The sources are large (a 2x window capture is ~2.4 MB) and follow the same
 * convention as `design_system/`: kept locally, not carried in the repo. Only
 * the optimised output in `public/` is committed, so re-run this after
 * replacing a source:
 *
 *     bun run images
 */
import { access, mkdir } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import sharp from "sharp"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const publicDir = join(root, "public")

/** Widths the `<picture>` offers. The page never displays it wider than 1200. */
const SCREENSHOT_WIDTHS = [1200, 2400]

/** The site's ground: the cool aluminium the whole page sits on. */
const PAPER = "#E9EDF3"

async function screenshots() {
  const sourcePath = join(root, "screenshots", "containers-inspector.png")

  // The source is git-ignored, so a fresh clone has the optimised output in
  // `public/` but not the capture it came from. Skip rather than fail: the
  // icons and the social card below are derived from committed files and are
  // the parts most likely to need regenerating on their own.
  try {
    await access(sourcePath)
  } catch {
    console.warn(
      `no ${sourcePath}; leaving the committed screenshots in public/ alone`
    )
    return null
  }

  // `trim` removes the fully transparent border `screencapture` leaves around
  // the window. What it keeps is macOS's own drop shadow, which lives in the
  // alpha channel and is what frames the window on the site's light ground —
  // the page deliberately adds no border or shadow of its own.
  const source = sharp(sourcePath).trim({ threshold: 0 }).withMetadata({
    density: 72,
  })

  const { width, height } = await source
    .clone()
    .toBuffer({ resolveWithObject: true })
    .then((r) => r.info)
  console.log(`screenshot trimmed to ${width}x${height}`)

  for (const w of SCREENSHOT_WIDTHS) {
    const suffix =
      w === SCREENSHOT_WIDTHS[0] ? "" : `@${w / SCREENSHOT_WIDTHS[0]}x`
    const base = join(publicDir, `cargodeck-containers-inspector${suffix}`)
    const resized = source
      .clone()
      .resize({ width: w, withoutEnlargement: true })

    await resized
      .clone()
      .avif({ quality: 62, effort: 9 })
      .toFile(`${base}.avif`)
    await resized
      .clone()
      .webp({ quality: 82, effort: 6 })
      .toFile(`${base}.webp`)
    await resized
      .clone()
      .png({ compressionLevel: 9, palette: true })
      .toFile(`${base}.png`)
  }

  return { width, height }
}

async function icons() {
  const icon = sharp(join(root, "..", "docs", "app-icon.png"))

  for (const size of [192, 512]) {
    await icon
      .clone()
      .resize(size, size)
      .png({ compressionLevel: 9 })
      .toFile(join(publicDir, `icon-${size}.png`))
  }

  // Apple wants an opaque icon: a transparent one renders black on the home
  // screen. Flattened onto the site's ground so the squircle's corners match
  // the page rather than cutting a dark notch out of it.
  await icon
    .clone()
    .resize(180, 180)
    .flatten({ background: PAPER })
    .png({ compressionLevel: 9 })
    .toFile(join(publicDir, "apple-touch-icon.png"))

  // 96px so it stays crisp as the 24px header mark and the 32px footer mark on
  // a 2x display, while still being small enough to serve as the favicon.
  await icon
    .clone()
    .resize(96, 96)
    .png({ compressionLevel: 9 })
    .toFile(join(publicDir, "favicon.png"))
}

/**
 * Open Graph card: the same idea as the page — the app as the one dark object
 * on a bright ground — with the window bleeding off the right and bottom
 * edges. 1200x630 is what every unfurler crops to.
 *
 * Helvetica Neue rather than Archivo: librsvg resolves fonts through
 * fontconfig, which only sees fonts installed on the machine, and installing
 * one to render a build artefact is not a trade worth making. It is the
 * closest system grotesque to the site's face, and the card carries two short
 * lines of text precisely so the substitution barely shows.
 */
async function openGraph() {
  const W = 1200
  const H = 630

  const shot = await sharp(
    join(publicDir, "cargodeck-containers-inspector@2x.png")
  )
    .resize({ width: 880 })
    .toBuffer()

  const icon = await sharp(join(root, "..", "docs", "app-icon.png"))
    .resize(84, 84)
    .toBuffer()

  const text = Buffer.from(`
    <svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
      <style>
        .n { font-family: "Helvetica Neue", Helvetica, sans-serif; fill: #0B1220; }
        .s { font-family: "Helvetica Neue", Helvetica, sans-serif; fill: #4F5A6B; }
      </style>
      <text class="n" x="72" y="212" font-size="42" font-weight="700" letter-spacing="-1">CargoDeck</text>
      <text class="s" x="72" y="266" font-size="25">A window for Apple’s container runtime.</text>
    </svg>`)

  await sharp({
    create: { width: W, height: H, channels: 4, background: PAPER },
  })
    .composite([
      { input: shot, top: 300, left: 320 },
      { input: icon, top: 74, left: 72 },
      { input: text, top: 0, left: 0 },
    ])
    .png({ compressionLevel: 9 })
    .toFile(join(publicDir, "og.png"))
}

await mkdir(publicDir, { recursive: true })
const measured = await screenshots()
await icons()
await openGraph()

if (measured) {
  console.log(
    `\nDone. Use width="${SCREENSHOT_WIDTHS[0]}" height="${Math.round((measured.height / measured.width) * SCREENSHOT_WIDTHS[0])}" on the <img>.`
  )
} else {
  console.log("\nDone: icons and the social card.")
}
