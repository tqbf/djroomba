import simd

/// 2-D vector used for layout positions, velocities and forces
/// (library-internal).
///
/// Backed by `SIMD2<Double>` for cheap arithmetic. A typealias plus free
/// helpers so it stays a trivial `Sendable` value with no bridging cost. It is
/// an engine detail and does **not** appear in any public API signature —
/// callers work in node ids / labels, never positions.
typealias Vector2 = SIMD2<Double>

extension Vector2 {
    static let zero = Vector2(0, 0)

    var length: Double {
        (x * x + y * y).squareRoot()
    }

    var lengthSquared: Double {
        x * x + y * y
    }

    /// Unit vector, or `.zero` if this vector has (near-)zero length.
    var normalized: Vector2 {
        let len = length
        guard len > 1e-12 else { return .zero }
        return self / len
    }

    func distance(to other: Vector2) -> Double {
        (self - other).length
    }
}

/// Linear interpolation between two vectors. `t` is not clamped.
func lerp(_ a: Vector2, _ b: Vector2, _ t: Double) -> Vector2 {
    a + (b - a) * t
}
