import SwiftUI

struct WindowPickerView: View {
    @EnvironmentObject var windowManager: WindowManager
    @Environment(\.dismiss) private var dismiss

    @State private var discoveredWindows: [DiscoveredWindow] = []
    @State private var selectedIDs: Set<CGWindowID> = []
    @State private var isLoading = true
    @State private var searchText = ""
    @State private var showOnlyTerminalApps = true

    private var filteredWindows: [DiscoveredWindow] {
        discoveredWindows.filter { window in
            // Exclude already monitored — by ID or by ownerName+title
            let alreadyByID = windowManager.monitoredWindows.contains(where: { $0.id == window.id })
            let alreadyByName = windowManager.monitoredWindows.contains(where: {
                $0.ownerName == window.ownerName && $0.windowTitle == window.windowTitle
            })
            let notMonitored = !alreadyByID && !alreadyByName

            // Search filter
            let matchesSearch = searchText.isEmpty ||
                window.ownerName.localizedCaseInsensitiveContains(searchText) ||
                window.windowTitle.localizedCaseInsensitiveContains(searchText)

            // Terminal/agent filter
            let matchesFilter = !showOnlyTerminalApps || AppCatalog.hasTerminalSupport(window.bundleIdentifier)

            return notMonitored && matchesSearch && matchesFilter
        }
    }

    var body: some View {
        VStack(spacing: 0) {
            // Header
            HStack {
                Text("Select Windows to Monitor")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding()

            Divider()

            // Filters
            HStack {
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundStyle(.secondary)
                    TextField("Search windows...", text: $searchText)
                        .textFieldStyle(.plain)
                }
                .padding(8)
                .background(.quaternary)
                .clipShape(RoundedRectangle(cornerRadius: 8))

                Toggle("Terminal apps only", isOn: $showOnlyTerminalApps)
                    .toggleStyle(.switch)
                    .controlSize(.small)
            }
            .padding(.horizontal)
            .padding(.vertical, 8)

            Divider()

            // Window list
            if isLoading {
                Spacer()
                ProgressView("Discovering windows...")
                Spacer()
            } else if filteredWindows.isEmpty {
                Spacer()
                Text("No windows found")
                    .foregroundStyle(.secondary)
                Spacer()
            } else {
                List(filteredWindows, selection: $selectedIDs) { window in
                    WindowRow(
                        window: window,
                        isSelected: selectedIDs.contains(window.id),
                        windowIndex: windowIndex(for: window)
                    )
                        .tag(window.id)
                        .onTapGesture {
                            if selectedIDs.contains(window.id) {
                                selectedIDs.remove(window.id)
                            } else {
                                selectedIDs.insert(window.id)
                            }
                        }
                }
                .listStyle(.inset(alternatesRowBackgrounds: true))
            }

            Divider()

            // Footer
            HStack {
                Button {
                    Task { await refreshWindows() }
                } label: {
                    Label("Refresh", systemImage: "arrow.clockwise")
                }

                Spacer()

                Text("\(selectedIDs.count) selected")
                    .foregroundStyle(.secondary)
                    .font(.caption)

                Button("Add Selected") {
                    addSelectedWindows()
                    dismiss()
                }
                .disabled(selectedIDs.isEmpty)
                .buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .frame(width: 600, height: 500)
        .task {
            await refreshWindows()
        }
    }

    private func refreshWindows() async {
        isLoading = true
        discoveredWindows = await windowManager.discoverWindows()
        isLoading = false
    }

    private func addSelectedWindows() {
        for window in discoveredWindows where selectedIDs.contains(window.id) {
            windowManager.addWindow(window.toMonitored())
        }
    }

    /// Returns the 1-based index for windows from the same app (nil if only one window)
    private func windowIndex(for window: DiscoveredWindow) -> Int? {
        let sameAppWindows = filteredWindows.filter { $0.ownerName == window.ownerName }
        guard sameAppWindows.count > 1 else { return nil }
        if let idx = sameAppWindows.firstIndex(where: { $0.id == window.id }) {
            return idx + 1
        }
        return nil
    }
}

struct WindowRow: View {
    let window: DiscoveredWindow
    let isSelected: Bool
    var windowIndex: Int?

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: isSelected ? "checkmark.circle.fill" : "circle")
                .foregroundStyle(isSelected ? .blue : .secondary)
                .font(.title3)

            if let icon = window.icon {
                Image(nsImage: icon)
                    .resizable()
                    .frame(width: 24, height: 24)
            } else {
                Image(systemName: "macwindow")
                    .frame(width: 24, height: 24)
                    .foregroundStyle(.secondary)
            }

            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 4) {
                    Text(window.ownerName)
                        .font(.body)
                        .fontWeight(.medium)

                    if let idx = windowIndex {
                        Text("(Window \(idx))")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                    }
                }

                if !window.windowTitle.isEmpty {
                    Text(window.windowTitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                } else {
                    Text("\(Int(window.bounds.width))x\(Int(window.bounds.height))")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }

            Spacer()

            if WindowDiscoveryService.isKnownAgentApp(window.bundleIdentifier) {
                Text("AI/Dev")
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(.blue.opacity(0.15))
                    .foregroundStyle(.blue)
                    .clipShape(Capsule())
            }

            if window.isOnScreen {
                Circle()
                    .fill(.green)
                    .frame(width: 8, height: 8)
                    .help("On screen")
            } else {
                Circle()
                    .fill(.gray.opacity(0.4))
                    .frame(width: 8, height: 8)
                    .help("Off screen / other space")
            }
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }
}
