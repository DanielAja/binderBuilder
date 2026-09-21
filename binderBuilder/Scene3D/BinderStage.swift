//
//  BinderStage.swift
//  binderBuilder
//
//  Turns a FoldState into the two things the 3D binder needs: where the
//  camera goes (a CameraRig.Stage) and how the binder dresses itself (how
//  deep the gutter reads under the crease).
//
//  The idea, in one line: on a folding device the *device* is the binder.
//
//  - Opened out flat there is no physical fold, so the binder supplies all
//    of the depth itself — an oblique desk view across the whole display,
//    spine and ring mechanism catching the light, thickness visible.
//  - Folded into book pose the two panels already form the V of an open
//    book, so the binder stops pretending: the camera swings overhead as the
//    hinge closes, each page ends up face-on and un-foreshortened, filling
//    its own panel, and the crease does the job of the spine. The gutter
//    darkens along it so the seam reads as the binder's own shadow instead
//    of a line through the artwork.
//  - Either way the spread is centred on the crease, not on the screen, so
//    the spine lands where the hardware actually bends.
//
//  All of it is driven by the live hinge angle rather than a pose
//  threshold, so the binder settles into place continuously while you fold.
//
//  Pure math over value types, so the whole policy is unit-testable without
//  a scene or a device.
//

import CoreGraphics
import Foundation
import simd

nonisolated enum BinderStage {

    // MARK: Tuning

    /// Oblique-to-overhead blend when the display is one flat surface. A
    /// little more top-down than the phone's tuned view, because a wide
    /// display has the room for the binder's depth.
    static let flatElevation: Float = 0.35
    /// Blend added as the hinge closes into book pose: at a full fold the
    /// camera is nearly straight overhead and each page reads square-on.
    static let bookElevationGain: Float = 0.5
    /// Tabletop keeps the tuned oblique view — the upright panel is already
    /// facing you, and a binder propped up there should look propped up.
    static let tabletopElevation: Float = 0

    /// Distance clamp for a folding device. Looser floor than the phone's,
    /// or the binder strands itself in the middle of a big unfolded display
    /// (the 0.75 floor was tuned for phone aspect ratios).
    static let foldedClamp: ClosedRange<Float> = 0.42...1.8
    /// Single-page framing on the outer display wants to come closer still.
    static let compactClamp: ClosedRange<Float> = 0.60...1.8

    /// Half-width of one page plus its margin, for the compact framing.
    static let pageHalfWidth: Float = 0.135
    /// Centre of the right-hand page in binder space.
    static let pageCenterX: Float = 0.125

    // MARK: Camera

    /// The camera stage for the open binder under the current fold.
    static func stage(fold: FoldState, viewport: CGSize) -> CameraRig.Stage {
        guard viewport.width > 0, viewport.height > 0 else {
            return CameraRig.Stage(viewport: viewport)
        }
        // No hinge: the binder keeps exactly the framing it has always had.
        guard fold.isFoldable else { return CameraRig.Stage(viewport: viewport) }

        switch fold.pose {
        case .compact:
            // Half a spread on the outer display is unreadable, so zoom to a
            // single page and centre on it.
            return CameraRig.Stage(
                viewport: viewport,
                elevationBlend: 0.5,
                subjectHalfWidth: pageHalfWidth,
                focus: SIMD3<Float>(pageCenterX, 0, 0),
                distanceClamp: compactClamp
            )

        case .tabletop:
            return CameraRig.Stage(
                viewport: viewport,
                frame: fold.stageRect,
                elevationBlend: tabletopElevation,
                distanceClamp: foldedClamp
            )

        case .flat, .book:
            return CameraRig.Stage(
                viewport: viewport,
                frame: spreadFrame(fold: fold, viewport: viewport),
                elevationBlend: flatElevation + bookElevationGain * fold.foldProgress,
                distanceClamp: foldedClamp
            )
        }
    }

    /// The rect the spread has to fill: full height, and as wide as it can be
    /// while staying symmetric about the crease. Symmetry is the point — a
    /// spread whose spine isn't on the crease has one page spilling across
    /// the bend, which is the single thing that breaks the illusion.
    static func spreadFrame(fold: FoldState, viewport: CGSize) -> CGRect {
        let full = CGRect(origin: .zero, size: viewport)
        guard fold.axis == .vertical else { return full }
        let creaseX = fold.creaseFraction * viewport.width
        let halfSpan = min(creaseX, viewport.width - creaseX)
        guard halfSpan > 1 else { return full }
        return CGRect(x: creaseX - halfSpan, y: 0, width: 2 * halfSpan, height: viewport.height)
    }

    // MARK: Binder dressing

    /// How the binder's own hardware responds to the fold.
    nonisolated struct Dressing: Equatable, Sendable {
        /// 0 = flat lighting across the gutter, 1 = a deep shadowed trough.
        /// Grows as the panels close so the seam between them reads as the
        /// binder's gutter rather than as a gap in the picture.
        var gutterDepth: Float
        /// World width (m) the gutter trough spans. Widened under an active
        /// crease so the hardware bend has only binder spine beneath it, never
        /// card art.
        var gutterWidth: Float
        /// Whether the spread is showing both pages.
        var showsSpread: Bool
    }

    /// Narrowest the gutter ever gets: the spine gap the binder already has.
    static let baseGutterWidth: Float = 0.03
    /// Widest the gutter opens under a fully closed hinge.
    static let maxGutterWidth: Float = 0.055

    static func dressing(fold: FoldState) -> Dressing {
        guard fold.isFoldable else {
            return Dressing(gutterDepth: 0, gutterWidth: baseGutterWidth, showsSpread: true)
        }
        if fold.pose == .compact {
            return Dressing(gutterDepth: 0, gutterWidth: baseGutterWidth, showsSpread: false)
        }
        let progress = fold.foldProgress
        return Dressing(
            gutterDepth: progress,
            gutterWidth: baseGutterWidth + (maxGutterWidth - baseGutterWidth) * progress,
            showsSpread: true
        )
    }
}
