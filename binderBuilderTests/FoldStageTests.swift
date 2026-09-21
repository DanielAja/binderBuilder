//
//  FoldStageTests.swift
//  binderBuilderTests
//
//  Unit tests for the iPhone Duo adaptation: deriving a pose from the hinge
//  and the crease's reserved region, the camera stage that follows from it,
//  and the binder hardware that dresses itself for the fold.
//
//  The load-bearing claim, and the reason these are tests rather than a
//  screenshot: the binder's spine must project ONTO the crease. If it
//  doesn't, one page spills across the bend and the whole illusion goes.
//  `projectsOnto...` below checks that by unprojecting the solved camera.
//

import CoreGraphics
import Foundation
import RealityKit
import Testing
import simd
@testable import binderBuilder

// MARK: - Fixtures

private let unfolded = CGSize(width: 960, height: 676)
private let phone = CGSize(width: 393, height: 724)

/// A book-style crease running top to bottom, `thickness` wide.
private func verticalCrease(
    in size: CGSize, at fraction: CGFloat = 0.5, thickness: CGFloat, active: Bool
) -> FoldCrease {
    FoldCrease(
        frame: CGRect(
            x: size.width * fraction - thickness / 2, y: 0,
            width: thickness, height: size.height),
        isActive: active)
}

private func horizontalCrease(in size: CGSize, thickness: CGFloat) -> FoldCrease {
    FoldCrease(
        frame: CGRect(
            x: 0, y: size.height / 2 - thickness / 2,
            width: size.width, height: thickness),
        isActive: true)
}

// MARK: - Pose derivation

struct FoldStateTests {
    @Test func plainPhoneReportsNothingToAdaptTo() {
        let state = FoldState(viewport: phone)
        #expect(!state.isFoldable)
        #expect(state.pose == .flat)
        #expect(state.axis == .none)
        #expect(state.foldProgress == 0)
        #expect(state.trayRect == nil)
        #expect(state.stageRect == CGRect(origin: .zero, size: phone))
    }

    @Test func openedFlatStillKnowsWhereTheCreaseIs() {
        // Flat, the division region is inactive and zero-width — but it is
        // still positioned, which is the whole point of .includeInactive:
        // the spine can be parked on the crease before anything folds.
        let state = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, thickness: 0, active: false),
            hingeDegrees: 180)
        #expect(state.isFoldable)
        #expect(state.pose == .flat)
        #expect(state.axis == .vertical)
        #expect(abs(state.creaseFraction - 0.5) < 1e-6)
        #expect(state.foldProgress == 0)
        // Nothing is folded yet, so nothing has to step off the crease.
        #expect(state.trailingPanelCenterOffset == 0)
    }

    @Test func halfFoldedWithAVerticalCreaseIsBookPose() {
        let state = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, thickness: 14, active: true),
            hingeDegrees: 120)
        #expect(state.pose == .book)
        #expect(state.axis == .vertical)
        // Both panels stay the binder's, spine on the bend.
        #expect(state.stageRect == CGRect(origin: .zero, size: unfolded))
        #expect(state.trayRect == nil)
    }

    @Test func halfFoldedWithAHorizontalCreaseIsTabletopPose() {
        let state = FoldState(
            viewport: unfolded,
            crease: horizontalCrease(in: unfolded, thickness: 14),
            hingeDegrees: 115)
        #expect(state.pose == .tabletop)
        #expect(state.axis == .horizontal)
        // Binder on the upright panel, controls on the one lying flat.
        #expect(state.stageRect.maxY <= unfolded.height / 2)
        #expect((state.trayRect?.minY ?? 0) >= unfolded.height / 2)
        #expect((state.trayRect?.height ?? 0) > 100)
    }

    @Test func shutMeansTheOuterDisplay() {
        let state = FoldState(viewport: phone, hingeDegrees: 0, isShut: true)
        #expect(state.pose == .compact)
        #expect(state.isFoldable)
    }

    @Test func foldProgressRampsContinuouslyAsTheHingeCloses() {
        func progress(_ degrees: Double) -> Float {
            FoldState(viewport: unfolded, hingeDegrees: degrees).foldProgress
        }
        #expect(progress(180) == 0)
        #expect(abs(progress(140) - 0.5) < 1e-5)
        #expect(progress(100) == 1)
        // Past the modelled range it saturates rather than overshooting.
        #expect(progress(70) == 1)
        // Strictly increasing in between — the scene has to settle smoothly,
        // not snap at a threshold.
        var previous = progress(180)
        for degrees in stride(from: 175.0, through: 105.0, by: -5.0) {
            let current = progress(degrees)
            #expect(current > previous)
            previous = current
        }
    }

    @Test func panelOffsetsMoveControlsOffTheCrease() {
        let book = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, thickness: 14, active: true),
            hingeDegrees: 120)
        // Screen centre is the crease; the panels' centres are a quarter of
        // the display either side of it.
        #expect(abs(book.trailingPanelCenterOffset - unfolded.width / 4) < 0.5)
        #expect(abs(book.leadingPanelCenterOffset + unfolded.width / 4) < 0.5)
        // Flat and on a phone there is no crease to dodge.
        #expect(FoldState(viewport: phone).trailingPanelCenterOffset == 0)
    }

    @Test func anOffCentreCreaseIsTrackedRatherThanAssumed() {
        let state = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, at: 0.42, thickness: 12, active: true),
            hingeDegrees: 130)
        #expect(abs(state.creaseFraction - 0.42) < 1e-6)
        #expect(abs(state.trailingPanelCenterOffset - unfolded.width * 0.21) < 0.5)
    }
}

