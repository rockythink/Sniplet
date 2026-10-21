# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

Sniplet is a native macOS menu-bar screenshot utility (capture → in-place annotate/beautify → copy/save/pin/drag, local OCR and history). Swift 6 + SwiftUI/AppKit + ScreenCaptureKit, macOS 14+, sandboxed, no network entitlement. A separate Astro static site lives in `website/`.

## Commands

`project.yml` (XcodeGen) is the source of truth; `Sniplet.xcodeproj` is generated. After changing targets, settings, version or Info.plist properties, run `xcodegen generate --spec project.yml`.

Local ad-hoc build (overrides the maintainer's Developer ID signing — do not edit signing in `project.yml`):

```sh
xcodebuild -project Sniplet.xcodeproj -scheme Sniplet \
  -configuration Debug -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/ContributorDerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS= build
```

Tests (Swift Testing, `import Testing` / `@Test` / `#expect`):

```sh
env SNIPLET_UNIT_TESTS=1 xcodebuild \
  -project Sniplet.xcodeproj -scheme Sniplet -configuration Debug \
  -destination 'platform=macOS,arch=arm64' \
  -derivedDataPath .build/TestDerivedData \
  CODE_SIGN_STYLE=Manual CODE_SIGN_IDENTITY=- DEVELOPMENT_TEAM= \
  ENABLE_HARDENED_RUNTIME=NO OTHER_CODE_SIGN_FLAGS= \
  -only-testing:SnipletTests test
```

Single suite / test: `-only-testing:SnipletTests/EditorSessionTests` or `-only-testing:'SnipletTests/EditorSessionTests/exportFreezeBlocksEditsAndCancellationRestoresEditing()'`.

Release packaging (maintainer only, needs Developer ID + `asc` auth): Release build with `ARCHS='arm64 x86_64'`, then `scripts/package-release.sh --identity '…' --notarize`. Output goes to `.build/Distribution/Sniplet-VERSION/` and the script refuses to overwrite an existing version.

Website: `npm --prefix website ci`, `npm --prefix website run dev -- --host 127.0.0.1 --port 4346`, `npm --prefix website run build`. Deploying (`npm run deploy`, Cloudflare Worker via `website/wrangler.jsonc`) needs the maintainer's login.

## Test host rules

- `AppRuntime.isUnitTesting` (`SNIPLET_UNIT_TESTS=1`, Debug only) turns the app into an inert test host: no menu bar item, settings UI, global shortcuts, capture, or real history service. `AppCoordinator.start()` returns early.
- Tests must stay headless: synthetic `CGImage`s, private pasteboards, temporary directories. Never trigger real screen capture, the general pasteboard, or desktop automation. Shared fixtures live in `SnipletTests/SessionTestSupport.swift`.

## Concurrency defaults

Build settings use `SWIFT_STRICT_CONCURRENCY: complete` and `SWIFT_DEFAULT_ACTOR_ISOLATION: MainActor`. Everything is MainActor unless marked otherwise; value/model types and rendering helpers that must run off the main actor are explicitly declared `nonisolated` (e.g. `CaptureRevision`, `AnnotationCompositor`, `HistoryStoreFactory`). Follow that pattern rather than adding `@MainActor` everywhere.

## Architecture

Capture pipeline (one capture at a time):

1. **Entry** — `SnipletApp` (`MenuBarExtra`, `LSUIElement`) and `GlobalHotKeyManager` call `AppCoordinator.requestCapture(mode)`. `AppCoordinator` owns all long-lived services (capture, renderer, encoder, OCR, file export, pins, history) and arbitrates with an already-open editor (finish / discard / cancel) before starting a new capture.
2. **Capture** — `CaptureWorkflowController` drives ScreenCaptureKit plus `SelectionOverlayController` / `WindowSelectionService` and returns a `CaptureOutcome`: a single **frozen** base image (`CapturedImage`), the selection, and the overlay host window, which is handed off to the editor rather than closed. Regions never span displays.
3. **Edit** — `EditorSession` (`Floating/`) is the state machine (`EditorPhase`: editing → exporting → finalized → closed) wrapping an `AnnotationEditor` (`Annotation/`). `InlineEditorController` presents it in place on the overlay with inline toolbars. Resizing/moving the selection crops within the frozen base image; it never re-reads the screen, and annotations stay aligned to source pixels.
4. **Render/Output** — `ImageRenderer` / `AnnotationCompositor` (`Imaging/`) produce a `RenderedCapture` including `CaptureStyle` beautification (corner radius, shadow, border, presets). Copy, save, pin, drag and history all consume the same final render via `EditorServices`. Selection chrome, toolbars and handles are never rendered into output or OCR.

Revision keying: every document change bumps a revision; `CaptureRevision(id, revision)` keys the cached render/PNG, export freezes and OCR tickets. Stale renders/OCR results are rejected (`accepts`, `acceptRendered`, `acceptOCR`), and edits/undo/cancel invalidate OCR. Preserve this invariant when adding outputs or async work.

Other subsystems:

- **History** (`History/`) — SwiftData index with CloudKit explicitly disabled plus PNG/thumbnail files on disk, written through a staging directory with cleanup/orphan recovery. Limits default to 500 items / 1 GiB (`HistoryLimits`). `HistoryIndexer` runs OCR on stored finals in the background. Only final PNGs and their OCR are persisted — never editable layers or undo stacks.
- **Drag export** (`Export/DragExport*`) — prepares data only once a real drag starts; offers a final PNG file URL, PNG/TIFF and a file promise. Temp files are deleted on cancel and cleaned up 10 minutes after acceptance.
- **Pinning** (`Pinning/`) — independent read-only windows showing final images.
- **Settings** (`Settings/AppPreferences`) — persisted preferences such as default capture style, selection appearance, OCR/history toggles and shortcuts.

## Constraints

- Entitlements are only `app-sandbox` and `files.user-selected.read-write`. Do not add network, accessibility, input monitoring or other entitlements, analytics, or global keyboard monitoring.
- Clipboard writes use `currentHostOnly`; never poll the system pasteboard.
- UI strings are Simplified Chinese.
- Portions are adapted from CapCap (MIT); keep `Sniplet/Resources/ThirdPartyNotices.txt` intact.
- Version bumps touch `project.yml` (`CFBundleShortVersionString`, `CFBundleVersion`), `website/src/data/release.json`, `website/package.json`, and the README download section.
- The website's beautification sample must stay labeled as an illustration, not a real screenshot.
