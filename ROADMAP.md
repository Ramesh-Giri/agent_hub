# Canopy — Roadmap

## Current State (v1.0)

- [x] Window monitoring with live screenshots
- [x] Floating panel with adaptive grid layout
- [x] Permission prompt interception (Allow/Deny from floating panel)
- [x] Event-driven frontmost detection (AXObserver + NSWorkspace)
- [x] Multi-window command sending via VS Code REST Control + PID-chain port discovery
- [x] Hook system for background project prompt interception

## v1.1 — Chat Panel & Response Reading

### Chat Panel in Floating Window
- [ ] Add a chat view per project in the floating panel
- [ ] Show sent messages and received responses inline
- [ ] PostToolUse hook to capture Claude's responses and write to file
- [ ] Canopy reads response files and displays in chat view
- [ ] Real-time streaming display as Claude types

### Agent-to-Agent Chat
- [ ] Select two Claude instances from the floating panel
- [ ] Route Project A's response as input to Project B
- [ ] Route Project B's response back to Project A
- [ ] Autonomous loop with configurable stop conditions
- [ ] Conversation transcript view

## v1.2 — Subprocess Mode (claude --print --stream-json)

### Direct Claude Management
- [ ] Spawn Claude Code as subprocess with stdin/stdout pipes
- [ ] Full structured JSON communication (no VS Code dependency)
- [ ] Per-project session management (start/stop/restart)
- [ ] Permission handling via --permission-mode flag
- [ ] Session persistence across app restarts (--session-id + --resume)

### Benefits over REST Control
- No VS Code extension dependency
- True bidirectional streaming
- Works for headless/server deployments
- Foundation for iOS companion app

## v1.3 — iOS Companion App

### Architecture
- [ ] WebSocket/HTTP relay server in Canopy macOS
- [ ] iOS app connects to Canopy via local network or Tailscale
- [ ] Send commands from iPhone/iPad to any Claude instance
- [ ] View live screenshots on mobile
- [ ] Respond to permission prompts from mobile
- [ ] Push notifications for attention-needed events

### Tech Stack
- SwiftUI (shared views between macOS and iOS where possible)
- Network.framework for Bonjour discovery
- URLSessionWebSocketTask for real-time communication

## v1.4 — Multi-Agent Orchestration

### Workflow Engine
- [ ] Define agent workflows (A → B → C pipelines)
- [ ] Conditional routing based on response content
- [ ] Parallel execution with result aggregation
- [ ] Template library for common patterns (code review, test + fix, research + implement)

### Dashboard
- [ ] Workflow status visualization
- [ ] Cost tracking per agent session
- [ ] Token usage monitoring
- [ ] Session history and replay

## v2.0 — Canopy Cloud

### Team Features
- [ ] Shared agent sessions across team members
- [ ] Permission delegation (approve from any team member's device)
- [ ] Centralized workflow templates
- [ ] Audit trail for all agent actions

### Hosted Infrastructure
- [ ] Cloud-hosted Claude sessions (no local machine needed)
- [ ] Auto-scaling for parallel agent workloads
- [ ] Integration with GitHub, Linear, Slack for trigger-based agents
