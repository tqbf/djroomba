import SwiftUI
import AppKit

/// The intent of a captured keystroke, classified for the search HUD.
enum SearchKey: Sendable, Equatable {
    /// A printable character to append to the query.
    case character(Character)
    case backspace
    /// Esc — clear the query / dismiss the HUD.
    case escape
    /// Return — select the top/active match (→ pinned-centre relayout).
    case `return`
    /// ↓ — cycle to the next match (and re-centre on it).
    case cycleNext
    /// ↑ — cycle to the previous match.
    case cyclePrevious
    /// ⌘F — explicit summon (discoverability; typing alone is primary).
    case summon
}

/// Captures printable keystrokes / Esc / Return / ↑↓ / Backspace over the
/// Canvas **without breaking click, drag, scroll or menu shortcuts**.
///
/// Same proven shape as `ScrollZoomModifier`: a click-transparent overlay
/// (`allowsHitTesting(false)`) anchors a **local `NSEvent` monitor** for
/// `.keyDown`. A focusable `NSView` first-responder would fight SwiftUI's
/// gesture/hit-test ownership and an overlay returning `nil` from `hitTest`
/// never receives key events anyway — the local monitor sidesteps both. It
/// only acts when our window is key and **no text control is first responder**
/// (so a Lab `TextField` still types normally), classifies the event, and
/// **consumes only the keys search actually handled** (returns `nil`);
/// everything else is returned unchanged so pan/zoom/click and `⌘`-shortcuts
/// are completely untouched.
struct KeyCaptureView: ViewModifier {
    /// Whether the HUD is currently shown. Drives which keys are consumed:
    /// when the HUD is closed only a *printable* key (or `⌘F`) is taken;
    /// once open, editing/navigation keys are taken too.
    let isSearchActive: Bool
    /// Returns `true` if the key was handled (⇒ consume it).
    let onKey: (SearchKey) -> Bool

    func body(content: Content) -> some View {
        content.overlay(
            KeyCaptureRepresentable(isSearchActive: isSearchActive, onKey: onKey)
                .allowsHitTesting(false)
        )
    }
}

private struct KeyCaptureRepresentable: NSViewRepresentable {
    let isSearchActive: Bool
    let onKey: (SearchKey) -> Bool

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.onKey = onKey
        view.isSearchActive = isSearchActive
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.onKey = onKey
        nsView.isSearchActive = isSearchActive
    }

    static func dismantleNSView(_ nsView: KeyCaptureNSView, coordinator: ()) {
        nsView.teardownMonitor()
    }
}

/// Click-transparent (`allowsHitTesting(false)`); exists only to anchor a
/// local `.keyDown` monitor to the graph's window for the lifetime of the
/// view, mirroring `ScrollZoomNSView`.
final class KeyCaptureNSView: NSView {
    var onKey: ((SearchKey) -> Bool)?
    var isSearchActive = false

    /// The opaque local-monitor token. `nonisolated(unsafe)` for the same
    /// reason as `ScrollZoomNSView.monitor`: assigned only on the main thread
    /// (NSView lifecycle), read once in `deinit`; `NSEvent.removeMonitor` is
    /// thread-safe, so this is sound and keeps the file warning-free under
    /// `-strict-concurrency=complete`.
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardownMonitor(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) {
            [weak self] event in
            let consumed = MainActor.assumeIsolated {
                self?.handle(event) ?? false
            }
            // nil consumes the event (search handled it); returning the event
            // lets it flow on untouched so click/drag/scroll/menus still work.
            return consumed ? nil : event
        }
    }

    func teardownMonitor() {
        if let monitor {
            NSEvent.removeMonitor(monitor)
            self.monitor = nil
        }
    }

    deinit {
        if let monitor { NSEvent.removeMonitor(monitor) }
    }

    /// Decide whether this key belongs to search; if so, dispatch it and
    /// report `true` so the caller consumes it.
    private func handle(_ event: NSEvent) -> Bool {
        // Only our key window, and never while a real text control owns the
        // responder chain (so a Lab `TextField` keeps typing normally).
        guard
            let window,
            event.window === window,
            window.isKeyWindow,
            !isEditingTextField(in: window)
        else { return false }

        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // ⌘F summons the HUD (alternate path). Other ⌘/⌃/⌥ combos are app
        // shortcuts — never swallow them.
        if flags.contains(.command) {
            if !flags.contains(.option), !flags.contains(.control),
               event.charactersIgnoringModifiers?.lowercased() == "f" {
                return dispatch(.summon)
            }
            return false
        }
        if flags.contains(.control) || flags.contains(.option) { return false }

        switch event.keyCode {
        // DJROOMBA PATCH (3) — neighbour-walk. Esc / Return / arrows are now
        // dispatched UNCONDITIONALLY (was: only while search active) and the
        // engine decides whether to consume them via the returned Bool: it
        // takes them for search-cycle when the HUD is up, OR to walk a
        // focused genre's linked genres when one is selected, and otherwise
        // returns false so the event passes straight through to the rest of
        // the app exactly as before (no genre highlighted ⇒ normal arrow /
        // Return / Esc behaviour). Letting the handler decide is the correct
        // extensible shape; the old in-view gating couldn't see the engine's
        // selection state. ←/→ now also cycle (was: always passed through).
        case 53: // Esc
            return dispatch(.escape)
        case 36, 76: // Return / Enter
            return dispatch(.return)
        case 125, 124: // ↓ / → → next
            return dispatch(.cycleNext)
        case 126, 123: // ↑ / ← → previous
            return dispatch(.cyclePrevious)
        case 51, 117: // Delete / Forward-delete — text edit, search only
            return isSearchActive ? dispatch(.backspace) : false
        case 48: // Tab — leave focus traversal alone
            return false
        default:
            return handlePrintable(event)
        }
    }

    /// A printable, non-control character starts (or extends) the query.
    private func handlePrintable(_ event: NSEvent) -> Bool {
        guard
            let characters = event.characters, !characters.isEmpty,
            let scalar = characters.unicodeScalars.first,
            !CharacterSet.controlCharacters.contains(scalar),
            !CharacterSet.illegalCharacters.contains(scalar)
        else { return false }
        // A lone Space shouldn't *start* a search (it's a common map/pan key
        // in graph apps), but it's a legitimate character mid-query.
        if characters == " ", !isSearchActive { return false }
        guard let character = characters.first else { return false }
        return dispatch(.character(character))
    }

    private func dispatch(_ key: SearchKey) -> Bool {
        onKey?(key) ?? false
    }

    private func isEditingTextField(in window: NSWindow) -> Bool {
        guard let responder = window.firstResponder else { return false }
        if responder is NSTextView { return true }
        if let textView = responder as? NSText, textView.isEditable { return true }
        return responder is NSTextField
    }
}