// MARK: - Stage policy

struct BinderStagePolicyTests {
    @Test func aPhoneKeepsExactlyTheFramingItAlwaysHad() {
        // Regression anchor: nothing about the non-folding path may move.
        let stage = BinderStage.stage(fold: FoldState(viewport: phone), viewport: phone)
        #expect(stage.frame == CGRect(origin: .zero, size: phone))
        #expect(stage.elevationBlend == 0)
        #expect(stage.subjectHalfWidth == nil)
        #expect(stage.focus == .zero)
        #expect(stage.distanceClamp == CameraRig.distanceClamp)
    }

    @Test func theSpreadFrameStaysSymmetricAboutAnOffCentreCrease() {
        let fold = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, at: 0.4, thickness: 12, active: true),
            hingeDegrees: 125)
        let frame = BinderStage.spreadFrame(fold: fold, viewport: unfolded)
        let creaseX = unfolded.width * 0.4
        #expect(abs(frame.midX - creaseX) < 0.5)
        // Symmetric means the narrower panel sets the budget, so the spread
        // can't overhang the display on the wide side.
        #expect(frame.minX >= -0.5)
        #expect(frame.maxX <= unfolded.width + 0.5)
        #expect(abs(frame.width - 2 * min(creaseX, unfolded.width - creaseX)) < 0.5)
    }

    @Test func closingTheHingeSwingsTheCameraOverhead() {
        func blend(_ degrees: Double) -> Float {
            BinderStage.stage(
                fold: FoldState(
                    viewport: unfolded,
                    crease: verticalCrease(in: unfolded, thickness: 14, active: degrees < 175),
                    hingeDegrees: degrees),
                viewport: unfolded
            ).elevationBlend
        }
        // Flat: a little more top-down than the phone, but still an oblique
        // desk view — the binder supplies its own depth.
        #expect(abs(blend(180) - BinderStage.flatElevation) < 1e-5)
        // Folded into book pose: nearly overhead, so each page reads square-on
        // to the panel it is sitting on.
        #expect(
            abs(blend(100) - (BinderStage.flatElevation + BinderStage.bookElevationGain)) < 1e-5)
        #expect(blend(140) > blend(180))
        #expect(blend(110) > blend(140))
    }

    @Test func aWideUnfoldedDisplayIsAllowedToBringTheBinderCloser() {
        let fold = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, thickness: 0, active: false),
            hingeDegrees: 180)
        let stage = BinderStage.stage(fold: fold, viewport: unfolded)
        #expect(stage.distanceClamp == BinderStage.foldedClamp)
        #expect(stage.distanceClamp.lowerBound < CameraRig.distanceClamp.lowerBound)
    }

    @Test func tabletopGivesTheBinderTheUprightPanelOnly() {
        let fold = FoldState(
            viewport: unfolded,
            crease: horizontalCrease(in: unfolded, thickness: 14),
            hingeDegrees: 115)
        let stage = BinderStage.stage(fold: fold, viewport: unfolded)
        #expect(stage.frame.maxY <= unfolded.height / 2 + 0.5)
        #expect(stage.elevationBlend == BinderStage.tabletopElevation)
    }

    @Test func theOuterDisplayShowsOnePage() {
        let fold = FoldState(viewport: phone, hingeDegrees: 0, isShut: true)
        let stage = BinderStage.stage(fold: fold, viewport: phone)
        #expect(stage.subjectHalfWidth == BinderStage.pageHalfWidth)
        // Framed on the right-hand page, not on the spine.
        #expect(stage.focus.x == BinderStage.pageCenterX)
        // A page is less than half a spread, so this really is a zoom in.
        #expect(BinderStage.pageHalfWidth < CameraRig.Framing.binderOpen.subjectHalfWidth)
    }

    @Test func theGutterDeepensAndWidensWithTheFold() {
        func dressing(_ degrees: Double) -> BinderStage.Dressing {
            BinderStage.dressing(
                fold: FoldState(
                    viewport: unfolded,
                    crease: verticalCrease(in: unfolded, thickness: 14, active: true),
                    hingeDegrees: degrees))
        }
        let flat = dressing(180)
        let folded = dressing(100)
        #expect(flat.gutterDepth == 0)
        #expect(folded.gutterDepth == 1)
        #expect(folded.gutterWidth > flat.gutterWidth)
        #expect(flat.gutterWidth == BinderStage.baseGutterWidth)
        #expect(abs(folded.gutterWidth - BinderStage.maxGutterWidth) < 1e-6)
        // A phone's binder is dressed exactly as it always was.
        let plain = BinderStage.dressing(fold: FoldState(viewport: phone))
        #expect(plain.gutterDepth == 0)
        #expect(plain.gutterWidth == BinderStage.baseGutterWidth)
        #expect(plain.showsSpread)
        // The outer display shows one page, so there is no gutter to dress.
        #expect(!BinderStage.dressing(
            fold: FoldState(viewport: phone, hingeDegrees: 0, isShut: true)).showsSpread)
    }
}

