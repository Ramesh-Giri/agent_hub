import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
    @State private var showingWindowPicker = false
    @State private var selectedWindow: MonitoredWindow?
    @State private var commandText = ""

    private var attentionCount: Int {
        windowManager.attentionService.attentionWindows.count
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 8), count: windowManager.gridColumns)
    }

    private var hookPrompt: RemoteControlService.PromptInfo? {
        windowManager.rcService.activePrompt
    }

    private func promptMatchesWindow(_ prompt: RemoteControlService.PromptInfo?, window: MonitoredWindow) -> Bool {
        guard let cwd = prompt?.cwd else { return false }
        let project = URL(fileURLWithPath: cwd).lastPathComponent
        return window.windowTitle.localizedCaseInsensitiveContains(project) ||
               window.displayName.localizedCaseInsensitiveContains(project)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Permission prompt banner — only show when windows are being monitored
            if !windowManager.monitoredWindows.isEmpty, let prompt = hookPrompt {
                promptBanner(prompt)
            }

            if windowManager.monitoredWindows.isEmpty {
                emptyState
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVGrid(columns: columns, spacing: 8) {
                        ForEach(windowManager.monitoredWindows) { window in
                            let isPromptSource = promptMatchesWindow(hookPrompt, window: window)
                            WindowThumbnailView(
                                window: window,
                                screenshot: windowManager.screenshots[window.id],
                                onSelect: {
                                    selectedWindow = window
                                    windowManager.bringWindowToFront(window)
                                },
                                onRemove: { windowManager.removeWindow(window) }
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: 10)
                                    .stroke(isPromptSource ? .orange : (selectedWindow?.id == window.id ? .blue : .clear), lineWidth: isPromptSource ? 3 : 2)
                            )
                            .shadow(color: isPromptSource ? .orange.opacity(0.4) : .clear, radius: 8)
                        }
                    }
                    .padding(8)
                }

                // Command input bar
                commandBar
            }
        }
        .background(Color(.windowBackgroundColor))
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Button {
                    showingWindowPicker = true
                } label: {
                    Image(systemName: "plus.rectangle.on.rectangle")
                }
            }
        }
        .sheet(isPresented: $showingWindowPicker) {
            WindowPickerView()
                .environmentObject(windowManager)
        }
        .navigationTitle("Canopy")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("No windows monitored")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Add code editors and terminals to monitor your AI agents")
                .font(.body)
                .foregroundStyle(.tertiary)

            Button {
                showingWindowPicker = true
            } label: {
                Label("Add Windows", systemImage: "plus")
                    .padding(.horizontal, 8)
            }
            .controlSize(.large)
            .buttonStyle(.borderedProminent)
        }
    }

    // MARK: - Permission Prompt Banner

    private func promptBanner(_ prompt: RemoteControlService.PromptInfo) -> some View {
        HStack(spacing: 12) {
            if let cwd = prompt.cwd {
                let project = URL(fileURLWithPath: cwd).lastPathComponent
                HStack(spacing: 4) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 10))
                    Text(project)
                        .font(.system(size: 11, weight: .bold))
                }
                .foregroundStyle(.white)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(.blue)
                .clipShape(Capsule())
            }

            Image(systemName: "lock.shield.fill")
                .font(.system(size: 16))
                .foregroundStyle(.orange)

            Text(prompt.description)
                .font(.system(size: 13, weight: .medium))
                .lineLimit(2)

            Spacer()

            Button("Allow") {
                windowManager.rcService.respondToPrompt(allow: true)
            }
            .buttonStyle(.borderedProminent)
            .tint(.green)
            .controlSize(.small)

            Button("Deny") {
                windowManager.rcService.respondToPrompt(allow: false)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(.orange.opacity(0.08))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)),
            alignment: .bottom
        )
    }

    // MARK: - Command Bar

    private var commandBar: some View {
        HStack(spacing: 8) {
            if let window = selectedWindow ?? windowManager.monitoredWindows.first,
               let icon = window.icon {
                Image(nsImage: icon).resizable().frame(width: 16, height: 16)
                Text(window.ownerName)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            TextField("Send command to terminal...", text: $commandText)
                .textFieldStyle(.roundedBorder)
                .onSubmit { sendCommand() }

            Button("Send") { sendCommand() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(8)
        .background(.bar)
    }

    private func sendCommand() {
        let text = commandText.trimmingCharacters(in: .whitespaces)
        guard !text.isEmpty else { return }
        guard let window = selectedWindow ?? windowManager.monitoredWindows.first else { return }
        commandText = ""

        let pid = findPID(for: window)
        windowManager.bringWindowToFront(window)

        DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) {
            let utf16 = Array(text.utf16)
            for i in stride(from: 0, to: utf16.count, by: 20) {
                let end = min(i + 20, utf16.count)
                var chunk = Array(utf16[i..<end])
                let down = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: true)
                down?.keyboardSetUnicodeString(stringLength: chunk.count, unicodeString: &chunk)
                if let pid { down?.postToPid(pid) } else { down?.post(tap: .cghidEventTap) }
                let up = CGEvent(keyboardEventSource: nil, virtualKey: 0x31, keyDown: false)
                if let pid { up?.postToPid(pid) } else { up?.post(tap: .cghidEventTap) }
                Thread.sleep(forTimeInterval: 0.005)
            }
            Thread.sleep(forTimeInterval: 0.02)
            let enterDown = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: true)
            if let pid { enterDown?.postToPid(pid) } else { enterDown?.post(tap: .cghidEventTap) }
            let enterUp = CGEvent(keyboardEventSource: nil, virtualKey: 0x24, keyDown: false)
            if let pid { enterUp?.postToPid(pid) } else { enterUp?.post(tap: .cghidEventTap) }
        }
    }

    private func findPID(for window: MonitoredWindow) -> pid_t? {
        NSWorkspace.shared.runningApplications.first {
            $0.bundleIdentifier == window.bundleIdentifier ||
            $0.localizedName == window.ownerName
        }?.processIdentifier
    }
}
