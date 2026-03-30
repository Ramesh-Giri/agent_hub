import Foundation
import AppKit
import UserNotifications

/// Tracks whether a monitored window needs user attention
struct WindowAttention: Identifiable {
    let id: CGWindowID
    let reason: AttentionReason
    let timestamp: Date
    let promptText: String?
    let contextLines: [String]

    enum AttentionReason: String {
        case inputNeeded = "Waiting for input"
        case titleChanged = "Activity detected"
        case errorDetected = "Error detected"
        case processIdle = "Process idle"
        case promptDetected = "Prompt waiting"
        case responseComplete = "Response complete"
    }
}

/// Detects when monitored windows need user attention by:
/// 1. Monitoring window title changes for prompt patterns
/// 2. Detecting idle/stale screenshots (pure terminals only)
@MainActor
final class AttentionDetectionService: NSObject, ObservableObject, UNUserNotificationCenterDelegate {
    @Published var attentionWindows: [CGWindowID: WindowAttention] = [:]
    @Published var notificationsEnabled = true

    enum NotificationAction {
        case bringToFront
        case sendYes
        case sendNo
        case sendText(String)
    }

    var onNotificationAction: ((CGWindowID, NotificationAction) -> Void)?

    private var previousTitles: [CGWindowID: String] = [:]
    private var unchangedFrameCount: [CGWindowID: Int] = [:]
    private var changedFrameCount: [CGWindowID: Int] = [:]
    private var previousScreenshots: [CGWindowID: NSImage] = [:]
    private var lastNotificationTime: [CGWindowID: Date] = [:]
    private let notificationCooldown: TimeInterval = 30
    /// Minimum frames of active change before we consider a "stop" as response complete
    private let activeThreshold = 3
    /// Frames of stability after activity to trigger responseComplete
    private let stableThreshold = 3

    /// Patterns indicating the terminal is waiting for user input (title-based only)
    private static let inputPatterns: [String] = [
        "(y/n)", "(Y/n)", "(y/N)", "(yes/no)",
        "[y/n]", "[Y/n]", "[y/N]", "[yes/no]",
        "Continue?", "Proceed?", "Confirm?",
        "Overwrite?", "Allow?", "Accept?",
        "Press Enter", "press enter",
        "waiting for input",
    ]

    private static let errorPatterns: [String] = [
        "Error:", "FAILED", "FATAL",
        "Permission denied",
        "panic:", "Traceback",
        "Build failed",
    ]

    private static let actionYes = "ACTION_YES"
    private static let actionNo = "ACTION_NO"
    private static let actionOpen = "ACTION_OPEN"
    private static let actionReply = "ACTION_REPLY"
    private static let categoryID = "ATTENTION"

    func requestNotificationPermission() {
        let center = UNUserNotificationCenter.current()
        center.delegate = self
        center.requestAuthorization(options: [.alert, .sound, .badge]) { _, _ in }

        let yesAction = UNNotificationAction(identifier: Self.actionYes, title: "Yes", options: [])
        let noAction = UNNotificationAction(identifier: Self.actionNo, title: "No", options: [])
        let openAction = UNNotificationAction(identifier: Self.actionOpen, title: "Open Window", options: [.foreground])
        let replyAction = UNTextInputNotificationAction(
            identifier: Self.actionReply, title: "Reply...", options: [],
            textInputButtonTitle: "Send", textInputPlaceholder: "Type response..."
        )

        let category = UNNotificationCategory(
            identifier: Self.categoryID,
            actions: [yesAction, noAction, openAction, replyAction],
            intentIdentifiers: [], options: []
        )
        center.setNotificationCategories([category])
    }

    /// Check all monitored windows for attention signals
    func checkWindows(
        windows: [MonitoredWindow],
        screenshots: [CGWindowID: NSImage],
        titles: [CGWindowID: String]
    ) {
        for window in windows {
            let windowID = window.id
            let isPureTerminal = AppCatalog.pureTerminalBundleIDs.contains(window.bundleIdentifier ?? "")

            // Title-based detection
            if let newTitle = titles[windowID],
               let oldTitle = previousTitles[windowID],
               newTitle != oldTitle {
                if Self.inputPatterns.contains(where: { newTitle.localizedCaseInsensitiveContains($0) }) {
                    flagAttention(windowID: windowID, reason: .promptDetected, windowName: window.displayName, promptText: newTitle)
                } else if Self.errorPatterns.contains(where: { newTitle.localizedCaseInsensitiveContains($0) }) {
                    flagAttention(windowID: windowID, reason: .errorDetected, windowName: window.displayName, promptText: newTitle)
                }
            }

            // Screenshot change detection
            if let currentShot = screenshots[windowID],
               let previousShot = previousScreenshots[windowID] {
                if imagesAreSimilar(currentShot, previousShot) {
                    // Screenshot stable
                    unchangedFrameCount[windowID, default: 0] += 1
                    let wasActive = changedFrameCount[windowID, default: 0] >= activeThreshold

                    if unchangedFrameCount[windowID, default: 0] >= 10 && isPureTerminal {
                        flagAttention(windowID: windowID, reason: .processIdle, windowName: window.displayName, promptText: nil)
                    }

                    // Response complete: was actively changing, now stable
                    if wasActive && unchangedFrameCount[windowID, default: 0] >= stableThreshold {
                        if attentionWindows[windowID]?.reason != .responseComplete {
                            flagAttention(windowID: windowID, reason: .responseComplete, windowName: window.displayName, promptText: "Claude finished responding")
                        }
                        changedFrameCount[windowID] = 0
                    }
                } else {
                    // Screenshot changed — activity in progress
                    changedFrameCount[windowID, default: 0] += 1
                    unchangedFrameCount[windowID] = 0
                    if attentionWindows[windowID]?.reason == .processIdle ||
                       attentionWindows[windowID]?.reason == .responseComplete {
                        clearAttention(windowID: windowID)
                    }
                }
            }

            previousScreenshots[windowID] = screenshots[windowID]
            if let title = titles[windowID] {
                previousTitles[windowID] = title
            }
        }
    }

