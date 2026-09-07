import { useEffect, useRef, useState } from "react"

import { RUN_COMMAND, RUN_COMMAND_TEXT, RUN_SHEET } from "@/lib/site"

const TONE = {
  cmd: "text-cyan",
  flag: "text-azure-lit",
} as const

/**
 * The sheet and the command it produces, side by side.
 *
 * Every field on the left is traceable in the command on the right — that
 * pairing is the argument, and it only works if the two stay in step. Both
 * come from `site.ts`.
 */
export function Command() {
  return (
    <section
      id="command"
      className="mx-auto max-w-[1160px] scroll-mt-20 px-6 pt-28 sm:px-8 sm:pt-36"
    >
      <h2 className="t-heading max-w-[18ch] text-[clamp(1.9rem,4.6vw,2.9rem)] text-pretty">
        The command is always on screen.
      </h2>
      <p className="mt-5 max-w-[64ch] text-[16px] leading-[1.6] text-pretty text-slate">
        Fill in the sheet and the app shows the exact invocation before it runs.
        It launches the executable directly, never through a shell, so what you
        read is what happens. Copy it into a script, or just read it and learn
        the flag.
      </p>

      <div className="mt-11 grid gap-6 lg:grid-cols-2 lg:gap-8">
        <RunSheet />
        <CommandBlock />
      </div>
    </section>
  )
}

/** A macOS sheet: right-aligned labels, left-aligned controls. */
function RunSheet() {
  return (
    <div className="overflow-hidden rounded-window border border-rule bg-paper-raised">
      <div className="border-b border-rule px-5 py-3">
        <span className="t-sub text-[14px]">Run container</span>
      </div>
      {/* A macOS sheet does not stretch its fields to the window: the value
          column is capped so a short name does not sit in a 500px box. */}
      <dl className="grid grid-cols-[minmax(0,6.5rem)_minmax(0,20rem)] items-center justify-center gap-x-4 gap-y-2.5 p-5">
        {RUN_SHEET.map((field) => (
          <div key={field.label} className="contents">
            <dt className="t-ui text-right text-[13px] text-mute">
              {field.label}
            </dt>
            <dd>
              {field.kind === "switch" ? (
                <Switch on={field.value === "On"} label={field.value} />
              ) : (
                <span className="block truncate rounded-[6px] border border-rule bg-white px-2.5 py-1.5 font-mono text-[12.5px] text-ink">
                  {field.value}
                </span>
              )}
            </dd>
          </div>
        ))}
      </dl>
    </div>
  )
}

/** The app's own switch, drawn rather than screenshotted. */
function Switch({ on, label }: { on: boolean; label: string }) {
  return (
    <span className="flex items-center gap-2.5">
      <span
        aria-hidden="true"
        className={`flex h-[17px] w-[29px] items-center rounded-full p-0.5 ${
          on ? "justify-end bg-azure" : "justify-start bg-rule"
        }`}
      >
        <span className="size-[13px] rounded-full bg-white shadow-sm" />
      </span>
      <span className="sr-only">{label}</span>
    </span>
  )
}

function CommandBlock() {
  const [copied, setCopied] = useState(false)
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  useEffect(() => () => clearTimeout(timer.current), [])

  async function copy() {
    try {
      await navigator.clipboard.writeText(RUN_COMMAND_TEXT)
      setCopied(true)
      clearTimeout(timer.current)
      timer.current = setTimeout(() => setCopied(false), 2000)
    } catch {
      // Clipboard access can be refused; the command stays selectable.
      setCopied(false)
    }
  }

  return (
    <div className="on-ink overflow-hidden rounded-window bg-ink">
      <div className="flex items-center justify-between gap-4 border-b border-rule-ink px-5 py-2.5">
        <span className="t-label text-[12px] text-haze">This is what runs</span>
        <button
          type="button"
          onClick={copy}
          className="t-ui rounded-[5px] px-2 py-1 text-[12.5px] text-haze transition-colors hover:bg-ink-raised hover:text-chalk"
        >
          {copied ? "Copied" : "Copy"}
        </button>
      </div>
      <pre className="overflow-x-auto px-5 py-5 text-[12.5px] leading-[1.95] text-chalk">
        <code>
          {RUN_COMMAND.map((line, lineIndex) => (
            <span key={lineIndex} className="block">
              {lineIndex > 0 && "  "}
              {line.map((token, tokenIndex) => (
                <span
                  key={tokenIndex}
                  className={token.tone ? TONE[token.tone] : undefined}
                >
                  {token.text}
                </span>
              ))}
            </span>
          ))}
        </code>
      </pre>
    </div>
  )
}
