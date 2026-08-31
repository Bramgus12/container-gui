import { useEffect, useRef, useState } from "react"

import { TYPED_COMMANDS } from "@/lib/site"

/**
 * The hero terminal, typing and deleting its way through real commands.
 *
 * The first command renders complete on the server and as the initial client
 * state, so the markup is never an empty box: hydration matches, crawlers see a
 * real command, and the animation simply takes over afterwards. Readers who ask
 * for reduced motion keep that first command and nothing moves.
 */
export function TypedCommand() {
  const [typed, setTyped] = useState<string>(TYPED_COMMANDS[0])
  const timer = useRef<ReturnType<typeof setTimeout> | undefined>(undefined)

  useEffect(() => {
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return

    let command = 0
    let count = TYPED_COMMANDS[0].length
    let deleting = true

    const tick = () => {
      const full = TYPED_COMMANDS[command]

      if (deleting) {
        count -= 2
        if (count <= 0) {
          count = 0
          deleting = false
          command = (command + 1) % TYPED_COMMANDS.length
          timer.current = setTimeout(tick, 340)
        } else {
          timer.current = setTimeout(tick, 18)
        }
      } else {
        count++
        if (count >= full.length) {
          deleting = true
          timer.current = setTimeout(tick, 1900)
        } else {
          timer.current = setTimeout(tick, 42 + Math.random() * 45)
        }
      }

      setTyped(TYPED_COMMANDS[command].slice(0, Math.max(0, count)))
    }

    timer.current = setTimeout(tick, 1900)
    return () => clearTimeout(timer.current)
  }, [])

  return (
    <div className="flex w-full items-center gap-3 rounded-lg border border-edge bg-surface px-4 py-3.5 sm:w-[440px] sm:px-[18px]">
      <span className="text-[13px] text-primary" aria-hidden="true">
        ❯
      </span>
      <span className="min-w-0 flex-1 truncate text-[13px]">{typed}</span>
      <span
        className="animate-blink inline-block h-4 w-2 shrink-0 bg-primary"
        aria-hidden="true"
      />
    </div>
  )
}
