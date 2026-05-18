# ForceGraph

A fast, lively, colourful **force-directed graph of word nodes** for SwiftUI —
shipped as a Swift Package. Built for messy real-world label graphs (genres,
tags, topics): sparse, partly disconnected, far too big to fit on screen.

- **One public view**, `ForceGraphView`. Drop it in, hand it nodes + edges.
- **Live force layout** — settles organically, then idles at ~no CPU.
- **Click to focus** — the node pins to centre and the graph re-settles.
- **Type-anywhere search** — start typing over the graph; matches light up,
  the rest dims, narrowing to one centres it.
- **Edge-crossing knot glyphs** — small over/under marks make tangles legible
  without losing the focal structure, plus a live crossing count.
- **Zero-config colour** — a stable hash→hue palette; fully overridable.
- Independent **light & dark** palettes (not inverted), and a full
  accessibility pass (Reduce Motion, Increase Contrast, Differentiate Without
  Color, VoiceOver).

> **It never fits the whole graph — by design.** Real word graphs don't fit and
> shouldn't be crushed to dots. `ForceGraphView` opens at a *readable* zoom
> centred on one node, shows a dismissable "this is a slice" hint, and lets the
> user pan/scroll a fast, clipped slice. There is intentionally no `fit()`.

## Requirements

- **macOS 14 (Sonoma) or later.** The control relies on macOS-14 APIs
  (`@Observable`, the modern `Canvas`/`TimelineView`, scroll/key event
  monitors). It is a macOS control; there is no iOS target.
- Swift 5.10+ toolchain. **No third-party dependencies.**

## Install (Swift Package Manager)

In **Xcode**: File ▸ Add Package Dependencies… and point it at this
repository, or add it to your `Package.swift`:

```swift
// Package.swift
dependencies: [
    .package(url: "https://example.com/ForceGraph.git", from: "1.0.0")
],
targets: [
    .target(
        name: "MyApp",
        dependencies: [
            .product(name: "ForceGraph", package: "ForceGraph")
        ]
    )
]
```

Then `import ForceGraph`.

## Minimal usage

```swift
import SwiftUI
import ForceGraph

struct ContentView: View {
    @State private var selection: String?

    var body: some View {
        ForceGraphView(
            nodes: [
                GraphNode(id: "ambient", label: "Ambient"),
                GraphNode(id: "techno",  label: "Techno"),
                GraphNode(id: "dub",     label: "Dub"),
            ],
            edges: [
                GraphEdge(a: "ambient", b: "techno", weight: 0.6),
                GraphEdge(a: "techno",  b: "dub",    weight: 0.9),
            ],
            selection: $selection
        )
    }
}
```

That's the whole API surface most apps need. The view fills its container; lay
it out like any other SwiftUI view.

### Carrying your own data + custom styling

`GraphNode<Value>` carries an opaque caller payload the library never inspects.
Use it (and the style callback / `onActivate`) to drive your app's behaviour:

```swift
ForceGraphView(
    nodes: genres,                       // [GraphNode<Genre>]
    edges: relations,
    selection: $selectedID,
    style: { node, ctx in
        // Start from the built-in hash→hue, then tweak.
        var s = GraphNode.defaultStyle(node, ctx)
        if node.value.isFavourite { s.fontWeight = .bold }
        if ctx.searchActive, !ctx.isSearchMatch { s.opacity = 0.18 }
        return s
    },
    onActivate: { node in open(node.value) }   // double-click / Return
)
```

`NodeContext` tells your closure everything about the node's current state:
selection, BFS distance from the selection, hover, search match / active,
degree, and the live colour scheme. The default resolver is a pure stable
hash→hue (`Palette.fill(for:scheme:)` is public if you want library-consistent
colours in a custom closure).

### Imperative tuning (optional)

For a dev/inspector harness you can pass an optional `GraphController`
(`@State`-owned, `@Observable @MainActor`) to tweak `ForceParameters` live and
nudge the layout (`reseed()`, `recenter()`), plus read back `alpha` /
`isSettled`. Ordinary callers never need it — `ForceGraphView`'s initialiser
keeps its simple shape (the `controller:` argument is defaulted to `nil`).

## Public API

| Symbol | What it is |
|---|---|
| `ForceGraphView<Value>` | The single public SwiftUI control. |
| `GraphNode<Value>` | A node: `id`, `label`, opaque `value` payload. |
| `GraphEdge` | An undirected, weighted (`0...1`) edge. |
| `Graph<Value>` | Validated nodes + edges with adjacency & BFS `distances(from:)`. |
| `NodeContext` | State handed to the style callback. |
| `NodeStyle` | A fully resolved per-node visual style. |
| `GraphTypography` | The label type scale (roles + `emphasised(_:)`). |
| `Palette` | The stable hash→hue colour source (light/dark, not inverted). |
| `ForceParameters` | Tunable simulation constants (`Sendable`). |
| `GraphController` | Optional imperative handle for tuning / nudges. |

Everything else (the simulation, quadtree, viewport, crossing detector, search
model, key/scroll capture) is **internal** — the library deliberately exposes
one view and a small, value-typed support surface.

## The Lab app

`ForceGraphLab` (an executable target in this package) is a developer harness:
a single-window macOS app with a live inspector for force knobs, the corpus,
appearance, and read-outs. It is **not** part of the shipped library product —
it exists to tweak and perfect the control. Run it with
`swift run ForceGraphLab` (or `scripts/make-app.sh release` to get a real
`.app` bundle).

## License

See the repository for license details.
