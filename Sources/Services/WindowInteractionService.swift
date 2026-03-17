import Foundation
import AppKit

/// Brings windows to front and sends keystrokes via Accessibility + CGEvent APIs.
final class WindowInteractionService {

    var hasAccessibilityPermission: Bool {
        AXIsProcessTrusted()
    }

    func requestAccessibilityPermission() {
        let options = [kAXTrustedCheckOptionPrompt.takeUnretainedValue(): true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }

    /// Bring a window's application to the front
    func bringToFront(windowID: CGWindowID, ownerName: String) {
        guard let app = findApp(ownerName) else { return }
        app.activate(options: .activateIgnoringOtherApps)

        let appElement = AXUIElementCreateApplication(app.processIdentifier)
        var windowsRef: CFTypeRef?
        let result = AXUIElementCopyAttributeValue(appElement, kAXWindowsAttribute as CFString, &windowsRef)

        if result == .success, let windows = windowsRef as? [AXUIElement] {
            for window in windows {
                var windowIDRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(window, "_AXWindowID" as CFString, &windowIDRef) == .success,
                   let wid = windowIDRef as? CGWindowID,
                   wid == windowID {
                    AXUIElementPerformAction(window, kAXRaiseAction as CFString)
                    return
                }
            }
            if let firstWindow = windows.first {
                AXUIElementPerformAction(firstWindow, kAXRaiseAction as CFString)
            }
        }
    }

    /// Send text + Return to a window via CGEvent keystroke injection.
    /// Brings the window to front first, waits briefly for focus, then types.
    func sendText(_ text: String, toWindowID windowID: CGWindowID, ownerName: String) {
        bringToFront(windowID: windowID, ownerName: ownerName)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            Self.postKeystrokes(text)
            Self.postReturn()
        }
    }

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
