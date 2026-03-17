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

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedPill
            } else {
                // Top bar
                topBar

                // Live screen view
                ZStack(alignment: .bottom) {
                    screenView

                    // Prompt overlay (appears when Claude needs input)
                    if let prompt = terminal.activePrompt {
                        promptOverlay(prompt)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)

                // Status bar
                statusBar

                // Input bar
                inputBar

                // Window tabs
                if windowManager.monitoredWindows.count > 1 {
                    windowTabs
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(Color.black)
        .onAppear {
            Task { await windowManager.autoDiscoverAgentWindows() }
            terminal.autoConnect()
        }
    }

    // MARK: - Top Bar (like Zoom meeting controls)

    private var topBar: some View {
        HStack(spacing: 8) {
            // Connection indicator
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

            Spacer()

            // Minimize
            TapIconButton(
                systemName: "chevron.down.2",
                action: { isMinimized = true; onMinimize?() },
                color: .white.opacity(0.7)
            )

            // Expand to full app
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

    // MARK: - Screen View (live screenshot)

    private var screenView: some View {
        Group {
            if let window = selectedWindow, let screenshot = windowManager.screenshots[window.id] {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Color.black)
                    .contentShape(Rectangle())
                    .onTapGesture { windowManager.bringWindowToFront(window) }
            } else {
                Color(white: 0.08)
                    .overlay {
                        VStack(spacing: 10) {
                            Image(systemName: "display")
                                .font(.system(size: 32))
                                .foregroundStyle(.gray.opacity(0.4))
                            Text("No screen to share")
                                .font(.system(size: 12))
                                .foregroundStyle(.gray.opacity(0.5))
                        }
                    }
            }
        }
    }

    // MARK: - Prompt Overlay (action buttons when Claude needs input)

    private func promptOverlay(_ prompt: TerminalBridgeService.TerminalPrompt) -> some View {
        VStack(spacing: 8) {
            // Prompt text
            Text(prompt.text)
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(.white)
                .multilineTextAlignment(.center)
                .lineLimit(3)
                .padding(.horizontal, 12)

            // Option buttons
            HStack(spacing: 8) {
                ForEach(Array(prompt.options.enumerated()), id: \.offset) { index, option in
                    TapButton(
                        label: option,
                        action: {
                            terminal.sendOption(index + 1)
                        },
                        color: .white,
                        bgColor: buttonColor(for: option),
                        font: .system(size: 12, weight: .semibold)
                    )
                }
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
        if l.contains("yes") || l.contains("allow") || l.contains("accept") { return .green.opacity(0.7) }
        if l.contains("no") || l.contains("deny") || l.contains("reject") { return .red.opacity(0.7) }
        return .blue.opacity(0.6)
    }

    // MARK: - Status Bar

    private var statusBar: some View {
        HStack(spacing: 6) {
            if !terminal.lastOutput.isEmpty {
                Text(terminal.lastOutput)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.5))
                    .lineLimit(1)
            } else {
                Text(terminal.isConnected ? "Connected" : "Not connected — run: source ~/.claude/scripts/remote-terminal.sh && remote-terminal")
                    .font(.system(size: 10))
                    .foregroundStyle(.white.opacity(0.4))
                    .lineLimit(1)
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .background(Color(white: 0.08))
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        HStack(spacing: 8) {
            TextField("Send a message...", text: $messageText)
                .textFieldStyle(.plain)
                .font(.system(size: 13))
                .foregroundStyle(.white)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(Color(white: 0.15))
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .onSubmit { sendMessage() }

            TapIconButton(
                systemName: "arrow.up.circle.fill",
                action: sendMessage,
                color: messageText.isEmpty ? .gray : .blue
            )
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(white: 0.1))
    }

    private func sendMessage() {
        guard !messageText.isEmpty else { return }
        terminal.sendCommand(messageText)
        messageText = ""
    }

    // MARK: - Window Tabs

    private var windowTabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(windowManager.monitoredWindows) { window in
                    HStack(spacing: 4) {
                        if let icon = window.icon {
                            Image(nsImage: icon).resizable().frame(width: 12, height: 12)
                        }
                        Text(window.ownerName)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(selectedWindow?.id == window.id ? Color.white.opacity(0.15) : Color.clear)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { selectedWindowID = window.id }
                }
            }
            .padding(.horizontal, 6)
            .padding(.vertical, 4)
        }
        .background(Color(white: 0.08))
    }

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
