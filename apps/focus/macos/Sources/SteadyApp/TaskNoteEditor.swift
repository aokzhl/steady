import AppKit
import SteadyCore
import SwiftUI

/// Keeps selection and typing attributes in AppKit while autosaving each edit through the binding.
struct TaskNoteEditor: NSViewRepresentable {
    @Binding var note: TaskNote
    let accessibilityID: String

    func makeNSView(context: Context) -> NoteEditorView {
        let view = NoteEditorView()
        view.textView.setAccessibilityLabel("Заметка задачи")
        view.textView.setAccessibilityIdentifier(accessibilityID)
        view.onChange = { context.coordinator.changed($0) }
        view.load(note)
        return view
    }

    func updateNSView(_ view: NoteEditorView, context: Context) {
        context.coordinator.binding = $note
        if view.value != note { view.load(note) }
    }

    func makeCoordinator() -> Coordinator { Coordinator(binding: $note) }

    @MainActor
    final class Coordinator {
        var binding: Binding<TaskNote>
        init(binding: Binding<TaskNote>) { self.binding = binding }
        func changed(_ note: TaskNote) { binding.wrappedValue = note }
    }
}

@MainActor
final class NoteEditorView: NSView, NSTextViewDelegate {
    let textView = NoteTextView()
    private(set) var value: TaskNote = .empty
    var onChange: ((TaskNote) -> Void)?
    private let placeholder = NSTextField(labelWithString: "Добавить заметку")

