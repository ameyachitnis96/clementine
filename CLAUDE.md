# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Clementine is a free macOS 14+ menu-bar file converter: drag a file, hold a modifier, and a radial "fan" opens at the pointer. Pure SwiftPM, no dependencies.

## Commands

```bash
swift build -q                         # typecheck
swift test -q                          # all tests
swift test --filter extractRefusesZipSlipAndUnpacksSafeArchive   # one test
./build-app.sh                         # release build -> dist/Clementine.app (ad-hoc signed)
.build/debug/Clementine --tool <FileTool rawValue> <files…>      # headless run of the same engine
.build/debug/Clementine --render <dir> <sample-file>             # PNG snapshots of fans/welcome/settings
```

- `swift test` sometimes fails on this toolchain with "plugin for module 'TestingMacros' not found". It is flaky, not a code error: rerun it. Don't use `swift build --build-tests`.
- No linter is configured. ffmpeg and webp (`brew install ffmpeg webp`) are optional; code checks `ToolLocator.ffmpeg` and must keep working without it.

## Architecture

Three modifier keys while dragging a file each open a different fan (`DragGestureMonitor`, which watches global mouse and modifier events and the drag pasteboard, no Accessibility permission needed):

- **Shift** → convert formats (`FormatCompatibilityMatrix.outputs(for:)`)
- **Command** → file tools (`FileTool.tools(for:)`)
- **Control** → file actions (`FileTool.fileActions`: AirDrop, Float/shelf, Copy, Move, Copy Path, Terminal)

Keys are user settings (`Settings.convertModifier/toolsModifier/actionsModifier`). Modes must match modifiers exactly.

Every fan petal is a `FanAction` (`.convert(format)` or `.tool(tool)`). The flow is `ConversionOverlayController` shows the fan, a drop calls `ActionRunner.run`, which handles instant and GUI actions (copy, move, editors, shelf) and sends the rest through `perform`/`apply` to the converters in `ConversionEngine.swift` (`ImageConverter`, `DocumentConverter`, `MediaConverter`, `ArchiveConverter`; AVFoundation edits live in `MediaEdits.swift`). The menu bar pickers and the CLI (`CLI.swift`) call the same `ActionRunner.perform`, so a tool added once works from the fan, the menu and `--tool`.

File grouping drives everything: `FormatCompatibilityMatrix.group(for:)` maps an extension to `.image/.video/.audio/.document/.text/.archive/.subtitle`. Only `.pdf` is `.document`; docx/txt/md are `.text`. Any folder is `.archive`.

Interactive tools open an `EditorWindow` (Crop, Trim in trim/split/bleep modes, Annotate, Redact, Collage, Organize, Image Edit, Background). They need the GUI and throw `unsupported` when run headless.

## Adding a tool

1. Add a case to `FileTool` plus its `label` and `symbol`.
2. Offer it in `FileTool.tools(for:)` (multi-file tools check `urls.count`).
3. Handle it in `ActionRunner`: `run` for GUI or instant actions, `perform` for multi-file, `apply` for per-file. Add it to the unsupported list in `apply` if it is handled elsewhere.
4. Add a test in `Tests/ClementineTests/ToolTests.swift`.

## Rules

- Never overwrite an original. Outputs go through `OutputPlacement.destination`/`uniqueURL` (honours `Settings.outputFolder`).
- Archive extraction validates every entry (`ArchiveConverter.isSafeEntry`, `tar -tf` listing) before writing anything. Keep that check on any new extract path.
- Run external tools through `Shell.run` with an argument array, never a shell string.
