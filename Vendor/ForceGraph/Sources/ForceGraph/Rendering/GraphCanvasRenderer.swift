import SwiftUI

/// Pure draw routine: `(RenderSnapshot, Viewport, ColorScheme) → Canvas calls`.
///
/// Holds no state and reads only value types so it never causes view churn and
/// can be unit-reasoned about. Draw order is back-to-front per the rendering
/// spec: background → edges → **knot glyphs at crossings** → nodes →
/// selection/hover ring. The LOD + culling scaffold keeps 1,594 nodes at 60fps
/// when zoomed out; knot glyphs are LOD-suppressed (the engine only carries
/// them above the label-drop zoom) and the crossing set is detected once on
/// settle by `CrossingIndex`, never recomputed per frame.
enum GraphCanvasRenderer {
    static func draw(
        _ snapshot: RenderSnapshot,
        viewport: Viewport,
        scheme: ColorScheme,
        selection: NodeID?,
        hovered: NodeID?,
        pulsePhase: Double,
        boldStrokes: Bool,
        context: GraphicsContext,
        size: CGSize
    ) {
        // 1. Background — content area is opaque, never blurred.
        context.fill(
            Path(CGRect(origin: .zero, size: size)),
            with: .color(Palette.surface(for: scheme))
        )

        let cull = cullRect(for: size)
        let labels = viewport.labelsVisible

        // 2. Edges. Batched into a single Path per opacity bucket so the
        //    16,960-edge corpus is a handful of stroke calls, not thousands.
        drawEdges(
            snapshot,
            viewport: viewport,
            scheme: scheme,
            cull: cull,
            boldStrokes: boldStrokes,
            context: context
        )

        // 3. Knot glyphs at edge crossings. The engine only carries these
        //    above the LOD zoom and only recomputes them on settle, so this
        //    is a small set of cheap marks — the tangle reads as over/under
        //    without losing the focal structure. (Search active ⇒ skip: the
        //    dimmed edges are already near-invisible and matches are the
        //    point; knots would just add noise.)
        if labels, !snapshot.searchActive, !snapshot.crossings.isEmpty {
            drawCrossings(
                snapshot.crossings,
                scheme: scheme,
                cull: cull,
                boldStrokes: boldStrokes,
                context: context
            )
        }

        // 4. Nodes. Already ordered (ordinary → hub → selected) by the engine
        //    so hubs/selected sit on top — no per-frame sort. Only on-screen
        //    nodes are drawn: the view is a fast, clipped slice.
        for node in snapshot.nodes {
            let p = viewport.toScreen(node.position)
            guard cull.contains(p) else { continue }
            drawNode(
                node,
                at: p,
                viewport: viewport,
                drawLabel: labels,
                isSelected: node.id == selection,
                isHovered: node.id == hovered,
                pulsePhase: pulsePhase,
                context: context
            )
        }
    }

    // MARK: - Edges

