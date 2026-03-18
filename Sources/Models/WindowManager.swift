import Foundation
import AppKit
import Combine

/// Central state manager for all monitored windows and their interactions
@MainActor
final class WindowManager: ObservableObject {
    @Published var monitoredWindows: [MonitoredWindow] = []
    @Published var screenshots: [CGWindowID: NSImage] = [:]
    @Published var gridColumns: Int = 2

    // Context from claude-mem
    @Published var windowContext: [CGWindowID: [MemoryEntry]] = [:]
    @Published var isClaudeMemAvailable = false

    // Attention detection
    @Published var attentionService = AttentionDetectionService()

    // Permission prompt handling
    @Published var rcService = RemoteControlService()

    // Event-driven frontmost window tracking
    @Published var frontmostTracker = FrontmostTracker()

    let sharingManager = ContentSharingManager()
    private let discoveryService = WindowDiscoveryService()
    private let interactionService = WindowInteractionService()
    private let claudeMemService = ClaudeMemService()
    private var titleMonitorTask: Task<Void, Never>?
    private var contextTask: Task<Void, Never>?

    /// Called once at app launch
    func setup() {
        Task {
            isClaudeMemAvailable = await claudeMemService.isAvailable()
        }

        // Notifications
        attentionService.requestNotificationPermission()
        attentionService.onNotificationAction = { [weak self] windowID, action in
            guard let self, let window = self.monitoredWindows.first(where: { $0.id == windowID }) else { return }
            switch action {
            case .bringToFront, .sendYes, .sendNo, .sendText:
                self.bringWindowToFront(window)
            }
        }

        // Start RC service (hook installation + prompt watching)
        rcService.start()

        // Start event-driven frontmost tracking (replaces 1s polling)
        frontmostTracker.start()
    }

    func addWindow(_ window: MonitoredWindow) {
        guard !monitoredWindows.contains(where: { $0.id == window.id }) else { return }
        guard !monitoredWindows.contains(where: {
            $0.ownerName == window.ownerName && $0.windowTitle == window.windowTitle
        }) else { return }
        let wasEmpty = monitoredWindows.isEmpty
        monitoredWindows.append(window)

        // Activate hook interception when first window is added
        if wasEmpty {
            rcService.activateHook()
        }

        if titleMonitorTask == nil {
            startTitleMonitoring()
        }

        Task { await fetchContextForWindow(window) }
    }

    func removeWindow(_ window: MonitoredWindow) {
        monitoredWindows.removeAll { $0.id == window.id }
        screenshots.removeValue(forKey: window.id)
        windowContext.removeValue(forKey: window.id)
        attentionService.cleanupWindow(window.id)
        if monitoredWindows.isEmpty {
            stopTitleMonitoring()
            rcService.deactivateHook()
        }
    }

    func removeWindow(byID id: CGWindowID) {
        monitoredWindows.removeAll { $0.id == id }
        screenshots.removeValue(forKey: id)
        windowContext.removeValue(forKey: id)
        attentionService.cleanupWindow(id)
        if monitoredWindows.isEmpty {
            stopTitleMonitoring()
            rcService.deactivateHook()
        }
    }

    func discoverWindows() async -> [DiscoveredWindow] {
        await discoveryService.discoverWindows()
    }

    /// Auto-discover and add known agent/terminal windows
    func autoDiscoverAgentWindows() async {
        let discovered = await discoveryService.discoverWindows()
        for window in discovered where WindowDiscoveryService.isKnownAgentApp(window.bundleIdentifier) {
            addWindow(window.toMonitored())
        }
    }

    var hasAccessibilityPermission: Bool {
        interactionService.hasAccessibilityPermission
    }

    func requestAccessibilityPermission() {
        interactionService.requestAccessibilityPermission()
    }

    func bringWindowToFront(_ window: MonitoredWindow) {
        attentionService.clearAttention(windowID: window.id)
        interactionService.bringToFront(windowID: window.id, ownerName: window.ownerName)
    }

    func sendTextToWindow(_ window: MonitoredWindow, text: String) {
        attentionService.clearAttention(windowID: window.id)
        interactionService.sendText(text, toWindowID: window.id, ownerName: window.ownerName)
    }

    // MARK: - Monitoring

    private func startTitleMonitoring() {
        titleMonitorTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }

                for window in self.monitoredWindows {
                    if let image = self.sharingManager.captureWindow(window.id) {
                        self.screenshots[window.id] = image
                    }
                }

                let titles = self.getCurrentWindowTitles()
                self.attentionService.checkWindows(
                    windows: self.monitoredWindows,
                    screenshots: self.screenshots,
                    titles: titles
                )
                try? await Task.sleep(for: .seconds(2))
            }
        }

        contextTask = Task { [weak self] in
            while !Task.isCancelled {
                guard let self else { return }
                await self.refreshAllContext()
                try? await Task.sleep(for: .seconds(30))
            }
        }
    }

    private func stopTitleMonitoring() {
        titleMonitorTask?.cancel()
        titleMonitorTask = nil
        contextTask?.cancel()
        contextTask = nil
    }

    private func getCurrentWindowTitles() -> [CGWindowID: String] {
        var titles: [CGWindowID: String] = [:]
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]] else {
            return titles
        }
        let monitoredIDs = Set(monitoredWindows.map(\.id))
        for info in windowList {
            if let windowID = info[kCGWindowNumber as String] as? CGWindowID,
               monitoredIDs.contains(windowID),
               let title = info[kCGWindowName as String] as? String {
                titles[windowID] = title
            }
        }
        return titles
    }

    private func fetchContextForWindow(_ window: MonitoredWindow) async {
        guard isClaudeMemAvailable else { return }
        let query = window.windowTitle.isEmpty ? window.ownerName : window.windowTitle
        let entries = await claudeMemService.search(query: query)
        if !entries.isEmpty { windowContext[window.id] = entries }
    }

    private func refreshAllContext() async {
        guard isClaudeMemAvailable else {
            isClaudeMemAvailable = await claudeMemService.isAvailable()
            return
        }
        for window in monitoredWindows { await fetchContextForWindow(window) }
    }

    deinit {
        titleMonitorTask?.cancel()
        contextTask?.cancel()
    }
}