    // MARK: - Image Comparison

    private func imagesAreSimilar(_ a: NSImage, _ b: NSImage) -> Bool {
        guard abs(a.size.width - b.size.width) < 2,
              abs(a.size.height - b.size.height) < 2 else { return false }

        let size = NSSize(width: 32, height: 32)
        guard let aData = downsample(a, to: size),
              let bData = downsample(b, to: size) else { return false }

        guard aData.count == bData.count else { return false }
        var diffCount = 0
        let threshold = aData.count / 5
        for i in 0..<aData.count {
            if abs(Int(aData[i]) - Int(bData[i])) > 15 {
                diffCount += 1
                if diffCount > threshold { return false }
            }
        }
        return true
    }

    private func downsample(_ image: NSImage, to size: NSSize) -> Data? {
        guard let bitmapRep = NSBitmapImageRep(
            bitmapDataPlanes: nil, pixelsWide: Int(size.width), pixelsHigh: Int(size.height),
            bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
            colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0
        ) else { return nil }

        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: bitmapRep)
        image.draw(in: NSRect(origin: .zero, size: size))
        NSGraphicsContext.restoreGraphicsState()

        return bitmapRep.representation(using: .png, properties: [:])
    }

    // MARK: - Attention Management

    func flagAttention(windowID: CGWindowID, reason: WindowAttention.AttentionReason, windowName: String, promptText: String?, contextLines: [String] = []) {
        if let existing = attentionWindows[windowID],
           existing.reason == reason,
           existing.promptText == promptText { return }

        let attention = WindowAttention(id: windowID, reason: reason, timestamp: Date(), promptText: promptText, contextLines: contextLines)
        attentionWindows[windowID] = attention

        if notificationsEnabled {
            sendNotification(windowID: windowID, windowName: windowName, reason: reason, promptText: promptText)
        }
    }

    func clearAttention(windowID: CGWindowID) {
        attentionWindows.removeValue(forKey: windowID)
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ["attention-\(windowID)"])
    }

    func clearAll() {
        let ids = attentionWindows.keys.map { "attention-\($0)" }
        attentionWindows.removeAll()
        UNUserNotificationCenter.current().removeDeliveredNotifications(withIdentifiers: ids)
    }

    func cleanupWindow(_ windowID: CGWindowID) {
        previousTitles.removeValue(forKey: windowID)
        previousScreenshots.removeValue(forKey: windowID)
        unchangedFrameCount.removeValue(forKey: windowID)
        changedFrameCount.removeValue(forKey: windowID)
        lastNotificationTime.removeValue(forKey: windowID)
        clearAttention(windowID: windowID)
    }

    // MARK: - Notifications

    private func sendNotification(windowID: CGWindowID, windowName: String, reason: WindowAttention.AttentionReason, promptText: String?) {
        if let lastTime = lastNotificationTime[windowID],
           Date().timeIntervalSince(lastTime) < notificationCooldown { return }
        lastNotificationTime[windowID] = Date()

        let content = UNMutableNotificationContent()
        content.title = "Canopy"
        content.subtitle = windowName
        content.body = promptText ?? reason.rawValue
        content.sound = .default
        content.categoryIdentifier = Self.categoryID
        content.userInfo = ["windowID": windowID]

        let request = UNNotificationRequest(identifier: "attention-\(windowID)", content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification, withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void) {
        completionHandler([.banner, .sound, .badge])
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse, withCompletionHandler completionHandler: @escaping () -> Void) {
        let userInfo = response.notification.request.content.userInfo
        guard let windowID = userInfo["windowID"] as? UInt32 else { completionHandler(); return }
        let wid = CGWindowID(windowID)

        let action: NotificationAction
        switch response.actionIdentifier {
        case Self.actionYes: action = .sendYes
        case Self.actionNo: action = .sendNo
        case Self.actionOpen, UNNotificationDefaultActionIdentifier: action = .bringToFront
        case Self.actionReply:
            if let textResponse = response as? UNTextInputNotificationResponse {
                action = .sendText(textResponse.userText)
            } else { action = .bringToFront }
        default: action = .bringToFront
        }

        Task { @MainActor [weak self] in self?.onNotificationAction?(wid, action) }
        completionHandler()
    }
}
