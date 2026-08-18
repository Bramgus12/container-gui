# Design system implementation plan

> The design source (`design_system/`) is not tracked in this repository — it is a
> set of design-tool exports including multi-megabyte icon renders. Paths below
> refer to that local folder.

Adopting `design_system/` (Design System v1 draft + Redesign 1a–1l) into the app.

Source of truth: `design_system/Design System.dc.html` for tokens and rules,
`design_system/Redesign.dc.html` for the nine redesigned screens,
`design_system/github.md` for the screen ↔ source mapping.

## 0. Decisions locked before planning

| Question | Decision |
| --- | --- |
| Container detail layout | **1d — single activity pane.** Stats row + live log on one surface; configuration moves behind a button. |
| Table state expression | **1a — dot + dimmed rail.** No chip column in tables; chips are reserved for headers and cards. |
| Mono typeface | **Bundle Geist Mono** (OFL-1.1), behind one token that falls back to SF Mono. |
| Containers Memory column | **Poll `container stats`** while the Containers screen is frontmost. |

Two consequences worth stating up front:

- Choosing 1d means the inspector must grow (today `min 360 / ideal 440 / max 620`,
  `Features/ContentView.swift:534`) and `ContainerDetailModel` must poll stats
  whenever the pane is visible, not only when the Stats tab is selected
  (`Features/Containers/ContainerDetailModel.swift:234`).
- The Memory column is cheap: `container stats --format json --no-stream` with no
  arguments already returns every running container, so it is one process per tick,
  not one per container. `ContainerCommand.stats(ids:)` (`CLI/ContainerCommand.swift:77`)
  already produces exactly that when handed an empty array.

## 1. Phase 1 — Foundation

New folder `container-gui/Shared/DesignSystem/`. The Xcode project uses
file-system synchronized groups (`objectVersion = 110`), so new files and folders
are picked up without editing `project.pbxproj`.

### 1.1 Color

Add colorsets to `container-gui/Assets.xcassets` with Any + Dark appearances so
they resolve without branching in code.

| Asset | Light | Dark |
| --- | --- | --- |
| `Canvas` | `#F4F5F7` | `#17191D` |
| `Surface` | `#FFFFFF` | `#1E2126` |
| `SurfaceRaised` | `#FAFAFC` | `#23262C` |
| `Hairline` | `#E3E5EA` | `#2E323A` |
| `TextPrimary` | `#1A1D23` | `#ECEEF2` |
| `TextSecondary` | `#5C6270` | `#A2A9B6` |
| `TextTertiary` | `#8A909E` | *unspecified — propose `#737A88`* |
| `Blue100…Blue700` | `#E7F0FF · #C9DDFF · #4A9BFF · #1C7BF5 · #0A5BEA · #0846B4` | same ramp |
| `StateRunning` | `#1C7BF5` | `#4A9BFF` |
| `StateAttention` | `#E39A33` | *unspecified — propose `#F0A94A`* |
| `StateIdle` | `#8A909E` | *unspecified — propose `#7A8290`* |
| `StateDestructive` | `#D6353B` | *unspecified — propose `#E85A5F`* |

`AccentColor.colorset` currently holds `#3276D3`; retune it to `#1C7BF5` / `#4A9BFF`.

The design system lists dark values only for the neutrals and the lifted accent.
The four proposals above need your sign-off before they harden.

### 1.2 Type

`Shared/DesignSystem/Typography.swift`:

- `.dsDisplay` — 28 / semibold / −2% tracking (onboarding titles)
- `.dsScreenTitle` — 21 / semibold
- `.dsCardHeading` — 15 / semibold
- `.dsBody` — 13 / regular (the macOS default; most text keeps it)
- `.dsSectionLabel` — 11 / semibold / +8% tracking, uppercased via `.textCase(.uppercase)`
  (never hardcoded caps — the catalog is localized)
- `.cliMono` — 12.5, `.cliMonoDim` — 12.5 secondary, `.cliMonoTabular` — 12 + `.monospacedDigit()`

Rule to enforce in review: anything the CLI emitted is mono (IDs, names, images,
digests, ports, addresses, sizes, commands); prose, labels and buttons never are.

### 1.3 Geist Mono

- Add `container-gui/Resources/Fonts/GeistMono-{Regular,Medium,SemiBold}.ttf` plus
  the OFL-1.1 license file (shipping the license is required by the license).
- Set `INFOPLIST_KEY_ATSApplicationFontsPath = Fonts` in both build configurations
  (`GENERATE_INFOPLIST_FILE = YES` is on, and Xcode passes `INFOPLIST_KEY_*` through).
- `Font.custom` silently falls back to the system font when a family is missing, which
  would hide a packaging mistake. Resolve through one helper that checks
  `NSFont(name:size:)` once and falls back to `.system(size:design:.monospaced)`, and
  assert the font loaded in a unit test.
