//
//  ShelfLayout.swift
//  binderBuilder
//
//  Pure layout math for the data-driven shelf: where each binder stands on
//  the low slab (face-out until the row is crowded, then a spine-out book
//  row) and where the display cases sit on the high slab. Kept nonisolated
//  and geometry-only so it unit-tests without RealityKit.
//

import Foundation

nonisolated enum ShelfLayout {
    /// Where one binder stands, in binder-list order.
    struct BinderPlacement: Equatable {
        let x: Float
        let faceOut: Bool
        /// Z-axis lean in radians (the last spine-out book relaxes against
        /// the row). 0 for face-out and interior books.
        let lean: Float
    }

    static let faceOutWidth: Float = 0.26
    static let faceOutGap: Float = 0.02
    static let spineWidth: Float = 0.05
    static let spineGap: Float = 0.008
    /// Usable slab width for the binder row.
    static let rowWidth: Float = 1.10
    static let bookLean: Float = 0.14   // ~8 degrees

    /// Placements for `count` binders, index-aligned with the binder list.
    /// Up to 4 stand face-out, centered. Beyond that the open binder (or the
    /// first) faces out at the left and the rest line up spine-out like
    /// books, the last one leaning when there's slack.
    static func binderPlacements(count: Int, openIndex: Int?) -> [BinderPlacement] {
        guard count > 0 else { return [] }
        if count <= 4 {
            let total = Float(count) * faceOutWidth + Float(count - 1) * faceOutGap
            let leading = -total / 2 + faceOutWidth / 2
            return (0..<count).map { index in
                BinderPlacement(
                    x: leading + Float(index) * (faceOutWidth + faceOutGap),
                    faceOut: true,
                    lean: 0)
            }
        }

        let featured = min(max(openIndex ?? 0, 0), count - 1)
        let spineCount = count - 1
        let spineRun = Float(spineCount) * spineWidth + Float(spineCount - 1) * spineGap
        let total = faceOutWidth + faceOutGap + spineRun
        // Center the whole arrangement; if it overflows the slab, pin to the
        // left edge and let the tail run long (14+ binders — rare).
        let leading = max(-rowWidth / 2, -total / 2)
        let faceX = leading + faceOutWidth / 2
        let spineStart = leading + faceOutWidth + faceOutGap

        var placements: [BinderPlacement] = []
        var spineIndex = 0
        for index in 0..<count {
            if index == featured {
                placements.append(BinderPlacement(x: faceX, faceOut: true, lean: 0))
                continue
            }
            let x = spineStart + spineWidth / 2 + Float(spineIndex) * (spineWidth + spineGap)
            let isLast = spineIndex == spineCount - 1
            let hasSlack = total < rowWidth - 0.04
            placements.append(BinderPlacement(
                x: x,
                faceOut: false,
                lean: isLast && hasSlack ? bookLean : 0))
            spineIndex += 1
        }
        return placements
    }

    /// Evenly spaced, centered positions on the high slab. Three keep the
    /// classic 0.34 m spacing; more pack tighter. The ±0.36 budget keeps the
    /// outermost cases inside the shelf camera framing (visible half-width
    /// ~0.45, cases ~0.06 half-wide).
    private static func rowPositions(_ count: Int) -> [Float] {
        guard count > 0 else { return [] }
        let spacing = min(0.34, 0.72 / Float(max(count - 1, 1)))
        let leading = -spacing * Float(count - 1) / 2
        return (0..<count).map { leading + Float($0) * spacing }
    }

    /// Display-case x positions. With `reserveAddSlot` the row is laid out
    /// one wider so the ghost "add a display" pedestal occupies the final
    /// position (and stays on the slab).
    static func displayXs(count: Int, reserveAddSlot: Bool = false) -> [Float] {
        Array(rowPositions(reserveAddSlot ? count + 1 : count).prefix(count))
    }

    /// The ghost pedestal's position: the last slot of the widened row. nil
    /// once the row is at capacity.
    static func addSlotX(count: Int, maxCount: Int) -> Float? {
        guard count < maxCount else { return nil }
        return rowPositions(count + 1).last
    }
}
