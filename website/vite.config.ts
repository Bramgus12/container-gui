import { defineConfig } from "vite"
import { tanstackStart } from "@tanstack/react-start/plugin/vite"
import viteReact from "@vitejs/plugin-react"
import tailwindcss from "@tailwindcss/vite"

const config = defineConfig({
  resolve: { tsconfigPaths: true },
  plugins: [
    tailwindcss(),
    tanstackStart({
      // The whole point of this site is to be found. Prerendering emits real
      // HTML with the copy already in it, so crawlers and link unfurlers never
      // have to run JavaScript to read the page.
      prerender: {
        enabled: true,
        crawlLinks: true,
        autoSubfolderIndex: true,
        failOnError: true,
      },
    }),
    viteReact(),
  ],
})

export default config
