import SwiftUI
import AppKit

struct CodeEditor: NSViewRepresentable {
    @Binding var text: String
    var editable: Bool = true

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.hasHorizontalScroller = true
        scroll.autohidesScrollers = true
        scroll.drawsBackground = true
        scroll.backgroundColor = .textBackgroundColor
        let view = NSTextView()
        view.isRichText = false
        view.isAutomaticQuoteSubstitutionEnabled = false
        view.isAutomaticDashSubstitutionEnabled = false
        view.isAutomaticTextReplacementEnabled = false
        view.isAutomaticSpellingCorrectionEnabled = false
        view.isContinuousSpellCheckingEnabled = false
        view.font = .monospacedSystemFont(ofSize: 13, weight: .regular)
        view.textColor = .textColor
        view.backgroundColor = .textBackgroundColor
        view.insertionPointColor = .controlAccentColor
        view.textContainerInset = NSSize(width: 28, height: 22)
        view.isHorizontallyResizable = true
        view.isVerticallyResizable = true
        view.autoresizingMask = [.width]
        view.minSize = NSSize(width: 0, height: 0)
        view.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        view.textContainer?.widthTracksTextView = false
        view.usesFindBar = true
        view.allowsUndo = true
        view.delegate = context.coordinator
        view.string = text
        view.isEditable = editable
        scroll.documentView = view
        context.coordinator.highlight(view)
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self
        guard let view = scroll.documentView as? NSTextView else { return }
        view.isEditable = editable
        if view.string != text {
            view.string = text
            view.undoManager?.removeAllActions()
            context.coordinator.highlight(view)
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: CodeEditor
        var pending: DispatchWorkItem?
        init(_ parent: CodeEditor) { self.parent = parent }
        func textDidChange(_ notification: Notification) {
            guard let view = notification.object as? NSTextView else { return }
            parent.text = view.string
            pending?.cancel()
            let work = DispatchWorkItem { [weak self, weak view] in
                if let view { self?.highlight(view) }
            }
            pending = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.18, execute: work)
        }

        func highlight(_ view: NSTextView) {
            guard let storage = view.textStorage else { return }
            let text = view.string as NSString
            // Keep editing large blocklists responsive; no full-document syntax pass above 256 KB.
            guard text.length <= 262_144 else { return }
            storage.beginEditing()
            storage.addAttributes([.foregroundColor: NSColor.textColor, .font: NSFont.monospacedSystemFont(ofSize: 13, weight: .regular)], range: NSRange(location: 0, length: text.length))
            let rules: [(String, NSColor)] = [
                ("(?m)^\\s*[0-9a-fA-F:.]+(?=\\s)", .systemTeal),
                ("(?m)#[^\\n]*", .secondaryLabelColor)
            ]
            for (pattern, color) in rules {
                guard let regex = try? NSRegularExpression(pattern: pattern) else { continue }
                regex.enumerateMatches(in: view.string, range: NSRange(location: 0, length: text.length)) { match, _, _ in
                    if let match { storage.addAttribute(.foregroundColor, value: color, range: match.range) }
                }
            }
            storage.endEditing()
        }
    }
}
