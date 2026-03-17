import SwiftUI

struct CompactDashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
    @StateObject private var terminal = TerminalBridgeService()
    let onExpand: () -> Void
    var onMinimize: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil

    @State private var isMinimized = false
    @State private var messageText = ""
    @State private var selectedWindowID: CGWindowID?

    private var selectedWindow: MonitoredWindow? {
        let windows = windowManager.monitoredWindows
        if let id = selectedWindowID, let w = windows.first(where: { $0.id == id }) { return w }
        return windows.first
    }

    private var projectName: String {
        guard let window = selectedWindow else { return "AgentHub" }
        let title = window.windowTitle
        if let lastDash = title.range(of: " — ", options: .backwards) {
            return String(title[lastDash.upperBound...])
        }
        return !title.isEmpty ? title : window.ownerName
    }

    /// Active prompt from the hook system
    private var hookPrompt: RemoteControlService.PromptInfo? {
        windowManager.rcService.activePrompt
    }

    /// Windows to show in the floating panel — exclude the frontmost one
    private var visibleWindows: [MonitoredWindow] {
        let frontApp = NSWorkspace.shared.frontmostApplication
        return windowManager.monitoredWindows.filter { window in
            // Hide windows belonging to the frontmost app
            if let frontBundleID = frontApp?.bundleIdentifier,
               let windowBundleID = window.bundleIdentifier,
               frontBundleID == windowBundleID {
                // Same app — check if this specific window title matches the frontmost
                // For multi-window apps like VS Code, only hide the active instance
                if let frontName = frontApp?.localizedName,
                   window.ownerName == frontName {
                    // If only one window from this app, hide it
                    let sameAppWindows = windowManager.monitoredWindows.filter { $0.bundleIdentifier == windowBundleID }
                    if sameAppWindows.count <= 1 { return false }
                    // Multiple windows — show all (we can't tell which is focused)
                    return true
                }
                return false
            }
            return true
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedPill
            } else {
                topBar

                // Prompt overlay
                if let prompt = hookPrompt {
                    actionOverlay(prompt)
                }

                // Window grid
                if visibleWindows.isEmpty {
                    Color(white: 0.05)
                        .overlay {
                            VStack(spacing: 8) {
                                Image(systemName: "display")
                                    .font(.system(size: 28))
                                    .foregroundStyle(.gray.opacity(0.4))
                                Text(windowManager.monitoredWindows.isEmpty
                                     ? "No windows detected"
                                     : "All windows in foreground")
                                    .font(.system(size: 11))
                                    .foregroundStyle(.gray.opacity(0.5))
                            }
                        }
                        .frame(maxHeight: .infinity)
                } else {
                    // Adapt layout to panel shape
                    GeometryReader { geo in
                        let isWide = geo.size.width > geo.size.height
                        let count = visibleWindows.count

                        if isWide {
                            // Horizontal: side by side
                            HStack(spacing: 4) {
                                ForEach(visibleWindows) { window in
                                    floatingWindowCard(window)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .padding(4)
                        } else if count <= 2 || geo.size.height > geo.size.width * 1.5 {
                            // Tall: stack vertically
                            VStack(spacing: 4) {
                                ForEach(visibleWindows) { window in
                                    floatingWindowCard(window)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .padding(4)
                        } else {
                            // Square-ish: 2-column grid
                            let cols = [GridItem(.flexible(), spacing: 4), GridItem(.flexible(), spacing: 4)]
                            LazyVGrid(columns: cols, spacing: 4) {
                                ForEach(visibleWindows) { window in
                                    floatingWindowCard(window)
                                        .frame(height: (geo.size.height - 12) / ceil(Double(count) / 2))
                                }
                            }
                            .padding(4)
                        }
                    }
                }

                // Input bar
                inputBar
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(Color.black)
        .onAppear {
            Task { await windowManager.autoDiscoverAgentWindows() }
            terminal.autoConnect()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(terminal.isConnected ? .green : .gray)
                .frame(width: 8, height: 8)

            if let window = selectedWindow, let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }

            Text(projectName)
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(.white)
                .lineLimit(1)

            if hookPrompt != nil {
                Text("Action")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange)
                    .clipShape(Capsule())
            }

            Spacer()

            TapIconButton(
                systemName: "chevron.down.2",
                action: { isMinimized = true; onMinimize?() },
                color: .white.opacity(0.7)
            )

            TapIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                action: onExpand,
                color: .white.opacity(0.7)
            )
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color(white: 0.12))
    }

    // MARK: - Window Card (for floating grid)

    private func floatingWindowCard(_ window: MonitoredWindow) -> some View {
        let isPromptSource = promptMatchesWindow(hookPrompt, window: window)
        return VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 4) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                }
                Text(window.displayName)
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
                Spacer()
                if isPromptSource {
                    Circle().fill(.orange).frame(width: 6, height: 6)
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 3)
            .background(Color(white: 0.12))

            // Screenshot — natural aspect ratio
            if let screenshot = windowManager.screenshots[window.id] {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity)
            } else {
                Color(white: 0.06)
                    .aspectRatio(16/10, contentMode: .fit)
                    .overlay {
                        Image(systemName: "terminal").foregroundStyle(.gray.opacity(0.3))
                    }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(isPromptSource ? .orange : .white.opacity(0.08), lineWidth: isPromptSource ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture {
            selectedWindowID = window.id
            windowManager.bringWindowToFront(window)
        }
    }

    private func promptMatchesWindow(_ prompt: RemoteControlService.PromptInfo?, window: MonitoredWindow) -> Bool {
        guard let cwd = prompt?.cwd else { return false }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        return window.windowTitle.localizedCaseInsensitiveContains(project) ||
               window.displayName.localizedCaseInsensitiveContains(project)
    }

    // MARK: - Action Overlay (dynamic buttons from hook-detected prompts)

    private func actionOverlay(_ prompt: RemoteControlService.PromptInfo) -> some View {
        VStack(spacing: 8) {
            Text(prompt.description)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.white)
                .lineLimit(2)
                .padding(.horizontal, 12)

            HStack(spacing: 8) {
                TapButton(
                    label: "Allow",
                    action: { windowManager.rcService.respondToPrompt(allow: true) },
                    color: .white, bgColor: .green.opacity(0.7),
                    font: .system(size: 12, weight: .bold)
                )
                TapButton(
                    label: "Deny",
                    action: { windowManager.rcService.respondToPrompt(allow: false) },
                    color: .white, bgColor: .red.opacity(0.7),
                    font: .system(size: 12, weight: .bold)
                )
            }
        }
        .padding(12)
        .background(.ultraThinMaterial)
        .background(Color.black.opacity(0.5))
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .shadow(color: .black.opacity(0.3), radius: 8)
        .padding(8)
        .transition(.move(edge: .bottom).combined(with: .opacity))
    }

    private func buttonColor(for label: String) -> Color {
        let l = label.lowercased()
        if l.contains("yes") || l.contains("allow") || l.contains("accept") || l.contains("1.") { return .green.opacity(0.7) }
        if l.contains("no") || l.contains("deny") || l.contains("reject") || l.contains("3.") { return .red.opacity(0.7) }
        return .blue.opacity(0.6)
    }

    /// Send a keystroke to the selected window (for action buttons)
    private func sendKeystroke(_ text: String) {
        guard let window = selectedWindow else { return }
        let pid = Self.findPID(for: window)

        windowManager.bringWindowToFront(window)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let utf16 = Array(text.utf16)
            for i in stride(from: 0, to: utf16.count, by: 20) {
                let end = min(i + 20, utf16.count)
                var chunk = Array(utf16[i..<end])
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                if let pid { down?.postToPid(pid) } else { down?.post(tap: .cghidEventTap) }
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false)
                if let pid { up?.postToPid(pid) } else { up?.post(tap: .cghidEventTap) }
            }

            // Clear the attention after responding
            Task { @MainActor [weak windowManager] in
                if let wid = window.id as CGWindowID? {
                    windowManager?.attentionService.clearAttention(windowID: wid)
                }
            }
        }
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            PanelTextField(
                placeholder: "Send a message...",
                text: $messageText,
                onSubmit: { sendMessage() }
            )
            .frame(height: 34)

            PanelSendButton(title: "  Send  ") {
                sendMessage()
            }
            .frame(height: 30)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let window = selectedWindow else { return }
        messageText = ""
        // Force-clear any NSTextField showing our text
        NotificationCenter.default.post(name: .init("AgentHubClearInput"), object: nil)

        // Get the target app's PID
        let pid = Self.findPID(for: window)

        // Bring window to front
        windowManager.bringWindowToFront(window)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            // Send text in 20-char chunks (CGEvent max per event)
            let utf16 = Array(text.utf16)
            for i in stride(from: 0, to: utf16.count, by: 20) {
                let end = min(i + 20, utf16.count)
                var chunk = Array(utf16[i..<end])
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                if let pid { down?.postToPid(pid) } else { down?.post(tap: .cghidEventTap) }
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false)
                if let pid { up?.postToPid(pid) } else { up?.post(tap: .cghidEventTap) }
                Thread.sleep(forTimeInterval: 0.005)
            }

            // Send Enter
            Thread.sleep(forTimeInterval: 0.02)
            let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true)
            if let pid { enterDown?.postToPid(pid) } else { enterDown?.post(tap: .cghidEventTap) }
            let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)
            if let pid { enterUp?.postToPid(pid) } else { enterUp?.post(tap: .cghidEventTap) }
        }
    }

    private static func findPID(for window: MonitoredWindow) -> pid_t? {
        guard let apps = NSWorkspace.shared.runningApplications as [NSRunningApplication]? else { return nil }
        let app = apps.first {
            $0.bundleIdentifier == window.bundleIdentifier ||
            $0.localizedName == window.ownerName
        }
        return app?.processIdentifier
    }

    // MARK: - Window Tabs

    // MARK: - Minimized Pill

    private var minimizedPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(terminal.isConnected ? .green : .gray)
                .frame(width: 6, height: 6)

            let count = windowManager.monitoredWindows.count
            Text(count > 0 ? "\(count) window\(count == 1 ? "" : "s")" : "AgentHub")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            if terminal.activePrompt != nil {
                Text("Action needed")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.orange)
                    .clipShape(Capsule())
            }

            Spacer()

            TapIconButton(
                systemName: "chevron.up.2",
                action: { isMinimized = false; onRestore?() },
                color: .white
            )
            TapIconButton(
                systemName: "arrow.up.left.and.arrow.down.right",
                action: onExpand,
                color: .white
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Color.black.opacity(0.7))
        .contentShape(Rectangle())
        .onTapGesture { isMinimized = false; onRestore?() }
    }
}
