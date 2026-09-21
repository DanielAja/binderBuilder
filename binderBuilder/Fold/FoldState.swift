//
//  FoldState.swift
//  binderBuilder
//
//  What the app knows about the device's fold, expressed in the terms the
//  binder cares about: where the crease runs, how far the hinge is closed,
//  and which slice of the screen the 3D binder should occupy.
//
//  Deliberately pure (CoreGraphics only, no SwiftUI, no new SDK symbols) so
//  every layout decision below is unit-testable and so a plain iPhone —
//  which reports no crease at all — walks the exact same code path with
//  `FoldState.none`.
//
//  The geometry is never hardcoded to a device. iOS reports the crease as a
//  *reserved region* (`GeometryProxy.reservedRegions(kind: .division)`) and
//  the hinge as a continuous angle; FoldReader feeds both in here and this
//  file derives the pose. So a crease that isn't dead-centre, a future
//  device with a different panel split, or a Stage Manager-ish resize all
//  land correctly without a special case.
//

import CoreGraphics
import Foundation

/// How the device is physically arranged right now.
nonisolated enum FoldPose: String, Sendable, CaseIterable {
    /// One continuous surface: a plain iPhone, or a Duo opened out flat.
    case flat
    /// Partly folded with the crease running top-to-bottom — held like a
    /// book, a panel under each thumb. The binder's spine lives on the crease.
    case book
    /// Partly folded with the crease running left-to-right — the lower panel
    /// resting on a table, the upper one standing up. Binder up top, controls
    /// on the flat half.
    case tabletop
    /// Shut, running on the outer display. Half a binder on a narrow screen
    /// is unreadable, so this pose shows one page at a time.
    case compact
}

/// Which way the crease runs, in view coordinates.
nonisolated enum FoldAxis: String, Sendable {
    case none
    /// Crease runs top-to-bottom; panels sit side by side.
    case vertical
    /// Crease runs left-to-right; panels sit above and below.
    case horizontal
}

/// The crease as the system reports it: a reserved region that content
/// should not rely on being readable through.
///
/// `isActive` is false while the device is flat — the region still has a
/// *position* (queried with `.includeInactive`), which is exactly what the
/// binder needs to keep its spine parked on the crease before you ever fold
/// anything.
nonisolated struct FoldCrease: Equatable, Sendable {
    var frame: CGRect
    var isActive: Bool

    init(frame: CGRect, isActive: Bool) {
        self.frame = frame
        self.isActive = isActive
    }
}

/// A snapshot of the fold, refreshed by `FoldReader`.
nonisolated struct FoldState: Equatable, Sendable {
    /// Size of the view the crease coordinates are expressed in.
    var viewport: CGSize
    /// Reserved division region, if this device has one.
    var crease: FoldCrease?
    /// Live hinge angle in degrees: 180 is flat, smaller is more closed.
    /// `nil` on hardware without a hinge.
    var hingeDegrees: Double?
    /// True when the hinge reports itself shut (we're on the outer display).
    var isShut: Bool

    init(
        viewport: CGSize = .zero,
        crease: FoldCrease? = nil,
        hingeDegrees: Double? = nil,
        isShut: Bool = false
    ) {
        self.viewport = viewport
        self.crease = crease
        self.hingeDegrees = hingeDegrees
        self.isShut = isShut
    }

    /// A device with no hinge at all — the default everywhere, and what every
    /// iPhone before the Duo keeps reporting forever.
    static let none = FoldState()

    /// True once the system has told us this device folds.
    var isFoldable: Bool { hingeDegrees != nil || crease != nil }

    // MARK: Derived geometry

    /// Which way the crease runs. Works for an inactive (zero-width) crease
    /// too: a flat device reports a degenerate rect that is still taller than
    /// it is wide for a book-style fold.
    var axis: FoldAxis {
        guard let crease, viewport.width > 0, viewport.height > 0 else { return .none }
        if crease.frame.width < crease.frame.height { return .vertical }
        if crease.frame.height < crease.frame.width { return .horizontal }
        return .none
    }

    var pose: FoldPose {
        if isShut { return .compact }
        guard let crease, crease.isActive else { return .flat }
        switch axis {
        case .vertical: return .book
        case .horizontal: return .tabletop
        case .none: return .flat
        }
    }

    /// Where the crease sits along its axis, 0...1. Half is the common case;
    /// this is read live so an off-centre crease still gets the spine.
    var creaseFraction: CGFloat {
        guard let crease else { return 0.5 }
        switch axis {
        case .vertical:
            guard viewport.width > 0 else { return 0.5 }
            return min(max(crease.frame.midX / viewport.width, 0), 1)
        case .horizontal:
            guard viewport.height > 0 else { return 0.5 }
            return min(max(crease.frame.midY / viewport.height, 0), 1)
        case .none:
            return 0.5
        }
    }

    /// How far shut the hinge is: 0 flat (180 degrees), 1 at `closedDegrees`
    /// or beyond. Drives every continuous response — the camera pitching to
    /// meet the panels, the gutter deepening — so the binder reacts while
    /// you fold rather than snapping between two layouts.
    static let closedDegrees: Double = 100

    var foldProgress: Float {
        guard let hingeDegrees else { return 0 }
        let span = 180 - Self.closedDegrees
        return Float(min(max((180 - hingeDegrees) / span, 0), 1))
    }

    /// The slice of the screen the 3D binder should fill.
    ///
    /// Book and flat give it everything — the point is a binder that reaches
    /// both edges with its spine on the crease. Tabletop hands the lower,
    /// table-flat panel to the controls and keeps the binder on the panel
    /// that's actually facing you.
    var stageRect: CGRect {
        let full = CGRect(origin: .zero, size: viewport)
        guard pose == .tabletop, let crease else { return full }
        let height = max(crease.frame.minY, viewport.height * 0.35)
        return CGRect(x: 0, y: 0, width: viewport.width, height: height)
    }

    /// The panel the controls move onto in tabletop pose; `nil` everywhere
    /// else, where controls stay floating over the scene.
    var trayRect: CGRect? {
        guard pose == .tabletop, let crease else { return nil }
        let top = min(crease.frame.maxY, viewport.height)
        guard viewport.height - top > 60 else { return nil }
        return CGRect(x: 0, y: top, width: viewport.width, height: viewport.height - top)
    }

    /// Horizontal offset from the middle of the screen to the middle of the
    /// panel on the trailing (right) side of a vertical crease; 0 when there
    /// is no crease to sit beside. A control centred on the screen in book
    /// pose is a control folded down the middle, so anything that would land
    /// there moves onto a panel instead.
    var trailingPanelCenterOffset: CGFloat {
        guard pose == .book, viewport.width > 0 else { return 0 }
        return creaseFraction * viewport.width / 2
    }

    /// The same, for the leading (left) panel.
    var leadingPanelCenterOffset: CGFloat {
        guard pose == .book, viewport.width > 0 else { return 0 }
        return (creaseFraction * viewport.width - viewport.width) / 2
    }
}
