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
            // Same for a click or drag-selection in progress: replacing the
            // document mid-drag would drop the selection being made. Catch up
            // on mouse-up instead.
            if tv.isPressing {
                let coordinator = context.coordinator
                tv.onPressEnded = { [weak tv] in
                    guard let tv else { return }
                    coordinator.parent.syncText(into: tv, coordinator: coordinator)
                }
                return
            }
            syncText(into: tv, coordinator: context.coordinator)
        } else if (tv.font?.pointSize ?? 0) != fontSize {
            apply(tv) // uiScale changed
        }
    }

    static func dismantleNSView(_ scroll: NSScrollView, coordinator: Coordinator) {
        coordinator.undoManager.removeAllActions()
        (scroll.documentView as? NSTextView)?.delegate = nil
    }

    /// Bring the editor to `text` (an Obsidian edit, or the app's own write),
    /// replacing only the span that differs. App-side writes are frontmatter
    /// keys at the top of the note; swapping the whole string for them reset
    /// the selection and scroll position and re-laid out the entire note.
    fileprivate func syncText(into tv: MarkdownTextView, coordinator: Coordinator) {
        guard !tv.hasMarkedText(), tv.string != text else { return }
        defer {
            // The typing history refers to ranges in the text that was just
            // replaced; undoing into a reloaded document would splice at the
            // wrong offsets. Start over.
            coordinator.undoManager.removeAllActions()
        }
        guard let ts = tv.textStorage else {
            tv.string = text
            apply(tv)
            return
        }
        let old = ts.string as NSString
        let new = text as NSString
        let shared = min(old.length, new.length)
        var prefix = 0
        while prefix < shared, old.character(at: prefix) == new.character(at: prefix) {
            prefix += 1
        }
        var suffix = 0
        while suffix < shared - prefix,
              old.character(at: old.length - 1 - suffix) == new.character(at: new.length - 1 - suffix) {
            suffix += 1
        }
        // Never cut a surrogate pair at either edge of the replaced span.
        if prefix > 0, UTF16.isLeadSurrogate(old.character(at: prefix - 1)) { prefix -= 1 }
        if suffix > 0, UTF16.isTrailSurrogate(old.character(at: old.length - suffix)) { suffix -= 1 }

        let oldRange = NSRange(location: prefix, length: old.length - prefix - suffix)
        let newRange = NSRange(location: prefix, length: new.length - prefix - suffix)
        let selection = tv.selectedRange()
        ts.beginEditing()
        ts.replaceCharacters(in: oldRange, with: NSAttributedString(
            string: new.substring(with: newRange), attributes: textAttributes))
        ts.endEditing()
        guard ts.string == text else { // belt and braces: never leave a divergent editor
            tv.string = text
            apply(tv)
            tv.setSelectedRange(NSRange(location: min(selection.location, new.length), length: 0))
            return
        }
        // Keep the user's place: a selection before the change stays, one
        // after it moves with it, one overlapping it collapses to its end.
        var kept = selection
        if selection.location >= oldRange.upperBound {
            kept.location += newRange.length - oldRange.length
        } else if selection.upperBound > oldRange.location {
            kept = NSRange(location: newRange.upperBound, length: 0)
        }
        kept.location = min(kept.location, new.length)
        kept.length = min(kept.length, new.length - kept.location)
        tv.setSelectedRange(kept)
    }

    private var textAttributes: [NSAttributedString.Key: Any] {
        let p = NSMutableParagraphStyle()
        p.lineSpacing = 2.5
        return [
            .font: NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular),
            .foregroundColor: NSColor.labelColor, .paragraphStyle: p,
        ]
    }

    /// (Re)apply font, colour and line spacing to the whole document + typing.
    private func apply(_ tv: NSTextView) {
        let attrs = textAttributes
        tv.typingAttributes = attrs
        tv.defaultParagraphStyle = attrs[.paragraphStyle] as? NSParagraphStyle
        tv.font = attrs[.font] as? NSFont
        if let ts = tv.textStorage {
            ts.addAttributes(attrs, range: NSRange(location: 0, length: ts.length))
        }
    }

    final class Coordinator: NSObject, NSTextViewDelegate {
        var parent: MarkdownNotesEditor
        /// The editor's own undo stack. Without this the text view registers
        /// its typing undo with the WINDOW's undo manager, where the entries
        /// outlive the editor: a task switch rebuilds TaskDetailView and
        /// tears the old editor down, but AppKit only unregisters from an
        /// undo manager it can still reach, and by then the view is out of
        /// the responder chain. The next ⌘Z anywhere in the window (a
        /// terminal pane, typically) popped an entry whose target — the old
        /// editor's text storage — had been freed: SIGSEGV in
        /// `_NSUndoStack popAndInvoke` (2026-09-29). Owning the manager here
        /// ties the entries' lifetime to the editor's.
        let undoManager = UndoManager()
        init(_ p: MarkdownNotesEditor) { parent = p }
        func undoManager(for view: NSTextView) -> UndoManager? { undoManager }
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
    /// Runs once when the current click / drag-selection in this editor ends.
    var onPressEnded: (() -> Void)?
    private var trackingMouse = false

    /// A click or drag-selection is in progress here. NSTextView tracks the
    /// drag inside `mouseDown`; the hardware button state backs that up.
    var isPressing: Bool {
        trackingMouse || (NSEvent.pressedMouseButtons & 1 != 0 && window?.firstResponder === self)
    }

    override func becomeFirstResponder() -> Bool {
        let ok = super.becomeFirstResponder()
        if ok { onFocus?() }
        return ok
    }

    override func mouseDown(with event: NSEvent) {
        trackingMouse = true
        super.mouseDown(with: event)
        trackingMouse = false
        finishPress()
    }

    override func mouseUp(with event: NSEvent) {
        super.mouseUp(with: event)
        finishPress()
    }

    private func finishPress() {
        guard let pending = onPressEnded else { return }
        onPressEnded = nil
        pending()
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
