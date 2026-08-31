import { MARQUEE_COMMANDS } from "@/lib/site"

/**
 * The band of CLI commands sliding under the hero. The list is rendered twice
 * because the animation translates by exactly -50%: the second copy is what the
 * first one slides away to reveal, so the loop has no seam. It is decoration,
 * hence `aria-hidden` — every command it names is spelled out in the
 * destinations table below.
 */
export function Marquee() {
  return (
    <div
      aria-hidden="true"
      className="mt-20 overflow-hidden border-y border-edge-faint py-5 whitespace-nowrap"
    >
      <div className="animate-marquee inline-flex gap-11 pr-11 text-xs text-dimmest">
        {[...MARQUEE_COMMANDS, ...MARQUEE_COMMANDS].map((command, index) => (
          <span key={`${command}-${index}`}>{command}</span>
        ))}
      </div>
    </div>
  )
}
