import { COMMAND_RECEIPT } from "@/lib/site"

const TONE = {
  cmd: "text-primary",
  flag: "text-amber",
} as const

export function CommandReceipt() {
  return (
    <section className="mx-auto max-w-[1180px] px-6 pt-[110px] sm:px-8">
      <div
        data-reveal
        className="grid items-center gap-12 rounded-[14px] border border-[#1e222a] bg-surface-raised p-8 sm:p-[52px] lg:grid-cols-2 lg:gap-14"
      >
        <div>
          <h2 className="mb-5 text-[26px] leading-[1.15] font-semibold tracking-[-0.02em] text-pretty sm:text-[30px]">
            You fill in a form. It shows you the command.
          </h2>
          <p className="text-sm leading-[1.8] text-pretty text-muted-foreground">
            Every sheet in the app ends with the invocation it is about to run.
            Nothing is generated behind your back, and everything you build in
            the UI is reproducible in a terminal.
          </p>
        </div>

        <div className="overflow-hidden rounded-[10px] border border-[#1e222a] bg-background">
          <div className="flex items-center gap-2 border-b border-border px-4 py-[11px] text-[11px] text-dimmer">
            <span
              className="size-2 rounded-full bg-primary"
              aria-hidden="true"
            />
            Run container — preview
          </div>
          <pre className="overflow-x-auto px-[18px] py-5 text-[12.5px] leading-[2] text-code">
            <code>
              {COMMAND_RECEIPT.map((line, lineIndex) => (
                <span key={lineIndex} className="block">
                  {lineIndex > 0 && lineIndex < COMMAND_RECEIPT.length && (
                    <span className="inline-block w-[22px]" />
                  )}
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
      </div>
    </section>
  )
}