// MARK: - Camera solve

struct CameraStageTests {
    private let fov: Float = 55

    private func solve(_ stage: CameraRig.Stage) -> (transform: Transform, distance: Float) {
        CameraRig.stageSolve(framing: .binderOpen, stage: stage, fovDegrees: fov)
    }

    /// Projects a world point to screen points through a camera transform —
    /// the inverse of CameraRig.ray, so the two have to agree about the
    /// convention (camera looks down its own -z).
    private func project(_ world: SIMD3<Float>, _ transform: Transform, _ viewport: CGSize) -> CGPoint {
        let inverse = transform.matrix.inverse
        let p = inverse * SIMD4<Float>(world.x, world.y, world.z, 1)
        let tanHalfFov = tan(fov * .pi / 360)
        let aspect = Float(viewport.width / viewport.height)
        let ndcX = (p.x / -p.z) / (tanHalfFov * aspect)
        let ndcY = (p.y / -p.z) / tanHalfFov
        return CGPoint(
            x: CGFloat((ndcX + 1) / 2) * viewport.width,
            y: CGFloat((1 - ndcY) / 2) * viewport.height)
    }

    @Test func aFullFrameStageReproducesTheLegacyFraming() {
        // The phone path must land on exactly the distance the old
        // aspect-only solve produced, for every aspect it was tuned against.
        let framing = CameraRig.Framing.binderOpen
        for size in [phone, CGSize(width: 375, height: 667), CGSize(width: 834, height: 1030)] {
            let staged = solve(CameraRig.Stage(viewport: size)).distance
            let legacy = CameraRig.framingDistance(
                subjectHalfWidth: framing.subjectHalfWidth,
                tunedDistance: framing.tunedDistance,
                aspect: Float(size.width / size.height),
                fovDegrees: fov)
            #expect(abs(staged - legacy) < 1e-4)
        }
    }

    @Test func aFullFrameStageLeavesTheCameraUnshifted() {
        let transform = solve(CameraRig.Stage(viewport: phone)).transform
        let centre = project(CameraRig.Framing.binderOpen.at, transform, phone)
        #expect(abs(centre.x - phone.width / 2) < 0.5)
        #expect(abs(centre.y - phone.height / 2) < 0.5)
    }

