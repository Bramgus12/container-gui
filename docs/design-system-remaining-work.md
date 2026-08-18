# Design system — remaining work

> The design source (`design_system/`) is not tracked in this repository — it is a
> set of design-tool exports including multi-megabyte icon renders. Paths below
> refer to that local folder.

Companion to `docs/design-system-implementation-plan.md`. That document said what to
build; this one says what is built, what is not, and in what order to finish it.

Audited against the working tree on `main` (uncommitted). `xcodebuild -scheme "Container GUI"
build` succeeds with no warnings, and the full test suite passes, including the six new
`DesignSystemDataTests`.

## 1. Status of the original plan

| Phase | State | Notes |
| --- | --- | --- |
| 1 — Foundation (colour, type, Geist Mono, metrics, components) | **Done** | All 17 colorsets carry Any + Dark; the four unspecified dark values were adopted as proposed. All 12 components exist, plus a light/dark `DesignSystemCatalog` preview. |
| 2 — Data layer | **Done** | `startedAt` / `publishedPorts` / `mounts` / `networkNames`, `RelativeUptimeFormatter`, `ContainerStatsPoller`, `InventoryIndex`, the glance layer, `ContainerCommand.pruneImages(all:)`. |
| 3 — Sidebar + Containers (1a, 1b) | **Done** | Header, disk block, counts, five-column table, footer strip, failure banner with invocation + exit code. |
| 4 — Container detail as activity pane (1d) | **Done** | Tabs removed, Config sheet added, inspector widened to 420/560/820, stats poll on appear. |
| 4.2 — Log pane | **Done** | Severity classification, filter + text search, ALL/WARN/ERR counts, explicit per-line numbers through the ruler, per-line tinting. |
| 5 — Images (1f) | **Mostly done** | Header, Used-by/UNUSED, size bars, footer, in-row pull progress. "Select unused" is a stub. |
| 6 — Volumes (1i) + Networks (1j) | **Done** | |
| 7 — System (1e), onboarding (1k), sheets (1g, 1h) | **Partly done** | System and both sheets are converted; onboarding got type and colour but not its redesign. |

Geist Mono packaging is verified end to end: three weights plus the OFL license ship in
`Resources/Fonts`, `INFOPLIST_KEY_ATSApplicationFontsPath = Fonts` is set in both
configurations, `AppDelegate` registers as a fallback, and
`DesignSystemDataTests.testBundledGeistMonoCanBeRegistered` asserts the family resolves.

Localization is not a debt this work created: all 58 new catalog keys carry Dutch. The
462-key catalog has 240 keys without a Dutch translation, but 243 were already missing at
`HEAD`, so the backlog predates the redesign.

## 2. What is left

Four groups. A is the largest and the most visible; C contains the only items that are
defects rather than unfinished work.

### A. The app is half-migrated

The screens listed in the plan were converted. The shared chrome underneath them was not,
so an inspector opened from a redesigned table still renders in stock SwiftUI.

**A1 — the shared inspector layer.** `Shared/Inspection/InspectionViews.swift` is
untouched: `InspectionSection` wraps `GroupBox` with a `.headline` label
(`:20`), `InspectionValueRow` renders CLI values as plain body text (`:41`),
`InspectionTokenList` and `InspectionSensitiveValueRow` use `.callout.monospaced()`
against a `.quaternary` chip, and `InspectionBooleanRow` uses `.green` (`:56`) — a colour
the design system reserves for nothing at all. It has roughly 100 call sites across
`ImageInspectionView.swift`, `NetworksView.swift`, `ContainerConfigurationView.swift` and
`VolumesView.swift`, so converting the four types converts every inspector at once:
section → `DSCard` + `SectionLabel`, value → `MonoText`, token → `TagChip` geometry,
boolean → `DSState` colours. This is the single highest-yield item in the list.

**A2 — five ad-hoc banners.** `InlineBanner` was supposed to replace every
`.background(.bar)` HStack. Five remain: `Features/Images/ImageManagementViews.swift:246`
and `:270`, `Features/Volumes/VolumesView.swift:227` and `:236`,
`Features/System/SystemView.swift:61`. Networks has two more of the same shape without the
`.bar` background, at `Features/Networks/NetworksView.swift:206` and `:427`.

**A3 — four legacy mono call sites.** `.font(.system(.callout, design: .monospaced))`
survives at `Features/ContentView.swift:171` (setup standard-error disclosure),
`Features/Images/ImageBuildSheet.swift:271`, `Features/System/SystemView.swift:572`, and
`Features/Containers/RunContainerSheet.swift:181`. These are exactly the CLI-emitted text
the mono token exists for, and they will not pick up Geist Mono until they move.

