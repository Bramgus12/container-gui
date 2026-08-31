/**
 * Writes `public/robots.txt` and `public/sitemap.xml` from `src/lib/site.ts`.
 *
 * Both files need the absolute origin, and hard-coding it in two more places
 * is exactly how a site ends up advertising a sitemap on a domain it no longer
 * uses. Running this as part of `build` keeps `SITE_URL` the only place the
 * domain is written down.
 */
import { writeFile } from "node:fs/promises"
import { dirname, join } from "node:path"
import { fileURLToPath } from "node:url"

import { SITE_URL } from "../src/lib/site"

const publicDir = join(dirname(fileURLToPath(import.meta.url)), "..", "public")

const robots = `User-agent: *
Allow: /

Sitemap: ${SITE_URL}/sitemap.xml
`

const sitemap = `<?xml version="1.0" encoding="UTF-8"?>
<urlset xmlns="http://www.sitemaps.org/schemas/sitemap/0.9">
  <url>
    <loc>${SITE_URL}/</loc>
    <lastmod>${new Date().toISOString().slice(0, 10)}</lastmod>
    <changefreq>monthly</changefreq>
    <priority>1.0</priority>
  </url>
</urlset>
`

await writeFile(join(publicDir, "robots.txt"), robots)
await writeFile(join(publicDir, "sitemap.xml"), sitemap)

console.log(`Wrote robots.txt and sitemap.xml for ${SITE_URL}`)
