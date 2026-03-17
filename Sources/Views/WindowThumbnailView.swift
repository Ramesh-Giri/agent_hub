import SwiftUI

struct WindowThumbnailView: View {
    let window: MonitoredWindow
    let screenshot: NSImage?
    let onSelect: () -> Void
    let onRemove: () -> Void

    @EnvironmentObject var windowManager: WindowManager
    @State private var isHovering = false
    @State private var showContext = false

    private var attention: WindowAttention? {
        windowManager.attentionService.attentionWindows[window.id]
    }

    private var contextEntries: [MemoryEntry] {
        windowManager.windowContext[window.id] ?? []
    }

    private var categoryLabel: String? {
        AppCatalog.category(for: window.bundleIdentifier)?.rawValue
    }

    private var borderColor: Color {
        if attention != nil { return .orange }
        if isHovering { return .accentColor }
        return Color.gray.opacity(0.3)
    }

    var body: some View {
        VStack(spacing: 0) {
            // Title bar
            HStack(spacing: 8) {
                if let icon = window.icon {
                    Image(nsImage: icon)
                        .resizable()
                        .frame(width: 16, height: 16)
                }

                Text(window.displayName)
                    .font(.caption)
                    .fontWeight(.medium)
                    .lineLimit(1)
                    .truncationMode(.middle)

                if let label = categoryLabel {
                    Text(label)
                        .font(.system(size: 9))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(.blue.opacity(0.15))
                        .foregroundStyle(.blue)
                        .clipShape(Capsule())
                }

                Spacer()

                // Attention badge
                if let attention {
                    attentionBadge(attention)
                }

                // Context indicator
                if !contextEntries.isEmpty {
                    Button {
                        showContext.toggle()
                    } label: {
                        Image(systemName: "brain.head.profile")
                            .font(.caption)
                            .foregroundStyle(.purple)
                    }
                    .buttonStyle(.plain)
                    .help("View claude-mem context")
                }

                // Quick action buttons on hover
                if isHovering {
                    Button {
                        windowManager.bringWindowToFront(window)
                    } label: {
                        Image(systemName: "macwindow")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Bring to front")

                    Button(action: onSelect) {
                        Image(systemName: "keyboard")
                            .font(.caption)
                    }
                    .buttonStyle(.plain)
                    .help("Send input")

                    Button(action: onRemove) {
                        Image(systemName: "xmark.circle.fill")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .buttonStyle(.plain)
                    .help("Remove")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(.bar)

            // Screenshot area
            ZStack(alignment: .bottomLeading) {
                Color(.controlBackgroundColor)

                if let screenshot {
                    Image(nsImage: screenshot)
                        .resizable()
                        .aspectRatio(contentMode: .fit)
                } else {
                    VStack(spacing: 8) {
                        Image(systemName: "terminal")
                            .font(.system(size: 28))
                            .foregroundStyle(.tertiary)
                        Text(window.ownerName)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Text("Click to interact")
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }

                // Attention overlay
                if let attention {
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 4) {
                            Image(systemName: "exclamationmark.circle.fill")
                                .foregroundStyle(.white)
                            Text(attention.reason.rawValue)
                                .font(.caption)
                                .foregroundStyle(.white)
                                .fontWeight(.bold)
                        }
                        if let prompt = attention.promptText {
                            Text(prompt)
                                .font(.system(size: 10))
                                .foregroundStyle(.white.opacity(0.9))
                                .lineLimit(2)
                        }
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(.orange.opacity(0.9))
                    .clipShape(RoundedRectangle(cornerRadius: 6))
                    .padding(8)
                }
            }
            .aspectRatio(16/10, contentMode: .fit)
            .onTapGesture(count: 2) {
                windowManager.bringWindowToFront(window)
            }
            .onTapGesture(count: 1) {
                onSelect()
            }

            // Context panel (expandable)
            if showContext && !contextEntries.isEmpty {
                contextPanel
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(borderColor, lineWidth: attention != nil ? 2.5 : (isHovering ? 2 : 1))
        )
        .shadow(color: .black.opacity(isHovering ? 0.15 : 0.05), radius: isHovering ? 8 : 2)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovering = hovering
            }
        }
    }

    private func attentionBadge(_ attention: WindowAttention) -> some View {
        HStack(spacing: 3) {
            Circle()
                .fill(.orange)
                .frame(width: 6, height: 6)
            Text(attention.reason.rawValue)
                .font(.system(size: 9))
                .foregroundStyle(.orange)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 2)
        .background(.orange.opacity(0.12))
        .clipShape(Capsule())
        .onTapGesture {
            windowManager.attentionService.clearAttention(windowID: window.id)
        }
        .help("Click to dismiss")
    }

    private var contextPanel: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Image(systemName: "brain.head.profile")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                Text("Claude-mem context")
                    .font(.caption2)
                    .foregroundStyle(.purple)
                Spacer()
            }

            ForEach(contextEntries.prefix(3)) { entry in
                Text(entry.displayContent)
                    .font(.system(size: 10))
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
            }
        }
        .padding(8)
        .background(.purple.opacity(0.05))
    }
}
