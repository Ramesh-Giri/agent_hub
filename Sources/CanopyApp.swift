import SwiftUI

@main
struct CanopyApp: App {
    @StateObject private var windowManager = WindowManager()
    @State private var showPermissionSetup = false
    private let floatingPanel = FloatingPanelManager()

    @AppStorage("hasShownPermissionSetup") private var hasShownPermissionSetup = false

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(windowManager)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    windowManager.setup()
                    floatingPanel.setup(windowManager: windowManager)
                    // Only show permission dialog on first ever launch
                    if !hasShownPermissionSetup {
                        if !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() {
                            showPermissionSetup = true
                            hasShownPermissionSetup = true
                        }
                    }
                    NotificationCenter.default.addObserver(
                        forName: NSApplication.willTerminateNotification,
                        object: nil, queue: .main
                    ) { _ in
                        windowManager.rcService.stop()
                    }
                }
                .sheet(isPresented: $showPermissionSetup) {
                    PermissionSetupView()
                        .environmentObject(windowManager)
                }
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 1200, height: 800)

        Settings {
            SettingsView()
                .environmentObject(windowManager)
        }
    }
}
