import { HeadContent, Scripts, createRootRoute } from "@tanstack/react-router"

import appCss from "../styles.css?url"
import { APP_NAME, DESCRIPTION, HEADLINE, SITE_URL } from "@/lib/site"

const TITLE = `${APP_NAME} — A native macOS app for Apple Container`

export const Route = createRootRoute({
  head: () => ({
    meta: [
      { charSet: "utf-8" },
      { name: "viewport", content: "width=device-width, initial-scale=1" },
      { title: TITLE },
      { name: "description", content: DESCRIPTION },
      // The page is light only: the app is the dark object on it, and there
      // is no dark variant to fall back to. Browser chrome — scrollbars, form
      // controls, the mobile address bar — is told to match rather than
      // following the reader's system setting.
      { name: "color-scheme", content: "light" },
      { name: "theme-color", content: "#e9edf3" },
      { name: "apple-mobile-web-app-title", content: APP_NAME },

      { property: "og:type", content: "website" },
      { property: "og:site_name", content: APP_NAME },
      { property: "og:title", content: TITLE },
      { property: "og:description", content: DESCRIPTION },
      { property: "og:url", content: `${SITE_URL}/` },
      { property: "og:image", content: `${SITE_URL}/og.png` },
      { property: "og:image:width", content: "1200" },
      { property: "og:image:height", content: "630" },
      { property: "og:image:alt", content: `${APP_NAME} — ${HEADLINE}` },
      { property: "og:locale", content: "en_US" },

      { name: "twitter:card", content: "summary_large_image" },
      { name: "twitter:title", content: TITLE },
      { name: "twitter:description", content: DESCRIPTION },
      { name: "twitter:image", content: `${SITE_URL}/og.png` },
      { name: "twitter:image:alt", content: `${APP_NAME} — ${HEADLINE}` },
    ],
    links: [
      { rel: "stylesheet", href: appCss },
      { rel: "canonical", href: `${SITE_URL}/` },
      { rel: "icon", href: "/favicon.png", type: "image/png", sizes: "96x96" },
      {
        rel: "icon",
        href: "/icon-512.png",
        type: "image/png",
        sizes: "512x512",
      },
      {
        rel: "apple-touch-icon",
        href: "/apple-touch-icon.png",
        sizes: "180x180",
      },
      { rel: "manifest", href: "/manifest.json" },
    ],
  }),
  notFoundComponent: () => (
    <main className="mx-auto flex min-h-svh max-w-2xl flex-col justify-center gap-4 px-6">
      <h1 className="t-heading text-[2rem]">Page not found</h1>
      <p className="text-[16px] leading-[1.6] text-slate">
        That page does not exist.{" "}
        <a
          className="text-azure underline decoration-azure/35 underline-offset-4"
          href="/"
        >
          Go to the {APP_NAME} home page
        </a>
        .
      </p>
    </main>
  ),
  shellComponent: RootDocument,
})

function RootDocument({ children }: { children: React.ReactNode }) {
  return (
    <html lang="en">
      <head>
        <HeadContent />
      </head>
      <body>
        {children}
        <Scripts />
      </body>
    </html>
  )
}
