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
import { mkdir } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"
import sharp from "sharp"

const root = join(dirname(fileURLToPath(import.meta.url)), "..")
const publicDir = join(root, "public")

/** Widths the `<picture>` offers. The page never displays it wider than 1200. */
const SCREENSHOT_WIDTHS = [1200, 2400]

/** The site's background, from design_system/Website.dc.html. */
const CANVAS_DARK = "#08090B"

async function screenshots() {
  // `trim` removes the transparent drop-shadow margin `screencapture` leaves
  // around the window, so the site can apply its own frame in CSS.
  const source = sharp(join(root, "screenshots", "containers-inspector.png"))
    .trim({ threshold: 0 })
    .withMetadata({ density: 72 })

  const { width, height } = await source
    .clone()
    .toBuffer({ resolveWithObject: true })
    .then((r) => r.info)
  console.log(`screenshot trimmed to ${width}x${height}`)

  for (const w of SCREENSHOT_WIDTHS) {
    const suffix =
      w === SCREENSHOT_WIDTHS[0] ? "" : `@${w / SCREENSHOT_WIDTHS[0]}x`
    const base = join(publicDir, `container-gui-containers-inspector${suffix}`)
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

  // Apple wants an opaque icon: a transparent one renders black on the home screen.
  await icon
    .clone()
    .resize(180, 180)
    .flatten({ background: CANVAS_DARK })
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
 * Open Graph card: the screenshot bleeding off the right edge of the app's own
 * dark canvas, with the icon and name on the left. 1200x630 is what every
 * unfurler crops to.
 */
async function openGraph() {
  const W = 1200
  const H = 630

  const shot = await sharp(
    join(publicDir, "container-gui-containers-inspector@2x.png")
  )
    .resize({ width: 820 })
    .toBuffer()

  const icon = await sharp(join(root, "..", "docs", "app-icon.png"))
    .resize(96, 96)
    .toBuffer()

  // Menlo rather than Geist Mono: librsvg resolves fonts through fontconfig,
  // which only sees fonts installed on the machine, and Menlo ships with every
  // macOS. It is the closest system monospace to the site's face.
  const text = Buffer.from(`
    <svg width="${W}" height="${H}" xmlns="http://www.w3.org/2000/svg">
      <style>
        .t { font-family: Menlo, ui-monospace, monospace; fill: #F2F3F5; }
        .s { font-family: Menlo, ui-monospace, monospace; fill: #9BA1AC; }
        .a { font-family: Menlo, ui-monospace, monospace; fill: #E8912A; }
      </style>
      <text class="a" x="72" y="216" font-size="17" letter-spacing="2.4">MACOS 26 · APPLE SILICON</text>
      <text class="t" x="72" y="286" font-size="46" font-weight="700">container-gui</text>
      <text class="s" x="72" y="346" font-size="25">Every apple/container command,</text>
      <text class="s" x="72" y="386" font-size="25">none of the typing.</text>
      <text class="s" x="72" y="452" font-size="19" opacity="0.7">A native macOS app for Apple Container</text>
    </svg>`)

  await sharp({
    create: { width: W, height: H, channels: 4, background: CANVAS_DARK },
  })
    .composite([
      { input: shot, top: 130, left: 590 },
      { input: icon, top: 96, left: 72 },
      { input: text, top: 0, left: 0 },
    ])
    .png({ compressionLevel: 9 })
    .toFile(join(publicDir, "og.png"))
}

await mkdir(publicDir, { recursive: true })
const { width, height } = await screenshots()
await icons()
await openGraph()

console.log(
  `\nDone. Use width="${SCREENSHOT_WIDTHS[0]}" height="${Math.round((height / width) * SCREENSHOT_WIDTHS[0])}" on the <img>.`
)
