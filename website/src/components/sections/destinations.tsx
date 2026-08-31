import { DESTINATIONS } from "@/lib/site"

export function Destinations() {
  return (
    <section
      id="surface"
      className="mx-auto max-w-[1180px] scroll-mt-[58px] px-6 pt-[110px] sm:px-8"
    >
      <div data-reveal className="flex flex-wrap items-baseline gap-4">
        <h2 className="text-[28px] font-semibold tracking-[-0.02em] sm:text-[34px]">
          Six destinations
        </h2>
        <span className="text-xs text-dimmer">one per noun in the CLI</span>
      </div>

      <p
        data-reveal
        className="mt-5 mb-11 max-w-[64ch] text-[13px] leading-[1.8] text-pretty text-dim"
      >
        <span className="text-amber">Coverage is still partial.</span> Not every
        flag and subcommand has a surface yet — full parity with the CLI is the
        goal, and the gaps are being closed release by release.
      </p>

      <ul data-reveal className="border-t border-border">
        {DESTINATIONS.map((destination) => (
          <li
            key={destination.index}
            className="grid grid-cols-[32px_1fr] items-baseline gap-x-5 gap-y-2 border-b border-border px-3 py-6 transition-colors hover:bg-surface-hover md:grid-cols-[40px_220px_1fr_130px] md:items-center md:gap-6 md:py-[26px]"
          >
            <span className="text-[11px] text-dimmest" aria-hidden="true">
              {destination.index}
            </span>
            <h3 className="text-[19px] font-semibold tracking-[-0.01em]">
              {destination.name}
            </h3>
            <p className="col-start-2 text-[13px] leading-[1.7] text-dim md:col-start-auto">
              {destination.body}
            </p>
            <span className="col-start-2 text-[11px] text-dimmer md:col-start-auto md:text-right">
              {destination.commands}
            </span>
          </li>
        ))}
      </ul>
    </section>
  )
}
