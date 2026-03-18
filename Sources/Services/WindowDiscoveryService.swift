import Foundation
import AppKit

/// Discovers available windows on the system for monitoring.
/// Uses CGWindowListCopyWindowInfo exclusively (no ScreenCaptureKit) to avoid TCC permission dialogs.
final class WindowDiscoveryService {

    /// System/utility apps to always exclude
    private static let excludedOwnerNames: Set<String> = [
        "Canopy",
        "WindowManager",
        "AutoFill",
        "loginwindow",
        "Spotlight",
        "ShareSheetUI",
        "legacyScreenSaver",
        "SystemUIServer",
        "Control Center",
        "Dock",
        "Notification Center",
        "ScreenCaptureKit",
        "universalAccessAuthWarn",
        "TextInputMenuAgent",
        "TextInputSwitcher",
        "CoreServicesUIAgent",
        "AXVisualSupportAgent",
    ]

    /// Discover all windows using CGWindowListCopyWindowInfo
    func discoverWindows() async -> [DiscoveredWindow] {
        guard let windowList = CGWindowListCopyWindowInfo([.optionAll, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return []
        }

        let windows = windowList.compactMap { info -> DiscoveredWindow? in
            guard let windowID = info[kCGWindowNumber as String] as? CGWindowID,
                  let ownerName = info[kCGWindowOwnerName as String] as? String,
                  let ownerPID = info[kCGWindowOwnerPID as String] as? pid_t,
                  let boundsDict = info[kCGWindowBounds as String] as? [String: Any],
                  let x = boundsDict["X"] as? CGFloat,
                  let y = boundsDict["Y"] as? CGFloat,
                  let w = boundsDict["Width"] as? CGFloat,
                  let h = boundsDict["Height"] as? CGFloat,
                  w > 200, h > 150,
                  let layer = info[kCGWindowLayer as String] as? Int,
                  layer == 0
            else { return nil }

            // Skip system utilities
            guard !Self.excludedOwnerNames.contains(ownerName) else { return nil }

            let title = info[kCGWindowName as String] as? String ?? ""
            let app = NSRunningApplication(processIdentifier: ownerPID)
            let bundleID = app?.bundleIdentifier
            let onScreen = info[kCGWindowIsOnscreen as String] as? Bool ?? false

            return DiscoveredWindow(
                id: windowID,
                ownerName: ownerName,
                ownerPID: ownerPID,
                windowTitle: title,
                bundleIdentifier: bundleID,
                icon: app?.icon,
                bounds: CGRect(x: x, y: y, width: w, height: h),
                isOnScreen: onScreen
            )
        }

        return sortWindows(deduplicateWindows(windows))
    }

    /// Check if a bundle ID matches known AI/dev tools
    static func isKnownAgentApp(_ bundleID: String?) -> Bool {
        AppCatalog.isKnownApp(bundleID)
    }

    /// Remove ghost windows from Electron apps.
    /// A ghost = same PID + same title (or empty title when titled windows exist).
    /// Keeps ALL distinct windows from the same process (multiple VS Code projects).
    private func deduplicateWindows(_ windows: [DiscoveredWindow]) -> [DiscoveredWindow] {
        var byPID: [pid_t: [DiscoveredWindow]] = [:]
        for window in windows {
            byPID[window.ownerPID, default: []].append(window)
        }

        var result: [DiscoveredWindow] = []
        for (_, group) in byPID {
            if group.count == 1 {
                result.append(group[0])
                continue
            }

            let titled = group.filter { !$0.windowTitle.isEmpty }
            let untitled = group.filter { $0.windowTitle.isEmpty }

            // Keep all titled windows, deduped by title (same title = ghost duplicate)
            var seenTitles: Set<String> = []
            for w in titled {
                if seenTitles.insert(w.windowTitle).inserted {
                    result.append(w)
                }
            }

            // Keep untitled windows ONLY if there are no titled ones
            // (they're likely ghosts when titled windows exist)
            if titled.isEmpty {
                // No titled windows at all — keep the best untitled one
                let best = untitled.max { a, b in
                    if a.isOnScreen != b.isOnScreen { return !a.isOnScreen }
                    return (a.bounds.width * a.bounds.height) < (b.bounds.width * b.bounds.height)
                }
                if let best { result.append(best) }
            }
        }
        return result
    }

    private func sortWindows(_ windows: [DiscoveredWindow]) -> [DiscoveredWindow] {
        windows.sorted { lhs, rhs in
            let lhsKnown = AppCatalog.isKnownApp(lhs.bundleIdentifier)
            let rhsKnown = AppCatalog.isKnownApp(rhs.bundleIdentifier)
            if lhsKnown != rhsKnown { return lhsKnown }
            if lhs.isOnScreen != rhs.isOnScreen { return lhs.isOnScreen }
            if lhs.ownerName != rhs.ownerName { return lhs.ownerName < rhs.ownerName }
            return lhs.id < rhs.id
        }
    }
}
