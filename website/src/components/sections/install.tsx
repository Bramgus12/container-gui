import { GithubIcon } from "@/components/github-icon"
import {
  APPLE_CONTAINER_URL,
  APP_NAME,
  RELEASES_URL,
  TROUBLESHOOTING_URL,
} from "@/lib/site"

export function Install() {
  return (
    <section
      id="install"
      className="mx-auto max-w-[1160px] scroll-mt-20 px-6 pt-28 sm:px-8 sm:pt-36"
    >
      <div className="grid gap-10 border-t border-rule pt-12 lg:grid-cols-[minmax(0,1fr)_260px] lg:gap-16">
        <div>
          <h2 className="t-heading text-[clamp(1.9rem,4.6vw,2.9rem)]">
            Install it.
          </h2>
          <p className="mt-5 max-w-[58ch] text-[16px] leading-[1.6] text-pretty text-slate">
            Download the signed disk image from the releases page. {APP_NAME}{" "}
            does not install a runtime for you — Apple's{" "}
            <a
              href={APPLE_CONTAINER_URL}
              target="_blank"
              rel="noreferrer"
              className="font-mono text-[15px] text-azure underline decoration-azure/35 underline-offset-4 transition-colors hover:decoration-azure"
            >
              container
            </a>{" "}
            CLI has to be on the machine first.
          </p>

          <div className="mt-9 flex flex-wrap items-center gap-x-8 gap-y-5">
            <a
              href={RELEASES_URL}
              target="_blank"
              rel="noreferrer"
              className="t-sub inline-flex items-center gap-2.5 rounded-control bg-azure px-5 py-3 text-[15px] text-white transition-colors hover:bg-[#0951c2]"
            >
              <GithubIcon className="size-[17px]" />
              Download for Apple silicon
            </a>
            <a
              href={TROUBLESHOOTING_URL}
              target="_blank"
              rel="noreferrer"
              className="t-ui py-3 text-[15px] text-slate underline decoration-transparent underline-offset-4 transition-colors hover:text-ink hover:decoration-current"
            >
              Something not working?
            </a>
          </div>
        </div>

        <p className="self-end text-[13px] leading-[1.65] text-pretty text-mute lg:text-right">
          Free and open source under GPL-3.0. Unofficial, and not affiliated
          with Apple Inc.
        </p>
      </div>
    </section>
  )
}
