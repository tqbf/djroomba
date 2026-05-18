import CoreGraphics

/// The model↔screen transform: a uniform `scale` plus a screen-space
/// `translation`.
///
/// A model point `p` maps to screen as `p * scale + translation`. The inverse
/// (used for hit-testing pointer locations) is `(s - translation) / scale`.
/// `Viewport` is a plain value type; `GraphEngine` owns one and mutates it in
/// response to pan/zoom gestures.
struct Viewport: Equatable, Sendable {
    /// Points-per-model-unit. Clamped to `zoomRange`.
    var scale: Double = 1
    /// Screen-space offset applied after scaling.
    var translation: CGSize = .zero

    /// The screen size we are currently laying out into. Kept so `fit` /
    /// `center` can recompute against the live viewport.
    var viewSize: CGSize = .zero

    static let zoomRange: ClosedRange<Double> = 0.05...8

    /// The zoom we open at: high enough that labels are comfortably readable.
    /// We never fit the whole graph — this is the readable "slice" scale.
    static let readableScale: Double = 1.0

    /// Below this scale the renderer drops labels and culls aggressively.
    static let labelDropScale: Double = 0.45

    var labelsVisible: Bool { scale >= Self.labelDropScale }

    // MARK: - Transforms

    func toScreen(_ p: Vector2) -> CGPoint {
        CGPoint(
            x: p.x * scale + translation.width,
            y: p.y * scale + translation.height
        )
    }

    func toModel(_ s: CGPoint) -> Vector2 {
        Vector2(
            (Double(s.x) - translation.width) / scale,
            (Double(s.y) - translation.height) / scale
        )
    }

    /// The model-space rectangle currently visible (used for viewport culling).
    func visibleModelRect() -> CGRect {
        guard scale > 0, viewSize != .zero else { return .infinite }
        let topLeft = toModel(.zero)
        let bottomRight = toModel(CGPoint(x: viewSize.width, y: viewSize.height))
        return CGRect(
            x: topLeft.x,
            y: topLeft.y,
            width: bottomRight.x - topLeft.x,
            height: bottomRight.y - topLeft.y
        )
    }

    // MARK: - Mutations

    private mutating func clampScale() {
        scale = min(max(scale, Self.zoomRange.lowerBound), Self.zoomRange.upperBound)
    }

    mutating func pan(by delta: CGSize) {
        translation.width += delta.width
        translation.height += delta.height
    }

    /// Zoom by `factor` keeping the model point under `anchor` (screen space)
    /// pinned — i.e. zoom toward the cursor.
    mutating func zoom(by factor: Double, around anchor: CGPoint) {
        let modelAnchor = toModel(anchor)
        scale *= factor
        clampScale()
        translation.width = Double(anchor.x) - modelAnchor.x * scale
        translation.height = Double(anchor.y) - modelAnchor.y * scale
    }

    mutating func setScale(_ newScale: Double, around anchor: CGPoint) {
        let modelAnchor = toModel(anchor)
        scale = newScale
        clampScale()
        translation.width = Double(anchor.x) - modelAnchor.x * scale
        translation.height = Double(anchor.y) - modelAnchor.y * scale
    }

    /// Ease (instantly here — animation is the caller's concern) a model point
    /// to the centre of the viewport, preserving the current scale.
    mutating func center(on modelPoint: Vector2) {
        guard viewSize.width > 0, viewSize.height > 0 else { return }
        translation = CGSize(
            width: viewSize.width / 2 - modelPoint.x * scale,
            height: viewSize.height / 2 - modelPoint.y * scale
        )
    }

    /// DJROOMBA PATCH (2): centre a model point AND bring the zoom to at
    /// least `minScale` (clamped) so the focused node is actually legible.
    /// `center(on:)` alone preserves the current scale, so cycling search
    /// matches while zoomed out just panned between unreadable dots. Never
    /// zooms *out* (a user already closer than `minScale` keeps their zoom);
    /// it only enforces a floor. To upstream: a public "focus on node" that
    /// search cycling uses instead of the pan-only `center`.
    mutating func focus(on modelPoint: Vector2, minScale: Double) {
        scale = max(scale, minScale)
        clampScale()
        center(on: modelPoint)
    }
}
