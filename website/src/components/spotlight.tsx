import { useEffect, useRef } from "react"

/**
 * The blue glow that follows the pointer across the hero.
 *
 * Purely decorative, so it stays hidden until a real mouse moves: touch devices
 * never see it, and neither does anyone who has asked for reduced motion.
 * Positions are written straight to CSS custom properties to keep the work off
 * React's render path.
 */
export function Spotlight() {
  const ref = useRef<HTMLDivElement>(null)

  useEffect(() => {
    const el = ref.current
    if (!el) return
    if (window.matchMedia("(prefers-reduced-motion: reduce)").matches) return
    if (!window.matchMedia("(hover: hover) and (pointer: fine)").matches) return

    const parent = el.parentElement
    if (!parent) return

    const onMove = (event: MouseEvent) => {
      const rect = parent.getBoundingClientRect()
      el.style.setProperty("--x", `${event.clientX - rect.left}px`)
      el.style.setProperty("--y", `${event.clientY - rect.top}px`)
      el.style.opacity = "1"
    }

    window.addEventListener("mousemove", onMove, { passive: true })
    return () => window.removeEventListener("mousemove", onMove)
  }, [])

  return (
    <div
      ref={ref}
      aria-hidden="true"
      className="pointer-events-none absolute top-[var(--y,0)] left-[var(--x,0)] size-[520px] -translate-x-1/2 -translate-y-1/2 rounded-full opacity-0 transition-opacity duration-500"
      style={{
        background:
          "radial-gradient(circle, rgba(28,123,245,.16), transparent 68%)",
      }}
    />
  )
}
