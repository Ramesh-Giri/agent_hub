import Foundation
import AppKit

// Private API: bridges AXUIElement to CGWindowID (used by alt-tab-macos, stable across macOS 10.x–15.x)
@_silgen_name("_AXUIElementGetWindow")
func _AXUIElementGetWindow(_ element: AXUIElement, _ windowID: inout CGWindowID) -> AXError

/// Brings windows to front and sends keystrokes via Accessibility + CGEvent APIs.
/// Uses multi-signal approach (AXRaise + kAXMainAttribute + activate + kAXFocusedAttribute)
/// for reliable window targeting among multiple same-PID windows (e.g., multiple VS Code instances).
final class WindowInteractionService {

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Bring a specific window to front using multi-signal approach.
    /// Prefers CGWindowID matching via _AXUIElementGetWindow, falls back to title matching.
    func bringToFront(windowID: CGWindowID, ownerName: String) {
        guard let app = findApp(ownerName) else { return }
        let pid = app.processIdentifier

        // Try to find the AXUIElement by CGWindowID first (most reliable)
        if let axWindow = Self.findAXWindowByID(windowID, pid: pid) {
            Self.raiseWithMultiSignal(axWindow: axWindow, app: app)
            return
        }

        // Fallback: iterate windows and match by _AXWindowID attribute
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        if AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
           let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var windowIDRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "_AXWindowID" as CFString, &windowIDRef) == .success,
                   let wid = windowIDRef as? CGWindowID,
                   wid == windowID {
                    Self.raiseWithMultiSignal(axWindow: window, app: app)
                    return
                }
            }
            // Last resort: raise first window
            if let firstWindow = windows.first {
                Self.raiseWithMultiSignal(axWindow: firstWindow, app: app)
                return
            }
        }

        app.activate()
    }

    /// Raise a specific window by project name (for command sending targeting).
    /// Uses CGWindowID matching when available, falls back to title matching.
    /// Returns the matched AXUIElement for verify-and-retry.
    @discardableResult
    static func raiseByProjectName(
        _ projectName: String,
        windowID: CGWindowID? = nil,
        ownerName: String
    ) -> AXUIElement? {
        guard let app = NSWorkspace.shared.runningApplications.first(where: {
            $0.localizedName == ownerName
        }) else { return nil }

        let pid = app.processIdentifier

        // Prefer CGWindowID match
        if let wid = windowID, let axWindow = findAXWindowByID(wid, pid: pid) {
            raiseWithMultiSignal(axWindow: axWindow, app: app)
            return axWindow
        }

        // Fall back to title match
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else {
            app.activate()
            return nil
        }

        for axWindow in axWindows {
            var titleRef: CFTypeRef?
            AXUIElementCopyAttributeValue(axWindow, kAXTitleAttribute as CFString, &titleRef)
            if let axTitle = titleRef as? String,
               axTitle.localizedCaseInsensitiveContains(projectName) {
                raiseWithMultiSignal(axWindow: axWindow, app: app)
                return axWindow
            }
        }

        app.activate()
        return nil
    }

    /// Multi-signal raise: AXRaise -> kAXMainAttribute -> activate -> kAXFocusedAttribute
    /// Order matters: raise BEFORE activate so the app knows which window should be frontmost.
    private static func raiseWithMultiSignal(axWindow: AXUIElement, app: NSRunningApplication) {
        // Signal 1: AXRaise (reorders within app's window stack)
        AXUIElementPerformAction(axWindow, kAXRaiseAction as CFString)
        // Signal 2: Set as main window
        AXUIElementSetAttributeValue(axWindow, kAXMainAttribute as CFString, kCFBooleanTrue)
        // Signal 3: Activate the app (brings to front of all apps)
        app.activate()
        // Signal 4: Set focused (belt-and-suspenders for apps that ignore kAXMain)
        AXUIElementSetAttributeValue(axWindow, kAXFocusedAttribute as CFString, kCFBooleanTrue)
    }

    /// Find AXUIElement matching a CGWindowID using the private _AXUIElementGetWindow API.
    /// More reliable than title matching — CGWindowIDs are unique and stable.
    static func findAXWindowByID(_ targetID: CGWindowID, pid: pid_t) -> AXUIElement? {
        let axApp = AXUIElementCreateApplication(pid)
        var windowsRef: CFTypeRef?
        guard AXUIElementCopyAttributeValue(axApp, kAXWindowsAttribute as CFString, &windowsRef) == .success,
              let axWindows = windowsRef as? [AXUIElement] else { return nil }

        for axWindow in axWindows {
            var wid: CGWindowID = 0
            if _AXUIElementGetWindow(axWindow, &wid) == .success, wid == targetID {
                return axWindow
            }
        }
        return nil
    }

    /// Verify that the frontmost non-Canopy window contains the expected project name.
    static func verifyFrontWindow(contains project: String) -> Bool {
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return false }
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

    // CGEvent keystroke methods kept for potential future use but not actively called

    private static func postKeystrokes(_ text: String) {
        let source = CGEventSource(stateID: .hidSystemState)
        for char in text {
            let utf16 = Array(String(char).utf16)
            if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: true) {
                keyDown.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyDown.post(tap: .cghidEventTap)
            }
            if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0, keyDown: false) {
                keyUp.keyboardSetUnicodeString(stringLength: utf16.count, unicodeString: utf16)
                keyUp.post(tap: .cghidEventTap)
            }
        }
    }

    private static func postReturn() {
        let source = CGEventSource(stateID: .hidSystemState)
        if let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: true) {
            keyDown.post(tap: .cghidEventTap)
        }
        if let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 0x24, keyDown: false) {
            keyUp.post(tap: .cghidEventTap)
        }
    }

    private func findApp(_ ownerName: String) -> NSRunningApplication? {
        NSWorkspace.shared.runningApplications.first {
            $0.localizedName == ownerName
        } ?? NSWorkspace.shared.runningApplications.first {
            $0.bundleURL?.deletingPathExtension().lastPathComponent == ownerName
        }
    }
}
