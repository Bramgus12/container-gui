import { APP_VERSION, REPO_URL, WORDMARK } from "@/lib/site"

const NAV = [
  { label: "what", href: "#what" },
  { label: "surface", href: "#surface" },
  { label: "install", href: "#install" },
]

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-50 border-b border-border bg-background/70 backdrop-blur-[14px]">
      <div className="mx-auto flex h-[58px] max-w-[1180px] items-center gap-3.5 px-6 sm:px-8">
        <a href="/" className="flex items-center gap-3.5">
          <img
            src="/favicon.png"
            alt=""
            width={22}
            height={22}
            className="size-[22px] rounded-[5px]"
          />
          <span className="text-[13px] font-semibold tracking-[-0.01em]">
            {WORDMARK}
          </span>
        </a>
        {/* One interpolation rather than `v{APP_VERSION}`, which React would
            split into two text nodes separated by a comment marker. */}
        <span className="text-[11px] text-dimmer">{`v${APP_VERSION}`}</span>

        <div className="ml-auto flex items-center gap-5 text-xs text-dim sm:gap-[26px]">
          <nav aria-label="Main" className="hidden sm:block">
            <ul className="flex items-center gap-[26px]">
              {NAV.map((item) => (
                <li key={item.href}>
                  <a
                    className="transition-colors hover:text-foreground"
                    href={item.href}
                  >
                    {item.label}
                  </a>
                </li>
              ))}
            </ul>
          </nav>
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            className="rounded-[5px] border border-[#2a2e36] px-3 py-1.5 text-foreground transition-colors hover:border-dimmer"
          >
            GitHub ↗
          </a>
        </div>
      </div>
    </header>
  )
}
