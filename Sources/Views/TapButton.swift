import SwiftUI

/// A tappable button that works in .nonactivatingPanel.
/// Uses onTapGesture (which works) instead of SwiftUI Button or NSButton (which don't).
struct TapButton: View {
    let label: String
    let action: () -> Void
    var color: Color = .primary
    var bgColor: Color = Color(.controlBackgroundColor)
    var font: Font = .system(size: 12, weight: .semibold, design: .monospaced)

    @State private var isPressed = false

    var body: some View {
        Text(label)
            .font(font)
            .foregroundStyle(color)
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(isPressed ? bgColor.opacity(0.8) : bgColor)
            .clipShape(RoundedRectangle(cornerRadius: 6))
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(.gray.opacity(0.3), lineWidth: 1)
            )
            .scaleEffect(isPressed ? 0.95 : 1.0)
            .contentShape(Rectangle())
            .onTapGesture { action() }
            .simultaneousGesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in isPressed = true }
                    .onEnded { _ in isPressed = false }
            )
    }
}

/// Icon-only tap button
struct TapIconButton: View {
    let systemName: String
    let action: () -> Void
    var color: Color = .secondary

    var body: some View {
        Image(systemName: systemName)
            .font(.system(size: 11))
            .foregroundStyle(color)
            .frame(width: 26, height: 24)
            .background(Color(.controlBackgroundColor).opacity(0.5))
            .clipShape(RoundedRectangle(cornerRadius: 5))
            .contentShape(Rectangle())
            .onTapGesture { action() }
    }
}
