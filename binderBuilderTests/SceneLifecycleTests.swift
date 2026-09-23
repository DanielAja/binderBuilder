//
//  SceneLifecycleTests.swift
//  binderBuilderTests
//
//  The 3D scene's bookkeeping that doesn't need a GPU: the floating-card
//  spring's stability, pulling out a card that is still on its way home,
//  snapping every out-of-pocket card back before a rebind, the texture
//  cache's per-card keying, which binder the page pool is bound to, the
//  Reduce Motion foil freeze, and the VoiceOver spread wording.
//

import Foundation
import RealityKit
import Testing
import simd
@testable import binderBuilder

// MARK: - Float spring

struct CardFloatSpringTests {
    private let target = SIMD3<Float>(0.1, 0.3, -0.2)

    @Test func aHitchFrameNeverOvershootsOrDiverges() {
        // 64 ms is where the old explicit Euler step went unstable at omega
        // 13; a quarter-second stall is an ordinary backgrounding hitch.
        for dt: Float in [0.016, 0.064, 0.1, 0.25, 1.0] {
            var position = SIMD3<Float>.zero
            var velocity = SIMD3<Float>.zero
            let start = simd_length(position - target)
            var previous = start
            for _ in 0..<60 {
                let step = CardFloatSystem.springStep(
                    position: position, velocity: velocity, target: target,
                    omega: CardFloatSystem.positionOmega, dt: dt)
                position = step.position
                velocity = step.velocity
                let error = simd_length(position - target)
                // Critically damped from rest: monotone approach, no ringing.
                #expect(error <= previous + 1e-6, "dt \(dt) grew the error")
                #expect(position.x.isFinite && velocity.x.isFinite)
                previous = error
            }
            #expect(previous < start * 1e-3, "dt \(dt) never arrived")
        }
    }

    @Test func matchesTheFlipSpringClosedFormPerAxis() {
        var flip = FlipSpring(t: 0.2, velocity: 1.5, target: 1, omega: 13)
        let step = CardFloatSystem.springStep(
            position: SIMD3<Float>(repeating: 0.2), velocity: SIMD3<Float>(repeating: 1.5),
            target: SIMD3<Float>(repeating: 1), omega: 13, dt: 0.05)
        flip.step(dt: 0.05)
        #expect(abs(step.position.y - flip.t) < 1e-6)
        #expect(abs(step.velocity.z - flip.velocity) < 1e-6)
    }

    @Test func zeroOrNonFiniteDtIsANoOp() {
        let p = SIMD3<Float>(1, 2, 3), v = SIMD3<Float>(0.5, 0, 0)
        for dt: Float in [0, -0.1, .infinity, .nan] {
            let step = CardFloatSystem.springStep(position: p, velocity: v, target: .zero, omega: 13, dt: dt)
            #expect(step.position == p)
            #expect(step.velocity == v)
        }
    }
}

// MARK: - Pull-out / return bookkeeping

@MainActor
struct CardFloatBookkeepingTests {
    private struct Rig {
        let root: Entity
        let page: Entity
        let card: ModelEntity
        let home: Transform
        let interaction: CardInteractionController
    }

    private func makeRig() -> Rig {
        CardSlotComponent.registerComponent()
        CardFloatComponent.registerComponent()
        let root = Entity()
        let camera = CameraRig()
        root.addChild(camera.root)
        let page = Entity()
        page.position = SIMD3<Float>(0.05, 0.01, 0)
        root.addChild(page)
        let card = ModelEntity()
        card.components.set(CardSlotComponent(
            ref: CardRef(cardID: "base1-4", variant: .holo), slot: 4, side: .front,
            flatCenter: SIMD3<Float>(0.1, 0.12, 0)))
        let home = Transform(
            scale: .one,
            rotation: simd_quatf(angle: 0.3, axis: SIMD3<Float>(0, 0, 1)),
            translation: SIMD3<Float>(0.1, 0.12, 0.001))
        card.transform = home
        page.addChild(card)
        return Rig(root: root, page: page, card: card, home: home,
                   interaction: CardInteractionController(root: root, cameraRig: camera))
    }

    @Test func pullingOutAReturningCardKeepsItsRealPocket() throws {
        let rig = makeRig()
        rig.interaction.pullOut(rig.card)
        #expect(rig.card.parent === rig.root)

        // Sent home, but still mid-flight (the float system hasn't run).
        rig.interaction.returnFloatingCard()
        #expect(!rig.interaction.isFloating)
        #expect(rig.card.components[CardFloatComponent.self]?.mode == .returning)
        rig.card.position += SIMD3<Float>(0, 0.1, 0.05)   // somewhere in the air

        // A second tap catches it on the way back.
        rig.interaction.pullOut(rig.card)
        let f = try #require(rig.card.components[CardFloatComponent.self])
        #expect(f.mode == .active)
        #expect(f.homeParent === rig.page, "home must stay the pocket, not the scene root")
        #expect(f.homeLocal == rig.home, "home pose must be the seated one, not the mid-air one")
        #expect(rig.interaction.floatingCard === rig.card)
    }

    @Test func snapHomeAlsoCatchesACardThatIsStillReturning() {
        let rig = makeRig()
        rig.interaction.pullOut(rig.card)
        rig.interaction.returnFloatingCard()
        // Untracked by the controller, but still root-parented.
        #expect(rig.interaction.floatingCard == nil)
        #expect(rig.card.parent === rig.root)

        rig.interaction.snapFloatingCardHome()
        #expect(rig.card.parent === rig.page)
        #expect(rig.card.transform == rig.home)
        #expect(!rig.card.components.has(CardFloatComponent.self))
        #expect(rig.card.components[CardSlotComponent.self]?.lastParams == nil)
    }

