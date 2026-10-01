# Open tasks

Status 28 Sep 2026: all components (C1–C5, native-size palette, app icon) passed their
independent critics with live tests on ninja's Mac; last live results: tiler-harness 194/194,
tiler-palettetest 68/68, tiler-hovertest 45/45, `swift test` 86/86, zero warnings.
Status 1 Oct 2026: T6 Mac verification of merged `main` — build 0 warnings, `swift test` 86/86,
tiler-harness 194/194, tiler-palettetest 82/83 (open: check 72, classic-menu Esc — new issue),
tiler-hovertest 45/45; installed to `~/Applications/Tiler.app` (ninja-codesign, LSUIElement).
T1's pill had to be redrawn as an explicit overlay (81c80aa): `NSStatusBarButton.highlight`
renders nothing on macOS 26.
What remains is below. Rules for working on these: `AGENTS.md`. Each task is also a GitHub
issue with the same number.

Status labels: **ready-for-code** (a cloud session can do it now), **needs-mac** (ninja on the
Mac), **needs-ninja** (a decision), **merged-untested** (merged to `main` 28 Sep, not yet
built or live-tested on the Mac — covered by T6).

---

## T1 — Keep the menu-bar icon highlighted while its palette is open · merged-untested

**Done 1 Oct 2026 (T6 round):** verified live; one correction — `NSStatusBarButton.highlight`
renders nothing on macOS 26 (Liquid Glass), so the pill is now an explicit translucent overlay
subview on the status-item button (`StatusItemPillView`, commit 81c80aa). palettetest pill
checks measure 37.2 vs the system's 38.1; all pill-gone checks 0.0.

