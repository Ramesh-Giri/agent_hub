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
        field.font = .systemFont(ofSize: 14)
        field.textColor = .white
        field.backgroundColor = NSColor.white.withAlphaComponent(0.1)
        field.drawsBackground = true
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.focusRingType = .none
        field.cell?.wraps = false
        field.cell?.isScrollable = true
        field.delegate = context.coordinator
        context.coordinator.textField = field

        NotificationCenter.default.addObserver(
            context.coordinator,
            selector: #selector(Coordinator.handleClear),
            name: .init("CanopyClearInput"),
            object: nil
        )
        return field
    }

    func updateNSView(_ nsView: NSTextField, context: Context) {
        context.coordinator.onSubmit = onSubmit
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
