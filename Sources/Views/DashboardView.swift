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
        Array(repeating: GridItem(.flexible(), spacing: 12), count: windowManager.gridColumns)
    }

    private var hookPrompt: RemoteControlService.PromptInfo? {
        windowManager.rcService.activePrompt
    }

    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
                // Permission prompt banner
                if let prompt = hookPrompt {
                    promptBanner(prompt)
                }

                if windowManager.monitoredWindows.isEmpty {
                    emptyState
                        .frame(maxHeight: .infinity)
                } else {
                    ScrollView {
                        LazyVGrid(columns: columns, spacing: 12) {
                            ForEach(windowManager.monitoredWindows) { window in
                                WindowThumbnailView(
                                    window: window,
                                    screenshot: windowManager.screenshots[window.id],
                                    onSelect: { selectedWindow = window },
                                    onRemove: { windowManager.removeWindow(window) }
                                )
                            }
                        }
                        .padding(16)
                    }
                }

                // Command input bar
                if !windowManager.monitoredWindows.isEmpty {
                    commandBar
                }
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .automatic) {
                if windowManager.networkServer.connectedClients > 0 {
                    HStack(spacing: 3) {
                        Image(systemName: "iphone.radiowaves.left.and.right")
                            .foregroundStyle(.green)
                        Text("\(windowManager.networkServer.connectedClients)")
                            .font(.caption2)
                            .foregroundStyle(.green)
                    }
                    .help("\(windowManager.networkServer.connectedClients) iOS device(s) connected")
                } else if windowManager.networkServer.isRunning {
                    Image(systemName: "antenna.radiowaves.left.and.right")
                        .foregroundStyle(.secondary)
                        .help("Waiting for iOS companion app")
                }

                if windowManager.isClaudeMemAvailable {
                    HStack(spacing: 3) {
                        Image(systemName: "brain.head.profile")
                            .foregroundStyle(.purple)
                        Text("mem")
                            .font(.caption2)
                            .foregroundStyle(.purple)
                    }
                    .help("Claude-mem connected at localhost:37777")
                }

                if attentionCount > 0 {
                    Button {
                    } label: {
                        HStack(spacing: 3) {
                            Image(systemName: "bell.badge.fill")
                                .foregroundStyle(.orange)
                            Text("\(attentionCount)")
                                .font(.caption)
                                .fontWeight(.bold)
                                .foregroundStyle(.orange)
                        }
                    }
                    .help("\(attentionCount) window(s) need attention")
                }
            }

            ToolbarItemGroup(placement: .primaryAction) {
                gridColumnControl

                Divider()

                Button {
                    windowManager.attentionService.notificationsEnabled.toggle()
                } label: {
                    Image(systemName: windowManager.attentionService.notificationsEnabled
                          ? "bell.fill" : "bell.slash")
                }
                .help(windowManager.attentionService.notificationsEnabled
                      ? "Notifications on" : "Notifications off")

                Button {
                    showingWindowPicker = true
                } label: {
                    Label("Add Windows", systemImage: "plus.rectangle.on.rectangle")
                }
            }
        }
        .sheet(isPresented: $showingWindowPicker) {
            WindowPickerView()
                .environmentObject(windowManager)
        }
        .sheet(item: $selectedWindow) { window in
            InteractionSheet(window: window)
                .environmentObject(windowManager)
        }
        .navigationTitle("AgentHub")
    }

    private var emptyState: some View {
        VStack(spacing: 16) {
            Image(systemName: "rectangle.on.rectangle.angled")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)

            Text("No windows monitored")
                .font(.title2)
                .foregroundStyle(.secondary)

            Text("Add AI agent windows to send commands via voice or text")
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
            // Project badge
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
            .controlSize(.regular)

            Button("Deny") {
                windowManager.rcService.respondToPrompt(allow: false)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
            .controlSize(.regular)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
        .background(.orange.opacity(0.08))
        .overlay(
            Rectangle().frame(height: 1).foregroundStyle(.orange.opacity(0.3)),
            alignment: .bottom
        )
    }

    // MARK: - Command Bar

    private var commandBar: some View {
        HStack(spacing: 10) {
            // Target window indicator
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
                .disabled(commandText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
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

    private var gridColumnControl: some View {
        HStack(spacing: 4) {
            Text("Grid:")
                .foregroundStyle(.secondary)
                .font(.caption)
            Picker("Columns", selection: $windowManager.gridColumns) {
                Text("1").tag(1)
                Text("2").tag(2)
                Text("3").tag(3)
                Text("4").tag(4)
            }
            .pickerStyle(.segmented)
            .frame(width: 140)
        }
    }
}
