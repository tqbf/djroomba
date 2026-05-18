import SwiftUI

/// Adds scroll-wheel and pinch-magnify zoom-toward-cursor over the Canvas.
///
/// SwiftUI has no first-class scroll-wheel gesture on macOS. An overlay NSView
/// that returns `nil` from `hitTest` (to stay click-transparent) never receives
/// `scrollWheel` either — the window routes scroll by hit-testing too. So we
/// install a **local NSEvent monitor** for `.scrollWheel` / `.magnify`: it sees
/// the events regardless of the view hierarchy, we act on the ones over our
/// view, and we return the event unconsumed so nothing else breaks. Clicks and
/// drags are untouched and still reach the SwiftUI Canvas.
struct ScrollZoomModifier<Value: Sendable>: ViewModifier {
    let engine: GraphEngine<Value>

    func body(content: Content) -> some View {
        content.overlay(ScrollZoomCatcher(engine: engine).allowsHitTesting(false))
    }
}

private struct ScrollZoomCatcher<Value: Sendable>: NSViewRepresentable {
    let engine: GraphEngine<Value>

    func makeNSView(context: Context) -> ScrollZoomNSView {
        let view = ScrollZoomNSView()
        view.onScroll = { deltaY, location in
            engine.noteUserInteraction()
            let factor = 1 + (deltaY * 0.0025)
            engine.viewport.zoom(by: factor, around: location)
        }
        view.onMagnify = { magnification, location in
            engine.noteUserInteraction()
            engine.viewport.zoom(by: 1 + magnification, around: location)
        }
        return view
    }

    func updateNSView(_ nsView: ScrollZoomNSView, context: Context) {}

    static func dismantleNSView(_ nsView: ScrollZoomNSView, coordinator: ()) {
        nsView.teardownMonitor()
    }
}

/// Click-transparent (`allowsHitTesting(false)`); it only exists to anchor a
/// local scroll/magnify monitor to the graph's on-screen rect.
final class ScrollZoomNSView: NSView {
    var onScroll: ((Double, CGPoint) -> Void)?
    var onMagnify: ((Double, CGPoint) -> Void)?

    /// The opaque local-monitor token. `nonisolated(unsafe)` because it is
    /// only ever assigned on the main thread (NSView lifecycle callbacks) and
    /// read once in `deinit` to remove the monitor — `NSEvent.removeMonitor`
    /// is itself thread-safe, so this is sound and keeps the file clean under
    /// `-strict-concurrency=complete`.
    nonisolated(unsafe) private var monitor: Any?

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window == nil { teardownMonitor(); return }
        guard monitor == nil else { return }
        monitor = NSEvent.addLocalMonitorForEvents(matching: [.scrollWheel, .magnify]) {
            [weak self] event in
            MainActor.assumeIsolated {
                self?.handle(event)
            }
            return event   // never consume — normal scrolling stays intact
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

    /// Convert a window-space point to this view's flipped local space.
    private func localPoint(_ event: NSEvent) -> CGPoint? {
        guard let window, event.window === window else { return nil }
        let p = convert(event.locationInWindow, from: nil)
        guard bounds.contains(p) else { return nil }
        return CGPoint(x: p.x, y: bounds.height - p.y)
    }

    private func handle(_ event: NSEvent) {
        guard let location = localPoint(event) else { return }
        switch event.type {
        case .scrollWheel:
            let delta = event.hasPreciseScrollingDeltas
                ? event.scrollingDeltaY
                : event.scrollingDeltaY * 3
            guard delta != 0 else { return }
            onScroll?(Double(delta), location)
        case .magnify:
            onMagnify?(Double(event.magnification), location)
        default:
            break
        }
    }
}
