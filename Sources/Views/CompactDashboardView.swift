import SwiftUI

struct CompactDashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
    let onExpand: () -> Void
    var onMinimize: (() -> Void)? = nil
    var onRestore: (() -> Void)? = nil

    @State private var selectedWindowID: CGWindowID?
    @State private var commandText = ""
    @State private var isMinimized = false

    private var rcService: RemoteControlService { windowManager.rcService }

    private var selectedWindow: MonitoredWindow? {
        let windows = windowManager.monitoredWindows
        if let id = selectedWindowID, let w = windows.first(where: { $0.id == id }) { return w }
        return windows.first
    }

    /// Total prompt count across all queues
    private var totalPromptCount: Int {
        rcService.pendingPrompts.count + (rcService.activePrompt != nil ? 1 : 0)
    }

    /// The prompt that belongs to the currently selected window (by matching project name to window title)
    private var promptForSelectedWindow: RemoteControlService.ControlPrompt? {
        guard let selected = selectedWindow else { return nil }
        // Check active prompt
        if let prompt = rcService.activePrompt, promptMatchesWindow(prompt, window: selected) {
            return prompt
        }
        // Check pending prompts
        return rcService.pendingPrompts.first { promptMatchesWindow($0, window: selected) }
    }

    /// Does this window have a prompt waiting?
    private func windowHasPrompt(_ window: MonitoredWindow) -> Bool {
        if let prompt = rcService.activePrompt, promptMatchesWindow(prompt, window: window) { return true }
        return rcService.pendingPrompts.contains { promptMatchesWindow($0, window: window) }
    }

    private func promptMatchesWindow(_ prompt: RemoteControlService.ControlPrompt, window: MonitoredWindow) -> Bool {
        guard let project = prompt.projectName else { return false }
        return window.windowTitle.localizedCaseInsensitiveContains(project) ||
               window.displayName.localizedCaseInsensitiveContains(project)
    }

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedPill
            } else {
                DragHandleBar(
                    onExpand: onExpand,
                    rcConnected: rcService.isConnected,
                    pendingCount: totalPromptCount,
                    onMinimize: {
                        isMinimized = true
                        onMinimize?()
                    }
                )

                // RC Prompt — only show if the selected window has one
                if let prompt = promptForSelectedWindow {
                    promptCard(prompt)
                }

                if windowManager.monitoredWindows.isEmpty {
                    emptyState
                } else {
                    ScrollView(.vertical, showsIndicators: false) {
                        VStack(spacing: 4) {
                            ForEach(windowManager.monitoredWindows) { window in
                                CompactWindowCard(
                                    window: window,
                                    screenshot: windowManager.screenshots[window.id],
                                    attention: windowManager.attentionService.attentionWindows[window.id],
                                    isSelected: selectedWindow?.id == window.id,
                                    rcConnected: rcService.isConnected,
                                    hasPrompt: windowHasPrompt(window),
                                    onSelect: { selectedWindowID = window.id },
                                    onBringToFront: { windowManager.bringWindowToFront(window) }
                                )
                            }
                        }
                        .padding(6)
                    }

                    Divider()
                    commandField
                }

                // RC status
                if !rcService.isConnected {
                    rcStatusBar
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .background(.ultraThinMaterial)
        .onAppear {
            Task { await windowManager.autoDiscoverAgentWindows() }
        }
        .onChange(of: rcService.activePrompt?.id) { _, _ in
            guard let prompt = rcService.activePrompt else { return }
            // Auto-restore if minimized
            if isMinimized {
                isMinimized = false
                onRestore?()
            }
            // Auto-select the matching window
            if let project = prompt.projectName {
                if let match = windowManager.monitoredWindows.first(where: {
                    $0.windowTitle.localizedCaseInsensitiveContains(project) ||
                    $0.displayName.localizedCaseInsensitiveContains(project)
                }) {
                    selectedWindowID = match.id
                }
            }
        }
    }

    // MARK: - Minimized Pill

    private var minimizedPill: some View {
        HStack(spacing: 8) {
            // RC status dot
            if rcService.isConnected {
                Circle().fill(.green).frame(width: 6, height: 6)
            } else {
                Circle().fill(.gray).frame(width: 6, height: 6)
            }

            // Window count
            let count = windowManager.monitoredWindows.count
            Text(count > 0 ? "\(count) window\(count == 1 ? "" : "s")" : "AgentHub")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            // Attention badge
            let attentionCount = windowManager.attentionService.attentionWindows.count
            if attentionCount > 0 {
                Text("\(attentionCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
            }

            Spacer()

            // Restore button
            TapIconButton(
                systemName: "chevron.up.2",
                action: {
                    isMinimized = false
                    onRestore?()
                },
                color: .white
            )

            // Expand to full app
            TapIconButton(systemName: "arrow.up.left.and.arrow.down.right", action: onExpand, color: .white)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(.black.opacity(0.5))
        .contentShape(Rectangle())
        .onTapGesture {
            isMinimized = false
            onRestore?()
        }
    }

    // MARK: - RC Prompt Card

    private func promptCard(_ prompt: RemoteControlService.ControlPrompt) -> some View {
        VStack(spacing: 8) {
            // Project badge
            if let project = prompt.projectName {
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 9))
                    Text(project)
                        .font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue.opacity(0.6))
                .clipShape(Capsule())
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            // Header
            HStack(spacing: 6) {
                Image(systemName: prompt.isAskQuestion ? "questionmark.circle.fill" : "lock.shield.fill")
                    .font(.system(size: 13))
                    .foregroundStyle(prompt.isAskQuestion ? .purple : .blue)
                Text(prompt.displayText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(3)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Tool details (for non-ask prompts)
            if !prompt.isAskQuestion {
                toolDetailView(prompt)
            }

            // Action buttons
            if prompt.isAskQuestion {
                askQuestionButtons(prompt)
            } else {
                permissionButtons(prompt)
            }
        }
        .padding(10)
        .background(prompt.isAskQuestion ? .purple.opacity(0.08) : .blue.opacity(0.08))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(prompt.isAskQuestion ? .purple.opacity(0.3) : .blue.opacity(0.3), lineWidth: 1)
        )
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
    }

    /// Shows tool input details (command, file path, etc.)
    @ViewBuilder
    private func toolDetailView(_ prompt: RemoteControlService.ControlPrompt) -> some View {
        if let command = prompt.toolInput["command"] as? String {
            Text(command)
                .font(.system(size: 10, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(3)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(6)
                .background(Color(.textBackgroundColor).opacity(0.5))
                .clipShape(RoundedRectangle(cornerRadius: 4))
        } else if let filePath = prompt.toolInput["file_path"] as? String {
            HStack(spacing: 4) {
                Image(systemName: "doc.text")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text(filePath)
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Permission buttons: Allow, Always Allow (from suggestions), Deny
    private func permissionButtons(_ prompt: RemoteControlService.ControlPrompt) -> some View {
        VStack(spacing: 6) {
            // Primary row: Allow + Deny
            HStack(spacing: 8) {
                TapButton(
                    label: "Allow",
                    action: { rcService.respondToPrompt(allow: true) },
                    color: .white, bgColor: .green,
                    font: .system(size: 11, weight: .bold)
                )
                TapButton(
                    label: "Deny",
                    action: { rcService.respondToPrompt(allow: false) },
                    color: .white, bgColor: .red,
                    font: .system(size: 11, weight: .bold)
                )
            }

            // Permission suggestion buttons (Always Allow, Don't Ask Again, etc.)
            if !prompt.permissionSuggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(prompt.permissionSuggestions) { suggestion in
                        TapButton(
                            label: suggestion.label,
                            action: { rcService.respondToPrompt(allow: true, applySuggestion: suggestion) },
                            color: .blue,
                            bgColor: .blue.opacity(0.12),
                            font: .system(size: 10, weight: .semibold)
                        )
                    }
                }
            }
        }
    }

    /// AskUserQuestion buttons: exact options from the API
    private func askQuestionButtons(_ prompt: RemoteControlService.ControlPrompt) -> some View {
        VStack(spacing: 4) {
            ForEach(prompt.askOptions) { option in
                TapButton(
                    label: option.label,
                    action: { rcService.respondToQuestion(answer: option.label) },
                    color: .white,
                    bgColor: .purple.opacity(0.7),
                    font: .system(size: 11, weight: .semibold)
                )
                .frame(maxWidth: .infinity)
            }

            // Fallback if no options parsed — just allow/deny
            if prompt.askOptions.isEmpty {
                HStack(spacing: 8) {
                    TapButton(
                        label: "Allow",
                        action: { rcService.respondToPrompt(allow: true) },
                        color: .white, bgColor: .green,
                        font: .system(size: 11, weight: .bold)
                    )
                    TapButton(
                        label: "Deny",
                        action: { rcService.respondToPrompt(allow: false) },
                        color: .white, bgColor: .red,
                        font: .system(size: 11, weight: .bold)
                    )
                }
            }
        }
    }

    // MARK: - Command Field

    private var commandField: some View {
        HStack(spacing: 6) {
            if let window = selectedWindow, let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }

            if promptForSelectedWindow != nil {
                // Only block when THIS window has a prompt
                Text("Waiting for prompt response...")
                    .font(.system(size: 12, design: .monospaced))
                    .foregroundStyle(.tertiary)
                    .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                TextField(
                    selectedWindow.map { "Send to \($0.displayName)..." } ?? "Select a window...",
                    text: $commandText
                )
                .textFieldStyle(.plain)
                .font(.system(size: 12, design: .monospaced))
                .onSubmit { sendCommand() }

                if !commandText.isEmpty {
                    TapIconButton(systemName: "return", action: sendCommand, color: .blue)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.bar)
    }

    // MARK: - RC Status

    private var rcStatusBar: some View {
        HStack(spacing: 6) {
            if let error = rcService.error {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.system(size: 9))
                    .foregroundStyle(.orange)
                Text(error)
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                Spacer()
                TapButton(label: "Retry", action: { rcService.start() },
                          font: .system(size: 9, weight: .semibold))
            } else {
                Image(systemName: "antenna.radiowaves.left.and.right")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
                Text("Hook not active — waiting for prompts")
                    .font(.system(size: 9))
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(.bar)
    }

    // MARK: - Empty / Actions

    private var emptyState: some View {
        VStack(spacing: 8) {
            Spacer()
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 24))
                .foregroundStyle(.tertiary)
            Text("No agent windows")
                .font(.system(size: 11))
                .foregroundStyle(.tertiary)
            TapButton(label: "Add Windows", action: onExpand,
                      color: .blue, font: .system(size: 10, weight: .medium))
            Spacer()
        }
        .frame(maxWidth: .infinity)
    }

    private func sendCommand() {
        guard let window = selectedWindow else { return }
        // Bring the window to front — keystroke injection doesn't work with Claude Code's Ink terminal
        windowManager.bringWindowToFront(window)
        commandText = ""
    }
}

// MARK: - Drag Bar

struct DragHandleBar: View {
    let onExpand: () -> Void
    var rcConnected: Bool = false
    var pendingCount: Int = 0
    var onMinimize: (() -> Void)? = nil

    var body: some View {
        HStack(spacing: 0) {
            RoundedRectangle(cornerRadius: 2)
                .fill(.white.opacity(0.3))
                .frame(width: 36, height: 4)
                .padding(.leading, 12)

            if rcConnected {
                HStack(spacing: 3) {
                    Circle().fill(.green).frame(width: 5, height: 5)
                    Text("RC").font(.system(size: 9, weight: .bold)).foregroundStyle(.green)
                }
                .padding(.leading, 8)
            }

            if pendingCount > 0 {
                Text("\(pendingCount)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(.orange)
                    .clipShape(Capsule())
                    .padding(.leading, 6)
            }

            Spacer()

            // Minimize to pill
            TapIconButton(
                systemName: "chevron.down.2",
                action: { onMinimize?() },
                color: .white
            )
            .padding(.trailing, 4)

            // Expand to full app
            TapIconButton(systemName: "arrow.up.left.and.arrow.down.right", action: onExpand, color: .white)
                .padding(.trailing, 8)
        }
        .frame(height: 28)
        .background(.black.opacity(0.4))
    }
}

// MARK: - Window Card

struct CompactWindowCard: View {
    let window: MonitoredWindow
    let screenshot: NSImage?
    let attention: WindowAttention?
    let isSelected: Bool
    let rcConnected: Bool
    var hasPrompt: Bool = false
    let onSelect: () -> Void
    let onBringToFront: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 6) {
                if let icon = window.icon {
                    Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                }
                Text(window.displayName)
                    .font(.system(size: 12, weight: .semibold))
                    .lineLimit(1)
                Spacer()
                if rcConnected {
                    Text("RC")
                        .font(.system(size: 8, weight: .heavy))
                        .foregroundStyle(.green)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(.green.opacity(0.15))
                        .clipShape(RoundedRectangle(cornerRadius: 3))
                }
                if hasPrompt {
                    // Pulsing indicator for active prompt
                    Circle()
                        .fill(.blue)
                        .frame(width: 8, height: 8)
                        .overlay(
                            Circle()
                                .stroke(.blue.opacity(0.5), lineWidth: 2)
                                .scaleEffect(1.5)
                        )
                } else if attention != nil {
                    Circle().fill(.orange).frame(width: 8, height: 8)
                }
                TapIconButton(systemName: "macwindow", action: onBringToFront)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(.bar)

            Group {
                if let screenshot {
                    Image(nsImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: .infinity)
                } else {
                    Rectangle()
                        .fill(.quaternary)
                        .aspectRatio(16/10, contentMode: .fit)
                        .frame(maxWidth: .infinity)
                        .overlay {
                            Image(systemName: "terminal").font(.title2).foregroundStyle(.tertiary)
                        }
                }
            }

            if let attention {
                HStack(spacing: 4) {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(attention.promptText ?? attention.reason.rawValue)
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.orange)
                        .lineLimit(1)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(.orange.opacity(0.06))
            }
        }
        .background(Color(.windowBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: (isSelected || hasPrompt) ? 2 : 1)
        )
        .contentShape(Rectangle())
        .onTapGesture { onSelect() }
    }

    private var borderColor: Color {
        if hasPrompt { return .blue }
        if isSelected { return .blue.opacity(0.7) }
        if attention != nil { return .orange.opacity(0.5) }
        return .gray.opacity(0.15)
    }
}
