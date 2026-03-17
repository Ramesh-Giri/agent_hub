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

There are no tests or linting configured. The project has zero external dependencies — pure Swift Package Manager with native macOS frameworks + SQLite3 (system library).

## Architecture

### Central State Pattern

`WindowManager` is the single `@ObservableObject` that owns all services and published state. Every view accesses it via `@EnvironmentObject`. Key monitoring loops:
- Screenshot capture every 2s
- Context refresh every 30s
- iOS broadcast every 3s
- Prompt file polling every 500ms (`RemoteControlService`)
- Frontmost window tracking every 1s (`CompactDashboardView`)

### App Lifecycle (AgentHubApp.swift)

On launch, `WindowManager.setup()` initializes all services including `RemoteControlService` (installs hooks, writes presence marker). `FloatingPanelManager` listens for app resign/activate — when the user switches away, the main window hides and a floating `NSPanel` appears. On quit, the presence marker is removed so hooks fall through to normal Claude Code behavior.

### Permission Prompt System (Core Feature)

AgentHub intercepts Claude Code permission prompts via a **blocking PreToolUse hook**:

1. **Hook script** (`~/.claude/hooks/agenthub-prompt.js`) — installed at launch by `RemoteControlService`
2. **Flow for BACKGROUND projects** (user is NOT looking at this project):
   - Hook fires → checks if project is frontmost (via `/tmp/agenthub-frontmost.txt`)
   - Project is NOT frontmost → hook blocks, writes prompt file to temp dir
   - `RemoteControlService` polls temp dir every 500ms, picks up prompt
   - Floating panel shows Allow/Deny banner with project badge
   - User taps Allow → `respondToPrompt(allow: true)` writes response file
   - Hook reads response → outputs `{"permissionDecision": "allow"}` to Claude Code
   - Claude Code proceeds — NO terminal dialog shown
3. **Flow for FRONTMOST projects** (user IS looking at this project):
   - Hook fires → sees project matches frontmost → exits immediately (no output)
   - Claude Code shows its normal terminal permission dialog
   - User responds directly in the terminal
4. **When AgentHub is not running:**
   - No presence marker (`/tmp/agenthub-active`) → hook exits immediately
   - Claude Code shows its normal terminal dialog

### Floating Panel (CompactDashboardView)

The floating panel shows:
- **Adaptive grid** of monitored windows (vertical/horizontal/grid based on panel shape)
- **Only background windows** — the frontmost window is hidden (detected via CGWindowList z-order)
- **Permission prompt banner** at top when a background project needs input
- **Command input bar** at bottom — sends keystrokes via CGEvent to the background window
- **Minimize to pill** / expand to main app

### Command Sending

Text is sent from the floating panel to a specific VS Code window via:
1. `raiseWindowByProjectName()` — uses Accessibility API (AXUIElement) to find and raise the specific VS Code window matching the project name
2. CGEvent `keyboardSetUnicodeString` in 20-char chunks — fast keystroke injection
3. Enter key sent after text

**Known issue:** CGEvent goes to whichever VS Code window is frontmost. Multi-window targeting via AX API is unreliable. The `raiseWindowByProjectName` method attempts to raise the correct window before sending.

### Service Layer (Sources/Services/)

- `RemoteControlService` — Hook installation, prompt file watching, response writing. Ensures `enableRemoteControl: true` in settings.
- `WindowDiscoveryService` — Enumerates windows via `CGWindowListCopyWindowInfo`, filters by `AppCatalog` known apps, deduplicates Electron ghost windows
- `WindowInteractionService` — Brings windows to front via Accessibility API (`AXUIElement`)
- `AttentionDetectionService` — Polls window titles for prompt patterns. Screenshot idle detection for pure terminals. macOS notifications with action buttons
- `FloatingPanelManager` — Creates `NSPanel` with `.nonactivatingPanel` style. Transition guard prevents activate/resign flickering loop
- `ContentSharingManager` — Screenshot capture via `CGWindowListCreateImage`
- `BrowserCookieService` — Reads/decrypts Arc/Chrome browser cookies (AES-CBC via CommonCrypto + Keychain). Used for WKWebView auth (currently unused but kept for future)
- `TerminalBridgeService` — WebSocket client for ttyd terminal (token auth, tty subprotocol). Currently unused but kept for future mobile app
- `NetworkServer` — Bonjour TCP for iOS companion
- `ClaudeMemService` — HTTP client to claude-mem

### View Layer (Sources/Views/)

- `CompactDashboardView` — Floating panel: adaptive window grid, permission banner, command bar
- `DashboardView` — Full main window: grid layout, toolbar, permission banner, command bar
- `PanelTextField` — NSTextField wrapper that works in non-activating panels (NSTextFieldDelegate for Enter key)
- `PanelSendButton` — NSButton wrapper with `acceptsFirstMouse` for non-activating panels
- `TapButton` / `TapIconButton` — Gesture-based buttons using `onTapGesture` (SwiftUI Button doesn't work in NSPanel)
- `WindowThumbnailView` — Window card with screenshot for main dashboard

## Key Conventions

- **No external dependencies.** Native macOS frameworks + system SQLite3 only.
- **Platform minimum:** macOS 14.0 (Sonoma).
- **NSPanel interaction requires special controls.** `NSPanel` with `.nonactivatingPanel` swallows normal SwiftUI `Button` events. Use `TapButton`/`TapIconButton` (gesture-based) or `PanelTextField`/`PanelSendButton` (native AppKit wrappers).
- **App sandbox is disabled** — needs CGWindowList, Accessibility API, Bonjour, keychain access.
- **Code signing:** Self-signed "AgentHub Dev" certificate for stable TCC permissions.
- **Hook is non-blocking for frontmost project.** The hook checks `/tmp/agenthub-frontmost.txt` to decide whether to block. Frontmost project's tools pass through to Claude Code's normal dialog.
- **CGEvent for command sending.** Uses `keyboardSetUnicodeString` with 20-char chunks. `postToPid` for targeting specific processes. Multi-window targeting uses AX API `kAXRaiseAction`.

## Permissions

- **Screen Recording** — for `CGWindowListCreateImage` (live screenshots)
- **Accessibility** — for `AXUIElement` (window raising, multi-window targeting)
- **enableRemoteControl: true** in `~/.claude/settings.json` — auto-set by AgentHub on launch

## Current Known Issues

1. **CGEvent goes to wrong VS Code window** — Both windows share the same PID. `raiseWindowByProjectName` attempts AX-based targeting but timing is unreliable.
2. **Hook allow-rule matching is imperfect** — Can't replicate Claude Code's full permission logic. Some auto-allowed tools may still trigger the hook.
3. **Frontmost tracking has 1s delay** — The file is updated every second, so there's a brief window where the hook may block for a just-switched-to project.