**A4 — `GroupBox` outside the design system.** Still in `ImageInspectionView.swift`,
`Features/Updates/UpdateViews.swift`, and `InspectionViews.swift`. A1 covers the third.

**A5 — `ContentUnavailableView` used directly** in about twenty places rather than through
`EmptyState`. Mechanical, and worth doing so the empty states stay consistent when
`EmptyState` grows.

**A6 — onboarding (1k) is the least-finished screen.** It received the display font, the
canvas, and a card, but not its redesign: `symbolColor`
(`Features/ContentView.swift:320`) still returns `.green` / `.orange` / `.red` instead of
`DSState` colours; the mockup leads with the app icon rather than a 48pt SF Symbol; the
key/value rows are plain `LabeledContent` where the mockup shows mono values; the missing-CLI
state names one search path where the mockup names both (`/usr/local/bin/container` **and**
`/opt/homebrew/bin/container`); and the service-stopped state has no "will run
`container system start`" line. `detailCard` (`:267`) is a private reimplementation of
`DSCard`.

**A7 — log severity colours bypass the assets.** `applySeverityAttributes`
(`Shared/Logs/LogViewer.swift:507`) paints with `NSColor.systemOrange` and
`NSColor.systemRed` rather than `StateAttention` and `StateDestructive`, so the log pane
drifts from every other amber and red in the app.

### B. Screens that do not yet match their mockup

**B1 — "Select unused" is a stub.** `ImageManagementViews.swift:348` selects the *first*
unused image and nothing else, because `AppModel.selectedImageID` is a single `String?`.
*Decided:* the button becomes a **filter toggle** that narrows the table to unused images,
rather than a multi-selection. The table stays single-selection, the inspector binding and
the delete-plan flow are untouched, and bulk reclamation stays where it already works — the
Reclaim action on System. The footer keeps its count and byte total.

**B2 — the System disk card draws the wrong bar.** 1e shows a stacked bar with a legend
(images / containers / volumes); `SystemDiskUsageSection` draws a single `UsageBar` of the
used fraction. A correct stacked bar already exists as `SidebarDiskBar`
(`Features/ContentView.swift:488`), private to the sidebar. Promote it to
`Shared/DesignSystem/Components/` as `StackedUsageBar` and use it in both places.

**B3 — the sidebar disk block collapses three facts into one.** 1a lists images, volumes
and reclaimable as three labelled rows; `SidebarDiskBlock` (`:453`) shows a single
"Images / volumes" row carrying the reclaimable figure, which reads as the size of images
and volumes.

**B4 — the run sheet rail is decorative.** `RunSectionRail`
(`Features/Containers/RunContainerSheet.swift:290`) renders the seven section names and
their counts but is not selectable and does not scroll the form. 1h's claim is that the
sections "stay reachable without scrolling past them", which needs a `ScrollViewReader` and
selection state. Per-field validation, the other half of 1h, is already in place.

**B5 — `InlineBanner` has no action slot.** `ContainerListView.refreshErrorBanner`
(`Features/ContentView.swift:798`) works around this by dropping a "Try Again" button into
a trailing `.overlay`, where it sits on top of the banner's own text. Give `InlineBanner`
an optional trailing action and the workaround disappears — A2's Retry-style banners need
the same slot.

**B6 — search stays in the toolbar.** *Decided: no change.* All four screens keep
`.searchable(placement: .toolbar)` for ⌘F, the native clear button and correct focus
behaviour. The screen header therefore differs from 1a and 1f by one control; that is
accepted, not outstanding.

**B7 — the table spike was never resolved.** No `.tableStyle` is set anywhere, and the 28pt
row height comes from a `minHeight` on a single cell in the containers table only — images,
volumes and networks have no row-height control at all. *Decided:* `.tableStyle(.inset)`
with alternating row backgrounds **off** and a 1px `Hairline` separator between rows, in all
four tables, with 28pt enforced through row content rather than one cell. The original
spike's fallback branch can be closed: containers already runs in-row mutation progress
inside a `Table`, so `List` is not needed.

### C. Defects and costs

**C1 — `inventoryIndex` is rebuilt on every read.** `AppModel.inventoryIndex`
(`App/AppModel.swift:458`) is a computed property that re-derives the whole index — a
filter over all containers for every image and every volume. It is read inside `Table` cell
bodies (`ImageManagementViews.swift` for Used-by, `NetworksView.swift` for Attached), so it
runs per row per redraw, and it is passed by value into `VolumesView` and `NetworksView`
from `ContentView`'s body. Cache it in a stored property and recompute when containers,
images, volumes or networks change. Harmless at seven containers; quadratic by
construction.

**C2 — a runtime string is pushed through the string catalog.**
`ContainerDetailView.swift:313` builds `LocalizedStringResource(stringLiteral: message)`
from a CLI error. It renders, but it asks the catalog to look up an arbitrary error string
as a key. `EmptyState` needs a `String` description overload.