    private static func drawEdges(
        _ snapshot: RenderSnapshot,
        viewport: Viewport,
        scheme: ColorScheme,
        cull: CGRect,
        boldStrokes: Bool,
        context: GraphicsContext
    ) {
        let searchActive = snapshot.searchActive
        // Buckets: faint / strong by weight, plus a "lit" bucket for
        // match-to-match edges while search is active (drawn brightest, last).
        var faint = Path()
        var strong = Path()
        var lit = Path()
        var focus = Path()
        for edge in snapshot.edges {
            let a = viewport.toScreen(edge.a)
            let b = viewport.toScreen(edge.b)
            // Cheap segment-vs-rect reject: skip only if both ends are off the
            // same side (keeps long edges that cross the viewport).
            if (a.x < cull.minX && b.x < cull.minX) ||
                (a.x > cull.maxX && b.x > cull.maxX) ||
                (a.y < cull.minY && b.y < cull.minY) ||
                (a.y > cull.maxY && b.y > cull.maxY) {
                continue
            }
            if searchActive && edge.bothMatch {
                lit.move(to: a)
                lit.addLine(to: b)
            } else if edge.incidentToFocus {
                // A connection from the focal node — collected for the
                // prominent pass so the neighbourhood is unmistakable.
                focus.move(to: a)
                focus.addLine(to: b)
            } else if edge.weight >= 0.6 {
                strong.move(to: a)
                strong.addLine(to: b)
            } else {
                faint.move(to: a)
                faint.addLine(to: b)
            }
        }
        let base: Color = scheme == .dark ? .white : .black
        // When search is active everything but match↔match edges dims hard so
        // the matched sub-structure pops; the graph shape is still readable.
        // `boldStrokes` is set under Increase Contrast *or* Differentiate
        // Without Color: it bumps every edge alpha so the structure is more
        // defined (and the over/under knot reads as a stronger non-colour
        // cue), without changing the palette hues. Honours the binding
        // accessibility rules.
        let cBoost = boldStrokes ? 1.9 : 1.0
        let faintAlpha = (searchActive ? 0.02 : 0.06) * cBoost
        let strongAlpha = (searchActive ? 0.04 : 0.14) * cBoost
        context.stroke(faint, with: .color(base.opacity(faintAlpha)), lineWidth: 0.75)
        context.stroke(strong, with: .color(base.opacity(strongAlpha)), lineWidth: 1.0)
        if searchActive {
            let litAlpha = boldStrokes ? 0.42 : 0.28
            context.stroke(lit, with: .color(base.opacity(litAlpha)), lineWidth: 1.25)
        }
        // Focal connections last, on top: a much heavier, brighter stroke so
        // it's immediately clear which nodes the centred node connects to.
        // `.primary` adapts to light/dark on its own.
        context.stroke(
            focus,
            with: .color(.primary.opacity(boldStrokes ? 0.85 : 0.6)),
            style: StrokeStyle(lineWidth: 2.4, lineCap: .round)
        )
    }

    // MARK: - Knot glyphs (edge crossings)

    /// Draw a small **over/under knot** at every detected crossing: the under-
    /// strand is broken with a clearance gap and the over-strand bridges across
    /// it, exactly like an ink knot/braid diagram. A small surface-coloured
    /// clearance disc desaturates/thins the tangle *locally* so the eye
    /// registers the crossing without the strands losing the focal structure
    /// around them. Cheap: a handful of short strokes per crossing, only above
    /// the LOD zoom, only computed on settle.
    private static func drawCrossings(
        _ crossings: [CrossingIndex.Crossing],
        scheme: ColorScheme,
        cull: CGRect,
        boldStrokes: Bool,
        context: GraphicsContext
    ) {
        let surface = Palette.surface(for: scheme)
        let strand: Color = scheme == .dark ? .white : .black
        // The over-strand reads a touch stronger than ordinary edges so the
        // bridge is legible; Increase Contrast strengthens it further.
        let overAlpha = boldStrokes ? 0.55 : 0.34
        let underAlpha = boldStrokes ? 0.34 : 0.20

        // Pixel sizes — small, fixed in screen space (knots shouldn't scale
        // with zoom, they're annotations).
        let reach: CGFloat = 9          // half-length of each drawn strand stub
        let clearance: CGFloat = 5      // gap punched in the under-strand
        let discRadius: CGFloat = 8     // local desaturation footprint

        for crossing in crossings {
            let p = crossing.point
            guard cull.contains(p) else { continue }

            let over = crossing.overDirection
            let under = crossing.underDirection

            // 1. Local "thin/desaturate" footprint: paint the surface colour
            //    softly over the tangle so the dense crossing of strands
            //    reads calmer right at the knot (it does not erase the edges
            //    elsewhere — only this small disc).
            let disc = Path(
                ellipseIn: CGRect(
                    x: p.x - discRadius, y: p.y - discRadius,
                    width: discRadius * 2, height: discRadius * 2
                )
            )
            context.fill(disc, with: .color(surface.opacity(0.72)))

            // 2. The under-strand: two stubs leaving a clearance gap at the
            //    crossing so it visually passes *beneath* the bridge.
            var underPath = Path()
            underPath.move(to: offset(p, under, clearance))
            underPath.addLine(to: offset(p, under, reach))
            underPath.move(to: offset(p, under, -clearance))
            underPath.addLine(to: offset(p, under, -reach))
            context.stroke(
                underPath,
                with: .color(strand.opacity(underAlpha)),
                style: StrokeStyle(lineWidth: 1.4, lineCap: .round)
            )

            // 3. The over-strand: one continuous stub bridging across the gap.
            var overPath = Path()
            overPath.move(to: offset(p, over, -reach))
            overPath.addLine(to: offset(p, over, reach))
            context.stroke(
                overPath,
                with: .color(strand.opacity(overAlpha)),
                style: StrokeStyle(lineWidth: 1.7, lineCap: .round)
            )
        }
    }

