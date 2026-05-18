import Foundation

/// A Barnes–Hut region quadtree used for O(n log n) repulsion.
///
/// The tree is stored in **flat, preallocated arrays** (struct-of-arrays) and
/// rebuilt in place every step: `rebuild(...)` resets a cursor and re-inserts
/// rather than allocating fresh nodes, so the hot path is allocation-free once
/// the buffers are warm. Each cell carries its aggregate mass and centre of
/// mass; when a cell's `size / distance < θ` it is treated as a single point
/// mass instead of being recursed into (the Barnes–Hut approximation).
///
/// Coordinates are model space. The root is square (the bounding box expanded
/// to a square) so the `size / distance` opening test is isotropic.
struct Quadtree {
    /// A cell. Internal cells have `childBase >= 0` pointing at the first of
    /// four contiguous children in quadrant order NW, NE, SW, SE
    /// (`childBase ..< childBase + 4`). Leaves have `childBase < 0`.
    ///
    /// `mass`, `comX`, `comY` accumulate the (possibly multiple, if coincident)
    /// bodies that landed in a leaf, and after `finalize()` hold the aggregate
    /// mass + centre of mass for the whole subtree.
    private struct Cell {
        var originX = 0.0
        var originY = 0.0
        var size = 0.0
        var childBase = -1
        var bodyIndex = -1
        var mass = 0.0
        var comX = 0.0
        var comY = 0.0
    }

    private var cells: [Cell] = []
    private var cellCount = 0
    private var scratch: [Int] = []

    /// Reserve buffers up front for `n` bodies (a quadtree over `n` points has
    /// at most ~`2n` internal+leaf cells; we reserve generously).
    init(capacity: Int) {
        reserve(capacity)
    }

    mutating func reserve(_ bodyCapacity: Int) {
        let needed = max(16, bodyCapacity * 4 + 8)
        if cells.count < needed {
            cells = [Cell](repeating: Cell(), count: needed)
        }
        if scratch.capacity < 256 { scratch.reserveCapacity(256) }
    }

    /// Rebuild the tree over `positions[i]` with per-node `masses[i]`,
    /// reusing existing buffers (allocation-free when capacity suffices).
    mutating func rebuild(positions: [Vector2], masses: [Double]) {
        let n = positions.count
        cellCount = 0
        guard n > 0 else { return }
        reserve(n)

        var minX = positions[0].x
        var maxX = positions[0].x
        var minY = positions[0].y
        var maxY = positions[0].y
        for i in 1..<n {
            let p = positions[i]
            if p.x < minX { minX = p.x }
            if p.x > maxX { maxX = p.x }
            if p.y < minY { minY = p.y }
            if p.y > maxY { maxY = p.y }
        }
        let span = max(maxX - minX, maxY - minY)
        let size = max(span, 1.0) * 1.0001 // strictly contain the far edge

        let root = allocCell()
        cells[root].originX = minX
        cells[root].originY = minY
        cells[root].size = size

        for i in 0..<n {
            insert(body: i, position: positions[i], mass: masses[i], root: root)
        }
        finalize()
    }

    // MARK: - Build internals

    private mutating func allocCell() -> Int {
        if cellCount == cells.count {
            cells.append(contentsOf: [Cell](repeating: Cell(), count: max(8, cells.count)))
        }
        let idx = cellCount
        cells[idx] = Cell()
        cellCount += 1
        return idx
    }

    private func quadrant(of p: Vector2, in cell: Cell) -> Int {
        let half = cell.size / 2
        let east = p.x >= cell.originX + half
        let south = p.y >= cell.originY + half
        // NW=0, NE=1, SW=2, SE=3
        return (south ? 2 : 0) + (east ? 1 : 0)
    }

    private mutating func subdivide(_ cell: Int) {
        let originX = cells[cell].originX
        let originY = cells[cell].originY
        let half = cells[cell].size / 2
        let base = cellCount
        for q in 0..<4 {
            let child = allocCell()
            let east = (q & 1) == 1
            let south = (q & 2) == 2
            cells[child].originX = originX + (east ? half : 0)
            cells[child].originY = originY + (south ? half : 0)
            cells[child].size = half
        }
        cells[cell].childBase = base
    }

