import { useRef, useState } from "react"

import { SCREEN_ICONS } from "@/components/screen-icons"
import { SCREENS } from "@/lib/site"

/**
 * The app's shape, as the app's own shape.
 *
 * Container GUI is a `NavigationSplitView`: a sidebar of six destinations and
 * a detail pane. Describing that in a bulleted list would throw away the one
 * thing worth showing, so this section is the split view — pick a destination
 * on the left and the pane on the right changes, the way it does in the app.
 *
 * Every pane is in the prerendered markup, so a crawler reads all six whether
 * or not it runs the script. Selection follows focus, which is the ARIA
 * pattern for tabs whose panels are cheap to render.
 */
export function Covers() {
  const [active, setActive] = useState(0)
  const tabs = useRef<Array<HTMLButtonElement | null>>([])

  function onKeyDown(event: React.KeyboardEvent) {
    const last = SCREENS.length - 1
    const next = {
      ArrowDown: active === last ? 0 : active + 1,
      ArrowRight: active === last ? 0 : active + 1,
      ArrowUp: active === 0 ? last : active - 1,
      ArrowLeft: active === 0 ? last : active - 1,
      Home: 0,
      End: last,
    }[event.key]

    if (next === undefined) return
    event.preventDefault()
    setActive(next)
    tabs.current[next]?.focus()
  }

  const screen = SCREENS[active]

  return (
    <section
      id="covers"
      className="mx-auto max-w-[1160px] scroll-mt-20 px-6 pt-28 sm:px-8 sm:pt-36"
    >
      <h2 className="t-heading max-w-[18ch] text-[clamp(1.9rem,4.6vw,2.9rem)] text-pretty">
        Six screens for the whole runtime.
      </h2>
      <p className="mt-5 max-w-[64ch] text-[16px] leading-[1.6] text-pretty text-slate">
        The app is organised the way the CLI is, so what you learn in one
        transfers to the other. Coverage is still partial — not every flag has a
        surface yet, and the gaps close release by release.
      </p>

      <div className="on-ink float mt-11 overflow-hidden rounded-window bg-ink">
        <div className="flex items-center gap-2 border-b border-rule-ink px-4 py-3">
          <span className="flex gap-1.5" aria-hidden="true">
            <span className="size-[9px] rounded-full bg-rule-ink" />
            <span className="size-[9px] rounded-full bg-rule-ink" />
            <span className="size-[9px] rounded-full bg-rule-ink" />
          </span>
          <span className="t-label ml-1.5 text-[12px] text-haze">
            Container GUI
          </span>
        </div>

        <div className="sm:grid sm:grid-cols-[200px_minmax(0,1fr)]">
          <div
            role="tablist"
            aria-label="Screens in Container GUI"
            aria-orientation="vertical"
            onKeyDown={onKeyDown}
            className="tab-strip flex gap-1 overflow-x-auto border-b border-rule-ink p-2.5 sm:flex-col sm:gap-0.5 sm:border-r sm:border-b-0"
          >
            {SCREENS.map((item, index) => {
              const selected = index === active
              return (
                <button
                  key={item.name}
                  ref={(node) => {
                    tabs.current[index] = node
                  }}
                  type="button"
                  role="tab"
                  id={`screen-tab-${index}`}
                  aria-selected={selected}
                  aria-controls={`screen-panel-${index}`}
                  tabIndex={selected ? 0 : -1}
                  onClick={() => setActive(index)}
                  className={`t-ui flex shrink-0 items-center gap-2.5 rounded-[6px] px-2.5 py-2 text-[13.5px] whitespace-nowrap transition-colors sm:w-full ${
                    selected
                      ? "bg-azure text-white"
                      : "text-haze hover:bg-ink-raised hover:text-chalk"
                  }`}
                >
                  <span className="size-4 shrink-0 opacity-80">
                    {SCREEN_ICONS[item.name]}
                  </span>
                  {item.name}
                  {item.count !== null && (
                    <span
                      className={`ml-auto hidden font-mono text-[11.5px] sm:block ${
                        // Quieter than the label, but still 4.9:1 and 5.5:1 —
                        // a count set below AA is a count nobody can read.
                        selected ? "text-white/90" : "text-haze/90"
                      }`}
                    >
                      {item.count}
                    </span>
                  )}
                </button>
              )
            })}
          </div>

          <div className="flex min-h-[330px] flex-col sm:min-h-[300px]">
            {SCREENS.map((item, index) => (
              <div
                key={item.name}
                role="tabpanel"
                id={`screen-panel-${index}`}
                aria-labelledby={`screen-tab-${index}`}
                hidden={index !== active}
                tabIndex={0}
                // Added and removed rather than keyed, so the pane animates in
                // without React tearing down and rebuilding all six.
                data-swap={index === active ? "" : undefined}
                className="flex-1 p-6 sm:p-8"
              >
                <h3 className="t-sub text-[22px] text-chalk">{item.name}</h3>
                <p className="mt-3.5 max-w-[56ch] text-[15px] leading-[1.65] text-pretty text-haze">
                  {item.body}
                </p>
                <ul className="mt-6 flex flex-wrap gap-1.5">
                  {item.commands.map((command) => (
                    <li
                      key={command}
                      className="rounded-[5px] border border-rule-ink bg-ink-raised px-2 py-1 font-mono text-[12px] text-chalk"
                    >
                      <span className="text-haze">container </span>
                      {command}
                    </li>
                  ))}
                </ul>
              </div>
            ))}

            {/*
              The app's status bar, which reports the command it just ran. It
              is the one thing worth repeating from the section below, and the
              reason the panel has a footer at all — so it gets the whole bar.
            */}
            <div className="border-t border-rule-ink px-6 py-2.5 font-mono text-[11.5px] text-cyan sm:px-8">
              {screen.status}
            </div>
          </div>
        </div>
      </div>
    </section>
  )
}
