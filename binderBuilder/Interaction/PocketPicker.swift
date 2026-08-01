//
//  PocketPicker.swift
//  binderBuilder
//
//  Slot-level picking for the binder's pocket editor.
//
//  CardInteractionController picks seated CARD entities, which is all the
//  pull-out interaction needs — but an EMPTY pocket has no entity to hit, and
//  "put a card in this pocket" has to work on empty ones. So this picker
//  ignores entities entirely and hit-tests the pockets themselves: for every
//  live page it evaluates each of the 18 pocket centres (9 front + 9 back)
//  through the page's current curl — the same CurlFunction evaluation
//  CardPlacementSystem uses to seat a card — and intersects the ray with the
//  resulting oriented box. The nearest hit wins, so the top sheet of each
//  stack shadows the ones beneath it, and the side facing the camera wins over
//  the side facing away (front pockets sit at +z, back pockets at -z).
//
//  Whether the pocket is occupied is then read off the page's card children,
//  so one pick answers both "which pocket" and "what's in it".
//

import CoreGraphics
import RealityKit
import simd

/// A picked pocket: where it lives in the binder, and what is seated in it.
nonisolated struct PocketHit: Identifiable, Equatable, Sendable {
    /// Physical sheet index — the `SlotLocation.pageIndex`.
    var sheetIndex: Int
    var side: PageSide
    /// 0...8, row-major — the stored `slot_assignment.slot_index`.
    var slotIndex: Int
    /// nil when the pocket is empty.
    var ref: CardRef?

    var id: String { "\(sheetIndex).\(side.rawValue).\(slotIndex)" }
    var isEmpty: Bool { ref == nil }

    func location(binderID: String) -> SlotLocation {
        SlotLocation(binderID: binderID, pageIndex: sheetIndex, side: side, slotIndex: slotIndex)
    }
}

/// Pure pocket-pick geometry, kept entity-free so it is unit-testable.
nonisolated enum PocketPickGeometry {
    /// Half-thickness of a pocket's pick box (m). Deliberately smaller than
    /// the ±`CardSlotGeometry.cardZ` offset between the two sides of a sheet,
    /// so the front and back boxes never overlap and the nearest-hit rule
    /// always resolves to the side actually facing the camera.
    static let halfThickness: Float = 0.0008

    /// Pocket-sized (not card-sized) so the pick box covers the whole visible
    /// pocket, including the sliver of sleeve around a seated card.
    static var halfExtents: SIMD3<Float> {
        SIMD3<Float>(SleeveGeometry.pocketWidth / 2, SleeveGeometry.pocketHeight / 2, halfThickness)
    }

    /// Page-local frame of a pocket under a given curl: the deformed pocket
    /// centre and the orientation of its surface patch.
    ///
    /// This mirrors `CardPlacementSystem.pose` — deliberately, since the pick
    /// box has to land exactly where that system seats a card. Occupied and
    /// empty pockets are therefore picked through identical geometry.
    static func frame(slot: Int, side: PageSide, params: CurlParams)
        -> (position: SIMD3<Float>, orientation: simd_quatf) {
        let eps: Float = 0.001
        let up = SIMD3<Float>(0, 0, 1)
        let c = CardSlotGeometry.center(slot: slot, side: side)
        let p = CurlFunction.deform(position: c, normal: up, params: params).position
        let pu = CurlFunction.deform(position: c + SIMD3<Float>(eps, 0, 0), normal: up, params: params).position
        let pv = CurlFunction.deform(position: c + SIMD3<Float>(0, eps, 0), normal: up, params: params).position

        let tu = normalizeSafe(pu - p, fallback: SIMD3<Float>(1, 0, 0))
        let tv = normalizeSafe(pv - p, fallback: SIMD3<Float>(0, 1, 0))
        let n = normalizeSafe(cross(tu, tv), fallback: SIMD3<Float>(0, 0, 1))
        let basis = side == .front ? float3x3(tu, tv, n) : float3x3(-tu, tv, -n)
        return (p, simd_quatf(basis))
    }

    /// The curl a page is currently drawn with. `appliedParams` is authoritative
    /// (PageTurnSystem writes it every time the deformer runs); the progress
    /// fallback covers the frame between a rebind and the first system tick.
    static func params(for page: PageComponent) -> CurlParams {
        if let applied = page.appliedParams { return applied }
        return CurlParams.progress(min(max(page.currentT, 0), 1))
    }

    /// World-space pick box for one pocket of a page at `pageTransform`.
    static func obb(
        slot: Int,
        side: PageSide,
        params: CurlParams,
        pageTransform: simd_float4x4,
        pageOrientation: simd_quatf
    ) -> OBB {
        let frame = frame(slot: slot, side: side, params: params)
        let world = pageTransform * SIMD4<Float>(frame.position, 1)
        return OBB(
            center: SIMD3<Float>(world.x, world.y, world.z),
            halfExtents: halfExtents,
            orientation: pageOrientation * frame.orientation)
    }

    private static func normalizeSafe(_ v: SIMD3<Float>, fallback: SIMD3<Float>) -> SIMD3<Float> {
        let len = length(v)
        return len > 1e-6 ? v / len : fallback
    }
}

@MainActor
final class PocketPicker {
    private let root: Entity
    private let cameraRig: CameraRig

    init(root: Entity, cameraRig: CameraRig) {
        self.root = root
        self.cameraRig = cameraRig
    }

    /// Nearest pocket under a screen point, or nil if the tap missed the pages.
    func pick(at point: CGPoint, viewport: CGSize) -> PocketHit? {
        let ray = cameraRig.ray(through: point, viewport: viewport)
        var best: (hit: PocketHit, distance: Float)?

        for page in livePages() {
            guard let component = page.components[PageComponent.self] else { continue }
            let params = PocketPickGeometry.params(for: component)
            let transform = page.transformMatrix(relativeTo: nil)
            let orientation = page.orientation(relativeTo: nil)
            let seated = seatedRefs(on: page)

            for side in PageSide.allCases {
                for slot in 0..<SpreadModel.slotsPerPage {
                    let box = PocketPickGeometry.obb(
                        slot: slot, side: side, params: params,
                        pageTransform: transform, pageOrientation: orientation)
                    guard let distance = GestureMath.rayOBBIntersection(
                            origin: ray.origin, direction: ray.direction, obb: box),
                          distance >= 0,
                          distance < (best?.distance ?? .greatestFiniteMagnitude)
                    else { continue }
                    best = (PocketHit(
                        sheetIndex: component.sheetIndex,
                        side: side,
                        slotIndex: slot,
                        ref: seated[SeatKey(side: side, slot: slot)]), distance)
                }
            }
        }
        return best?.hit
    }

    private struct SeatKey: Hashable {
        var side: PageSide
        var slot: Int
    }

    private func seatedRefs(on page: Entity) -> [SeatKey: CardRef] {
        var out: [SeatKey: CardRef] = [:]
        for child in page.children {
            guard let slot = child.components[CardSlotComponent.self] else { continue }
            out[SeatKey(side: slot.side, slot: slot.slot)] = slot.ref
        }
        return out
    }

    /// Enabled page entities only — the pool disables the entities it isn't
    /// currently binding to a sheet, and those have had their cards cleared.
    private func livePages() -> [Entity] {
        var out: [Entity] = []
        func walk(_ entity: Entity) {
            if entity.isEnabled {
                if entity.components.has(PageComponent.self) { out.append(entity) }
                for child in entity.children { walk(child) }
            }
        }
        walk(root)
        return out
    }
}
