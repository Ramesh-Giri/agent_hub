import SwiftUI
import AppKit

struct PermissionSetupView: View {
    @EnvironmentObject var windowManager: WindowManager
    @Environment(\.dismiss) private var dismiss

    @State private var hasScreenRecording = false
    @State private var hasAccessibility = false

    private var allGranted: Bool {
        hasScreenRecording && hasAccessibility
    }

    var body: some View {
        VStack(spacing: 24) {
            VStack(spacing: 8) {
                Image(systemName: "shield.checkered")
                    .font(.system(size: 48))
                    .foregroundStyle(.blue)

                Text("AgentHub Permissions")
                    .font(.title2)
                    .fontWeight(.bold)

                Text("AgentHub needs two permissions to monitor and interact with your AI agent windows.")
                    .font(.body)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 400)
            }

            VStack(spacing: 12) {
                permissionRow(
                    title: "Screen Recording",
                    description: "Live window previews and attention detection",
                    icon: "rectangle.inset.filled.and.person.filled",
                    isGranted: hasScreenRecording,
                    action: { windowManager.sharingManager.requestPermission() }
                )

                permissionRow(
                    title: "Accessibility",
                    description: "Send text and keystrokes to agent windows",
                    icon: "hand.tap",
                    isGranted: hasAccessibility,
                    action: { windowManager.requestAccessibilityPermission() }
                )
            }

            Text("After granting, you may need to relaunch AgentHub for changes to take effect.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)

            HStack {
                Button("Skip for now") { dismiss() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.secondary)

                Spacer()

                Button("Refresh") { checkPermissions() }
                    .buttonStyle(.bordered)

                Button(allGranted ? "Done" : "Continue Anyway") { dismiss() }
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(32)
        .frame(width: 520, height: 420)
        .task { checkPermissions() }
    }

    private func permissionRow(
        title: String,
        description: String,
        icon: String,
        isGranted: Bool,
        action: @escaping () -> Void
    ) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon)
                .font(.title2)
                .frame(width: 36)
                .foregroundStyle(isGranted ? .green : .orange)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.body)
                    .fontWeight(.medium)
                Text(description)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            if isGranted {
                Image(systemName: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.title3)
            } else {
                Button("Grant") { action() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }
        }
        .padding(12)
        .background(isGranted ? Color.green.opacity(0.05) : Color.orange.opacity(0.05))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    private func checkPermissions() {
        hasScreenRecording = CGPreflightScreenCaptureAccess()
        hasAccessibility = AXIsProcessTrusted()
    }
}
