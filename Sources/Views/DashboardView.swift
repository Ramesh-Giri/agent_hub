import SwiftUI

struct DashboardView: View {
    @EnvironmentObject var windowManager: WindowManager
    @State private var showingWindowPicker = false
    @State private var selectedWindow: MonitoredWindow?

    private var attentionCount: Int {
        windowManager.attentionService.attentionWindows.count
    }

    private var columns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 12), count: windowManager.gridColumns)
    }

    var body: some View {
        ZStack {
            Color(.windowBackgroundColor)
                .ignoresSafeArea()

            VStack(spacing: 0) {
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
