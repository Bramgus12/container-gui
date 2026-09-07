import { GithubIcon } from "@/components/github-icon"
import {
  DECK,
  RELEASES_URL,
  REPO_URL,
  REQUIREMENTS,
  SCREENSHOT,
} from "@/lib/site"

export function Hero() {
  return (
    <section className="mx-auto max-w-[1160px] px-6 pt-14 sm:px-8 sm:pt-20 lg:pt-24">
      <div className="grid gap-x-16 gap-y-10 lg:grid-cols-[minmax(0,1fr)_240px]">
        <div>
          <h1
            data-enter
            className="t-display max-w-[15ch] text-[clamp(2.35rem,8.4vw,5.5rem)] text-pretty"
          >
            A window for Apple’s container runtime.
          </h1>

          <p
            data-enter
            style={{ "--enter": 1 } as React.CSSProperties}
            className="mt-8 max-w-[62ch] text-[17px] leading-[1.6] text-pretty text-slate"
          >
            {DECK}
          </p>

          <div
            data-enter
            style={{ "--enter": 2 } as React.CSSProperties}
            className="mt-9 flex flex-wrap items-center gap-x-8 gap-y-5"
          >
            <a
              href={RELEASES_URL}
              target="_blank"
              rel="noreferrer"
              className="t-sub rounded-control bg-azure px-5 py-3 text-[15px] text-white transition-colors hover:bg-[#0951c2]"
            >
              Download for Apple silicon
            </a>
            <a
              href={REPO_URL}
              target="_blank"
              rel="noreferrer"
              className="t-ui inline-flex items-center gap-2 py-3 text-[15px] text-slate underline decoration-transparent underline-offset-4 transition-colors hover:text-ink hover:decoration-current"
            >
              <GithubIcon className="size-4" />
              Read the source
            </a>
          </div>
        </div>

        {/*
          The facts a reader needs before clicking download, set as key and
          value the way the app's own inspector sets them. This is why there is
          no tracked-capitals eyebrow above the headline: the same information
          is here, as data.
        */}
        <dl
          data-enter
          style={{ "--enter": 3 } as React.CSSProperties}
          className="max-w-[26rem] self-end lg:max-w-none"
        >
          <div className="t-label mb-1 text-[12px] text-mute">Requires</div>
          {REQUIREMENTS.map((item) => (
            <div
              key={item.label}
              className="flex items-baseline justify-between gap-4 border-t border-rule py-2.5 last:border-b"
            >
              <dt className="t-ui text-[13px] text-mute">{item.label}</dt>
              <dd className="font-mono text-[12.5px] text-ink">{item.value}</dd>
            </div>
          ))}
        </dl>
      </div>

      {/*
        The product itself, and the darkest thing on the page — which is the
        whole visual argument: the app is the object, the site is the table it
        sits on. No glow behind it and no CSS frame: the capture carries macOS's
        own window shadow in its alpha channel, roughly 2.75% of the image width
        on each side, so the figure is widened by exactly that much to line the
        window's edges up with the text column above it.
      */}
      <figure
        data-enter
        style={{ "--enter": 4 } as React.CSSProperties}
        className="-mx-[2.75%] mt-14 -mb-[3%] w-[105.5%] sm:mt-16"
      >
        <picture>
          <source
            type="image/avif"
            srcSet={`${SCREENSHOT.base}.avif 1200w, ${SCREENSHOT.base}@2x.avif 2400w`}
            sizes="(min-width: 1160px) 1096px, 100vw"
          />
          <source
            type="image/webp"
            srcSet={`${SCREENSHOT.base}.webp 1200w, ${SCREENSHOT.base}@2x.webp 2400w`}
            sizes="(min-width: 1160px) 1096px, 100vw"
          />
          <img
            src={`${SCREENSHOT.base}.png`}
            srcSet={`${SCREENSHOT.base}.png 1200w, ${SCREENSHOT.base}@2x.png 2400w`}
            sizes="(min-width: 1160px) 1096px, 100vw"
            width={SCREENSHOT.width}
            height={SCREENSHOT.height}
            alt={SCREENSHOT.alt}
            fetchPriority="high"
            decoding="async"
            className="block h-auto w-full"
          />
        </picture>
      </figure>
    </section>
  )
}