    private mutating func insert(
        body: Int,
        position p: Vector2,
        mass m: Double,
        root: Int
    ) {
        var cell = root
        while true {
            if cells[cell].childBase >= 0 {
                cell = cells[cell].childBase + quadrant(of: p, in: cells[cell])
                continue
            }
            if cells[cell].bodyIndex < 0 && cells[cell].mass == 0 {
                // Empty leaf — take it.
                cells[cell].bodyIndex = body
                cells[cell].mass = m
                cells[cell].comX = p.x
                cells[cell].comY = p.y
                return
            }
            // Occupied leaf. If too small to subdivide meaningfully (coincident
            // or near-coincident points), accumulate into this leaf instead of
            // recursing forever.
            if cells[cell].size < 1e-6 {
                let total = cells[cell].mass + m
                cells[cell].comX = (cells[cell].comX * cells[cell].mass + p.x * m) / total
                cells[cell].comY = (cells[cell].comY * cells[cell].mass + p.y * m) / total
                cells[cell].mass = total
                return
            }
            // Push the resident body down, then continue placing `body`.
            let resX = cells[cell].comX
            let resY = cells[cell].comY
            let resMass = cells[cell].mass
            let resBody = cells[cell].bodyIndex
            cells[cell].bodyIndex = -1
            cells[cell].mass = 0
            subdivide(cell)
            let resChild = cells[cell].childBase + quadrant(of: Vector2(resX, resY), in: cells[cell])
            cells[resChild].bodyIndex = resBody
            cells[resChild].mass = resMass
            cells[resChild].comX = resX
            cells[resChild].comY = resY
            cell = cells[cell].childBase + quadrant(of: p, in: cells[cell])
        }
    }

    /// Post-order aggregation of mass + centre of mass. Children are always
    /// allocated *after* their parent, so one reverse sweep is a valid
    /// post-order. Leaf cells already hold their (point or coincident-cluster)
    /// mass/COM from `insert`; only internal cells need combining.
    private mutating func finalize() {
        var i = cellCount - 1
        while i >= 0 {
            let base = cells[i].childBase
            if base >= 0 {
                var m = 0.0
                var cx = 0.0
                var cy = 0.0
                for q in 0..<4 {
                    let ch = cells[base + q]
                    if ch.mass > 0 {
                        m += ch.mass
                        cx += ch.comX * ch.mass
                        cy += ch.comY * ch.mass
                    }
                }
                cells[i].mass = m
                if m > 0 {
                    cells[i].comX = cx / m
                    cells[i].comY = cy / m
                }
            }
            i -= 1
        }
    }

    // MARK: - Barnes–Hut force query

    /// Accumulate the repulsive force on `body` (located at `p`) from the whole
    /// tree into `force`. `k` is `k_r` (repulsion strength), `minDist` clamps
    /// the singular `1/d²` core, `theta` is the opening criterion. Iterative
    /// (explicit stack) and allocation-free: pass a reusable `stack` buffer.
    func repulsion(
        on body: Int,
        at p: Vector2,
        repulsion k: Double,
        theta: Double,
        minDist: Double,
        into force: inout Vector2,
        stack: inout [Int]
    ) {
        guard cellCount > 0 else { return }
        let thetaSq = theta * theta
        let minDistSq = minDist * minDist
        stack.removeAll(keepingCapacity: true)
        stack.append(0)
        while let idx = stack.popLast() {
            let cell = cells[idx]
            if cell.mass <= 0 { continue }

            let dx = cell.comX - p.x
            let dy = cell.comY - p.y
            var distSq = dx * dx + dy * dy

            if cell.childBase < 0 {
                // Leaf. Skip the body acting on itself (a single-occupant leaf
                // whose only body is `body`); coincident clusters still repel.
                if cell.bodyIndex == body { continue }
                if distSq < 1e-18 { continue }
                if distSq < minDistSq { distSq = minDistSq }
                let invDist = 1.0 / distSq.squareRoot()
                let mag = -k * cell.mass / distSq
                force.x += mag * dx * invDist
                force.y += mag * dy * invDist
                continue
            }

            // Internal cell: Barnes–Hut opening test `size² < θ² · dist²`.
            if cell.size * cell.size < thetaSq * distSq {
                if distSq < minDistSq { distSq = minDistSq }
                let invDist = 1.0 / distSq.squareRoot()
                let mag = -k * cell.mass / distSq
                force.x += mag * dx * invDist
                force.y += mag * dy * invDist
            } else {
                let base = cell.childBase
                stack.append(base)
                stack.append(base + 1)
                stack.append(base + 2)
                stack.append(base + 3)
            }
        }
    }
}
