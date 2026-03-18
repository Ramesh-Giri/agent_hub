import SwiftUI

struct SettingsView: View {
    @EnvironmentObject var windowManager: WindowManager

    var body: some View {
        Form {
            Section("Display") {
                HStack {
                    Text("Default grid columns")
                    Spacer()
                    Picker("", selection: $windowManager.gridColumns) {
                        Text("1").tag(1)
                        Text("2").tag(2)
                        Text("3").tag(3)
                        Text("4").tag(4)
                    }
                    .pickerStyle(.segmented)
                    .frame(width: 200)
                }
            }

            Section("Notifications") {
                Toggle("Enable attention notifications", isOn: $windowManager.attentionService.notificationsEnabled)

                VStack(alignment: .leading, spacing: 4) {
                    Text("Canopy detects when windows need your attention:")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("  - Prompt waiting (y/n, Continue?, etc.)")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("  - Terminal/agent idle for extended period")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                    Text("  - Window title changes indicating errors")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Section("Claude-mem Integration") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Status")
                            .font(.body)
                        Text("Connects to claude-mem at localhost:37777")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if windowManager.isClaudeMemAvailable {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Connected")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } else {
                        HStack(spacing: 4) {
                            Circle().fill(.red).frame(width: 8, height: 8)
                            Text("Not available")
                                .foregroundStyle(.red)
                                .font(.caption)
                        }
                    }
                }
            }

            Section("Permissions") {
                HStack {
                    VStack(alignment: .leading) {
                        Text("Screen Recording")
                            .font(.body)
                        Text("Required for live window previews and attention detection")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if CGPreflightScreenCaptureAccess() {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Granted")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } else {
                        Button("Grant Permission") {
                            CGRequestScreenCaptureAccess()
                        }
                    }
                }

                HStack {
                    VStack(alignment: .leading) {
                        Text("Accessibility")
                            .font(.body)
                        Text("Required to send input to agent windows")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Spacer()
                    if AXIsProcessTrusted() {
                        HStack(spacing: 4) {
                            Circle().fill(.green).frame(width: 8, height: 8)
                            Text("Granted")
                                .foregroundStyle(.green)
                                .font(.caption)
                        }
                    } else {
                        Button("Open Privacy Settings") {
                            NSWorkspace.shared.open(
                                URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!
                            )
                        }
                    }
                }
            }

            Section("About") {
                HStack {
                    Text("Canopy")
                    Spacer()
                    Text("v1.0.0")
                        .foregroundStyle(.secondary)
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 550, height: 500)
    }
}