    override init(frame: NSRect) {
        super.init(frame: frame)
        let toolbar = NSStackView()
        toolbar.spacing = 8
        toolbar.orientation = .horizontal
        for (symbol, label, action) in [
            ("bold", "Жирный (⌘B)", #selector(NoteTextView.toggleBold)),
            ("highlighter", "Выделение", #selector(NoteTextView.toggleHighlight)),
            ("list.bullet", "Маркированный список", #selector(NoteTextView.toggleList)),
            ("link", "Ссылка (⌘K)", #selector(NoteTextView.insertLink))
        ] {
            let button = NSButton(image: NSImage(systemSymbolName: symbol, accessibilityDescription: label)!, target: textView, action: action)
            button.bezelStyle = .texturedRounded
            button.toolTip = label
            button.setAccessibilityLabel(label)
            toolbar.addArrangedSubview(button)
        }
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.drawsBackground = false
        scroll.borderType = .noBorder
        textView.isRichText = true
        textView.importsGraphics = false
        textView.isAutomaticLinkDetectionEnabled = true
        textView.isAutomaticTextReplacementEnabled = true
        textView.isEditable = true
        textView.isSelectable = true
        textView.allowsUndo = true
        textView.drawsBackground = false
        textView.textColor = NoteTextView.defaultTextColor
        textView.font = .systemFont(ofSize: 14)
        textView.textContainerInset = NSSize(width: 4, height: 8)
        textView.minSize = NSSize(width: 0, height: 120)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.isVerticallyResizable = true
        textView.isHorizontallyResizable = false
        textView.autoresizingMask = [.width]
        textView.textContainer?.widthTracksTextView = true
        textView.delegate = self
        scroll.documentView = textView
        placeholder.textColor = .placeholderTextColor
        placeholder.font = .systemFont(ofSize: 14)
        placeholder.isSelectable = false
        for child in [toolbar, scroll, placeholder] {
            child.translatesAutoresizingMaskIntoConstraints = false
            addSubview(child)
        }
        NSLayoutConstraint.activate([
            toolbar.topAnchor.constraint(equalTo: topAnchor),
            toolbar.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.topAnchor.constraint(equalTo: toolbar.bottomAnchor, constant: 6),
            scroll.leadingAnchor.constraint(equalTo: leadingAnchor),
            scroll.trailingAnchor.constraint(equalTo: trailingAnchor),
            scroll.bottomAnchor.constraint(equalTo: bottomAnchor),
            placeholder.leadingAnchor.constraint(equalTo: scroll.leadingAnchor, constant: 9),
            placeholder.topAnchor.constraint(equalTo: scroll.topAnchor, constant: 8)
        ])
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    func load(_ note: TaskNote) {
        value = note
        let attributed = try? NSAttributedString(data: note.rtf, options: [.documentType: NSAttributedString.DocumentType.rtf], documentAttributes: nil)
        textView.textStorage?.setAttributedString(attributed ?? NSAttributedString(string: note.plainText, attributes: [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NoteTextView.defaultTextColor]))
        textView.typingAttributes = [.font: NSFont.systemFont(ofSize: 14), .foregroundColor: NoteTextView.defaultTextColor]
        placeholder.isHidden = !textView.string.isEmpty
        textView.undoManager?.removeAllActions()
    }

    func textDidChange(_ notification: Notification) {
        // NSTextView's RTF exporter supports every attribute exposed by this editor.
        guard let rtf = textView.rtf(from: NSRange(location: 0, length: textView.string.utf16.count)) else { return }
        value = textView.string.isEmpty ? .empty : TaskNote(rtf: rtf, plainText: textView.string)
        placeholder.isHidden = !textView.string.isEmpty
        onChange?(value)
    }
}

@MainActor
final class NoteTextView: NSTextView {
    static let defaultTextColor = NSColor(calibratedWhite: 0.9, alpha: 1)
    @objc func toggleBold() {
        transformSelection { attributes in
            let font = attributes[.font] as? NSFont ?? .systemFont(ofSize: 14)
            let bold = NSFontManager.shared.traits(of: font).contains(.boldFontMask)
            var result = attributes
            result[.font] = bold ? NSFontManager.shared.convert(font, toNotHaveTrait: .boldFontMask) : NSFontManager.shared.convert(font, toHaveTrait: .boldFontMask)
            return result
        }
    }

    @objc func toggleHighlight() {
        transformSelection { attributes in
            var result = attributes
            if attributes[.backgroundColor] != nil {
                result.removeValue(forKey: .backgroundColor)
                result[.foregroundColor] = Self.defaultTextColor
            } else {
                result[.backgroundColor] = NSColor.systemYellow
                result[.foregroundColor] = NSColor.black
            }
            return result
        }
    }

    private func transformSelection(_ transform: ([NSAttributedString.Key: Any]) -> [NSAttributedString.Key: Any]) {
        window?.makeFirstResponder(self)
        let range = selectedRange()
        guard range.length > 0, let textStorage else { typingAttributes = transform(typingAttributes); return }
        let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        replacement.enumerateAttributes(in: NSRange(location: 0, length: replacement.length)) { attributes, range, _ in
            replacement.setAttributes(transform(attributes), range: range)
        }
        insertText(replacement, replacementRange: range)
        setSelectedRange(range)
    }

    @objc func toggleList() {
        window?.makeFirstResponder(self)
        let range = (string as NSString).paragraphRange(for: selectedRange())
        guard let textStorage else { return }
        let replacement = NSMutableAttributedString(attributedString: textStorage.attributedSubstring(from: range))
        let selected = replacement.string
        let lines = selected.components(separatedBy: "\n")
        let nonempty = lines.filter { !$0.isEmpty }
        let remove = !nonempty.isEmpty && nonempty.allSatisfy { $0.hasPrefix("• ") }
        var offset = 0
        var paragraphs: [(Int, String)] = []
        for (index, line) in lines.enumerated() {
            if !(index == lines.count - 1 && line.isEmpty && selected.hasSuffix("\n")) {
                paragraphs.append((offset, line))
            }
            offset += line.utf16.count + 1
        }
        // Edit backwards so all original UTF-16 offsets and inline formatting remain valid.
        for (offset, line) in paragraphs.reversed() {
            if remove && line.hasPrefix("• ") {
                replacement.deleteCharacters(in: NSRange(location: offset, length: 2))
            } else if !remove && !line.hasPrefix("• ") {
                let attributes = offset < replacement.length ? replacement.attributes(at: offset, effectiveRange: nil) : typingAttributes
                replacement.insert(NSAttributedString(string: "• ", attributes: attributes), at: offset)
            }
        }
        insertText(replacement, replacementRange: range)
    }

    override func insertNewline(_ sender: Any?) {
        let paragraph = (string as NSString).paragraphRange(for: NSRange(location: selectedRange().location, length: 0))
        let line = (string as NSString).substring(with: paragraph).trimmingCharacters(in: .newlines)
        if line == "• " {
            insertText("", replacementRange: NSRange(location: paragraph.location, length: 2))
        } else {
            super.insertNewline(sender)
            if line.hasPrefix("• ") { insertText("• ", replacementRange: selectedRange()) }
        }
    }

    @objc func insertLink() {
        window?.makeFirstResponder(self)
        let range = selectedRange()
        let alert = NSAlert()
        alert.messageText = "Ссылка в заметке"
        alert.informativeText = "Введите адрес, начинающийся с https:// или http://"
        let address = NSTextField(frame: NSRect(x: 0, y: 0, width: 280, height: 24))
        address.placeholderString = "https://…"
        address.setAccessibilityLabel("Адрес ссылки")
        alert.accessoryView = address
        alert.addButton(withTitle: "Вставить")
        alert.addButton(withTitle: "Отмена")
        while alert.runModal() == .alertFirstButtonReturn {
            let input = address.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: input), ["http", "https"].contains(url.scheme?.lowercased() ?? ""), url.host != nil else {
                alert.informativeText = "Проверьте адрес: нужен полный https:// или http:// адрес."
                continue
            }
            let label = range.length > 0 ? (string as NSString).substring(with: range) : input
            var attributes = typingAttributes
            attributes[.link] = url
            insertText(NSAttributedString(string: label, attributes: attributes), replacementRange: range)
            typingAttributes.removeValue(forKey: .link)
            return
        }
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        if event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command {
            switch event.charactersIgnoringModifiers?.lowercased() {
            case "b": toggleBold(); return true
            case "k": insertLink(); return true
            default: break
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}
