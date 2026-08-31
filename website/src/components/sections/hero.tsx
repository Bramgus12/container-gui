import { Button } from "@/components/ui/button"
import { Spotlight } from "@/components/spotlight"
import { TypedCommand } from "@/components/typed-command"
import { SCREENSHOT } from "@/lib/site"

export function Hero() {
  return (
    <section className="relative mx-auto max-w-[1180px] px-6 pt-16 sm:px-8 sm:pt-24">
      <Spotlight />

      <p className="mb-7 flex items-center gap-2.5 text-[11px] tracking-[0.14em] text-amber uppercase">
        <span
          className="animate-pulse-dot size-[7px] shrink-0 rounded-full bg-amber"
          aria-hidden="true"
        />
        macOS 26 · Apple container runtime
      </p>

      {/* The size clamps below `sm` because "apple/container" cannot wrap:
          at a fixed 38px the unbreakable token is wider than a 320px screen
          and would be silently clipped by the section's overflow. */}
      <h1 className="max-w-[22ch] text-[clamp(30px,9vw,38px)] leading-[0.98] font-semibold tracking-[-0.035em] text-pretty sm:text-[56px] lg:text-[76px]">
        Every{" "}
        {/* Browsers treat "/" as a break opportunity, and splitting the
            project's name across two lines reads as a typo. */}
        <span className="whitespace-nowrap">apple/container</span> command, none
        of the typing.
      </h1>

      <p className="mt-[30px] max-w-[56ch] text-[15px] leading-[1.75] text-pretty text-muted-foreground">
        Apple ships <span className="text-foreground">container</span> as a CLI.
        This is the window around it — a native macOS app that runs the same
        binary, shows you the flags it built, and prints the command before it
        fires.
      </p>

      <div className="mt-[38px] flex flex-wrap items-center gap-3.5">
        <TypedCommand />
        <Button
          asChild
          className="h-auto rounded-lg px-6 py-[15px] text-[13px] font-semibold hover:bg-[#3e92ff]"
        >
          <a href="#install">Download for Apple silicon</a>
        </Button>
      </div>

      <figure data-reveal className="relative mt-16">
        <div
          aria-hidden="true"
          className="absolute -inset-px rounded-[14px] opacity-60 blur-[26px]"
          style={{
            background:
              "linear-gradient(180deg, rgba(28,123,245,.5), rgba(28,123,245,0) 55%)",
          }}
        />
        <div className="animate-float relative">
          <picture>
            <source
              type="image/avif"
              srcSet={`${SCREENSHOT.base}.avif 1200w, ${SCREENSHOT.base}@2x.avif 2400w`}
              sizes="(min-width: 1180px) 1116px, 100vw"
            />
            <source
              type="image/webp"
              srcSet={`${SCREENSHOT.base}.webp 1200w, ${SCREENSHOT.base}@2x.webp 2400w`}
              sizes="(min-width: 1180px) 1116px, 100vw"
            />
            <img
              src={`${SCREENSHOT.base}.png`}
              srcSet={`${SCREENSHOT.base}.png 1200w, ${SCREENSHOT.base}@2x.png 2400w`}
              sizes="(min-width: 1180px) 1116px, 100vw"
              width={SCREENSHOT.width}
              height={SCREENSHOT.height}
              alt={SCREENSHOT.alt}
              fetchPriority="high"
              decoding="async"
              className="block h-auto w-full rounded-xl border border-[#23272f] shadow-[0_40px_120px_rgba(0,0,0,.75)]"
            />
          </picture>
        </div>
      </figure>
    </section>
  )
}
