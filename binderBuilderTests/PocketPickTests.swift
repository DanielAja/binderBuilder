//
//  PocketPickTests.swift
//  binderBuilderTests
//
//  Slot-level pick geometry for the 3D pocket editor: the math that lets a tap
//  land on an EMPTY pocket, which has no entity to ray-pick.
//

import Testing
import simd
@testable import binderBuilder

struct PocketPickTests {
    /// A page lying flat on its stack — d == page width means "no curl".
    private let flat = CurlParams.progress(0)
    private let identityTransform = matrix_identity_float4x4
    private let identityOrientation = simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0))

    /// Nearest pocket a page-local ray lands on, over all 18 pockets of one
    /// flat page — the same nearest-hit rule PocketPicker applies.
    private func pick(
        origin: SIMD3<Float>,
        direction: SIMD3<Float>,
        params: CurlParams? = nil
    ) -> (slot: Int, side: PageSide)? {
        var best: (slot: Int, side: PageSide, distance: Float)?
        for side in PageSide.allCases {
            for slot in 0..<SpreadModel.slotsPerPage {
                let box = PocketPickGeometry.obb(
                    slot: slot, side: side, params: params ?? flat,
                    pageTransform: identityTransform, pageOrientation: identityOrientation)
                guard let distance = GestureMath.rayOBBIntersection(
                        origin: origin, direction: direction, obb: box),
                      distance >= 0,
                      distance < (best?.distance ?? .greatestFiniteMagnitude)
                else { continue }
                best = (slot, side, distance)
            }
        }
        guard let best else { return nil }
        return (best.slot, best.side)
    }

    // MARK: - Frames

    @Test func flatPageLeavesPocketCentersWhereTheGeometryPutsThem() {
        for slot in 0..<SpreadModel.slotsPerPage {
            for side in PageSide.allCases {
                let frame = PocketPickGeometry.frame(slot: slot, side: side, params: flat)
                let expected = CardSlotGeometry.center(slot: slot, side: side)
                #expect(distance(frame.position, expected) < 1e-5)
            }
        }
    }

    /// The nearest-hit rule can only resolve front vs back if their boxes are
    /// disjoint in z — hence the deliberately thin pick box.
    @Test func frontAndBackPickBoxesDoNotOverlap() {
        #expect(PocketPickGeometry.halfThickness < CardSlotGeometry.cardZ)
    }

    /// A curled page moves its pockets: the pick boxes have to ride the curl,
    /// or a tap mid-flip would address the flat position.
    @Test func curlMovesPocketFramesOffTheFlatPlane() {
        let curled = CurlParams.progress(0.5)
        let flatFrame = PocketPickGeometry.frame(slot: 4, side: .front, params: flat)
        let curledFrame = PocketPickGeometry.frame(slot: 4, side: .front, params: curled)
        #expect(distance(flatFrame.position, curledFrame.position) > 0.01)
    }

    /// The pick box is built in page-local space and pushed out through the
    /// page's world transform — a page lying on a desk is neither at the origin
    /// nor axis-aligned with the camera.
    @Test func pickBoxRidesThePagesWorldTransform() {
        let rotation = simd_quatf(angle: -.pi / 2, axis: SIMD3<Float>(1, 0, 0)) // page flat on a desk
        let translation = SIMD3<Float>(0.2, 0.05, -0.1)
        var transform = simd_float4x4(rotation)
        transform.columns.3 = SIMD4<Float>(translation, 1)

        let box = PocketPickGeometry.obb(
            slot: 4, side: .front, params: flat,
            pageTransform: transform, pageOrientation: rotation)
        let local = CardSlotGeometry.center(slot: 4, side: .front)
        #expect(distance(box.center, rotation.act(local) + translation) < 1e-5)

        // The box's own axes turn with the page: its local +z (the pocket
        // normal) now points along world +y.
        let normal = box.orientation.act(SIMD3<Float>(0, 0, 1))
        #expect(distance(normal, SIMD3<Float>(0, 1, 0)) < 1e-4)
    }

    // MARK: - Picking

    @Test func rayFromTheFrontHitsTheFrontPocketItAimsAt() {
        for slot in 0..<SpreadModel.slotsPerPage {
            let center = CardSlotGeometry.center(slot: slot, side: .front)
            let hit = pick(
                origin: SIMD3<Float>(center.x, center.y, 1),
                direction: SIMD3<Float>(0, 0, -1))
            #expect(hit?.slot == slot)
            #expect(hit?.side == .front)
        }
    }

    /// From behind, the same page position resolves to the BACK pocket whose
    /// (column-mirrored) index shares that spot — top-left seen from the back
    /// is page-local top-right.
    @Test func rayFromBehindHitsTheColumnMirroredBackPocket() {
        for slot in 0..<SpreadModel.slotsPerPage {
            let center = CardSlotGeometry.center(slot: slot, side: .front)
            let hit = pick(
                origin: SIMD3<Float>(center.x, center.y, -1),
                direction: SIMD3<Float>(0, 0, 1))
            #expect(hit?.side == .back)
            // The back slot that lands on this physical pocket.
            #expect(hit.map { CardSlotGeometry.physicalSlot(slot: $0.slot, side: .back) } == slot)
        }
    }

    @Test func tapBetweenPocketsMissesEverything() {
        // Midway across the weld land between the first two pockets of row 0.
        let a = SleeveGeometry.pocketOrigin(slot: 0)
        let x = a.x + SleeveGeometry.pocketWidth + SleeveGeometry.gap / 2
        let y = a.y + SleeveGeometry.pocketHeight / 2
        #expect(pick(origin: SIMD3<Float>(x, y, 1), direction: SIMD3<Float>(0, 0, -1)) == nil)
    }

    @Test func tapOffThePageMissesEverything() {
        #expect(pick(origin: SIMD3<Float>(-0.5, 0.5, 1), direction: SIMD3<Float>(0, 0, -1)) == nil)
    }

    // MARK: - Hit -> slot address

    @Test func hitMapsOntoTheStoredSlotAddress() {
        let hit = PocketHit(sheetIndex: 3, side: .back, slotIndex: 7, ref: nil)
        let slot = hit.location(binderID: "binder-1")
        #expect(slot == SlotLocation(binderID: "binder-1", pageIndex: 3, side: .back, slotIndex: 7))
        #expect(hit.isEmpty)

        let occupied = PocketHit(
            sheetIndex: 0, side: .front, slotIndex: 0,
            ref: CardRef(cardID: "base1-4", variant: .holo))
        #expect(!occupied.isEmpty)
        #expect(occupied.id != hit.id)
    }
}