**Why:** SPEC §4.A says the menu-bar palette is a menu-like dropdown. Every native status menu
(including Tiler's own right-click menu) shows the icon's highlight pill while open; Tiler's
palette does not, so it doesn't read as an open menu (last open critic gap, component C3).

**Start from:** `wip/status-item-highlight.patch` — an unfinished, uncompiled attempt by a
previous builder (+108 lines in `Sources/Tiler/App/StatusMenu.swift`,
`Sources/Tiler/Palette/PaletteController.swift`, `Sources/tiler-palettetest/main.swift`).
`git apply wip/status-item-highlight.patch`, then review and finish it; delete the patch file
in the same PR.

**Do:**
- For `.statusItem` sessions call `button.highlight(true)` after the button's own mouse
  tracking has ended (setting it on mouse-down is reset by the cell's tracking — do it on the
  `.leftMouseUp` action or dispatch it after), and `highlight(false)` on EVERY dismissal path in
  `PaletteController.dismiss` (Esc via `EscConsumingTap`, click outside, apply, second icon
  click, target closed, switch to the classic menu, Pause).
- tiler-palettetest: add a check that pixel-samples the status item rect (CGWindowListCreateImage
  or `screencapture -R`) while the palette is open (pill present) and after each dismissal path
  (pill gone).

**Files:** the three above only. **DoD (Mac):** `swift build -c release` zero warnings;
`tiler-palettetest --lock-held` all checks pass incl. the new highlight checks.

---

## T2 — Make the green-button "hat" as invisible as Apple's own button · merged-untested

**Why (ninja's decision, 28 Sep):** the hover trigger must look exactly like stock macOS. Today
the hat (a tiny panel over the green button that stops Apple's hover menu, SPEC §4.C step 4) is
black at alpha 0.02: on a dark titlebar that is invisible (39→38/255) but on a pure-white light
titlebar it darkens 255→250, a faint 22 pt square a careful eye can see.

**Facts you need:** alpha 0.0 does NOT work (fully transparent pixels are hover-through, Apple's
menu appears ~0.9 s later). The window server stores per-pixel alpha in 8 bits, so the smallest
non-zero value is 1/255 ≈ 0.0039 (white titlebar 255→254, below perception). Whether 1/255 still
captures hover is unverified.

**Do:**
- `Sources/Tiler/Hover/HatPanel.swift:55`: replace the literal 0.02 with a named constant
  `hatAlpha`, default `1.0 / 255.0`, overridable for tests via env var `TILER_HAT_ALPHA`
  (parse as Double, clamp to 1/255…0.05). Update the doc comment at line 5.
- Also shrink the hat to the button's own 16×16 pt rect inflated by 1 pt (SPEC says 3 pt) only
  if the code comments/research give no reason against it; otherwise leave the size.
- tiler-hovertest: add `--hat-alpha-sweep` mode that runs the existing suppression check
  (native menu owner `ThemeWidgetControlViewService`, layer 101, must not appear within 4 s)
  for alphas 1/255, 2/255, 3/255, 5/255 and prints which pass, plus a measurement check: with the
  helper window forced to light appearance, sample the titlebar pixel under the hat with and
  without the hat; assert the difference ≤ 1/255 at the chosen default.
- SPEC §4.C step 4: change "alpha 0.02" to "the smallest alpha that still captures hover
  (default 1/255; verified by `tiler-hovertest --hat-alpha-sweep`)".

**Files:** `HatPanel.swift`, `Sources/tiler-hovertest/main.swift`, `SPEC.md`.
**DoD (Mac):** sweep shows 1/255 suppresses the native menu (else set the default to the lowest
passing value); `tiler-hovertest --lock-held` all pass; light-titlebar difference ≤ 1 level.

---

## T3 — Integration review, round 2 (static) · merged-untested

**Why:** round 2 of the whole-app integration check never ran (stopped by usage limits).
**Do (read-only review, then small fixes in separate commits on one branch):**
- One icon renderer (`PresetIcon`) and one glass container (`GlassContainerView`) used everywhere;
  no leftover duplicate drawing code.
- Settings keys used consistently between `TilerSettings`, `EditorView`, `PaletteController`,
  `HoverMonitor` (paletteHotkey, hoverTriggerEnabled, showMacOSMenuByDefault, hoverDelay,
  paletteSize 0.8–2.0, stageManagerInset, launchAtLogin handling).
- Dead code / unused stubs; stale comments that contradict SPEC (e.g. old 44×35 icon size,
  old "no live tests" notes, alpha 0.02 after T2).
- Every SPEC §8 bullet is covered by a unit test or a live-test check; list gaps as new issues.
- README matches actual behaviour and flags (`LaunchOptions.usage`).
**DoD:** PR with the fixes + a comment listing anything that needs the Mac.

---

## T4 — README: first-run section · merged-untested

Add a short "First run" section at the top of `README.md`: install (`scripts/install.sh`), the
one-time keychain "Always Allow" for `ninja-codesign`, granting Accessibility to
`~/Applications/Tiler.app`, where the menu-bar icon is, ⌃⌥T. Keep it ≤ 15 lines. README only.

---

## #9 — Live test for the Settings editor: drag and drop + persistence · merged-untested

`tiler-palettetest --editor` (section E) plus the AX identifiers it needs in
`WellGridView.swift`. Closes the SPEC §8 "Editor" live-test gap.

---

## T5 — Decisions · needs-ninja

- License for the public repo (none yet = all rights reserved).
- ~~Delete the merged branches~~ done: `git ls-remote --heads public` shows only `main`
  (verified 1 Oct 2026).

---

## T6 — Mac verification and install · needs-mac

**Status 1 Oct 2026:** steps 1–3 machine-verified on `main` (numbers in the header; the pill
defect this round caught is fixed in 81c80aa and the fixed build is installed and running).
Step 4's manual checks remain for ninja. The lock-probe key is `CGSSessionScreenIsLocked`
(no `k` prefix); `kCGSSessionScreenIsLocked` always reads "not-locked".

For the merged tasks (T1–T4, #9 — all on `main` now, so test `main`), on the Mac
(`/Users/Guest123/Documents/tiler` has the GitHub repo as remote `public`):
1. `git fetch public && git switch --detach public/<branch>` (or test `main` after merging).
2. `swift build -c release` (0 warnings), `swift test`, then under the live-UI lock:
   `tiler-harness`, `tiler-palettetest --lock-held`, `tiler-hovertest --lock-held`.
3. `scripts/install.sh`, grant Accessibility to `~/Applications/Tiler.app`.
4. Manual: Safari / Obsidian / Claude frontmost → menu-bar click and ⌃⌥T (header shows the app
   and window title, preset applies, focus returns); arrange 3x2 / 1+3 with those three windows
   (nearest slots, no gaps, Revert restores); Stage Manager variant leaves 72 pt free; desktop
   focused → "No window"; hover opt-in on those apps (palette, never Apple's menu; ⌘ shows
   Apple's menu; clicking green still toggles full screen); Light mode once: palette tone vs
   Apple's menu; Activity Monitor ≈ 0 % CPU idle.
5. compare palette with Apple's green-button menu side by side, light + dark
