import SwiftUI

@main
struct AgentHubApp: App {
    @StateObject private var windowManager = WindowManager()
    @State private var showPermissionSetup = false
    private let floatingPanel = FloatingPanelManager()

    var body: some Scene {
        WindowGroup {
            DashboardView()
                .environmentObject(windowManager)
                .frame(minWidth: 800, minHeight: 500)
                .task {
                    windowManager.setup()
                    floatingPanel.setup(windowManager: windowManager)
                    if !CGPreflightScreenCaptureAccess() || !AXIsProcessTrusted() {
                        showPermissionSetup = true
                    }
                    // Clean up presence file on quit so hooks fall through to normal Claude Code
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
