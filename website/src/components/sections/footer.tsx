import { LICENSE_URL, TROUBLESHOOTING_URL, WORDMARK } from "@/lib/site"

export function Footer() {
  return (
    <footer className="mx-auto mt-[110px] max-w-[1180px] px-6 sm:px-8">
      <div className="flex flex-wrap items-center gap-4 border-t border-edge-faint pt-[34px] pb-14 text-[11px] text-dimmer">
        <img
          src="/favicon.png"
          alt=""
          width={18}
          height={18}
          loading="lazy"
          decoding="async"
          className="size-[18px] rounded-[4px] opacity-70"
        />
        <span>
          {WORDMARK} — an unofficial GUI for Apple's container runtime
        </span>
        <span className="flex items-center gap-4">
          <a
            className="transition-colors hover:text-foreground"
            href={LICENSE_URL}
            target="_blank"
            rel="noreferrer"
          >
            GPL-3.0
          </a>
          <a
            className="transition-colors hover:text-foreground"
            href={TROUBLESHOOTING_URL}
            target="_blank"
            rel="noreferrer"
          >
            Troubleshooting
          </a>
        </span>
        <span className="w-full sm:ml-auto sm:w-auto">
          Not affiliated with Apple Inc.
        </span>
      </div>
    </footer>
  )
}