- Fallback if the build setting misbehaves: register at launch with
  `CTFontManagerRegisterFontsForURL`.
- Use `Font.custom(_:size:relativeTo:)` so Dynamic Type still scales the mono text.

### 1.4 Metrics

`Shared/DesignSystem/Metrics.swift`: spacing 4 / 8 / 12 / 16 / 24, radii 5 (controls
and chips) / 8 (inline blocks) / 12 (cards and sheets), table row height 28,
gutter 12, 1px hairlines between rows only.

### 1.5 Components

`Shared/DesignSystem/Components/`. Each is small and previewable; they are what the
screen work in phases 3–7 assembles from.

| Component | Used by |
| --- | --- |
| `StateDot` (dot + optional label, a11y label always carries the word) | every table |
| `StateChip` (RUNNING / PAUSED / STOPPED / FAILED) | detail header, cards |
| `TagChip` (UNUSED / BUILT-IN / ANONYMOUS) | images, volumes, networks |
| `MonoText` (mono + selection + truncation mode) | everywhere CLI data appears |
| `CommandStrip` (fixed footer: mono command + Copy) | all four sheets, container detail |
| `MetricTile` (big number + unit + caption) | container detail, system |
| `UsageBar` (proportional bar) | images, volumes, system disk |
| `InlineBanner` (scope: row / card / bar; severity: error / attention / info; optional Copy + Dismiss) | replaces every ad-hoc `.background(.bar)` HStack |
| `DSCard` | replaces `GroupBox` in System and the inspectors |
| `SectionLabel` | all screens |
| `SidebarRow` (icon + title + count/dot) | sidebar |
| `EmptyState` (thin wrapper over `ContentUnavailableView`) | all screens |

`InlineBanner` alone replaces duplicated code in `Features/ContentView.swift:651`
and `:668`, `Features/Images/ImageManagementViews.swift:218` and `:234`,
`Features/Volumes/VolumesView.swift:161`, `Features/Networks/NetworksView.swift`,
and `Features/System/SystemView.swift:48`.

## 2. Phase 2 — Data the redesign needs

Nothing here is visible on its own; it unblocks phases 3–7.

**2.1 Widen `ContainerSummary`** (`Models/ContainerModels.swift:429`) with
`publishedPorts`, `startedAt`, `mounts`, `networkNames`. All four are already in the
`container ls` JSON — the fixtures confirm it
(`container-gui-tests/Fixtures/1.0.0/containers-1.0.0.json` carries `publishedPorts`
and `mounts`; `Fixtures/0.12.0/containers-0.12.0.json` carries `startedDate`) and the
DTOs already decode them. Zero extra CLI calls.

**2.2 Uptime formatting** — `2d 4h`, `6h 12m`, `stopped 4h`, `created`. New
`RelativeUptimeFormatter` in `Shared/`, driven by `startedAt` for running containers
and `createdAt` otherwise. Pure and unit-testable.

**2.3 Stats poller** — new `@MainActor @Observable ContainerStatsPoller` issuing
`.stats(ids: [])` every 5s, only while `destination == .containers` and the window is
active, paused during mutations, yielding `[containerID: ContainerStats]` and `—` on
failure. `CLIContainerDetailService.stats(containerID:)`
(`Features/Containers/ContainerDetailModel.swift:78`) decodes a single entry today and
needs a multi-entry sibling.

**2.4 Cross-reference index** — a pure `InventoryIndex` value computed from the
container list:

- image → dependent containers (the digest-matching logic in
  `AppModel.prepareImageDeletion` already exists; lift and reuse it)
- volume → attached containers (match container mount `source` to volume name)
- network → attached container count

This is what powers "Used by", "Attached to", and the UNUSED tags. It means the
containers list must be loaded before Images / Volumes / Networks can label anything.

**2.5 Glance layer for the sidebar** — `AppModel` gains inventory counts and owns
`SystemModel` from `activate(_:)` rather than lazily at first visit to System
(`App/AppModel.swift:914`), so service status, version, and `system df` are available
to the sidebar. Refresh on activate, on each screen refresh, and on a slow (30s) timer.

*Cost to accept:* this adds four list commands plus `system status` and `system df` to
startup. Run them concurrently in a task group after the containers list resolves, so
the first screen is not delayed.

## 3. Phase 3 — Sidebar + Containers (mockups 1a, 1b)

**Sidebar** (`Features/ContentView.swift:355`): app header with icon, name, and
`service up · 0.12.4` behind a state dot; destination rows with counts on the right and
an attention dot on System; a Disk footer block (stacked bar, images / volumes /
reclaimable, "Review housekeeping" → System).

