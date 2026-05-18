import SwiftUI
import Observation

/// An optional, caller-held handle for tuning and nudging a `ForceGraphView`'s
/// simulation imperatively — the standard SwiftUI "escape hatch" pattern for
/// the few actions that don't fit a declarative input (re-seed the layout,
/// jump to a fresh readable slice) plus live force tunables.
///
/// Passing one is optional; the public `ForceGraphView` initialiser keeps its
/// documented shape (the parameter is defaulted to `nil`). The Lab uses it to
/// drive the inspector knobs; ordinary callers never need it.
///
/// `@Observable @MainActor`, owned by the caller via `@State` — no
/// `ObservableObject`. The view's engine attaches itself on appear so the
/// controller can forward `reseed()` / `recenter()` and observe `parameters`.
@Observable
@MainActor
public final class GraphController {
    /// Live force tunables. Mutating this (e.g. from a Lab slider) is picked
    /// up by the attached engine, which reheats so the change is visible.
    public var parameters = ForceParameters.default

    /// Latest engine read-outs for inspector display.

    /// Current layout heat (`1` reheated → `0` settled).
    public private(set) var alpha: Double = 0
    /// Whether the layout has cooled to rest (idle ⇒ ~no CPU).
    public private(set) var isSettled: Bool = true
    /// On-screen edge crossings from the last settle-time detection. The true
    /// total (the drawn knot glyphs are a thinned subset); `0` when the layout
    /// is live or zoomed below the label-drop LOD.
    public private(set) var crossingCount = 0

    /// Set by the attached engine so the controller can drive it.
    @ObservationIgnored fileprivate weak var attachment: (any GraphControllable)?

    public init() {}

    /// Re-seed the deterministic initial layout and restart the simulation.
    public func reseed() {
        attachment?.controllerDidRequestReseed()
    }

    /// Open on a fresh readable slice and reheat (never fits the whole graph).
    public func recenter() {
        attachment?.controllerDidRequestRecenter()
    }

    // MARK: - Engine bridge (internal)

    func attach(_ engine: any GraphControllable) {
        attachment = engine
        engine.controllerDidUpdateParameters(parameters)
    }

    func publish(alpha: Double, isSettled: Bool, crossingCount: Int) {
        self.alpha = alpha
        self.isSettled = isSettled
        self.crossingCount = crossingCount
    }
}

/// What `GraphController` needs from the engine. Lets the generic
/// `GraphEngine<Value>` be driven without the controller knowing `Value`.
@MainActor
protocol GraphControllable: AnyObject {
    func controllerDidRequestReseed()
    func controllerDidRequestRecenter()
    func controllerDidUpdateParameters(_ parameters: ForceParameters)
}