    @Test func snapHomeClearsTheFloatingCardAndReportsIt() {
        let rig = makeRig()
        var reported: [CardRef?] = []
        rig.interaction.onFloatingChanged = { reported.append($0) }
        rig.interaction.pullOut(rig.card)
        rig.interaction.snapFloatingCardHome()
        #expect(!rig.interaction.isFloating)
        #expect(rig.card.parent === rig.page)
        #expect(reported.count == 2 && reported.last! == nil)
    }

    @Test func reduceMotionArrivesInsteadOfFlying() throws {
        let rig = makeRig()
        rig.interaction.reduceMotion = true
        rig.interaction.pullOut(rig.card)
        let f = try #require(rig.card.components[CardFloatComponent.self])
        #expect(simd_length(rig.card.position(relativeTo: nil) - f.targetPosition) < 1e-5)

        // And the return is immediate: back in the sleeve, no float left.
        rig.interaction.returnFloatingCard()
        #expect(rig.card.parent === rig.page)
        #expect(!rig.card.components.has(CardFloatComponent.self))
    }
}

// MARK: - Texture cache keying

@MainActor
struct CardTextureCacheKeyTests {
    @Test func everyVariantOfACardSharesOneTexture() async throws {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("texkey-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        let images = ImageCache(
            pinnedRoot: dir.appendingPathComponent("pinned"),
            cachesRoot: dir.appendingPathComponent("caches"))
        let cache = CardTextureCache(imageCache: images, capacity: 4)

        // imageBase nil resolves to the bundled card back — no network.
        let normal = CardRef(cardID: "texkey-1", variant: .normal)
        let holo = CardRef(cardID: "texkey-1", variant: .holo)
        let first = try await cache.load(normal, imageBase: nil)

        // The art is fetched by card ID, so the holo printing is already here.
        let hit = try #require(cache.cached(holo))
        #expect(hit === first)
        _ = try await cache.load(holo, imageBase: nil)
        #expect(cache.residentCount == 1)

        // A different card is a different texture.
        _ = try await cache.load(CardRef(cardID: "texkey-2", variant: .holo), imageBase: nil)
        #expect(cache.residentCount == 2)
    }
}

// MARK: - Pool binding

struct PoolBindingTests {
    @Test func aFreshBindingAlwaysNeedsARebind() {
        let binding = PoolBinding()
        #expect(binding.needsRebind(for: "a"))
        #expect(binding.needsRebind(for: nil))
    }

    @Test func followsTheContentBinder() {
        var binding = PoolBinding()
        binding.markBound("a")
        #expect(!binding.needsRebind(for: "a"))
        // "Open in 3D" on another binder swaps the content under the pool.
        #expect(binding.needsRebind(for: "b"))
        binding.markBound("b")
        #expect(!binding.needsRebind(for: "b"))
        #expect(binding.binderID == "b")
    }

    @Test func emptyContentIsItsOwnBinding() {
        var binding = PoolBinding()
        binding.markBound(nil)
        #expect(!binding.needsRebind(for: nil))
        #expect(binding.needsRebind(for: "a"))
        binding.markBound("a")
        // The last binder was deleted: the empty snapshot must be rebound.
        #expect(binding.needsRebind(for: nil))
    }
}

// MARK: - Reduce Motion foil freeze

struct ReducedMotionFoilTests {
    @Test func reduceMotionFreezesAtTheRestPhase() {
        let frozen = MotionUpdateSystem.effectiveOverride(launchOverride: nil, motionReduced: true)
        #expect(frozen == MotionUpdateSystem.reducedMotionPhase)
        // Whatever the tilt and however long it has been running.
        let tilted = MotionSample(
            gravity: SIMD3<Float>(0.6, -0.6, 0.5), userAcceleration: .zero,
            attitude: simd_quatf(angle: 0, axis: SIMD3<Float>(0, 1, 0)), timestamp: 0)
        let a = MotionUpdateSystem.holoPhase(sample: tilted, elapsed: 0, override: frozen)
        let b = MotionUpdateSystem.holoPhase(sample: .rest, elapsed: 500, override: frozen)
        #expect(a == b)
    }

    @Test func theLaunchArgumentStillWins() {
        let pinned = SIMD2<Float>(0.3, 0.7)
        #expect(MotionUpdateSystem.effectiveOverride(launchOverride: pinned, motionReduced: true) == pinned)
        #expect(MotionUpdateSystem.effectiveOverride(launchOverride: pinned, motionReduced: false) == pinned)
        #expect(MotionUpdateSystem.effectiveOverride(launchOverride: nil, motionReduced: false) == nil)
    }
}

// MARK: - VoiceOver wording

struct SceneAccessibilityTests {
    @Test func describesEachSpread() {
        #expect(SceneAccessibility.spreadDescription(spread: 0, sheetCount: 10) == "Page 1 of 10")
        #expect(SceneAccessibility.spreadDescription(spread: 3, sheetCount: 10) == "Pages 3–4 of 10")
        #expect(SceneAccessibility.spreadDescription(spread: 10, sheetCount: 10) == "Page 10 of 10, back")
        #expect(SceneAccessibility.spreadDescription(spread: 0, sheetCount: 0) == "No pages")
        // Out-of-range spreads (a flip announced past either end) clamp.
        #expect(SceneAccessibility.spreadDescription(spread: -1, sheetCount: 4) == "Page 1 of 4")
        #expect(SceneAccessibility.spreadDescription(spread: 9, sheetCount: 4) == "Page 4 of 4, back")
    }
}
