# AgentHub

A macOS app for monitoring and controlling multiple Claude Code sessions from a single floating overlay. See live screenshots of your agent windows, respond to permission prompts without switching apps, and send commands to background terminals.

## What It Does

When you run multiple Claude Code sessions across different projects, AgentHub lets you:

- **See all sessions at once** — Live screenshots in a grid, auto-discovered
- **Respond to permission prompts remotely** — Allow/Deny buttons appear on the floating panel when a background session needs permission, without leaving your current work
- **Send commands to background terminals** — Type in the floating panel, keystrokes go to the correct VS Code window
- **Smart window filtering** — Only shows windows you're NOT looking at. The frontmost window is hidden from the panel

## How It Works

### Permission Prompts (Blocking Hook)

AgentHub installs a Claude Code PreToolUse hook that:
- **Blocks** when a background project needs permission (you can't see the terminal)
- **Shows Allow/Deny** on the floating panel with the project name
- **Responds directly** via file-based IPC — no keystroke injection for permission responses
- **Passes through** when the project is in the foreground (you can see and respond in the terminal)
- **Passes through** when AgentHub isn't running (normal Claude Code behavior)

### Floating Panel

Appears automatically when you switch away from the app. Shows:
- Adaptive grid of background terminal windows (vertical/horizontal based on panel size)
- Permission prompt banner with project badge
- Command input bar for sending text to background terminals
- Minimize to pill / expand to full app

### Command Sending

Text from the input bar is sent via CGEvent keystrokes (20 chars per event) to the target VS Code window, raised via Accessibility API.

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **macOS** | 14.0+ (Sonoma) | Required for APIs used |
| **Swift** | 5.9+ | Comes with Xcode 15+ |
| **Xcode CLT** | Latest | `xcode-select --install` |

## Setup

```bash
git clone <repo-url>
cd AgentHub
chmod +x build-and-run.sh
./build-and-run.sh --install
```

Grant permissions on first launch:
1. **Screen Recording** — System Settings > Privacy & Security > Screen Recording
2. **Accessibility** — System Settings > Privacy & Security > Accessibility

AgentHub automatically:
- Sets `enableRemoteControl: true` in `~/.claude/settings.json`
- Installs the PreToolUse hook in `~/.claude/hooks/agenthub-prompt.js`
- Creates a presence marker (`/tmp/agenthub-active`) while running

## Project Structure

```
AgentHub/
├── Sources/
│   ├── AgentHubApp.swift                  # App entry, lifecycle
│   ├── Models/
│   │   ├── WindowManager.swift            # Central state (all services, monitoring loops)
│   │   ├── MonitoredWindow.swift          # Window data models
│   │   └── AppCatalog.swift               # 50+ known AI/dev app registry
│   ├── Views/
│   │   ├── CompactDashboardView.swift     # Floating panel (grid, prompts, input bar)
│   │   ├── DashboardView.swift            # Main window (grid, toolbar, prompts, input bar)
│   │   ├── PanelTextField.swift           # NSTextField for non-activating panels
│   │   ├── TapButton.swift                # Gesture-based button for panels
│   │   ├── WindowThumbnailView.swift      # Window card with screenshot
│   │   ├── WindowPickerView.swift         # Window selection sheet
│   │   ├── SettingsView.swift             # App settings
│   │   └── PermissionSetupView.swift      # First-run permission guide
│   └── Services/
│       ├── RemoteControlService.swift     # Hook install, prompt watching, response
│       ├── WindowDiscoveryService.swift   # CGWindowList discovery + dedup
│       ├── WindowInteractionService.swift # AXUIElement window management
│       ├── AttentionDetectionService.swift # Title/idle detection, notifications
│       ├── FloatingPanelManager.swift     # NSPanel lifecycle
│       ├── ContentSharingManager.swift    # Screenshot capture
│       ├── BrowserCookieService.swift     # Arc/Chrome cookie decryption (future use)
│       ├── TerminalBridgeService.swift    # ttyd WebSocket client (future use)
│       ├── NetworkServer.swift            # Bonjour TCP for iOS
│       └── SpeechService.swift            # Speech recognition
├── build-and-run.sh          # Build, sign, install, launch
├── Package.swift              # SPM config (no external deps, links sqlite3)
├── Info.plist                 # App metadata
└── AgentHub.entitlements      # App sandbox disabled
```

## Known Issues

1. **CGEvent multi-window targeting** — When sending commands to a specific VS Code window among multiple, the keystroke may go to the wrong one. Both windows share the same PID.
2. **Hook allow-rule matching** — Can't fully replicate Claude Code's permission logic. Some auto-allowed tools may still trigger the blocking hook.
3. **1s frontmost tracking delay** — The frontmost project file updates every second, causing a brief window where the hook may incorrectly block.

## Tech Stack

Swift 5.9 / SwiftUI / AppKit / CommonCrypto / SQLite3 / UserNotifications / Network.framework / Speech / AVFoundation