    private static func offset(_ p: CGPoint, _ d: CGVector, _ t: CGFloat) -> CGPoint {
        CGPoint(x: p.x + d.dx * t, y: p.y + d.dy * t)
    }

    // MARK: - Nodes

    private static func drawNode(
        _ node: RenderSnapshot.Node,
        at p: CGPoint,
        viewport: Viewport,
        drawLabel: Bool,
        isSelected: Bool,
        isHovered: Bool,
        pulsePhase: Double,
        context: GraphicsContext
    ) {
        let style = node.style
        // A lively but restrained pulse on search matches: a small synced
        // scale + a soft halo. `pulsePhase` is 0…1 (held at 1 under Reduce
        // Motion, so matches just sit at full emphasis — no motion).
        let pulse = node.isSearchMatch ? pulsePhase : 1.0

        guard drawLabel else {
            // LOD: below the label-drop scale just draw a coloured dot so the
            // overall graph shape stays readable. Matches keep full opacity
            // and pulse their radius so they're findable even zoomed out.
            let scale = node.isSearchMatch ? (1.0 + 0.5 * pulse) : 1.0
            let r = max(2.0, 3.0 * viewport.scale) * scale
            let dot = Path(ellipseIn: CGRect(x: p.x - r, y: p.y - r, width: 2 * r, height: 2 * r))
            context.fill(dot, with: .color(style.fill.opacity(style.opacity)))
            return
        }

        var text = Text(node.label)
            .font(.system(size: style.fontSize, weight: style.fontWeight))
        if style.tracking != 0 {
            text = text.tracking(style.tracking)
        }
        let resolved = context.resolve(text.foregroundStyle(style.textColor))
        let textSize = resolved.measure(in: CGSize(width: 600, height: 200))

        let capsuleSize = CGSize(
            width: textSize.width + style.capsulePadding.width * 2,
            height: textSize.height + style.capsulePadding.height * 2
        )
        let rect = CGRect(
            x: p.x - capsuleSize.width / 2,
            y: p.y - capsuleSize.height / 2,
            width: capsuleSize.width,
            height: capsuleSize.height
        )
        let capsule = Path(roundedRect: rect, cornerRadius: capsuleSize.height / 2)

        if node.isSearchMatch {
            // Soft pulsing halo so a match reads instantly without changing
            // the layout. Scale + opacity ride `pulse` (0…1); under Reduce
            // Motion `pulse` is pinned to 1 ⇒ a steady, motion-free halo.
            let grow = 6.0 + 5.0 * pulse
            let haloRect = rect.insetBy(dx: -grow, dy: -grow)
            let halo = Path(
                roundedRect: haloRect,
                cornerRadius: (capsuleSize.height + grow * 2) / 2
            )
            context.fill(
                halo,
                with: .color(style.fill.opacity(0.18 + 0.22 * pulse))
            )
        }

        context.fill(capsule, with: .color(style.fill.opacity(style.opacity)))

        if isSelected || isHovered {
            // Hairline ring; selection brighter than hover.
            context.stroke(
                capsule,
                with: .color(.primary.opacity(isSelected ? 0.85 : 0.45)),
                lineWidth: isSelected ? 1.5 : 1.0
            )
        }

        context.draw(resolved, at: p, anchor: .center)
    }

    // MARK: - LOD helpers

    /// Inflate the on-screen rect a little so capsules straddling the edge
    /// still draw.
    private static func cullRect(for size: CGSize) -> CGRect {
        CGRect(origin: .zero, size: size).insetBy(dx: -80, dy: -80)
    }
}