**Containers screen**: in-content header (`Containers` + `3 of 7 running`), keeping
`.searchable` and the segmented filter. Columns become
Container (dot + mono name) | Image (mono) | Ports (mono) | Memory (bar + value) | Uptime.
A row mid-mutation replaces its state cell, keeps its geometry, and disables only its own
actions. Footer strip: `refreshed 12s ago · container ls --all` with ⌘R / ⌘N hints.
The failed-mutation banner gains the exact command and exit code plus a Copy button (1b).

**Spike first:** SwiftUI `Table` gives sorting, selection, and column resize for free but
constrains row height, in-row progress, and row-level tinting. Try `Table` with custom
cell views and `.tableStyle(.inset)`; if 28pt rows with an in-row pull/mutation progress
cell prove impossible, fall back to `List` for the containers table only. Decide this
before building the other three tables, because they inherit the answer.

## 4. Phase 4 — Container detail as an activity pane (mockup 1d)

**4.1 The pane.** New `ContainerActivityView`: header (StateChip + mono name + Stop +
Config), a metric row (Memory / CPU / Net rx-tx / Block r-w) in an adaptive grid — 4-up
at ≥560pt, 2×2 below — then the live log filling the remaining height, then a
`CommandStrip` showing `container logs -f <id>`. Widen the inspector to
`min 420 / ideal 560 / max 820` (`Features/ContentView.swift:534`) and check it against
the 720×480 window minimum (`Features/ContentView.swift:32`).

Overview content (image, platform, address, resources, ports, mounts) and the existing
`ContainerConfigurationView` move into a Config sheet, Overview first.
`ContainerDetailTab` and the tab picker go away; stats polling starts when the pane
appears instead of when a tab is selected.

**4.2 The log pane — the heaviest single item in this plan.**
`Shared/Logs/LogViewer.swift` is a hand-tuned `NSTextView` with incremental text-storage
updates, a line-number ruler, viewport anchoring, and tailing. Adding a filter field,
ALL / WARN / ERR counts, and per-line tinting touches all of it:

- `LogBuffer` classifies each line on append (error / warn / plain) and keeps counters.
- Filtering must happen at the snapshot level, and it breaks the ruler's assumption that
  line numbers are `firstLogicalLineNumber + offset`. `LogSnapshot` needs explicit
  per-line numbers, and `LogLineNumberRuler.drawHashMarksAndLabels`
  (`Shared/Logs/LogViewer.swift:694`) must read them.
- A filter change also breaks the `hasPrefix` fast paths in `LogTextStorageUpdater`
  (`Shared/Logs/LogViewer.swift:42`). Accept a full replace when the filter changes;
  keep the incremental append path when it does not.
- `applyTextAttributes` (`:499`) applies uniform attributes today and needs per-line
  severity attributes. The mockup's full-row error tint is not reachable with the
  `.backgroundColor` text attribute alone (it spans the glyphs, not the row). Start with
  the text-range background; if it reads badly, a colored left rail drawn in the ruler is
  the cheaper second option, and custom layout-fragment drawing the expensive third.

Budget this as its own PR with its own tests.

## 5. Phase 5 — Images (mockup 1f)

Columns: Reference (mono) | Digest (dim mono, middle truncation) | Platform |
Used by (count or UNUSED) | Size (bar + value). Header `Images 12 · 1.42 GB`;
footer `2 unused images · 52.7 MB` with "Select unused".

Pull progress moves into the row it belongs to: the sheet
(`Features/Images/ImageManagementViews.swift:410`) shrinks to reference entry and
dismisses on start, and `ImagePullModel` drives a placeholder row with
`unpacking layers 3/7 · 91.4 / 148 MB` and a Cancel button.

*Dependency:* that row needs parsed progress. `pullImage` uses `--progress plain`
(`CLI/ContainerCommand.swift:85`) and the model keeps the raw text today
(`ImagePullModel.progress`). Parsing needs to be written against real output and
degrade to an indeterminate bar plus the last line when a line does not match.

## 6. Phase 6 — Volumes (1i) and Networks (1j)

**Volumes** (`Features/Volumes/VolumesView.swift:11`): Name | Attached to (container or
UNUSED) | Size (UsageBar) | Format, with a footer banner
`2 volumes are attached to nothing — 138 MB can be reclaimed` and "Prune unused…".

**Networks** (`Features/Networks/NetworksView.swift:11`): Name (+ BUILT-IN tag) | Mode |
IPv4 subnet (mono) | Attached (count or UNUSED) | Plugin.

Both drop their "Created" column in favour of the attachment fact, per the mockups. Both
depend on 2.4.

## 7. Phase 7 — System, onboarding, sheets

