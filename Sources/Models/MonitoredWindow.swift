import Foundation
import AppKit

/// Represents a window the user has chosen to monitor
struct MonitoredWindow: Identifiable, Hashable {
    let id: CGWindowID
    let ownerName: String
    let windowTitle: String
    let bundleIdentifier: String?
    let icon: NSImage?

    var displayName: String {
        if windowTitle.isEmpty {
            return ownerName
        }
        return "\(ownerName) — \(windowTitle)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: MonitoredWindow, rhs: MonitoredWindow) -> Bool {
        lhs.id == rhs.id
    }
}

/// Represents a discovered window available for monitoring
struct DiscoveredWindow: Identifiable, Hashable {
    let id: CGWindowID
    let ownerName: String
    let ownerPID: pid_t
    let windowTitle: String
    let bundleIdentifier: String?
    let icon: NSImage?
    let bounds: CGRect
    let isOnScreen: Bool

    var displayName: String {
        if windowTitle.isEmpty {
            return ownerName
        }
        return "\(ownerName) — \(windowTitle)"
    }

    func hash(into hasher: inout Hasher) {
        hasher.combine(id)
    }

    static func == (lhs: DiscoveredWindow, rhs: DiscoveredWindow) -> Bool {
        lhs.id == rhs.id
    }

    func toMonitored() -> MonitoredWindow {
        MonitoredWindow(
            id: id,
            ownerName: ownerName,
            windowTitle: windowTitle,
            bundleIdentifier: bundleIdentifier,
            icon: icon
        )
    }
}
