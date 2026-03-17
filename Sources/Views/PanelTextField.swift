import SwiftUI
import AppKit

/// NSTextField that works in NSPanel (.nonactivatingPanel).
struct PanelTextField: NSViewRepresentable {
    let placeholder: String
    @Binding var text: String
    var onSubmit: () -> Void = {}

    func makeNSView(context: Context) -> NSTextField {
        let field = NSTextField()
        field.placeholderString = placeholder
        field.stringValue = text
        field.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        field.textColor = .white
        field.backgroundColor = NSColor.white.withAlphaComponent(0.08)
        field.drawsBackground = true
        field.isBezeled = false
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.wantsLayer = true
        field.layer?.cornerRadius = 8
        field.delegate = context.coordinator
        context.coordinator.textField = field
        // Listen for clear notifications
        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleClear),
            name: .init("AgentHubClearInput"),
            object: nil
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
        // Only sync text if field isn't currently being edited
        if nsView.currentEditor() == nil && nsView.stringValue != text {
            nsView.stringValue = text
        }
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(text: $text, onSubmit: onSubmit)
    }

    class Coordinator: NSObject, NSTextFieldDelegate {
        @Binding var text: String
        var onSubmit: () -> Void
        weak var textField: NSTextField?

        init(text: Binding<String>, onSubmit: @escaping () -> Void) {
            _text = text
            self.onSubmit = onSubmit
        }

        func controlTextDidChange(_ obj: Notification) {
            if let field = obj.object as? NSTextField {
                text = field.stringValue
            }
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                onSubmit()
                clearField()
                return true
            }
            return false
        }

        func clearField() {
            textField?.stringValue = ""
            text = ""
        }

        @objc func handleClear() {
            clearField()
        }
    }
}

/// Native NSButton that works in NSPanel
struct PanelSendButton: NSViewRepresentable {
    let title: String
    let action: () -> Void

    func makeNSView(context: Context) -> NSButton {
        let button = SendButton(title: title, target: context.coordinator, action: #selector(Coordinator.clicked))
        button.bezelStyle = .rounded
        button.contentTintColor = .white
        button.wantsLayer = true
        button.layer?.backgroundColor = NSColor.systemBlue.cgColor
        button.layer?.cornerRadius = 6
        button.isBordered = false
        button.font = .systemFont(ofSize: 12, weight: .bold)
        return button
    }

    func updateNSView(_ nsView: NSButton, context: Context) {
        context.coordinator.action = action
    }

    func makeCoordinator() -> Coordinator {
        Coordinator(action: action)
    }

    class Coordinator: NSObject {
        var action: () -> Void
        init(action: @escaping () -> Void) { self.action = action }
        @objc func clicked() { action() }
    }
}

/// NSButton subclass that accepts first mouse in non-activating panels
class SendButton: NSButton {
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
    override func mouseDown(with event: NSEvent) {
        window?.makeKey()
        super.mouseDown(with: event)
    }
}
