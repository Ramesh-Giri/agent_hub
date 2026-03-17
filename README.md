# AgentHub

A macOS dashboard for monitoring multiple AI agent windows (Claude Code, ChatGPT, Cursor, VS Code, terminals). See live screenshots, get notified when agents need input, and control Claude Code sessions via Remote Control — all from a floating overlay.

## Features

- **Window Monitoring** — Discover and track AI agent/terminal windows with live screenshot thumbnails
- **Floating Panel** — Always-on-top overlay that appears when you switch apps, embedding claude.ai/code as a full Remote Control browser for connected Claude Code sessions
- **Attention Detection** — Title-based monitoring detects when window titles contain prompt patterns like `(y/n)`, `Continue?`
- **Idle Detection** — Flags pure terminal apps (iTerm, Terminal, Warp) that haven't changed for 20+ seconds
- **macOS Notifications** — System notifications with actionable buttons when agents wait for input
- **iOS Companion** — Bonjour TCP server broadcasts window list with screenshots to an iOS app
- **Voice Commands** — On-device speech recognition for hands-free input
- **Claude-mem Integration** — Pulls context from claude-mem service for enriched window information

## Prerequisites

| Requirement | Version | Notes |
|---|---|---|
| **macOS** | 14.0+ (Sonoma) | Required for APIs used |
| **Swift** | 5.9+ | Comes with Xcode 15+ |
| **Xcode Command Line Tools** | Latest | `xcode-select --install` |
| **OpenSSL** | Any | Pre-installed on macOS, used for code signing cert |
| **Claude Code** | 2.1.51+ | Required for floating panel Remote Control. `claude --version` to check |

## macOS Permissions Required

Grant these via System Settings > Privacy & Security:

| Permission | Purpose | Required? |
|---|---|---|
| **Screen Recording** | Live window screenshots | Yes |
| **Accessibility** | Bring agent windows to front | Yes |
| **Notifications** | Alert when agents need input | Recommended |
| **Microphone** | Voice command input | Optional |
| **Speech Recognition** | Convert voice to text | Optional |
| **Local Network** | iOS companion app via Bonjour | Optional |

## Setup & Installation

### 1. Build and install

```bash
git clone <repo-url>
cd AgentHub
chmod +x build-and-run.sh
./build-and-run.sh --install
```

This automatically:
- Creates a self-signed code signing certificate (`AgentHub Dev`) on first run
- Builds with `swift build`
- Creates an `.app` bundle with proper Info.plist
- Signs with stable identity (permissions persist across rebuilds)
- Installs to `/Applications/AgentHub.app` and launches

> **First run:** You may see a keychain dialog — click "Always Allow".

### 2. Grant permissions

On first launch, grant:
1. **Screen Recording** — Add AgentHub in System Settings, then **relaunch**
2. **Accessibility** — Add AgentHub in System Settings

### 3. Enable Claude Remote Control (required)

The floating panel is a Remote Control browser — it needs this enabled. Add to `~/.claude/settings.json`:

```json
{
  "enableRemoteControl": true
}
```

Or run `/config` inside any Claude Code session and toggle "Enable Remote Control for all sessions".

After enabling, new Claude Code sessions automatically register at claude.ai/code and appear in the floating panel.

## Usage

### Adding Windows

1. Click **"Add Windows"** (+ button) in the toolbar
2. Select terminal/agent windows to monitor
3. Click "Add Selected"

### Floating Panel

When you switch to another app, the main window hides and a floating overlay appears showing claude.ai/code — a full Remote Control browser for your connected Claude Code sessions. All input and interaction goes through Claude's Remote Control protocol directly in the web view.

Click the expand arrow to restore the full app. Cmd+Tab or dock click also restores it.

### Attention Detection

AgentHub watches window titles for prompt patterns:
- `(y/n)`, `[Y/n]`, `(yes/no)` — prompt patterns in window titles
- `Continue?`, `Proceed?`, `Confirm?` — question prompts
- `Error:`, `FAILED`, `Build failed` — error patterns

When detected:
- Orange attention badge on the window card
- macOS notification with the prompt text
- Notification action buttons for quick response

### Interacting with Agents

The floating panel embeds claude.ai/code directly — interact with all connected Claude Code sessions through the Remote Control web UI. No keystroke injection or clipboard needed.

From the main dashboard, click a window card to bring the agent window to front.

## Project Structure

```
AgentHub/
├── Sources/
│   ├── AgentHubApp.swift               # App entry point
│   ├── Models/
│   │   ├── WindowManager.swift         # Central state manager
│   │   ├── MonitoredWindow.swift       # Window data models
│   │   └── AppCatalog.swift            # Known AI/dev app registry (50+ apps)
│   ├── Views/
│   │   ├── DashboardView.swift         # Main grid view
│   │   ├── CompactDashboardView.swift  # Floating panel (RC browser + expand button)
│   │   ├── WindowThumbnailView.swift   # Window card with screenshot
│   │   ├── WindowPickerView.swift      # Window selection sheet
│   │   ├── InteractionSheet.swift      # Window details modal
│   │   ├── SettingsView.swift          # App settings
│   │   ├── PermissionSetupView.swift   # First-run permission guide
│   │   ├── RemoteControlWebView.swift  # Claude remote control (WKWebView + session management)
│   │   └── TapButton.swift            # Gesture-based button for floating panels
│   └── Services/
│       ├── WindowDiscoveryService.swift    # CGWindowList discovery + Electron dedup
│       ├── WindowInteractionService.swift  # Bring windows to front (Accessibility API)
│       ├── ContentSharingManager.swift     # Screenshot capture (CGWindowListCreateImage)
│       ├── AttentionDetectionService.swift # Title + idle detection, notifications
│       ├── FloatingPanelManager.swift      # Always-on-top floating panel
│       ├── NetworkServer.swift             # Bonjour TCP server for iOS
│       ├── SpeechService.swift             # On-device speech recognition
│       └── ClaudeMemService.swift          # claude-mem integration
├── build-and-run.sh          # Build, sign, install, launch
├── Package.swift             # SPM configuration (no external deps)
├── Info.plist                # App metadata
└── AgentHub.entitlements     # App sandbox disabled
```

## Development

```bash
# Debug build only
swift build

# Build + launch from build dir
./build-and-run.sh

# Build + install to /Applications + launch
./build-and-run.sh --install
```

### Code Signing

The build script creates a self-signed `AgentHub Dev` certificate in your login keychain. This ensures TCC permissions persist across rebuilds. Verify:
```bash
security find-identity -v -p codesigning | grep "AgentHub Dev"
```

## Known Limitations

- **Electron ghost windows** — VS Code/Cursor create extra CG windows. AgentHub deduplicates by PID + title but edge cases exist.
- **Google OAuth** in embedded web view is blocked — redirects to default browser for login.
- **Title-based detection** only works when prompt patterns appear in the window title, not terminal content.

## Tech Stack

Swift 5.9 / SwiftUI / AppKit / WebKit / UserNotifications / Network.framework / Speech / AVFoundation

## License

MIT