    @Test func theSpineProjectsOntoAnOffCentreCrease() {
        // The claim the whole adaptation rests on. Crease at 40% of the
        // display: the binder's spine has to land there, not at 50%.
        let fold = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, at: 0.4, thickness: 14, active: true),
            hingeDegrees: 120)
        let stage = BinderStage.stage(fold: fold, viewport: unfolded)
        let spine = project(CameraRig.Framing.binderOpen.at, solve(stage).transform, unfolded)
        #expect(abs(spine.x - unfolded.width * 0.4) < 1.0)
    }

    @Test func tabletopLiftsTheBinderOntoTheUprightPanel() {
        let fold = FoldState(
            viewport: unfolded,
            crease: horizontalCrease(in: unfolded, thickness: 14),
            hingeDegrees: 115)
        let stage = BinderStage.stage(fold: fold, viewport: unfolded)
        let solved = solve(stage)
        let centre = project(CameraRig.Framing.binderOpen.at, solved.transform, unfolded)
        // Centred in the upper panel, well clear of the crease.
        #expect(abs(centre.y - stage.frame.midY) < 1.0)
        #expect(centre.y < unfolded.height / 2)
        // And pulled back, because it now has to fit in half the height.
        let fullPanel = solve(
            CameraRig.Stage(viewport: unfolded, distanceClamp: BinderStage.foldedClamp)).distance
        #expect(solved.distance > fullPanel)
    }

    @Test func elevationBlendRaisesTheCameraWithoutSwingingItAround() {
        let at = CameraRig.Framing.binderOpen.at
        let flat = solve(CameraRig.Stage(viewport: unfolded, elevationBlend: 0)).transform
        let overhead = solve(CameraRig.Stage(viewport: unfolded, elevationBlend: 1)).transform
        #expect(overhead.translation.y > flat.translation.y)
        // Nearly overhead, but never exactly on the pole — the look-at basis
        // degenerates against world up there.
        let direction = simd_normalize(overhead.translation - at)
        #expect(direction.y > 0.99)
        #expect(direction.y < 1.0)
        // Same bearing: it rises over the binder, it doesn't orbit it.
        #expect(abs(direction.x) < 1e-5)
        #expect(direction.z > 0)
    }

    @Test func aWideDisplayIsFilledRatherThanStranded() {
        // The bug this fixes: the phone-tuned distance floor left the binder
        // marooned in the middle of a big unfolded display.
        let fold = FoldState(
            viewport: unfolded,
            crease: verticalCrease(in: unfolded, thickness: 0, active: false),
            hingeDegrees: 180)
        let stage = BinderStage.stage(fold: fold, viewport: unfolded)
        let distance = solve(stage).distance
        let aspect = Float(unfolded.width / unfolded.height)
        let visibleWidth = 2 * distance * tan(fov * .pi / 360) * aspect
        let fill = 2 * CameraRig.Framing.binderOpen.subjectHalfWidth / visibleWidth
        #expect(fill > 0.80)
        // With the phone's clamp it would have been far worse.
        let stranded = solve(
            CameraRig.Stage(viewport: unfolded, elevationBlend: stage.elevationBlend)).distance
        #expect(stranded > distance)
    }

    @Test func anEmptyOrDegenerateStageIsRejectedRatherThanDividedBy() {
        #expect(!CameraRig.Stage(viewport: .zero).isValid)
        #expect(!CameraRig.Stage(viewport: phone, frame: .zero).isValid)
        #expect(CameraRig.Stage(viewport: phone).isValid)
    }
}

// MARK: - Binder hardware

@MainActor
struct BinderHardwareTests {
    @Test func ringsGrowWithTheBindersThickness() {
        let slim = BinderBuilder3D.ringRadius(sheets: 0)
        let fat = BinderBuilder3D.ringRadius(sheets: 40)
        #expect(slim == BinderBuilder3D.ringRadiusRange.lowerBound)
        #expect(fat > slim)
        #expect(BinderBuilder3D.ringRadiusRange.contains(fat))
        // Monotonic, and never smaller than the stack it has to clear.
        var previous = slim
        for sheets in stride(from: 4, through: 60, by: 4) {
            let radius = BinderBuilder3D.ringRadius(sheets: sheets)
            #expect(radius >= previous)
            previous = radius
        }
        #expect(BinderBuilder3D.ringRadius(sheets: 500) == BinderBuilder3D.ringRadiusRange.upperBound)
    }

    @Test func ringsClearTheSpineGapSoTheyThreadThePages() {
        // A ring that never reaches the pages' inner edge reads as a bead on
        // the spine instead of a ring through the holes.
        #expect(BinderBuilder3D.ringRadius(sheets: 0) > BinderBuilder3D.stackInnerX)
    }
}
