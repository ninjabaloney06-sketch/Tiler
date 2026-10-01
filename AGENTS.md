# Agent guide — read before touching code

Tiler is ninja's Moom-style macOS window manager (Swift 6, AppKit, Accessibility API).
`SPEC.md` is the single source of truth for behaviour. Open work lives in **GitHub issues**
(label `ready-for-code`); `TASKS.md` mirrors them in case issues are not reachable.
This file says how to work from a **cloud session with only GitHub access and coding tools**
(Linux, no macOS, no Xcode).

## What a cloud session can and cannot do

- **Cannot:** build or run the app (`Tiler`, `TilerAX` and the live test tools need AppKit and
  the macOS SDK), take screenshots, move windows, run `tiler-harness` / `tiler-palettetest` /
  `tiler-hovertest`. Never claim something was built, tested or verified live when it was not.
- **Optional:** if a Linux Swift toolchain is available, try `swift build --target TilerCore`
  and `swift test --filter TilerCoreTests` (pure logic). If it doesn't compile on Linux, don't
  port it — say so and move on.
- **Can:** write code, extend the live test tools so they cover the change, update `SPEC.md` /
  `README.md`, review other branches statically.

Compiling, live tests and visual checks happen later on ninja's Mac.

## Workflow (make → review)

1. Take the lowest-numbered open task in `TASKS.md` / issue labelled `ready-for-code`.
   Branch `task/<n>-<slug>` from `main`. Never push to `main`.
2. Read `SPEC.md` (§0 traps, the sections the task names, §8 quality bar) and the listed files.
3. Implement the smallest change that meets the task's Definition of Done. Match the
   surrounding style. Touch only the files the task names (plus tests / SPEC / README when it
   says so).
4. Swift 6 language mode, `defaultIsolation(MainActor.self)` in app targets. SPEC §0 pitfalls
   are real (CFTypeRef casts, global AX constants, `String(format:)` type-checker hangs).
   Write code you would bet compiles: explicit types at AX/CF boundaries, no guessed APIs; if
   unsure an AppKit API exists on macOS 14, say so in the PR.
5. Open a PR `<task title> (#<n>)`. Body: what changed and why (file:line);
   `Untested: not compiled, not run` (or exactly what ran on Linux); the Mac verification steps
   from the task.
6. **Review pass** (same or a second session, fresh eyes): re-read the diff against the task's
   DoD and SPEC; check types, isolation, optionals, unrelated edits, test-tool coverage. Post
   `LGTM (static)` or one concrete blocking finding (file:line, why) as a PR comment; fix and
   repeat until LGTM.
7. Nobody but ninja merges — after the Mac build and live tests pass.

## Repo map

- `Sources/TilerCore` — presets, geometry, assignment, config, icon geometry (pure, unit-tested).
- `Sources/TilerAX` — Accessibility window engine.
- `Sources/Tiler/{App,Palette,Hover,Windows}` — menu-bar app/editor, palette + triggers, hover.
- `Sources/TilerTestSupport`, `tiler-harness`, `tiler-palettetest`, `tiler-hovertest`,
  `TilerTestWindows` — live test tools (run only on the Mac).
- `scripts/` — `build.sh`, `install.sh`, `make-icon.swift`.
- Local-only, not in this repo: `docs/` (research, Apple/Moom reference captures) and `tools/`.
  SPEC mentions of them are informational; the measured numbers you need are in SPEC and the
  tasks. Don't recreate them.

## Never

- Push to `main`, force-push, merge, or delete branches.
- Add dependencies, change `Package.swift` platforms/tools-version, or touch signing.
- Add features not asked for. A bug outside your task → new issue, not a drive-by fix.
- Put secrets or personal data in the repo.
