# CLAUDE.md

This file provides guidance to Claude Code when working with this repository.

## Build & Run

```bash
swift build                              # Build only
./build-and-run.sh                       # Build + launch
./build-and-run.sh --install             # Build + install to /Applications + launch
pkill -x Canopy; sleep 0.5 && ./build-and-run.sh  # Kill + rebuild
```

No tests or linting. Zero external dependencies — pure SPM with native macOS frameworks + SQLite3 (system library).

## Architecture

### Central State: `WindowManager`

Single `@ObservableObject` owning all services and published state. Every view accesses via `@EnvironmentObject`. Monitoring loops:
- Screenshot capture every 2s
- Context refresh every 30s (claude-mem)
- Prompt file polling every 500ms (`RemoteControlService`)
- Frontmost tracking: event-driven via AXObserver + 2s polling fallback (`FrontmostTracker`)

### App Lifecycle

On launch, `WindowManager.setup()` initializes services including `RemoteControlService` (installs hook) and `FrontmostTracker` (starts AXObserver). `FloatingPanelManager` listens for app resign/activate. On quit, presence marker is removed.

### User Flow

1. App starts blank — user adds windows via "Add Windows"
2. First window added → presence marker written → hook starts intercepting background prompts
3. All windows removed → marker removed → hook passes through everything
4. Floating panel only appears when windows are monitored AND user switches away

### Permission Prompt System

Blocking `PreToolUse` hook (`~/.claude/hooks/canopy-prompt.js`):
- Only intercepts `Bash`, `Write`, `Edit` in `default`/`plan` modes
- Checks frontmost file — if project matches CWD path, passes through
- `__CANOPY_ACTIVE__` marker → Canopy main window is active → pass through everything
- Checks allow rules in `Tool(pattern)` format with glob matching
- Blocks and writes prompt file → `RemoteControlService` polls → UI shows Allow/Deny
- Response written to file → hook reads and outputs `permissionDecision`

### Frontmost Detection

`FrontmostTracker` uses two layers:
- Layer 1: `NSWorkspace.didActivateApplicationNotification` — app switches
- Layer 2: `AXObserver` with `kAXFocusedWindowChangedNotification` — within-app window switches
- Gets actual focused window via `kAXFocusedWindowAttribute` (AX API), not CGWindowList z-order
- Matches AXUIElement to CGWindowID via `_AXUIElementGetWindow` (private API, stable across macOS 10.x–15.x)
- When Canopy itself is frontmost, writes `__CANOPY_ACTIVE__` so hook doesn't block

### Floating Panel

- Only shows when `monitoredWindows` is non-empty
- Hides the frontmost monitored window (the one user is looking at)
- Shows ALL windows when user is on a non-monitored app
- `NSPanel` with `.nonactivatingPanel` — requires `TapButton`/`TapIconButton` for interaction (SwiftUI `Button` doesn't work)

### Command Sending (Current)

Clipboard paste approach: save clipboard → set text → AXRaise + multi-signal window raise → Cmd+V → Enter → restore clipboard. Known limitations with multi-window targeting.

### Service Layer

| Service | Purpose |
|---|---|
| `RemoteControlService` | Hook installation, prompt file watching, response IPC |
| `FrontmostTracker` | Event-driven frontmost window tracking |
| `WindowDiscoveryService` | CGWindowList enumeration + Electron deduplication |
| `WindowInteractionService` | AXUIElement multi-signal raise + CGEvent keystrokes |
| `AttentionDetectionService` | Title monitoring, idle detection, notifications |
| `FloatingPanelManager` | NSPanel lifecycle, activate/resign guards |
| `ContentSharingManager` | Screenshot capture via CGWindowListCreateImage |
| `ClaudeMemService` | HTTP client to claude-mem (optional) |

## Key Conventions

- **No external dependencies.** Native macOS frameworks only.
- **macOS 14.0+** (Sonoma).
- **NSPanel requires special controls.** Use `TapButton`/`TapIconButton` (gesture-based) or `PanelTextField` (AppKit wrapper). SwiftUI `Button` gets swallowed.
- **App sandbox disabled** — needs CGWindowList, Accessibility, keychain.
- **Presence marker gates everything.** No windows = no marker = hook passes through = no floating panel.
- **Multi-signal window raise:** AXRaise → kAXMainAttribute → activate → kAXFocusedAttribute. Order matters.

## Permissions

- **Screen Recording** — `CGWindowListCreateImage` (screenshots)
- **Accessibility** — `AXUIElement` (window raising, frontmost detection)
- **enableRemoteControl: true** in `~/.claude/settings.json` — auto-set on launch
