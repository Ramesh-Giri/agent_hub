import SwiftUI

struct CompactDashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
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

    /// Show names of windows visible in the panel (background ones)
    private var projectName: String {
        let names = visibleWindows.compactMap { window -> String? in
            let title = window.windowTitle
            if let lastDash = title.range(of: " — ", options: .backwards) {
                return String(title[lastDash.upperBound...])
            }
            return !title.isEmpty ? title : window.ownerName
        }
        if names.isEmpty { return "Canopy" }
        return names.joined(separator: " · ")
    }

    /// Show prompts only from BACKGROUND projects (frontmost project's hook doesn't block)
    private var hookPrompt: RemoteControlService.PromptInfo? {
        windowManager.rcService.activePrompt
    }

    /// The frontmost monitored window — only hides a window if the user is ACTUALLY looking at it.
    /// Uses FrontmostTracker (event-driven, ~100ms latency).
    /// Returns nil when the user is on a non-monitored app (Chrome, Finder, etc.) → all windows show.
    private var frontmostMonitoredWindow: MonitoredWindow? {
        // If Canopy itself is frontmost, this is the floating panel — show all windows
        if windowManager.frontmostTracker.frontmostProjectName == "__CANOPY_ACTIVE__" {
            return nil
        }

        // Try matching tracker's window ID directly against monitored windows
        if let trackedID = windowManager.frontmostTracker.frontmostWindowID,
           let match = windowManager.monitoredWindows.first(where: { $0.id == trackedID }) {
            return match
        }

        // Try matching by project name from the tracker
        if let trackedProject = windowManager.frontmostTracker.frontmostProjectName {
            if let match = windowManager.monitoredWindows.first(where: {
                $0.windowTitle.localizedCaseInsensitiveContains(trackedProject) ||
                $0.displayName.localizedCaseInsensitiveContains(trackedProject)
            }) {
                return match
            }
        }

        // No match → user is on a non-monitored app (Chrome, etc.) → show ALL windows
        return nil
    }

    /// Windows to show in the floating panel — exclude the frontmost one
    private var visibleWindows: [MonitoredWindow] {
        guard let front = frontmostMonitoredWindow else {
            return windowManager.monitoredWindows
        }
        return windowManager.monitoredWindows.filter { $0.id != front.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            if isMinimized {
                minimizedPill
            } else {
                topBar

                // Permission prompt banner (top, full width — always visible)
                if let prompt = hookPrompt {
                    promptBanner(prompt)
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
                            HStack(spacing: 4) {
                                ForEach(visibleWindows) { window in
                                    floatingWindowCard(window)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .padding(4)
                        } else if count <= 2 || geo.size.height > geo.size.width * 1.5 {
                            VStack(spacing: 4) {
                                ForEach(visibleWindows) { window in
                                    floatingWindowCard(window)
                                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                                }
                            }
                            .padding(4)
                        } else {
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
        .onAppear { }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(windowManager.rcService.isConnected ? .green : .gray)
                .frame(width: 8, height: 8)

            if let window = selectedWindow, let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 14, height: 14)
            }

            if visibleWindows.count <= 1 {
                Text(projectName)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white)
                    .lineLimit(1)
            }

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
        let isSelected = selectedWindowID == window.id
        return VStack(spacing: 0) {
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

            ZStack {
                Color(white: 0.06)
                if let screenshot = windowManager.screenshots[window.id] {
                    Image(nsImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fill)
                } else {
                    Image(systemName: "terminal").foregroundStyle(.gray.opacity(0.3))
                }
            }
            .aspectRatio(16/10, contentMode: .fit)
            .clipped()
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(
                    isPromptSource ? .orange : (isSelected ? .blue.opacity(0.6) : .white.opacity(0.08)),
                    lineWidth: isPromptSource ? 2 : (isSelected ? 1.5 : 1)
                )
        )
        .contentShape(Rectangle())
        .onTapGesture(count: 2) {
            windowManager.bringWindowToFront(window)
        }
        .onTapGesture(count: 1) {
            selectedWindowID = window.id
        }
    }

    private func promptMatchesWindow(_ prompt: RemoteControlService.PromptInfo?, window: MonitoredWindow) -> Bool {
        guard let cwd = prompt?.cwd else { return false }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        return window.windowTitle.localizedCaseInsensitiveContains(project) ||
               window.displayName.localizedCaseInsensitiveContains(project)
    }

    // MARK: - Permission Prompt Banner

    private func promptBanner(_ prompt: RemoteControlService.PromptInfo) -> some View {
        VStack(spacing: 8) {
            if let cwd = prompt.cwd {
                let source = URL(fileURLWithPath: cwd).lastPathComponent
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill").font(.system(size: 9))
                    Text(source).font(.system(size: 10, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(.blue)
                .clipShape(Capsule())
            }

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
        .padding(10)
        .frame(maxWidth: .infinity)
        .background(.orange.opacity(0.15))
        .overlay(Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)), alignment: .bottom)
    }

    // MARK: - Input Bar

    private var inputBar: some View {
        VStack(spacing: 0) {
            if let error = sendError {
                Text(error)
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(.orange.opacity(0.1))
            }
            HStack(spacing: 8) {
                PanelTextField(
                    placeholder: "Message...",
                    text: $messageText,
                    onSubmit: { sendMessage() }
                )
                .frame(maxWidth: .infinity)

                Text("Send")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 60, height: 28)
                    .background(isSending ? .gray : .blue)
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .contentShape(Rectangle())
                    .onTapGesture { sendMessage() }
            }
            .padding(.horizontal, 8)
            .padding(.vertical, 8)
        }
        .background(Color(white: 0.1))
    }

    /// Target for commands: the selected visible window, or the first visible background window
    private var commandTarget: MonitoredWindow? {
        if let id = selectedWindowID, let w = visibleWindows.first(where: { $0.id == id }) { return w }
        return visibleWindows.first ?? windowManager.monitoredWindows.first
    }

    @State private var isSending = false
    @State private var sendError: String?

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let target = commandTarget else { return }
        // Don't block on isSending — let it queue

        let frozenWindow = MonitoredWindow(
            id: target.id,
            ownerName: target.ownerName,
            windowTitle: target.windowTitle,
            bundleIdentifier: target.bundleIdentifier,
            icon: target.icon
        )

        messageText = ""
        sendError = nil
        NotificationCenter.default.post(name: .init("CanopyClearInput"), object: nil)

        Task {
            let result = await CommandService.sendText(text, to: frozenWindow)
            switch result {
            case .sent:
                sendError = nil
            case .failed(let reason):
                sendError = reason
                // Clear error after 4s
                try? await Task.sleep(for: .seconds(4))
                sendError = nil
            }
        }
    }

    // MARK: - Minimized Pill

    private var minimizedPill: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(windowManager.rcService.isConnected ? .green : .gray)
                .frame(width: 6, height: 6)

            let count = windowManager.monitoredWindows.count
            Text(count > 0 ? "\(count) window\(count == 1 ? "" : "s")" : "Canopy")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.9))

            if hookPrompt != nil {
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
