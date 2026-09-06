import { GithubIcon } from "@/components/github-icon"
import { APP_NAME, APP_VERSION, RELEASES_URL, REPO_URL } from "@/lib/site"

const NAV = [
  { label: "What it covers", href: "#covers" },
  { label: "How it works", href: "#command" },
]

export function SiteHeader() {
  return (
    <header className="sticky top-0 z-50 border-b border-rule bg-paper/85 backdrop-blur-xl">
      <div className="mx-auto flex h-16 max-w-[1160px] items-center gap-3 px-6 sm:px-8">
        <a href="/" className="flex shrink-0 items-center gap-2.5">
          <img
            src="/favicon.png"
            alt=""
            width={26}
            height={26}
            className="size-[26px] rounded-[6px]"
          />
          <span className="t-sub text-[15px] whitespace-nowrap">
            {APP_NAME}
          </span>
        </a>
        {/* One interpolation rather than `v{APP_VERSION}`, which React would
            split into two text nodes separated by a comment marker. */}
        {/* The version is a detail, not a headline: it goes as soon as the
            header has to fight for room. */}
        <span className="hidden rounded-[5px] bg-ink/6 px-1.5 py-0.5 font-mono text-[11px] text-mute min-[420px]:block">
          {APP_VERSION}
        </span>

        <nav aria-label="Main" className="ml-auto hidden md:block">
          <ul className="t-ui flex items-center gap-7 text-[14px] text-slate">
            {NAV.map((item) => (
              <li key={item.href}>
                <a
                  className="transition-colors hover:text-ink"
                  href={item.href}
                >
                  {item.label}
                </a>
              </li>
            ))}
          </ul>
        </nav>

        <div className="ml-auto flex items-center gap-2 md:ml-7">
          <a
            href={REPO_URL}
            target="_blank"
            rel="noreferrer"
            aria-label={`${APP_NAME} on GitHub`}
            className="grid size-9 place-items-center rounded-control text-slate transition-colors hover:bg-ink/6 hover:text-ink"
          >
            <GithubIcon className="size-[17px]" />
          </a>
          <a
            href={RELEASES_URL}
            target="_blank"
            rel="noreferrer"
            className="t-ui rounded-control bg-azure px-3.5 py-2 text-[14px] text-white transition-colors hover:bg-[#0951c2]"
          >
            Download
          </a>
        </div>
      </div>
    </header>
  )
}
