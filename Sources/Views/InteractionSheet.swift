import SwiftUI

struct InteractionSheet: View {
    let window: MonitoredWindow
    @EnvironmentObject var windowManager: WindowManager
    @Environment(\.dismiss) private var dismiss

    @State private var inputText = ""
    @State private var recentCommands: [String] = ["y", "n", "yes", "no"]

    private var speech: SpeechService { windowManager.speechService }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 20, height: 20)
                }
                Text("Interact: \(window.displayName)")
                    .font(.headline)
                    .lineLimit(1)
                Spacer()
                Button("Close") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            .padding()

            Divider()

            // Accessibility permission check
            if !windowManager.hasAccessibilityPermission {
                accessibilityBanner
            }

            // Live preview (if available)
            if let screenshot = windowManager.screenshots[window.id] {
                Image(nsImage: screenshot)
                    .resizable()
                    .aspectRatio(contentMode: .fit)
                    .frame(maxHeight: 300)
                    .clipShape(RoundedRectangle(cornerRadius: 4))
                    .padding(.horizontal)
                    .padding(.top, 8)
            }

            // Quick actions
            VStack(spacing: 12) {
                Text("Quick Responses")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    ForEach(recentCommands, id: \.self) { command in
                        Button(command) {
                            sendCommand(command)
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                    }
                }

                Divider()

                // Voice input
                VStack(spacing: 8) {
                    HStack(spacing: 12) {
                        Button {
                            if speech.isListening {
                                speech.stopListening()
                                if !speech.transcript.isEmpty {
                                    sendCommand(speech.transcript)
                                }
                            } else {
                                speech.startListening()
                            }
                        } label: {
                            HStack(spacing: 6) {
                                Image(systemName: speech.isListening ? "mic.fill" : "mic")
                                    .foregroundStyle(speech.isListening ? .red : .primary)
                                Text(speech.isListening ? "Stop & Send" : "Voice Input")
                            }
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.large)
                        .disabled(!speech.isAvailable)

                        if speech.isListening {
                            Circle()
                                .fill(.red)
                                .frame(width: 8, height: 8)
                                .opacity(0.8)
                            Text("Listening...")
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }

                    if !speech.transcript.isEmpty {
                        Text(speech.transcript)
                            .font(.body)
                            .padding(8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.quaternary)
                            .clipShape(RoundedRectangle(cornerRadius: 6))
                    }

                    if !speech.isAvailable {
                        Text("Microphone/Speech permission needed — check System Settings")
                            .font(.caption2)
                            .foregroundStyle(.orange)
                    }
                }

                Divider()

                // Custom input
                HStack {
                    TextField("Type a command...", text: $inputText)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit {
                            guard !inputText.isEmpty else { return }
                            sendCommand(inputText)
                            inputText = ""
                        }

                    Button("Send") {
                        guard !inputText.isEmpty else { return }
                        sendCommand(inputText)
                        inputText = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(inputText.isEmpty)

                    Button {
                        windowManager.bringWindowToFront(window)
                    } label: {
                        Image(systemName: "macwindow")
                    }
                    .help("Switch to window")
                }
            }
            .padding()

            Divider()

            // Bring to front
            HStack {
                Spacer()
                Button {
                    windowManager.bringWindowToFront(window)
                    dismiss()
                } label: {
                    Label("Switch to Window", systemImage: "macwindow.and.cursorarrow")
                }
                .controlSize(.large)
            }
            .padding()
        }
        .frame(minWidth: 550, minHeight: 450)
        .onDisappear {
            if speech.isListening {
                speech.stopListening()
            }
        }
    }

    private var accessibilityBanner: some View {
        HStack(spacing: 12) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title3)
                .foregroundStyle(.orange)

            VStack(alignment: .leading, spacing: 2) {
                Text("Accessibility permission needed")
                    .font(.callout)
                    .fontWeight(.medium)
                Text("Required to send keystrokes to agent windows")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button("Grant Access") {
                windowManager.requestAccessibilityPermission()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)
        }
        .padding(12)
        .background(.orange.opacity(0.1))
    }

    private func sendCommand(_ command: String) {
        // Keystroke injection not supported — bring window to front for manual input
        windowManager.bringWindowToFront(window)
    }
}