**System (1e)** (`Features/System/SystemView.swift`): three status cards across the top
(service / builder / update), a Disk usage card with a stacked bar and a
`Reclaim 1.81 GB…` action, the resource table, and a recent-logs card.

*Reclaim* has no single CLI command. It composes `container image prune` (verified
present on 1.2.2, supports `--all`) with the existing volume prune. Add
`.pruneImages(all:)` to `ContainerCommand` and name the exact amounts in the confirm
dialog, per the rule that destructive actions name what they destroy.

**Gap — the build cache row.** `container system df --format json` on 1.2.2 returns only
`containers`, `images`, and `volumes`. There is no build-cache figure and no build-cache
prune subcommand (`container builder` offers only start / status / stop / delete). The
mockup's `Build cache 740 MB` row is unbacked. Recommend dropping it and letting
`SystemDiskUsage.decode` — which is already shape-tolerant
(`Models/SystemModels.swift:108`) — surface the row automatically if a future CLI adds it.

**Onboarding (1k)** (`Features/ContentView.swift:52`): icon-led layout, a key/value card
per state, one obvious action. `container-gui-ui-tests/OnboardingUITests.swift` asserts on
literal titles ("Install Apple Container", "Start Service", "Copy Diagnostics") and
identifiers — keep both, or update the tests deliberately in the same PR.

**Build sheet (1g)** (`Features/Images/ImageBuildSheet.swift`): two columns, essentials
first, advanced folded into a disclosure with an "N set" badge, the builder-stopped
notice, and a fixed `CommandStrip` footer replacing the buried "Command Preview" section
at `:18`.

**Run sheet (1h)** (`Features/Containers/RunContainerSheet.swift`): a section rail
(Container / Resources / Networks / Storage / Ports / Environment / Command) with
per-section counts, content on the right, fixed `CommandStrip` + Cancel / Run, and
validation reasons inline next to the offending field. The same footer treatment applies
to the volume (`Features/Volumes/VolumesView.swift:311`) and network
(`Features/Networks/NetworksView.swift:397`) create sheets.

## 8. Risks and open questions

1. **Dark variants for amber, red and grey are unspecified.** Four proposals in §1.1 need
   your call.
2. **`Table` may not stretch to the redesigned rows.** Spike in phase 3 before three more
   tables inherit the decision.
3. **The log pane is delicate.** Filtering breaks both the ruler's numbering and the
   incremental update fast path. Isolate it in its own PR.
4. **Colour-blind readers.** Dot + dimmed rail encodes state as hue plus dimming. Keep the
   state word in the row and in every accessibility label — the design system flags this
   about its own choice.
5. **Localization.** `Localizable.xcstrings` holds 407 strings in en + nl. Every new or
   reworded string needs a Dutch translation; uppercase labels and chips must be uppercased
   with `.textCase(.uppercase)`, never as literal caps in the catalog.
6. **Startup cost.** The glance layer adds five CLI processes at launch (§2.5).
7. **Widths.** The run sheet already asks 760pt and the inspector grows to 560 ideal;
   re-check the 720×480 window minimum.
8. **Geist Mono packaging.** Verify `INFOPLIST_KEY_ATSApplicationFontsPath` lands in the
   generated Info.plist and that the synchronized group adds the `.ttf` files to the
   resources build phase; ship the OFL license.

## 9. Testing

Unit (`container-gui-tests/`): uptime formatting; port summarization; the `InventoryIndex`
cross-references; log severity classification and filtering; multi-entry stats decode;
sidebar disk aggregation; a font-loading assertion for Geist Mono. Extend the JSON
fixtures rather than adding new ones where the shapes already exist.

UI (`container-gui-ui-tests/`): keep every existing accessibility identifier; add
identifiers for new controls (sidebar disk block, command strips, log filter, reclaim);
extend `OnboardingUITests` for the redesigned setup states.

Add `#Preview`s for each design-system component in both appearances — that is the
cheapest regression net for a visual change of this size.

## 10. Suggested sequence

| PR | Contents | Depends on |
| --- | --- | --- |
| 1 | Colors, type, metrics, Geist Mono packaging | — |
| 2 | Component library + previews | 1 |
| 3 | Data layer: summary fields, uptime, stats poller, inventory index, glance layer | — (parallel with 1–2) |
| 4 | Table spike + sidebar + Containers screen | 2, 3 |
| 5 | Log pane: severity, filtering, ruler numbering | 1 |
| 6 | Container detail as activity pane + Config sheet | 4, 5 |
| 7 | Images, including in-row pull progress | 4 |
| 8 | Volumes + Networks | 4 |
| 9 | System (incl. reclaim) + onboarding + the four sheets | 2, 3 |

PRs 1–3 are independent and can run in parallel. PR 4 is the gate: its table decision
constrains 7 and 8.
