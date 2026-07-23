// A plain-text notes editor backed by NSTextView (SwiftUI's TextEditor can't
// expose the selection or intercept ⌘B). Notes are markdown files synced to
// Obsidian, so "bold / italic / strikethrough" = wrapping the selection in the
// markdown marks **…** / *…* / ~~…~~ — the file stays plain text and renders
// everywhere. The shortcuts toggle: re-applying on an already-wrapped
// selection strips the marks.
import AppKit
import SwiftUI

struct MarkdownNotesEditor: NSViewRepresentable {
    @Binding var text: String
    var fontSize: CGFloat
    var onFocus: () -> Void

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> NSScrollView {
        let tv = MarkdownTextView()
        tv.delegate = context.coordinator
        tv.onFocus = onFocus
        tv.isRichText = false
        tv.allowsUndo = true
        tv.drawsBackground = false
        tv.backgroundColor = .clear
        tv.textContainerInset = NSSize(width: 8, height: 6)
        tv.isAutomaticQuoteSubstitutionEnabled = false
        tv.isAutomaticDashSubstitutionEnabled = false
        tv.isAutomaticSpellingCorrectionEnabled = false
        tv.isAutomaticTextReplacementEnabled = false
        tv.smartInsertDeleteEnabled = false
        tv.string = text
        apply(tv)

        tv.minSize = NSSize(width: 0, height: 0)
        tv.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        tv.isVerticallyResizable = true
        tv.isHorizontallyResizable = false
        tv.autoresizingMask = [.width]
        tv.textContainer?.widthTracksTextView = true
        tv.textContainer?.containerSize = NSSize(width: 0, height: CGFloat.greatestFiniteMagnitude)

        let scroll = NSScrollView()
        scroll.documentView = tv
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        return scroll
    }

    func updateNSView(_ scroll: NSScrollView, context: Context) {
        context.coordinator.parent = self // keep the binding fresh across rebuilds
        guard let tv = scroll.documentView as? MarkdownTextView else { return }
        // NEVER touch the document while an IME composition (marked text) is
        // in progress. Replacing the string mid-composition kills the 注音
        // being typed AND leaves the input method holding a stale marked
        // range, so following keys chew up neighbouring text. This fired when
        // the previous (English) keystrokes' 0.8s save → dir kqueue → rescan
        // re-render landed exactly while composing right after an
        // input-source switch. External edits simply wait for the next
        // update pass after the composition ends.
        if tv.hasMarkedText() { return }
        if tv.string != text { // external edit (e.g. Obsidian) — reload
            let sel = tv.selectedRange()
            tv.string = text
            apply(tv)
            let len = (text as NSString).length
            tv.setSelectedRange(NSRange(location: min(sel.location, len), length: 0))
        } else if (tv.font?.pointSize ?? 0) != fontSize {
            apply(tv) // uiScale changed
        }
    }

    /// (Re)apply font, colour and line spacing to the whole document + typing.
    private func apply(_ tv: NSTextView) {
        let font = NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        let attrs: [NSAttributedString.Key: Any] = [
            .font: font, .foregroundColor: NSColor.labelColor, .paragraphStyle: p,
        ]
        tv.typingAttributes = attrs
        tv.defaultParagraphStyle = p
        tv.font = font
        if let ts = tv.textStorage {
            ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNotesEditor
        init(_ p: MarkdownNotesEditor) { parent = p }
        func textDidChange(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            // Mid-composition the storage contains uncommitted 注音 — keep it
            // out of the binding (it would get debounce-saved to disk and
            // trigger re-renders during the composition). Committing fires
            // another change with no marked text; we sync then.
            if tv.hasMarkedText() { return }
            parent.text = tv.string // equal on the way back → updateNSView no-ops
        }
    }
}

final class MarkdownTextView: NSTextView {
    var onFocus: (() -> Void)?

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        guard window?.firstResponder === self else {
            return super.performKeyEquivalent(with: event)
        }
        let mods = event.modifierFlags.intersection([.command, .shift, .option, .control])
        let key = event.charactersIgnoringModifiers?.lowercased()
        if mods == .command, key == "b" { toggleWrap("**"); return true }
        if mods == .command, key == "i" { toggleWrap("*"); return true }
        if mods == [.command, .shift], key == "x" { toggleWrap("~~"); return true }
        return super.performKeyEquivalent(with: event)
    }

    /// Wrap the selection in `mark`; if it's already wrapped, strip it. With no
    /// selection, insert the pair and park the cursor inside.
    private func toggleWrap(_ mark: String) {
        guard let ts = textStorage else { return }
        let full = string as NSString
        let range = selectedRange()
        let m = mark as NSString
        let mlen = m.length

        if range.length == 0 {
            let pair = mark + mark
            if shouldChangeText(in: range, replacementString: pair) {
                ts.replaceCharacters(in: range, with: pair)
                didChangeText()
                setSelectedRange(NSRange(location: range.location + mlen, length: 0))
            }
            return
        }

        let sel = full.substring(with: range) as NSString
        if sel.length >= 2 * mlen,
           sel.hasPrefix(mark), sel.hasSuffix(mark) {
            let inner = sel.substring(with: NSRange(location: mlen, length: sel.length - 2 * mlen))
            if shouldChangeText(in: range, replacementString: inner) {
                ts.replaceCharacters(in: range, with: inner)
                didChangeText()
                setSelectedRange(NSRange(location: range.location, length: (inner as NSString).length))
            }
            return
        }

        let wrapped = mark + (sel as String) + mark
        if shouldChangeText(in: range, replacementString: wrapped) {
            ts.replaceCharacters(in: range, with: wrapped)
            didChangeText()
            setSelectedRange(NSRange(location: range.location + mlen, length: sel.length))
        }
    }
}
