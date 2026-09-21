//
//  FoldReader.swift
//  binderBuilder
//
//  The one file in the app that touches the iPhone Duo APIs. Everything else
//  reads `@Environment(\.fold)` and gets a plain `FoldState` value, so the
//  fold-aware layout and the 3D staging stay testable and stay buildable on
//  hardware that never folds.
//
//  Two system inputs, both new in iOS 27.1:
//
//  - `GeometryProxy.reservedRegions(kind: .division, options: .includeInactive)`
//    gives the crease as a rect in view coordinates. `.includeInactive`
//    matters: flat, the region is zero-width but still POSITIONED, which is
//    what lets the binder park its spine on the crease before you fold
//    anything, so opening the device doesn't shove the spine sideways.
//
//  - `.onHingeChange` gives the continuous hinge angle plus a coarse
//    closed / partiallyOpen / fullyOpen status. The angle is what drives the
//    camera and the gutter continuously (see BinderStage) — the binder reacts
//    *while* you fold, instead of snapping between two layouts at a
//    threshold.
//
//  Availability. The SDK symbols only exist in the iOS 27.1 SDK, and no
//  compiler conditional can see an SDK version: Xcode 27.0 already ships
//  Swift 6.4, so `#if compiler(>=6.4)` is true there while the symbols are
//  still absent. They therefore sit behind the `DUO_SDK` compilation
//  condition, which is OFF by default and set in the target's
//  SWIFT_ACTIVE_COMPILATION_CONDITIONS once Xcode 27.1 is installed, plus the
//  usual `@available` runtime check. Without it the app compiles on Xcode
//  27.0 and simply reports `FoldState.none` — every device looks like a
//  regular iPhone, which is the pre-existing behaviour. The `-fold` launch
//  argument below still exercises every fold layout on an ordinary
//  simulator, so the staging stays verifiable in the meantime.
//

import SwiftUI

// MARK: - Environment

private struct FoldStateKey: EnvironmentKey {
    static let defaultValue = FoldState.none
}

extension EnvironmentValues {
    /// The live fold, or `FoldState.none` on hardware that doesn't fold.
    var fold: FoldState {
        get { self[FoldStateKey.self] }
        set { self[FoldStateKey.self] = newValue }
    }
}

extension View {
    /// Installs the fold reader and publishes `\.fold` to everything below.
    /// Applied once, at the app's root.
    func foldAware() -> some View {
        modifier(FoldReader())
    }
}

// MARK: - Reader

/// Geometry half of the reading: viewport plus crease, refreshed by
/// `onGeometryChange` whenever *any* of it moves — including a crease that
/// becomes active without the view resizing.
nonisolated struct FoldGeometry: Equatable, Sendable {
    var viewport: CGSize = .zero
    var crease: FoldCrease?
}

private struct FoldReader: ViewModifier {
    @State private var geometry = FoldGeometry()
    @State private var hingeDegrees: Double?
    @State private var isShut = false

    func body(content: Content) -> some View {
        content
            .environment(\.fold, resolved)
            .onGeometryChange(for: FoldGeometry.self) { proxy in
                FoldGeometry(viewport: proxy.size, crease: FoldSupport.crease(in: proxy))
            } action: { reading in
                geometry = reading
            }
            .trackingHinge { degrees, shut in
                hingeDegrees = degrees
                isShut = shut
            }
    }

    /// Live reading, unless a debug launch argument is simulating a pose.
    private var resolved: FoldState {
        let live = FoldState(
            viewport: geometry.viewport,
            crease: geometry.crease,
            hingeDegrees: hingeDegrees,
            isShut: isShut
        )
        return FoldSupport.simulated(over: live) ?? live
    }
}

// MARK: - System bridge

nonisolated enum FoldSupport {
    /// Reads the crease out of a geometry proxy. Returns `nil` on any device
    /// or SDK without the Duo APIs.
    static func crease(in proxy: GeometryProxy) -> FoldCrease? {
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            let regions = proxy.reservedRegions(kind: .division, options: .includeInactive)
            // A single fold today; if a device ever reports two, the widest
            // span is the one the binder should straddle.
            guard let region = regions.max(by: {
                max($0.frame.width, $0.frame.height) < max($1.frame.width, $1.frame.height)
            }) else { return nil }
            return FoldCrease(frame: region.frame, isActive: region.isActive)
        }
        #endif
        return nil
    }

    /// The fold as measured in one particular view's coordinate space.
    ///
    /// The crease rect is only meaningful relative to the proxy it came from,
    /// so a view that has to line real geometry up with the crease — the 3D
    /// binder putting its spine there — reads it from its OWN proxy rather
    /// than trusting the root's. The hinge angle is device-wide, so that part
    /// comes from the environment.
    static func fold(in proxy: GeometryProxy, hinge: FoldState) -> FoldState {
        let local = FoldState(
            viewport: proxy.size,
            crease: crease(in: proxy),
            hingeDegrees: hinge.hingeDegrees,
            isShut: hinge.isShut
        )
        return simulated(over: local) ?? local
    }

    /// `-fold <pose> [-hinge <degrees>]` fakes a crease down (or across) the
    /// middle of the viewport so the Duo layouts can be exercised, and
    /// screenshot-verified by tools/verify.sh, on any simulator.
    static func simulated(over live: FoldState) -> FoldState? {
        let launch = DebugLaunchState.current
        guard let pose = launch.foldPose else { return nil }
        let viewport = live.viewport
        guard viewport.width > 0, viewport.height > 0 else { return nil }

        let defaultDegrees: Double
        switch pose {
        case .flat: defaultDegrees = 180
        case .book, .tabletop: defaultDegrees = 115
        case .compact: defaultDegrees = 0
        }
        let degrees = launch.hingeDegrees ?? defaultDegrees

        // Flat reports a zero-width crease that is still positioned; a folded
        // device reports a real band. Match that so the derivation in
        // FoldState sees exactly the shape the system would hand it.
        let thickness: CGFloat = pose == .flat ? 0 : 14
        let crease: FoldCrease?
        switch pose {
        case .compact:
            crease = nil
        case .flat, .book:
            crease = FoldCrease(
                frame: CGRect(
                    x: viewport.width / 2 - thickness / 2, y: 0,
                    width: thickness, height: viewport.height),
                isActive: pose != .flat)
        case .tabletop:
            crease = FoldCrease(
                frame: CGRect(
                    x: 0, y: viewport.height / 2 - thickness / 2,
                    width: viewport.width, height: thickness),
                isActive: true)
        }

        return FoldState(
            viewport: viewport,
            crease: crease,
            hingeDegrees: degrees,
            isShut: pose == .compact
        )
    }
}

private extension View {
    /// Subscribes to hinge updates where the SDK has them; a no-op otherwise.
    @ViewBuilder
    func trackingHinge(_ onChange: @escaping (Double?, Bool) -> Void) -> some View {
        #if DUO_SDK
        if #available(iOS 27.1, *) {
            self.onHingeChange { _, context in
                guard let hinge = context.hinge else {
                    onChange(nil, false)
                    return
                }
                onChange(hinge.angle.degrees, hinge.status == .closed)
            }
        } else {
            self
        }
        #else
        self
        #endif
    }
}
