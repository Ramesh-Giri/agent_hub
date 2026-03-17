# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Build & Run Commands

```bash
# Build only (debug)
swift build

# Build + launch from .build/debug/AgentHub.app
./build-and-run.sh

# Build + install to /Applications + launch (use for permission-persistent installs)
./build-and-run.sh --install

# Kill running instance before rebuild
pkill -x AgentHub; sleep 0.5 && ./build-and-run.sh
```

There are no tests or linting configured. The project has zero external dependencies — pure Swift Package Manager with native macOS frameworks only.

## Architecture

**Central state pattern:** `WindowManager` is the single `@ObservableObject` that owns all services and published state. Every view accesses it via `@EnvironmentObject`. All monitoring loops (screenshot capture every 2s, context refresh every 30s, iOS broadcast every 3s) run as `Task` instances inside WindowManager.

**App lifecycle (AgentHubApp.swift):** On launch, `WindowManager.setup()` initializes all services. `FloatingPanelManager` listens for app resign/activate notifications — when the user switches away, the main window hides and a floating `NSPanel` (always-on-top, joins all spaces) appears showing `CompactDashboardView`. Clicking expand restores the main app.

**Floating panel (`CompactDashboardView`):** The floating panel is a full-screen Remote Control browser embedding claude.ai/code via WKWebView. It shows connected Claude Code terminal sessions and allows direct interaction through the web interface. No keystroke injection or clipboard tricks — all input goes through Claude's Remote Control protocol. The only chrome is an expand button overlay to restore the main app.

**Prerequisite:** `~/.claude/settings.json` must have `"enableRemoteControl": true` so Claude Code sessions auto-register at claude.ai/code.

**Service layer (`Sources/Services/`):**
- `WindowDiscoveryService` — Enumerates windows via `CGWindowListCopyWindowInfo`, filters by `AppCatalog` known apps, deduplicates Electron ghost windows by PID+title
- `WindowInteractionService` — Brings windows to front via Accessibility API (`AXUIElement`)
- `AttentionDetectionService` — Polls window titles for prompt patterns (`(y/n)`, `Continue?`, error strings). For pure terminals, also does screenshot idle detection (32x32 downsample pixel diff). Fires macOS notifications with actionable buttons (Yes/No/Reply)
- `FloatingPanelManager` — Creates `NSPanel` with `.nonactivatingPanel` style. Normal SwiftUI buttons don't work in non-activating panels, which is why `TapButton`/`TapIconButton` use `onTapGesture` instead
- `ContentSharingManager` — Screenshot capture via `CGWindowListCreateImage` (not ScreenCaptureKit, to avoid extra TCC dialogs)
- `NetworkServer` — Bonjour TCP (`_agenthub._tcp`) with newline-delimited JSON protocol for iOS companion
- `ClaudeMemService` — HTTP client to `localhost:37777` with self-signed cert trust

**View layer (`Sources/Views/`):**
- `CompactDashboardView` — Floating panel: full WKWebView browser for claude.ai/code Remote Control with expand button overlay
- `DashboardView` — Full-size main window with grid layout, toolbar, window picker
- `InteractionSheet` — Modal for detailed window interaction (text input, voice, quick responses)

## Key Conventions

- **No external dependencies.** Everything uses native macOS frameworks (AppKit, WebKit, Network.framework, Speech, AVFoundation, UserNotifications).
- **Platform minimum:** macOS 14.0 (Sonoma). Set in both `Package.swift` and `project.yml`.
- **Floating panel interaction is via Remote Control only.** Never use clipboard or CGEvent keystroke injection to send commands from the floating panel. The embedded claude.ai/code web view handles all terminal input through Claude's Remote Control protocol.
- **Gesture-based buttons required** in the floating panel (`TapButton`, `TapIconButton`) because `NSPanel` with `.nonactivatingPanel` style swallows normal SwiftUI `Button` events.
- **App sandbox is disabled** (`AgentHub.entitlements`) — the app needs CGWindowList, Accessibility API, Bonjour networking.
- **Code signing:** `build-and-run.sh` creates a self-signed "AgentHub Dev" certificate for stable CDHash so TCC permissions (Screen Recording, Accessibility) persist across rebuilds. Ad-hoc signing would revoke permissions every build.
- **`AppCatalog.swift`** contains a registry of 50+ known dev/AI apps with bundle IDs, categories, and `pureTerminalBundleIDs` (used for idle detection — only pure terminals get flagged for screenshot staleness).

## Permissions

The app requires **Screen Recording** (for `CGWindowListCreateImage`) and **Accessibility** (for `AXUIElement` window raising). Without these, core functionality doesn't work. `PermissionSetupView` guides first-run users. `enableRemoteControl: true` must be set in `~/.claude/settings.json` for the floating panel RC browser to show connected sessions.
