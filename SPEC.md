# Tiler — spec (single source of truth for builders and critics)

Personal Moom-style window manager for ninja. Native Swift menu-bar app. Trigger: palette on
hover over a window's green traffic-light button. Palette content is user-arranged from a
preset library in a Moom-style spatial editor.

Project root on ninja's Mac: `/Users/Guest123/Documents/tiler`; public repo:
https://github.com/ninjabaloney06-sketch/Tiler (without `docs/` and `tools/`, which stay local).
App name `Tiler`. Open work: `TASKS.md` / GitHub issues; how to work: `AGENTS.md`.
Research with sources: `docs/research.md`. Moom reference images: `docs/reference/`
(`default.png` = palette, `half_top.jpg` + `half_bottom.jpg` + `blanks.png` = palette editor,
`full_panel.jpg` = settings window). Moom help text: `docs/reference/moom-help/*.txt`.
Working probes (proven on this Mac): `tools/probes/*.swift`.

## 0. Hard constraints and traps (read first)

- **Do not install anything** (no Homebrew, no packages). Xcode 26.6 / Swift 6.3.3 / MacOSX26.5.sdk.
- `Package.swift`: `// swift-tools-version: 6.2`, `platforms: [.macOS(.v14)]`. No `.v26`/`.v27`
  (fails with this toolchain). App target: `swiftSettings: [.swiftLanguageMode(.v6),
  .defaultIsolation(MainActor.self)]`. Bare `swiftc` defaults to minos 28.0 — pass
  `-target arm64-apple-macos14.0` if you ever use it.
- **Parallel builders:** always build with your own scratch path, e.g.
  `swift build --scratch-path .build-<component>`; never share `.build`.
- **Never move, resize, minimize or close ninja's windows.** Tests use only windows of our own
  test helper (`TilerTestWindows`). Arrange presets act on ALL visible windows on a screen, so
  every test/debug run of an arrange action must pass the pid filter
  (`TILER_ONLY_PIDS=<pid>[,<pid>]` env var, honoured by the window enumerator). Cursor
  movement via HID-posted events is allowed; restore the cursor position afterwards.
- **Live UI tests run only on ninja's Mac (cloud sessions cannot run them)** — only under the live-UI lock, only on
  TilerTestWindows windows with TILER_ONLY_PIDS, cursor restored afterwards, runs kept short. The
  orchestrator keeps the display awake with `caffeinate` during this window. If ninja says stop,
  all live testing stops immediately.
- **Live-UI lock.** Only one agent may run a live UI test (test windows, cursor moves, launching
  Tiler, harness) at a time: `until mkdir /Users/Guest123/Documents/tiler/.live-test.lock
  2>/dev/null; do sleep 5; done` before, `rmdir` it after (also on failure; a lock older than
  15 min is stale and may be removed). Keep live runs short — ninja uses this Mac.
- **Shared repo.** Several agents work concurrently: commit only your own paths explicitly
  (`git commit -m "..." -- <paths>`), retry if `.git/index.lock` exists, never `git add -A`,
  never revert or reformat other components' files. If the full package fails to build because
  of another component's in-progress change, wait a few minutes and retry.
- **No system settings changes.** Never `defaults write` to other domains (no
  `NSZoomButtonShowMenu`, no `com.apple.WindowManager`). Never `tccutil reset` (with or without
  a bundle id). Never register login items or LaunchAgents during tests (the launch-at-login
  toggle may exist, but must not be switched on by an agent).
- Accessibility: binaries launched from this agent shell inherit trust from the Claude app
  (`AXIsProcessTrusted()` = true). A Finder-launched `.app` does NOT; ninja grants it once.
  For live tests run the executable directly (`.build-x/release/Tiler`), not via `open`.
- Swift 6 pitfalls (all verified): `static let x = AXUIElementCreateSystemWide()` is a compile
  error → `nonisolated(unsafe)` or create per use. `kAXTrustedCheckOptionPrompt` is an error →
  use literal `"AXTrustedCheckOptionPrompt"`. `v as? AXUIElement` on CFTypeRef is an error →
  check `CFGetTypeID(v) == AXUIElementGetTypeID()` then `as!`. Region-isolation errors only show
  in a full build, not `-typecheck`. `String(format:)` with many mixed args can hang the type
  checker >60 s → bind args to typed locals.
