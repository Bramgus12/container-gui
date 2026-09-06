import {
  APP_NAME,
  LICENSE_URL,
  REPO_URL,
  TROUBLESHOOTING_URL,
} from "@/lib/site"

const LINKS = [
  { label: "Source", href: REPO_URL },
  { label: "Troubleshooting", href: TROUBLESHOOTING_URL },
  { label: "GPL-3.0", href: LICENSE_URL },
]

export function Footer() {
  return (
    <footer className="mx-auto mt-28 max-w-[1160px] px-6 sm:mt-36 sm:px-8">
      <div className="flex flex-wrap items-center gap-x-6 gap-y-3 border-t border-rule py-8 text-[13px] text-mute">
        <span className="flex items-center gap-2.5">
          <img
            src="/favicon.png"
            alt=""
            width={20}
            height={20}
            loading="lazy"
            decoding="async"
            className="size-5 rounded-[5px]"
          />
          {APP_NAME}
        </span>
        <nav aria-label="Footer" className="flex flex-wrap gap-x-6 gap-y-3">
          {LINKS.map((link) => (
            <a
              key={link.href}
              href={link.href}
              target="_blank"
              rel="noreferrer"
              className="transition-colors hover:text-ink"
            >
              {link.label}
            </a>
          ))}
        </nav>
      </div>
    </footer>
  )
}
