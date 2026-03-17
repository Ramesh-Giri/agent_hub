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

    /// Show names of windows visible in the panel (background ones)
    private var projectName: String {
        let names = visibleWindows.compactMap { window -> String? in
            let title = window.windowTitle
            if let lastDash = title.range(of: " — ", options: .backwards) {
                return String(title[lastDash.upperBound...])
            }
            return !title.isEmpty ? title : window.ownerName
        }
        if names.isEmpty { return "AgentHub" }
        return names.joined(separator: " · ")
    }

    /// Show prompts only from BACKGROUND projects (frontmost project's hook doesn't block)
    private var hookPrompt: RemoteControlService.PromptInfo? {
        windowManager.rcService.activePrompt
    }

    /// Write the frontmost project name to a file so the hook knows which project is visible
    private func startFrontmostTracking() {
        Task {
            while true {
                try? await Task.sleep(for: .seconds(1))
                if let front = frontmostMonitoredWindow {
                    let title = front.windowTitle
                    let project: String
                    if let dash = title.range(of: " — ", options: .backwards) {
                        project = String(title[dash.upperBound...])
                    } else {
                        project = title
                    }
                    let path = FileManager.default.temporaryDirectory.path + "/agenthub-frontmost.txt"
                    try? project.write(toFile: path, atomically: true, encoding: .utf8)
                }
            }
        }
    }

    /// Find the frontmost monitored window by checking ALL on-screen windows in z-order.
    /// The floating panel is non-activating, so the frontmost app might still be AgentHub.
    /// Instead, scan the window list in z-order and find the topmost MONITORED window.
    private var frontmostMonitoredWindow: MonitoredWindow? {
        guard let windowList = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return nil }

        let monitoredIDs = Set(windowManager.monitoredWindows.map(\.id))
        let myPID = ProcessInfo.processInfo.processIdentifier

        for info in windowList {
            guard let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  ownerPID != myPID, // Skip our own windows
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? CGFloat, w > 200
            else { continue }

            // Direct ID match
            if monitoredIDs.contains(windowID) {
                return windowManager.monitoredWindows.first { $0.id == windowID }
            }

            // Title match (window IDs may have changed since discovery)
            if let title = info[kCGWindowName as String] as? String, !title.isEmpty {
                if let match = windowManager.monitoredWindows.first(where: { $0.windowTitle == title }) {
                    return match
                }
            }
        }
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
            startFrontmostTracking()
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

            // Only show title when one or zero windows (cards already have titles)
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

    // MARK: - Permission Prompt Banner (top, full width)

    private func promptBanner(_ prompt: RemoteControlService.PromptInfo) -> some View {
        VStack(spacing: 8) {
            // Show which project triggered the prompt
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

    private func buttonColor(for label: String) -> Color {
        let l = label.lowercased()
        if l.contains("yes") || l.contains("allow") || l.contains("accept") || l.contains("1.") { return .green.opacity(0.7) }
        if l.contains("no") || l.contains("deny") || l.contains("reject") || l.contains("3.") { return .red.opacity(0.7) }
        return .blue.opacity(0.6)
    }

    /// Send a keystroke to a specific window — brings it to front, types, then restores
    private func sendKeystrokeToWindow(_ text: String, window: MonitoredWindow) {
        // Bring the TARGET window to front
        windowManager.bringWindowToFront(window)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.4) {
            let pid = Self.findPID(for: window)
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
        }
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

    /// Target for commands: the window shown in the floating panel (background one)
    /// The user is already typing in the frontmost window — floating panel targets the OTHER window
    private var commandTarget: MonitoredWindow? {
        if let id = selectedWindowID, let w = visibleWindows.first(where: { $0.id == id }) { return w }
        return visibleWindows.first ?? windowManager.monitoredWindows.first
    }

    private func sendMessage() {
        let text = messageText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let window = commandTarget else { return }
        messageText = ""
        NotificationCenter.default.post(name: .init("AgentHubClearInput"), object: nil)

        let title = window.windowTitle
        let project: String
        if let lastDash = title.range(of: " — ", options: .backwards) {
            project = String(title[lastDash.upperBound...])
        } else {
            project = title
        }

        // 1. Save clipboard
        let pasteboard = NSPasteboard.general
        let saved = pasteboard.string(forType: .string)

        // 2. Set text on clipboard
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        // 3. Raise the correct window (AXRaise BEFORE activate)
        Self.raiseWindowByProjectName(project, ownerName: window.ownerName)

        // 4. Wait, verify, paste, enter
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.7) {
            // Verify correct window is in front
            if !Self.verifyFrontWindow(contains: project) {
                // Retry
                DispatchQueue.main.sync {
                    Self.raiseWindowByProjectName(project, ownerName: window.ownerName)
                }
                Thread.sleep(forTimeInterval: 0.5)
            }

            // Cmd+V paste (single operation — fast and reliable)
            let src = CGEventSource(stateID: .hidSystemState)
            let vDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true)
            vDown?.flags = .maskCommand
            vDown?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)?.post(tap: .cghidEventTap)

            Thread.sleep(forTimeInterval: 0.15)

            // Enter
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: true)?.post(tap: .cghidEventTap)
            CGEvent(keyboardEventSource: src, virtualKey: 0x24, keyDown: false)?.post(tap: .cghidEventTap)

            // Restore clipboard
            Thread.sleep(forTimeInterval: 0.3)
            DispatchQueue.main.async {
                pasteboard.clearContents()
                if let s = saved { pasteboard.setString(s, forType: .string) }
            }
        }
    }

    /// Check if the topmost non-AgentHub window contains the project name
    private static func verifyFrontWindow(contains project: String) -> Bool {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else { return false }
        let myPID = ProcessInfo.processInfo.processIdentifier
        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let t = info[kCGWindowName as String] as? String,
                  let b = info[kCGWindowBounds as String] as? [String: Any],
                  let w = b["Width"] as? CGFloat, w > 200 else { continue }
            return t.localizedCaseInsensitiveContains(project)
        }
        return false
    }

    /// Raise a specific window: AXRaise first, THEN activate app
    private static func raiseWindowByProjectName(_ projectName: String, ownerName: String) {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == ownerName
        }) else { return }

        let axApp = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            app.activate()
            return
        }

        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            if let axTitle = titleRef as? String,
               axTitle.localizedCaseInsensitiveContains(projectName) {
                // Raise FIRST, then activate — ensures this specific window comes to front
                AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
                app.activate()
                return
            }
        }
        app.activate()
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
