/**
 * The six sidebar glyphs, drawn here rather than pulled from an icon set.
 *
 * Each one names the thing the app's own sidebar names, in the same order, at
 * the same 16px optical size the app draws SF Symbols at. A general-purpose
 * icon package would ship a few hundred kilobytes to render six shapes.
 */
const COMMON = {
  viewBox: "0 0 16 16",
  fill: "none",
  stroke: "currentColor",
  strokeWidth: 1.4,
  strokeLinecap: "round",
  strokeLinejoin: "round",
  "aria-hidden": true,
} as const

export const SCREEN_ICONS: Record<string, React.ReactNode> = {
  // A corrugated container, front on — the same object as the app icon.
  Containers: (
    <svg {...COMMON}>
      <rect x="2.25" y="4.5" width="11.5" height="7" rx="1.2" />
      <path d="M5.5 4.5v7M8 4.5v7M10.5 4.5v7" />
    </svg>
  ),
  // A screen on a stand: the long-lived Linux VM.
  Machines: (
    <svg {...COMMON}>
      <rect x="1.75" y="3" width="12.5" height="8.25" rx="1.4" />
      <path d="M5.5 13.75h5" />
    </svg>
  ),
  // Stacked layers.
  Images: (
    <svg {...COMMON}>
      <path d="M8 2.25 14.25 5.5 8 8.75 1.75 5.5z" />
      <path d="M2.4 8.9 8 11.85l5.6-2.95" />
    </svg>
  ),
  // A disk.
  Volumes: (
    <svg {...COMMON}>
      <ellipse cx="8" cy="4.1" rx="5" ry="2.1" />
      <path d="M3 4.1v7.8c0 1.16 2.24 2.1 5 2.1s5-.94 5-2.1V4.1" />
    </svg>
  ),
  // Three attached nodes.
  Networks: (
    <svg {...COMMON}>
      <circle cx="8" cy="3.6" r="1.85" />
      <circle cx="3.4" cy="12.4" r="1.85" />
      <circle cx="12.6" cy="12.4" r="1.85" />
      <path d="M6.95 5.25 4.45 10.75M9.05 5.25l2.5 5.5M5.25 12.4h5.5" />
    </svg>
  ),
  // A pulse: service health, builder, disk.
  System: (
    <svg {...COMMON}>
      <path d="M1.5 8h3l2.1-4.6 3.2 9.2L11.7 8h2.8" />
    </svg>
  ),
}
