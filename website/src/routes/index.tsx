import { createFileRoute } from "@tanstack/react-router"

import { CommandReceipt } from "@/components/sections/command-receipt"
import { Destinations } from "@/components/sections/destinations"
import { Footer } from "@/components/sections/footer"
import { Hero } from "@/components/sections/hero"
import { Install } from "@/components/sections/install"
import { Marquee } from "@/components/sections/marquee"
import { Principles } from "@/components/sections/principles"
import { SiteHeader } from "@/components/site-header"
import {
  APP_NAME,
  APP_VERSION,
  DESCRIPTION,
  LICENSE_URL,
  RELEASES_URL,
  REPO_URL,
  SCREENSHOT,
  SITE_URL,
} from "@/lib/site"

export const Route = createFileRoute("/")({ component: Home })

/**
 * Built from the same constants the page renders.
 *
 * There is no `FAQPage` node: the design has no FAQ section, and a FAQPage
 * describing questions that are not on the page is exactly what earns a
 * structured-data manual action.
 */
const structuredData = {
  "@context": "https://schema.org",
  "@graph": [
    {
      "@type": "WebSite",
      "@id": `${SITE_URL}/#website`,
      url: `${SITE_URL}/`,
      name: APP_NAME,
      description: DESCRIPTION,
      inLanguage: "en",
    },
    {
      "@type": "SoftwareApplication",
      "@id": `${SITE_URL}/#app`,
      name: APP_NAME,
      alternateName: "Apple Container GUI",
      description: DESCRIPTION,
      applicationCategory: "DeveloperApplication",
      applicationSubCategory: "Container management",
      operatingSystem: "macOS 26 or later, Apple silicon",
      softwareVersion: APP_VERSION,
      url: `${SITE_URL}/`,
      downloadUrl: RELEASES_URL,
      installUrl: RELEASES_URL,
      screenshot: `${SITE_URL}${SCREENSHOT.base}@2x.png`,
      image: `${SITE_URL}/og.png`,
      license: LICENSE_URL,
      isAccessibleForFree: true,
      offers: {
        "@type": "Offer",
        price: "0",
        priceCurrency: "USD",
      },
      author: {
        "@type": "Person",
        name: "Bram Gussekloo",
        url: "https://github.com/Bramgus12",
      },
      codeRepository: REPO_URL,
      softwareRequirements:
        "Apple Container CLI 0.12.0 or later and below 2.0.0",
    },
  ],
}

function Home() {
  return (
    <>
      <script
        type="application/ld+json"
        // The payload is built from local constants, never from user input.
        dangerouslySetInnerHTML={{
          __html: JSON.stringify(structuredData).replace(/</g, "\\u003c"),
        }}
      />
      <SiteHeader />
      <main className="overflow-hidden">
        <Hero />
        <Marquee />
        <Principles />
        <Destinations />
        <CommandReceipt />
        <Install />
      </main>
      <Footer />
    </>
  )
}
