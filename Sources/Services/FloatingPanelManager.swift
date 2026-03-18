import SwiftUI
import AppKit

class FloatingPanel: NSPanel {
    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

class PanelHostingView<Content: View>: NSHostingView<Content> {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}

@MainActor
final class FloatingPanelManager: NSObject, ObservableObject, NSWindowDelegate {
    private var panel: FloatingPanel?
    private weak var windowManager: WindowManager?
    private var resignTask: Task<Void, Never>?
    private var normalHeight: CGFloat = 480
    private let minimizedHeight: CGFloat = 32
    private var isTransitioning = false

    func setup(windowManager: WindowManager) {
        self.windowManager = windowManager
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidResignActive),
            name: NSApplication.didResignActiveNotification, object: nil
        )
        NotificationCenter.default.addObserver(
            self, selector: #selector(appDidBecomeActive),
            name: NSApplication.didBecomeActiveNotification, object: nil
        )
    }

    @objc private func appDidResignActive() {
        resignTask?.cancel()
        guard !isTransitioning else { return }
        resignTask = Task {
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled, !NSApp.isActive, !self.isTransitioning else { return }
            // Don't show floating panel if user hasn't added any windows
            guard let wm = self.windowManager, !wm.monitoredWindows.isEmpty else { return }
            self.showPanel()
            self.hideMainWindows()
        }
    }

    @objc private func appDidBecomeActive() {
        resignTask?.cancel()
        // If the panel is visible and mouse is inside it, user clicked the panel — don't hide
        let mouse = NSEvent.mouseLocation
        if let panel, panel.isVisible, panel.frame.contains(mouse) { return }
        guard !isTransitioning else { return }
        isTransitioning = true
        showMainWindows()
        hidePanel()
        // Debounce: ignore resign/activate events for a short window
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.isTransitioning = false
        }
    }

    func expandToFullApp() {
        isTransitioning = true
        hidePanel()
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            for window in NSApp.windows where !(window is NSPanel) {
                window.makeKeyAndOrderFront(nil)
            }
        }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
            self?.isTransitioning = false
        }
    }

    func minimizePanel() {
        guard let panel else { return }
        // Remember current height for restore
        normalHeight = panel.frame.height
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y + frame.height - minimizedHeight,
            width: frame.width,
            height: minimizedHeight
        )
        panel.setFrame(newFrame, display: true, animate: true)
    }

    func restorePanel() {
        guard let panel else { return }
        let frame = panel.frame
        let newFrame = NSRect(
            x: frame.origin.x,
            y: frame.origin.y - (normalHeight - minimizedHeight),
            width: frame.width,
            height: normalHeight
        )
        panel.setFrame(newFrame, display: true, animate: true)
    }

    private func showPanel() {
        if panel == nil { createPanel() }
        panel?.orderFront(nil)
        panel?.makeKey()
    }

    private func hidePanel() { panel?.orderOut(nil) }

    private func hideMainWindows() {
        for window in NSApp.windows where !(window is NSPanel) && window.isVisible {
            window.orderOut(nil)
        }
    }

    private func showMainWindows() {
        for window in NSApp.windows where !(window is NSPanel) {
            window.makeKeyAndOrderFront(nil)
        }
    }

    private func createPanel() {
        guard let windowManager else { return }

        let panel = FloatingPanel(
            contentRect: .zero,
            styleMask: [.titled, .resizable, .fullSizeContentView, .utilityWindow, .nonactivatingPanel],
            backing: .buffered, defer: false
        )
        panel.level = .floating
        panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        panel.isFloatingPanel = true
        panel.hidesOnDeactivate = false
        panel.title = ""
        panel.titleVisibility = .hidden
        panel.titlebarAppearsTransparent = true
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.isMovableByWindowBackground = true
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.minSize = NSSize(width: 300, height: minimizedHeight)
        panel.delegate = self

        if let screen = NSScreen.main {
            let w: CGFloat = 360
            let h: CGFloat = normalHeight
            let x = screen.visibleFrame.maxX - w - 16
            let y = screen.visibleFrame.maxY - h - 16
            panel.setFrame(NSRect(x: x, y: y, width: w, height: h), display: true)
        }

        let view = CompactDashboardView(
            onExpand: { [weak self] in
                self?.expandToFullApp()
            },
            onMinimize: { [weak self] in
                self?.minimizePanel()
            },
            onRestore: { [weak self] in
                self?.restorePanel()
            }
        )
        .environmentObject(windowManager)

        panel.contentView = PanelHostingView(rootView: view)
        self.panel = panel
    }

    nonisolated func windowShouldClose(_ sender: NSWindow) -> Bool {
        Task { @MainActor [weak self] in self?.expandToFullApp() }
        return false
    }

    nonisolated func windowWillResize(_ sender: NSWindow, to frameSize: NSSize) -> NSSize {
        return frameSize
    }
}