**C3 — two state vocabularies.** `ContainerState.displayName` and the new
`.localizedTitle` are both live: the redesigned surfaces use the latter
(`ContentView.swift:695`, `ContainerDetailView.swift:87`), while
`ImageManagementViews.swift:393`, `ContainerConfigurationView.swift:51` and
`ContainerDetailView.swift:338` still use the former. They can drift apart in translation.

**C4 — the glance layer is staler than the plan intends.** `refreshSidebarData()` runs on
activate and on a 30s timer, but not after a mutation or a per-screen refresh. Stop a
container and the sidebar counts, the UNUSED tags and the reclaimable figure keep the old
answer for up to 30 seconds.

**C5 — System shows its status twice.** `SystemStatusCards` (`SystemView.swift:114`) sits
*above* `SystemHealthSection` and `SystemBuilderSection`, so service state, version and
builder state each appear twice on one screen. *Decided:* the three cards **replace** both
sections, per 1e. Stop/Start Service moves onto the service card, Start Builder and
Delete… onto the builder card, and `status.message` becomes a row inside the service card.
`SystemHealthSection` and `SystemBuilderSection` are then deleted, not trimmed.

### D. Verification not yet done

- No visual pass in both appearances, and none at the 720×480 window minimum against the
  widened inspector (560 ideal) and the 760pt run sheet — risk 7 in the original plan.
- The new accessibility identifiers exist (`sidebar.disk`, `command.strip`, `logs.filter`,
  `system.reclaim`, `container.detail.config`, `images.build.advanced`) but only
  `logs.filter` and `container.detail.config` are asserted by a UI test.
- The 240 untranslated Dutch keys are pre-existing, but they are now the largest
  localization gap in the project and worth scheduling separately.

## 3. Decisions locked

| Question | Decision |
| --- | --- |
| Table rendering (B7) | **`.inset`, striping off, 1px hairline between rows**, applied to all four tables. `List` fallback dropped — in-row progress already works inside `Table`. |
| Images "Select unused" (B1) | **Filter toggle, not multi-selection.** Table stays single-select; bulk reclamation stays on System. |
| System layout (C5) | **The three status cards replace** `SystemHealthSection` and `SystemBuilderSection`; their actions move onto the cards. |
| Search placement (B6) | **Stays in the toolbar.** `.searchable` keeps ⌘F and native clear/focus behaviour; the one-control difference from 1a/1f is accepted. |

Two consequences worth stating:

- Turning striping off and drawing hairlines means each of the four tables needs its row
  background set explicitly rather than inherited, so B7 is a four-file change, not a
  one-line modifier. Do it in one PR so the tables cannot drift.
- Deleting `SystemHealthSection` and `SystemBuilderSection` removes the current homes of
  `system.stop`, `system.start` and the builder controls. Those accessibility identifiers
  must move onto the cards, or `OnboardingUITests` breaks.

## 4. Sequence

Nothing is blocked now. Ordered so the widest-reach, lowest-risk work lands first.

| PR | Contents | Depends on |
| --- | --- | --- |
| A | Inspector layer: convert `InspectionViews.swift`'s four types (A1). Every inspector in the app changes with it. | — |
| B | Mop-up: remaining banners → `InlineBanner` with a new trailing-action slot (A2, B5), four mono call sites (A3), `GroupBox` → `DSCard` (A4), `ContentUnavailableView` → `EmptyState` + `String` overload (A5, C2), log tint from assets (A7). | A |
| C | Correctness: cache `inventoryIndex` (C1), collapse the two state vocabularies (C3), refresh the glance layer after mutations (C4). | — (parallel with A, B) |
| D | Tables: `.inset`, striping off, hairline separators, 28pt rows, all four tables (B7). | — (parallel with A–C) |
| E | Disk visualisation: promote `SidebarDiskBar` to `StackedUsageBar`, use it in System with a legend (B2), split the sidebar block into three rows (B3). | — |
| F | System rebuilt on the three cards; health and builder sections deleted, identifiers moved (C5). | B, E |
| G | Onboarding (1k): app icon, DS state colours, mono key/value rows, both search paths, the "will run" command line (A6). Extend `OnboardingUITests` in the same PR. | B |
| H | Small screen fixes: "Select unused" as a filter toggle (B1), run-sheet rail made navigable (B4). | D |
| I | Verification: light/dark pass at 720×480 against the widened inspector and the 760pt run sheet, UI-test identifiers for the new controls (D1–D3). | all |

A, B, C, D and E can all start today; A–D are the bulk of the visible inconsistency. F and G
wait only on B. The Dutch translation backlog (D4) is independent of all of this and should
be scheduled on its own.