- Coordinates: AX/CG = top-left global, y down, origin = top-left of the PRIMARY screen.
  NSScreen/NSEvent = bottom-left. Flip with `NSScreen.screens[0].frame.maxY`, never
  `NSScreen.main`. Rect: `y' = H - r.maxY`. This Mac: 1470×956 pt, scale 2,
  visibleFrame (0,66,1470,856). Stage Manager is ON (`com.apple.WindowManager GloballyEnabled=1`).

## 1. Presets

Two kinds. Every preset has a stable `id`, `name`, `kind`, and icon geometry derived from its
rects (icons are drawn procedurally — never hand-drawn per preset).

**Move & resize (single window = the hovered window).** Rect in unit space (0…1, origin
top-left of the usable area):
Fill, Left half, Right half, Top half, Bottom half, Center (keeps size, centers on usable area),
Top-left / Top-right / Bottom-left / Bottom-right quarter, Left / Middle / Right third,
Left two-thirds, Right two-thirds.

**Arrange (all visible windows on the hovered window's screen).** A list of slots (unit rects):
- Grids, named cols×rows: `2x1` (Left & Right), `1x2` (Top & Bottom), `2x2` (Quarters), `3x2`,
  `3x3`, `4x3`, `4x4`.
- Split layouts, left column = 50 % width:
  - `1+3`: left = 1 full-height slot; right = 3 stacked rows.
  - `2+3`: left = 2 stacked rows; right = 3 stacked rows.
  - `1+4 (grid)`: left = 1; right = 2×2 grid. `1+4 (rows)`: left = 1; right = 4 stacked rows.
  - `2+4 (grid)`: left = 2 stacked; right = 2×2 grid. `2+4 (rows)`: left = 2 stacked; right = 4 stacked rows.

**Arrange algorithm** (ninja's words: "checks the windows placement, sees which one is closest
to which ideal position, and resizes and moves the items to the right spot"):
1. Candidate windows = visible standard windows on the target screen, current Space: role
   AXWindow, subrole AXStandardWindow, not minimized, not a sheet, not AXSystemDialog, not
   full screen, app not hidden, not our own process; CG list filtered to alpha > 0.01 and
   layer 0; drop owners Dock, WindowManager, Notification Center. Honour `TILER_ONLY_PIDS`.
2. Order front-to-back (CGWindowList z-order); the hovered window is always first.
3. If windows > slots: keep the first `slots` windows (most recently used); the rest are left
   untouched.
4. The target window (hovered) takes the PRIMARY slot — slot index 0 in the preset's slot
   order (the left full-height slot of the splits, the top-left cell of grids) — whatever its
   position or size (macOS green-menu parity: the target always lands in the main position;
   ninja, 1 Oct 2026 — pure min-cost sent a hovered mid-size window to a small right slot). The
   remaining kept windows are assigned to the remaining slots with an optimal assignment
   (Hungarian / min-cost matching) minimizing Σ cost, cost = distance between window center and
   slot center + 0.5 × (|Δwidth| + |Δheight|), all in points. No target (hovered window nil or
   out of range) → all kept windows are assigned by the same min-cost matching over all slots.
   If windows < slots, extra slots stay empty.
5. Move each window to its slot frame through the frame engine (§3).

**Width variants (ninja, 22 Sep 2026).** EVERY preset above (move & resize, center and arrange)
exists twice in the library: the full-width preset (default; fills the whole `visibleFrame`
like the native macOS menu) and a "· Stage Manager" variant that leaves the Stage Manager
inset free on the left. Ids: `<id>` and `<id>-sm`; names: `<Name>` and `<Name> · Stage Manager`.
Both can sit in the palette side by side. There is NO global "leave room for Stage Manager"
toggle any more; only the inset width (default 72 pt) is a setting. The variant's icon shows a
small Stage Manager strip mark at the left edge (three short stacked bars, like thumbnails),
with the layout drawn in the remaining width.

In a `-sm` variant the ONLY free space is the inset strip on the left; the layout is the same
as full width, just scaled horizontally into `width − inset` — windows still touch each other
and the top/right/bottom screen edges.

**Stage Manager and tiling (measured, 2 Oct 2026).** macOS's own tiling does NOT reserve the
strip zone — native Fill (Window menu → Move & Resize → Fill) with Stage Manager on fills the
full `visibleFrame` (measured on a TextEdit window: 0,34,1470×849 on 2 Oct 2026); the strip
draws above tiled windows. Tiler matches: presets apply their literal geometry; the `-sm`
variants exist for explicit choice when ninja wants the strip area kept free. (Superseded: the
1 Oct 2026 auto-swap idea — applying the variant matching the live Stage Manager state — is
removed; it contradicted the measured native behavior.)

**No gaps between windows (ninja, 22 Sep 2026).** Window edges touch: gap is fixed at 0 and
there is no gap control in the UI (the core may keep its gap parameter, always 0).

**Geometry.** Usable area = target screen `visibleFrame`, minus the Stage Manager inset on the
left for `-sm` presets. Unit rect → points: compute each boundary independently,
`edge(i) = round((min + i·len/n) · scale) / scale` so tiles meet exactly (no Rectangle-style
floor slack). **Window frames are rounded to whole points** (measured by C2: macOS truncates
half-point window frames, which left 1 pt gaps); icons stay on the device-pixel grid. Gap `g` (default 0): outer edges inset by `g` only if "apply to screen edges" is
on; interior shared edges inset by `g/2` on each side.

**Settings (with defaults):** hover delay 0.15 s (range 0–1 s); palette size 1.0 (0.8–2.0, §10.1);
Stage Manager inset 72 pt (editable; used only by `-sm` presets); default hover mode = Tiler
palette (⌘ held at hover = macOS menu), with an option to invert; launch at login off.
(Superseded: gap settings and the global Stage Manager toggle are removed.)

## 2. Palette editor model (Moom-style spatial wells)

- 11 columns × 6 rows of wells. Each preset occupies at most one well.
- **Revert is a well item (ninja, 3 Oct 2026)**, reserved id `"revert"`: placed, moved and
  removed like a preset (at most one well), one tile in size; there is no fixed Revert element
  any more. Default placement and migration: config files without `"paletteRevision": 2` (saved
  before this change) get Revert once in the well left of the palette's top-left well (else the
  first empty well); every save writes revision 2, so a Revert the user drags out stays removed.
- Default placement (rows/cols 0-based): row 2, col 2 = Revert; row 2, cols 3–7 = Fill, Left
  half, Right half, Top half, Bottom half. Row 3, cols 3–7 = `3x2`, `3x3`, `4x3`, `4x4`, `1+3`.
  All other presets start in the library only.
- The live palette = bounding box of occupied wells; empty wells inside the box render as blank
  space (see `docs/reference/blanks.png`).
- Persistence: `~/Library/Application Support/Tiler/config.json` (settings + well placements),
  written atomically, versioned (`"version": 1`), unknown/missing preset ids ignored. Loading a
  missing or corrupt file falls back to defaults and never crashes.

## 3. Window engine (Accessibility)

One `@MainActor` class does all AX IPC. Messaging timeout 0.1 s on every element touched
(hit-test on system-wide element 0.05–0.1 s). Set frame = glide → size → position → size, with
`AXEnhancedUserInterface` switched off on the app element before and restored after (not
restored for Chromium-family bundle ids, per Rectangle's "automatic" policy). Read the frame
back; if it differs by > 1 pt (min-size / fixed-aspect windows), re-align inside the target
(anchor edges the slot shares with the usable area, else center) and nudge back on screen.
Skip non-settable sizes for resize (move only; those windows do not glide — their final
position is only known after the size is read). Never AX-touch our own windows.

**Glide (ninja, 2 Oct 2026: windows should move like macOS's native animations).** Before the
exact set, a resizable window glides from its current frame to the target: ~0.2 s, ease-in-out
(smoothstep), 10 interpolation steps at whole-point frames, one AX size + position set per
step; a failed or slow step is skipped, never aborts the move (added wall time bounded
≤ 0.35 s). The exact final set and the readback/re-align always follow, so landed frames are
exact. Skipped while the env `TILER_NO_ANIMATE` is set (same pattern as `TILER_ONLY_PIDS`,
read per move): tiler-harness sets it for its in-process engine; tiler-palettetest and
tiler-hovertest pass it to the spawned Tiler.

**Revert:** remember each moved window's previous frame (keyed by CGWindowID via
`@_silgen_name("_AXUIElementGetWindow")`, fallback pid+frame); a Revert well (§2) is enabled
when the target window (or the last arrange) has history, dimmed and inert otherwise; clicking
it restores the previous frames.

## 4. Triggers and palette (the core UX)

**Trigger decision (roast verdict, 23 Sep 2026):** the palette is opened from the **menu-bar
icon** (default) and a **global hotkey** (default). Green-button hover is an **opt-in, off by
default** (Settings: "Also show palette when hovering the green button (beta)").

**4.A Menu-bar trigger.** Left-click on the status item → capture the target FIRST (frontmost
app's focused window via AX, before anything can change focus), then show the palette as a
dropdown directly under the status item (menu-like, aligned to the icon, clamped on screen).
Right-click or ⌃-click on the status item → the classic menu (§5). The palette's footer has a
"Tiler Settings…" row (like the native menu's "Full Screen" row) that opens Settings.
Menu-like persistence (ninja, 3 Oct 2026): the palette and the status item's pill stay up until
the user dismisses them (click outside, Esc, icon again, apply, target closed). Another app
becoming active dismisses only when the user caused it (a key press or click within 1 s before
the activation, e.g. ⌘-Tab); a background app activating itself does not.

**4.B Hotkey trigger.** Global hotkey via Carbon `RegisterEventHotKey` (no permission needed),
default ⌃⌥T, recordable in Settings (validate, show conflicts as an error, allow clearing).
Capture the target first, then show the palette centered on the target window (or on the
screen under the mouse when there is no target). The panel may become key WITHOUT activating
Tiler (nonactivating panel that can become key) so the keyboard works: ←→↑↓ move the selection
across wells (skipping blanks), Return applies, 1–9 apply the n-th preset in reading order
(row-major), Esc closes. Pressing the hotkey again closes it. The frontmost app must stay
frontmost (verify: `NSWorkspace.frontmostApplication` unchanged).

**Target & header (all triggers).** The palette shows a header line with the target, e.g.
"Obsidian — Notes.md" (app name — window title, truncated middle), like the native menu's
section headers. No usable target (no window, sheet/dialog focused, full-screen window, Finder
desktop) → header "No window", single-window presets disabled (dimmed, like the native menu's
dimmed icons), arrange presets still work on the screen of the trigger (status item's screen /
mouse screen). Arrange acts on the target window's screen when there is a target.

**4.C Green-button hover (opt-in, off by default).** Built last. When enabled, the hovered
window is the target and the palette appears under the button. Proven pipeline (see
`docs/research.md` CRITIC section and `tools/probes/poster.swift`):
1. `NSEvent.addGlobalMonitorForEvents(.mouseMoved)` (no permission needed for mouse), throttle
   30–50 ms, skip when the cursor is inside any of our own windows.
2. `AXUIElementCopyElementAtPosition(systemWide, x, y)` (AX coords). Accept role AXButton with
   subrole **AXFullScreenButton OR AXZoomButton** (on macOS 27 fullscreen-capable windows report
   AXFullScreenButton). Window = the button's `kAXWindowAttribute` (NOT kAXParent — that's an
   AXGroup). Skip if the window's `AXFullScreen` is true.
3. If ⌘ is held at detection → do nothing (native macOS menu shows on its own ~0.9 s schedule).
   Inverted when the setting "show macOS menu by default" is on.
4. Otherwise immediately order front a **hat**: borderless nonactivating NSPanel over the button
   rect inflated by 3 pt, `isOpaque = false`, background black at the smallest alpha that still
   captures hover (default 1/255; verified by `tiler-hovertest --hat-alpha-sweep`) (NEVER 0.0 — fully
   transparent is hover-through and the native menu appears), no shadow, level `.popUpMenu`,
   collectionBehavior `[.canJoinAllSpaces, .fullScreenAuxiliary, .transient, .ignoresCycle]`.
   This suppresses Apple's green-button menu without any defaults write (verified). The native
   menu's hover timeout is ~0.6 s + ~0.25 s XPC, so the hat must be up well before that.
5. After the hover delay, fade the palette in (~100 ms). Palette panel (all triggers): borderless,
   nonactivating, `orderFrontRegardless()`, level `.popUpMenu`, same collection behavior; app
   activation policy `.accessory`; key only for the hotkey trigger (4.B).
6. The hat's `mouseDown` forwards `AXPress` to the green button (keeps click-to-full-screen).
7. Own windows don't receive global-monitor events → hat and palette use `NSTrackingArea`
   (`.activeAlways, .mouseEnteredAndExited, .mouseMoved`). Dismiss after ~250 ms outside the
   hot region (button rect + hat + palette + corridor between), on Esc, on any mouseDown
   elsewhere, or when the target window moves/closes. Fade out ~100 ms in place.
8. Hover over icons: icon highlights in `controlAccentColor` on a lighter tile; tooltip with the
   preset name. Click applies the preset to the hovered window / its screen, then the palette
   fades out. Background (non-frontmost) windows work too (hit-test based); the affected window
   is raised.

**Visual spec — Apple's current style (ninja, 22 Sep 2026; supersedes the Moom look).**
Reference: `docs/reference/apple-native-menu.png` (ninja's screenshot of the native macOS
green-button menu, dark mode). If screen capture works from the agent shell, capture the live
native menu yourself at 2× in light AND dark mode (open it on an OWN test window with the
proven `AXShowMenu` probe in `tools/probes/ctl.swift`, then `screencapture -l <windowid>` of the
`ThemeWidgetControlViewService` window) and save them as
`docs/reference/apple-native-menu-{light,dark}@2x.png`; match those.
- **Icons** (palette, library, editor wells, preview — one shared renderer): drawn like Apple's
  Move & Resize / Fill & Arrange icons: a rounded-rect "screen" outline in the label color
  (thin stroke, 1.8 pt measured = 2 pt snapped to the pixel grid at size 1.0, generous corner
  radius), the target region(s) as filled rounded rects inset from the outline, arrange slots separated by a thin gap; monochrome
  (label color / secondary label color), template-like so they adapt to light/dark and
  highlight states. Proportions follow the reference icon (≈ 25×20 pt at size 1.0, §10.1; measure it).
  Keep the C1 guarantees: whole-pixel sizes, mirror symmetry, equal slots exactly equal.
- **Palette panel:** native menu material — `NSGlassEffectView` (Liquid Glass) when
  `#available(macOS 26, *)`, else `NSVisualEffectView` material `.menu`, state `.active`;
  menu-like corner radius and shadow, no callout triangle. Spacing between icons and padding
  like the native menu's rows. Hover: the icon under the cursor gets the native menu's
  selection treatment (accent-colored rounded highlight with the icon drawn in white), plus a
  tooltip with the preset name.
- Placement: per trigger (4.A under the status item, 4.B centered on the target, 4.C directly
  below the green button like the native menu, with the hat covering the button); always
  clamp/flip to stay fully inside the screen's visibleFrame.
- Dismissal (all triggers): click outside, Esc, after applying a preset (fade out ~100 ms),
  target window closed; for 4.C also leaving the hot region (step 7).
- Everything scales with the palette size setting.

## 5. App shell, menu bar, editor window

- LSUIElement menu-bar app. Status item: left-click = palette (§4.A); right-click / ⌃-click =
  menu: "Settings…", Accessibility status line
  ("Accessibility: granted" / "Accessibility: missing — click to open Settings", which calls
  `AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true])` and opens
  `x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility`),
  "Pause Tiler" toggle, "Quit".
- Settings window (SwiftUI in NSHostingController, single window, sidebar like
  `full_panel.jpg`): left = **Library** list of all presets (icon + name) grouped
  "Move & Resize" / "Arrange", plus "Other" › Revert (§2, variant-independent); right =
  **Palette** pane with the 11×6 wells (look:
  `half_top.jpg`), and below it: Delay slider (with value label), Size slider, "Stage Manager
  inset" (pt, for `-sm` presets), "Palette hotkey" recorder (default ⌃⌥T), "Also show palette
  when hovering the green button (beta)" (off by default) with, indented and only enabled when
  on, "Show macOS menu by default (⌘ for Tiler)" and the hover Delay, "Launch at login", and a
  live preview of the resulting palette (same glass look as the real palette).
  The library shows each preset's two width variants (e.g. a "Full width / Stage Manager"
  segmented switch above the list, or both listed); icons in Apple's style (§4).
- Drag and drop: library → empty well (add; if the preset is already in another well it moves);
  well → well (move; dropping on an occupied well swaps); well → outside the wells / onto the
  library (remove); right-click a well → Remove. Changes save immediately and the live palette
  uses them on the next hover (no restart).
- Debug/verification flags on the executable (no UI): `--render-palette <out.png> [--dark]
  [--size <s>]`, `--render-editor <out.png> [--dark]` render headless PNGs of the palette /
  settings window at 2× so critics can inspect visuals without screen-recording permission.

## 6. Build, sign, install

- `scripts/build.sh [--dev]`: `swift build -c release`, assemble `Tiler.app`
  (Contents/MacOS/Tiler, Info.plist: CFBundleIdentifier `dev.ninja.tiler` (`dev.ninja.tiler.dev`
  with --dev), CFBundleExecutable Tiler, CFBundlePackageType APPL, LSUIElement true,
  LSMinimumSystemVersion 14.0, NSHighResolutionCapable true, version strings), then sign:
  if `security find-identity -p codesigning` lists `ninja-codesign`, `codesign --force --sign
  "ninja-codesign" --identifier <bundle id>`; else ad-hoc `--sign -` and print a warning that
  the Accessibility grant will not survive rebuilds. No `--deep`.
- `scripts/install.sh`: build, `ditto` to `~/Applications/Tiler.app`, quit a running copy
  (`pkill -f Tiler.app/Contents/MacOS/Tiler`), `open` the installed copy. Grant Accessibility to
  this installed copy only.
- `README.md`: what it is, install, grant Accessibility, how to edit the palette, the ⌘ rule,
  the self-signed cert note. Short.

## 7. Package layout (interfaces between components)

```
Package.swift
Sources/TilerCore/        C1 — pure logic, no AppKit windows, no AX: Preset, PresetLibrary,
                          PaletteLayout (wells), Settings, ConfigStore (JSON), Geometry
                          (unit→points, gaps, insets, pixel rounding), Assignment (Hungarian),
                          IconGeometry (rects for drawing an icon of a preset).
Sources/TilerAX/          C2 — library: AXWindowEngine (@MainActor), WindowEnumerator,
                          FrameSetter, RevertHistory, ScreenGeometry (NSScreen ↔ AX conversion);
                          re-exported into the app by Sources/Tiler/Windows/TilerAX.swift.
Sources/Tiler/Palette/    C3 — PalettePanel, PaletteView, PaletteController, TargetResolver,
                          HotkeyTrigger, PaletteToolTip, PaletteSnapshot (uses the shared icon
                          renderer and glass container from Sources/Tiler/App; the status item
                          itself is StatusMenu in Sources/Tiler/App).
Sources/Tiler/Hover/      C5 — HoverMonitor, HatPanel (opt-in green-button trigger).
Sources/tiler-palettetest/ C3 — live test: menu-bar click + hotkey + keyboard on test windows.
Sources/tiler-hovertest/  C5 — live test of the hover trigger + native-menu suppression.
Sources/Tiler/App/        C4 — main.swift, AppDelegate, StatusMenu, SettingsWindow, EditorView,
                          render flags.
Sources/TilerTestWindows/ C2 — test helper app: `TilerTestWindows <n>` opens n titled resizable
                          standard windows ("TW1"…"TWn"), prints its pid, stays alive.
Sources/tiler-harness/    C2 — CLI: spawns/uses TilerTestWindows, applies every preset with
                          TILER_ONLY_PIDS=<its pid>, reads frames back, asserts ≤1 pt per edge.
Sources/TilerTestSupport/ shared scaffolding of the live tests (report, HID, AX/CG, lock, cleanup).
Tests/TilerCoreTests/     C1 — swift-testing or XCTest.
scripts/ build.sh install.sh
```
C1 owns `Package.swift` initially and creates all target directories with compiling stubs so
later components only fill their own directories. Interface contracts:
- `PaletteController.shared.start(config: ConfigStore)` / `.stop()` — called by AppDelegate.
- `ConfigStore` publishes changes (e.g. `NotificationCenter` name `.tilerConfigDidChange` or an
  `@Observable` model) so the palette and editor stay in sync.
- `AXWindowEngine.apply(preset:, hoveredWindow:, screen:)` executes any preset.

## 8. Quality bar (what critics judge against)

- `swift build -c release` and `swift test` succeed from a clean scratch path, Swift 6 mode,
  zero errors, zero warnings in our code.
- Geometry: every preset on a 1470×856 usable area (and on a second synthetic 2560×1415 area)
  tiles exactly: slot union = usable area, no overlaps, edges on the pixel grid; gap math
  correct. Assignment is optimal (compare to brute force for n ≤ 7).
- Window engine: `tiler-harness` moves TilerTestWindows windows through every preset; every
  resizable window lands within 1 pt per edge; closest-slot assignment observed; revert
  restores ≤ 1 pt; ninja's windows untouched (verify frames of other apps before/after). Moves
  glide (~0.2 s ease-in-out, exact final frame + readback, §3); the harness runs with
  `TILER_NO_ANIMATE` set, so landed frames stay exact and timing-free.
- Triggers: clicking the status item (HID click at its frame) with a TilerTestWindows window
  frontmost shows the palette under the icon within 150 ms with header "TilerTestWindows — TW1";
  clicking a preset moves that window; the frontmost app never changes. Hotkey ⌃⌥T (HID-posted)
  opens it centered on the target; arrows/Return/1–9/Esc work; the frontmost app never changes.
  No target → single-window presets dimmed and inert, arrange still works.
- Hover (opt-in, only when enabled in the test config): with a TilerTestWindows window frontmost and the cursor HID-moved onto its green
  button, the palette appears within delay + 150 ms, the native menu (CGWindowList owner
  `ThemeWidgetControlViewService`, layer 101) never appears within 4 s; ⌘ held → native menu
  appears and no palette; clicking a preset moves the window; leaving dismisses within ~400 ms;
  clicking the green button itself still toggles full screen/zoom.
- Visual: rendered palette and icons are a close match to Apple's native green-button menu
  (`docs/reference/apple-native-menu*.png`) in icon proportions, stroke weight, corner radii,
  fill insets, material and hover highlight (side-by-side A/B), in light and dark, at sizes
  0.8 / 1.0 / 2.0. Editor keeps Moom's 11×6 well layout (`half_top.jpg`) but with the Apple icons.
- Width variants: every preset has a full-width and a `-sm` variant; full-width frames span the
  entire visibleFrame; `-sm` frames start exactly at visibleFrame.minX + inset. Windows touch
  (no gaps).
- Editor: all drag-drop operations work and persist across relaunch; corrupt config → defaults.
- Idle cost: CPU ≈ 0 % (`ps -o %cpu` over 10 s < 1 %) with hover off AND with hover on.

## 9. Out of scope (v1)

Per-preset hotkeys, URL scheme (`tiler://apply/<id>`, candidate for v1.1), interactive grid picker, ⌥ alternate layer, drag-to-display arrows,
folders/chains, snap-to-edge, multiple-display special cases beyond "use the hovered
window's screen", Moom import. (Superseded: the simple apply-time glide moved INTO scope
2 Oct 2026 — §3.)

## 10. Additions (ninja, 24 Sep 2026)

**10.1 Native-size palette.** At palette size 1.0 the palette must be the SAME size as Apple's
native green-button menu (ninja: ours was "like 2x too large"). Measure
`docs/reference/apple-native-menu-light@2x.png` / `-dark@2x.png` (2× captures): icon size
(≈25×20 pt), icon-to-icon spacing, outer padding, section header font size/weight/colour and
its spacing, separator, footer row height and font, corner radius, overall width for a row of 4
icons. Size 1.0 = those metrics exactly (±1 pt); all other sizes scale from there. Slider range
becomes 0.8–2.0 (default 1.0); old configs with a size below 0.8 clamp to 0.8. Applies to every
trigger (hover, menu bar, hotkey) and to the Settings preview (which hosts the real PaletteView).
IconGeometry keeps all its guarantees (whole pixels, symmetry, exact equal slots) at the new size.

**10.2 App icon.** Tiler gets an app icon (Finder, Launchpad, Dock when ninja keeps it there,
Settings/About). macOS 26 style: the standard macOS app icon grid (rounded-square body 824 px on
a 1024 px canvas with the system-like drop shadow), a calm gradient, and a glyph that reads as
"window tiling" in the visual language of the palette icons (a rounded screen outline with tiled
rounded regions, e.g. a 1+3 or 2×2 layout), legible down to 16 px. Generated procedurally and
reproducibly by a script in the repo (Swift/CoreGraphics, no installs) into
`Resources/AppIcon.icns` via `iconutil` (all sizes 16–1024 @1x/@2x); `scripts/build.sh` copies it
into `Contents/Resources/` and sets `CFBundleIconFile`. Commit the generator and the .icns.

