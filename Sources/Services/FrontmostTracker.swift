import Foundation
import AppKit

/// Event-driven frontmost window tracker using NSWorkspace notifications + AXObserver.
/// Uses Accessibility API to get the actual focused window (reliable for same-app window switches).
/// Falls back to CGWindowList z-order scan. Also polls every 2s as safety net.
@MainActor
final class FrontmostTracker: ObservableObject {
    @Published var frontmostProjectName: String?
    @Published var frontmostWindowID: CGWindowID?

    private var axObservers: [pid_t: AXObserver] = [:]
    private var pollTask: Task<Void, Never>?
    private let filePath: String = {
        let dir = NSHomeDirectory() + "/Library/Application Support/Canopy/ipc"
        let fm = FileManager.default
        if !fm.fileExists(atPath: dir) {
            try? fm.createDirectory(atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
        return dir + "/canopy-frontmost.txt"
    }()

    func start() {
        // Layer 1: App activation changes
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appActivated(_:)),
            name: NSWorkspace.didActivateApplicationNotification,
            object: nil
        )
        NSWorkspace.shared.notificationCenter.addObserver(
            self,
            selector: #selector(appTerminated(_:)),
            name: NSWorkspace.didTerminateApplicationNotification,
            object: nil
        )

        // Bootstrap for current frontmost app
        if let front = NSWorkspace.shared.frontmostApplication {
            setupAXObserver(for: front)
        }
        updateFrontmostWindow()

        // Safety net: poll every 2s in case AXObserver misses an event
        pollTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(2))
                self?.updateFrontmostWindow()
            }
        }
    }

    func stop() {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTask?.cancel()
        pollTask = nil
        for pid in axObservers.keys {
            teardownAXObserver(for: pid)
        }
    }

    // MARK: - NSWorkspace Notifications

    @objc private func appActivated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        setupAXObserver(for: app)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.updateFrontmostWindow()
        }
    }

    @objc private func appTerminated(_ note: Notification) {
        guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
        teardownAXObserver(for: app.processIdentifier)
    }

    // MARK: - AXObserver (Layer 2: within-app window switches)

    private func setupAXObserver(for app: NSRunningApplication) {
        let pid = app.processIdentifier
        if axObservers[pid] != nil { return }

        var observer: AXObserver?
        let callback: AXObserverCallback = { _, _, _, refcon in
            guard let refcon else { return }
            let tracker = Unmanaged<FrontmostTracker>.fromOpaque(refcon).takeUnretainedValue()
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                tracker.updateFrontmostWindow()
            }
        }

        guard AXObserverCreate(pid, callback, &observer) == .success,
              let observer else { return }

        let axApp = AXUIElementCreateApplication(pid)
        let refcon = UnsafeMutableRawPointer(Unmanaged.passUnretained(self).toOpaque())

        AXObserverAddNotification(observer, axApp, kAXFocusedWindowChangedNotification as CFString, refcon)
        AXObserverAddNotification(observer, axApp, kAXMainWindowChangedNotification as CFString, refcon)

        CFRunLoopAddSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)

        axObservers[pid] = observer
    }

    private func teardownAXObserver(for pid: pid_t) {
        guard let observer = axObservers.removeValue(forKey: pid) else { return }
        CFRunLoopRemoveSource(CFRunLoopGetMain(), AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    // MARK: - Frontmost Detection

    /// Get the actual focused window using Accessibility API (most reliable),
    /// then fall back to CGWindowList z-order.
    private func updateFrontmostWindow() {
        let myPID = ProcessInfo.processInfo.processIdentifier

        // When Canopy itself is frontmost, write a special marker so the hook
        // doesn't block ANY project — the user can see all prompts in Canopy's UI
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier == myPID {
            frontmostProjectName = "__CANOPY_ACTIVE__"
            frontmostWindowID = nil
            try? "__CANOPY_ACTIVE__".write(toFile: filePath, atomically: true, encoding: .utf8)
            return
        }

        // Try AX API first — get the focused window of the frontmost app
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           frontApp.processIdentifier != myPID {
            let axApp = AXUIElementCreateApplication(frontApp.processIdentifier)
            var focusedRef: CFTypeRef?

            if AXUIElementCopyAttributeValue(axApp, kAXFocusedWindowAttribute as CFString, &focusedRef) == .success,
               let focusedWindow = focusedRef {
                // Get the title of the focused window
                var titleRef: CFTypeRef?
                if AXUIElementCopyAttributeValue(focusedWindow as! AXUIElement, kAXTitleAttribute as CFString, &titleRef) == .success,
                   let title = titleRef as? String, !title.isEmpty {

                    // Get the CGWindowID via private API
                    var wid: CGWindowID = 0
                    let axWindow = focusedWindow as! AXUIElement
                    if _AXUIElementGetWindow(axWindow, &wid) == .success {
                        frontmostWindowID = wid
                    } else {
                        frontmostWindowID = nil
                    }

                    // Extract project name from VS Code title "file — ProjectName"
                    let project: String
                    if let dash = title.range(of: " — ", options: .backwards) {
                        project = String(title[dash.upperBound...])
                    } else {
                        project = title
                    }

                    frontmostProjectName = project
                    try? project.write(toFile: filePath, atomically: true, encoding: .utf8)
                    return
                }
            }
        }

        // Fallback: CGWindowList z-order scan
        guard let list = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID
        ) as? [[String: Any]] else { return }

        for info in list {
            guard let pid = info[kCGWindowOwnerPID as String] as? pid_t, pid != myPID,
                  let layer = info[kCGWindowLayer as String] as? Int, layer == 0,
                  let title = info[kCGWindowName as String] as? String, !title.isEmpty,
                  let bounds = info[kCGWindowBounds as String] as? [String: Any],
                  let w = bounds["Width"] as? CGFloat, w > 200
            else { continue }

            let windowID = info[kCGWindowNumber as String] as? CGWindowID

            let project: String
            if let dash = title.range(of: " — ", options: .backwards) {
                project = String(title[dash.upperBound...])
            } else {
                project = title
            }

            frontmostProjectName = project
            frontmostWindowID = windowID
            try? project.write(toFile: filePath, atomically: true, encoding: .utf8)
            return
        }

        frontmostProjectName = nil
        frontmostWindowID = nil
    }

    deinit {
        NSWorkspace.shared.notificationCenter.removeObserver(self)
        pollTask?.cancel()
    }
}
