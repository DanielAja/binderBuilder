//
//  SceneBootstrap.swift
//  binderBuilder
//
//  Assembles the 3D scene root for BinderSceneView: CameraRig + lights +
//  ground + procedural open binder + the pooled deformable pages, and owns
//  BinderFlipController — the object that binds pooled pages to physical
//  sheets around the current spread, resizes the page stacks, and runs the
//  drag/spring flip lifecycle.
//
//  Honors DebugLaunchState: -curl <0..1> freezes the active page mid-curl,
//  -autoFlip runs one scripted forward flip (~2 s) shortly after launch, and
//  -deformer gpu|cpu selects the PageDeformer implementation (default gpu,
//  with automatic CPU fallback if the GPU material fails to build).
//

import CoreGraphics
import OSLog
import RealityKit
import UIKit
import simd

@MainActor
struct SceneBootstrapResult {
    let root: Entity
    let cameraRig: CameraRig
    let controller: BinderFlipController?
    let router: GestureRouter?
    /// Card pull-out / inspect / return interaction (tap + arcball drag).
    let cardInteraction: CardInteractionController?
    /// Shelf <-> binder mode switching + camera transitions.
    let modeController: SceneModeController?
    /// Device-motion source driving the holo sweep; kept alive by the result.
    let motionProvider: any MotionProvider
    /// "gpu" or "cpu" — what actually got used after any fallback.
    let activeDeformerLabel: String
}

@MainActor
enum SceneBootstrap {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "SceneBootstrap")

    /// Seconds after scene assembly before the scripted -autoFlip starts.
    /// Tuned against tools/verify.sh screenshot SHOT_DELAY=10 (mid-flip)
    /// and SHOT_DELAY=11.2 (settled, stacks rebound).
    static let autoFlipDelay: TimeInterval = 7.45

    static func assemble(
        launchState: DebugLaunchState = .current,
        cardContent: (any CardContentProviding)? = nil,
        textureCache: CardTextureCache? = nil
    ) -> SceneBootstrapResult {
        PageTurnSystem.ensureRegistered()
        CardPlacementSystem.ensureRegistered()
        MotionUpdateSystem.ensureRegistered()
        CardFloatSystem.ensureRegistered()
        HitZoneComponent.registerComponent()

        // Device motion drives the card holo sweep (and, later, floating-card
        // drift). Provider runs for the scene's lifetime; -holoPhase freezes it.
        let motionProvider = MotionProviderFactory.make(launchState: launchState)
        motionProvider.start()
        MotionUpdateSystem.provider = motionProvider
        MotionUpdateSystem.holoPhaseOverride = launchState.holoPhase

        let root = Entity()
        root.name = "SceneRoot"

        // Studio image-based lighting (soft reflections + ambient fill); the
        // explicit lights below carry the scene if the IBL asset can't load.
        EnvironmentBuilder.applyIBL(to: root)

        // Camera.
        let cameraRig = CameraRig()
        root.addChild(cameraRig.root)

        // Warm key from upper-right.
        let key = DirectionalLight()
        key.name = "KeyLight"
        key.light.intensity = 6500
        key.light.color = .init(red: 1.0, green: 0.96, blue: 0.90, alpha: 1)
        key.look(at: .zero, from: SIMD3<Float>(0.55, 1.4, 0.75), relativeTo: nil)
        root.addChild(key)

        // Cool fill from the left.
        let fill = PointLight()
        fill.name = "FillLight"
        fill.light.intensity = 16000
        fill.light.attenuationRadius = 7
        fill.light.color = .init(red: 0.86, green: 0.91, blue: 1.0, alpha: 1)
        fill.position = SIMD3<Float>(-0.5, 0.6, 0.5)
        root.addChild(fill)

        // Soft ambient lift from the front so the desk + walls aren't murky
        // (RealityKit has no ambient light; a dim wide directional stands in).
        let ambient = DirectionalLight()
        ambient.name = "AmbientLift"
        ambient.light.intensity = 2600
        ambient.light.color = .init(red: 0.95, green: 0.95, blue: 1.0, alpha: 1)
        ambient.look(at: .zero, from: SIMD3<Float>(-0.2, 0.7, 1.0), relativeTo: nil)
        root.addChild(ambient)

        // Neutral dark ground plane (thin box).
        var groundMaterial = PhysicallyBasedMaterial()
        groundMaterial.baseColor = .init(tint: .init(white: 0.16, alpha: 1))
        groundMaterial.roughness = 0.95
        groundMaterial.metallic = 0.0
        let ground = ModelEntity(
            mesh: .generateBox(width: 1.6, height: 0.01, depth: 1.6, cornerRadius: 0.005),
            materials: [groundMaterial]
        )
        ground.name = "Ground"
        // Sits well below the binder desk (which has its top at y=0) so they
        // never z-fight; it's the floor for the shelf scene.
        ground.position = SIMD3<Float>(0, -0.12, 0)
        root.addChild(ground)

        // Open binder shell (stacks sized by the controller below).
        let rig = BinderBuilder3D.makeOpenBinder()
        root.addChild(rig.root)

        // The binder's "setting": a wooden desk, back wall, contact shadow, and
        // background props. Parented under the binder root so it shows/hides
        // with the binder (the shelf scene has its own environment).
        rig.root.addChild(DeskSceneBuilder.build())

        // Pooled deformable pages, one deformer instance each.
        let texture = (try? Self.makePaperTexture()) ?? Self.fallbackTexture()
        let (pages, activeLabel) = PageFactory.makePages(
            requested: launchState.deformer ?? .gpu,
            texture: texture
        )

        var controller: BinderFlipController?
        var router: GestureRouter?
        var cardInteraction: CardInteractionController?
        var modeController: SceneModeController?
        if pages.isEmpty {
            log.fault("No pooled pages could be built; binder is static")
        } else {
            let contentSource: any CardContentProviding = cardContent ?? DebugCardContentSource()
            let flipController = BinderFlipController(
                contentSource: contentSource,
                rig: rig,
                pages: pages,
                initialSpread: contentSource.sheetCount / 2
            )
            controller = flipController

            // Card layer: spawn/despawn pocket cards on every rebind, then
            // rebind once now that the hook is wired so the initial spread
            // gets its cards. (The init's first rebind ran before this hook.)
            let cardTextures = textureCache ?? CardTextureCache(imageCache: .standard())
            let placement = CardPlacement(provider: contentSource, textures: cardTextures)
            flipController.onRebound = { placement.rebound($0) }
            flipController.rebind(spread: flipController.spreadIndex)

            if let curl = launchState.curl {
                flipController.freezeCurl(curl)
                log.info("Curl frozen at \(curl, privacy: .public) on sheet \(flipController.spreadIndex, privacy: .public)")
            }

            // Hit testing: scene.raycast primary, analytic OBB fallback.
            let composite = CompositeHitTester(
                primary: SceneRaycastHitTester(sceneAnchor: root),
                fallback: AnalyticHitTester(zoneProvider: { [weak flipController] in
                    flipController?.analyticZones() ?? []
                })
            )
            router = GestureRouter(controller: flipController, hitTester: composite, cameraRig: cameraRig)

            // Card pull-out / inspect / return.
            let interaction = CardInteractionController(root: root, cameraRig: cameraRig)
            cardInteraction = interaction

            // -uiState cardFloating: auto-pull a card shortly after launch so
            // the floating/holo pose can be screenshot deterministically.
            if launchState.uiState == .cardFloating {
                Task {
                    try? await Task.sleep(for: .seconds(2))
                    interaction.pullOutFirstAvailable(yawDegrees: launchState.cardYawDegrees)
                }
            }

            // Startup self-probe (logged + printed): proves whether
            // scene.raycast works under the virtual camera on this run.
            Task {
                try? await Task.sleep(for: .seconds(3))
                _ = composite.probe(origin: SIMD3<Float>(0.125, 0.5, 0), direction: SIMD3<Float>(0, -1, 0))
            }

            if launchState.autoFlip {
                log.info("autoFlip scheduled in \(Self.autoFlipDelay, privacy: .public)s")
                Task {
                    try? await Task.sleep(for: .seconds(Self.autoFlipDelay))
                    flipController.startAutoFlip()
                }
            }
        }

        log.info("Page deformer active: \(activeLabel, privacy: .public)")

        // Shelf "home" scene: tap the standing binder to dolly into it.
        let shelfRig = ShelfSceneBuilder.build()
        root.addChild(shelfRig.root)
        let initialMode: AppMode
        switch launchState.uiState {
        case .binderOpen, .cardFloating: initialMode = .binderOpen
        default: initialMode = .shelf
        }
        modeController = SceneModeController(
            mode: initialMode, cameraRig: cameraRig, shelfRoot: shelfRig.root, binderRoot: rig.root
        )

        DebugSceneOverrides.apply(to: root, cameraRig: cameraRig, launchState: launchState)

        return SceneBootstrapResult(
            root: root,
            cameraRig: cameraRig,
            controller: controller,
            router: router,
            cardInteraction: cardInteraction,
            modeController: modeController,
            motionProvider: motionProvider,
            activeDeformerLabel: activeLabel
        )
    }

    // MARK: Textures

    /// Subtle off-white vinyl-paper texture for the pooled pages: faint
    /// vertical shading plus a thin darker rim so page edges read against
    /// the stacks. (The garish dev checker lives on in makeCheckerTexture
    /// for debugging.)
    static func makePaperTexture() throws -> TextureResource {
        let width = 256
        let height = 320
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PageDeformerError.metalUnavailable
        }

        for row in 0..<height {
            let shade = 0.90 + 0.06 * CGFloat(row) / CGFloat(height)
            context.setFillColor(CGColor(red: shade, green: shade, blue: shade * 0.99, alpha: 1))
            context.fill(CGRect(x: 0, y: row, width: width, height: 1))
        }
        // Thin darker rim.
        context.setStrokeColor(CGColor(red: 0.72, green: 0.72, blue: 0.73, alpha: 1))
        context.setLineWidth(3)
        context.stroke(CGRect(x: 1.5, y: 1.5, width: CGFloat(width) - 3, height: CGFloat(height) - 3))

        guard let image = context.makeImage() else {
            throw PageDeformerError.metalUnavailable
        }
        return try TextureResource(image: image, options: .init(semantic: .color))
    }

    /// Procedural checker + gradient so any deformation is visually obvious:
    /// 8x10 checker in light gray/white, red tide toward the free edge (u=1)
    /// and a blue band along the top, over the full 0..1 UV range.
    static func makeCheckerTexture() throws -> TextureResource {
        let width = 512
        let height = 640
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        guard let context = CGContext(
            data: nil,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: 0,
            space: colorSpace,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else {
            throw PageDeformerError.metalUnavailable
        }

        let cols = 8
        let rows = 10
        let cellW = CGFloat(width) / CGFloat(cols)
        let cellH = CGFloat(height) / CGFloat(rows)
        for row in 0..<rows {
            for col in 0..<cols {
                let even = (row + col) % 2 == 0
                let redTide = 0.15 + 0.75 * CGFloat(col) / CGFloat(cols - 1)
                let base: CGFloat = even ? 0.92 : 0.62
                context.setFillColor(CGColor(
                    red: min(1, base * 0.6 + redTide * 0.4),
                    green: base * (even ? 0.95 : 0.75),
                    blue: base * (even ? 0.9 : 0.7),
                    alpha: 1
                ))
                context.fill(CGRect(
                    x: CGFloat(col) * cellW,
                    y: CGFloat(row) * cellH,
                    width: cellW.rounded(.up),
                    height: cellH.rounded(.up)
                ))
            }
        }
        // Blue band along the image top (v near 0 in mesh UVs after flip —
        // the far/top edge of the page).
        context.setFillColor(CGColor(red: 0.2, green: 0.35, blue: 0.95, alpha: 1))
        context.fill(CGRect(x: 0, y: CGFloat(height) - cellH / 2, width: CGFloat(width), height: cellH / 2))
        // Dark stripe at the free edge (u = 1).
        context.setFillColor(CGColor(red: 0.1, green: 0.1, blue: 0.12, alpha: 1))
        context.fill(CGRect(x: CGFloat(width) - cellW / 4, y: 0, width: cellW / 4, height: CGFloat(height)))

        guard let image = context.makeImage() else {
            throw PageDeformerError.metalUnavailable
        }
        return try TextureResource(
            image: image,
            options: .init(semantic: .color)
        )
    }

    private static func fallbackTexture() -> TextureResource {
        // 1x1 white pixel; only hit if CoreGraphics fails (effectively never).
        guard let ctx = CGContext(
                data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else {
            fatalError("CoreGraphics could not allocate a 1x1 context for the fallback texture")
        }
        ctx.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: 1, height: 1))
        guard let image = ctx.makeImage(),
              let texture = try? TextureResource(image: image, options: .init(semantic: .color)) else {
            fatalError("Could not create the fallback texture from a 1x1 image")
        }
        return texture
    }
}

// MARK: - BinderFlipController

/// Owns the page pool: binds pooled entities to the sheets around the
/// current spread, resizes the stack slabs, exposes the drag lifecycle to
/// GestureRouter, and advances the spread when a flip settles.
@MainActor
final class BinderFlipController {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "BinderFlip")

    let contentSource: any PageContentSource
    private let rig: BinderRig
    private let pages: [PageFactory.PooledPage]
    private(set) var spreadIndex: Int

    /// Called at the end of every rebind with each pool entity and the sheet it
    /// now represents (nil = disabled). The card layer hooks here to spawn /
    /// despawn pocket cards. Set after init; assign then call `rebind` once to
    /// populate the initial spread.
    var onRebound: (([(entity: ModelEntity, sheet: Int?)]) -> Void)?

    /// Index into `pages` of the page currently being dragged.
    private var activeDragIndex: Int?

    // Invisible pick zones above each stack (collision-only entities).
    private let rightPick: Entity
    private let leftPick: Entity

    /// How far successive resting pages float above their stack top (m).
    private static func layerLift(_ layer: Int) -> Float {
        max(0.0001, 0.0011 - 0.0005 * Float(layer))
    }

    var sheetCount: Int { contentSource.sheetCount }

    init(
        contentSource: any PageContentSource,
        rig: BinderRig,
        pages: [PageFactory.PooledPage],
        initialSpread: Int
    ) {
        self.contentSource = contentSource
        self.rig = rig
        self.pages = pages
        self.spreadIndex = min(max(initialSpread, 0), contentSource.sheetCount)

        for page in pages {
            rig.root.addChild(page.entity)
            PageTurnSystem.deformers[page.entity.id] = page.deformer
        }

        // Pick zones: thin static boxes over each page area.
        func makePick(name: String, kind: HitZoneKind, centerX: Float) -> Entity {
            let pick = Entity()
            pick.name = name
            pick.components.set(HitZoneComponent(kind: kind))
            pick.components.set(CollisionComponent(shapes: [
                .generateBox(
                    width: BinderBuilder3D.pageStackWidth,
                    height: 0.006,
                    depth: BinderBuilder3D.pageStackDepth
                )
            ]))
            pick.position = SIMD3<Float>(centerX, BinderBuilder3D.coverThickness, 0)
            rig.root.addChild(pick)
            return pick
        }
        let stackCenterX = BinderBuilder3D.stackInnerX + BinderBuilder3D.pageStackWidth / 2
        rightPick = makePick(name: "PickRightPage", kind: .rightPage, centerX: stackCenterX)
        leftPick = makePick(name: "PickLeftPage", kind: .leftPage, centerX: -stackCenterX)

        // Covers double as (currently inert) pick targets.
        let coverShape = ShapeResource.generateBox(
            width: BinderBuilder3D.coverWidth,
            height: BinderBuilder3D.coverThickness,
            depth: BinderBuilder3D.coverDepth
        )
        rig.leftCover.components.set(HitZoneComponent(kind: .leftCover))
        rig.leftCover.components.set(CollisionComponent(shapes: [coverShape]))
        rig.rightCover.components.set(HitZoneComponent(kind: .rightCover))
        rig.rightCover.components.set(CollisionComponent(shapes: [coverShape]))

        PageTurnSystem.onFlipSettled = { [weak self] entity, component in
            self?.handleSettled(entity: entity, component: component)
        }

        rebind(spread: spreadIndex)
    }

    // MARK: Pool rebinding

    /// Binds pooled pages to the sheets around `spread`, recomputes both
    /// stack slabs, rest heights, occupancy, and the pick zones. Called at
    /// startup and after every settled flip.
    func rebind(spread: Int) {
        spreadIndex = min(max(spread, 0), sheetCount)
        let bound = PagePool.boundSheets(spread: spreadIndex, sheetCount: sheetCount)
        let leftSheets = PagePool.sheetsOnLeft(spread: spreadIndex)
        let rightSheets = PagePool.sheetsOnRight(spread: spreadIndex, sheetCount: sheetCount)

        BinderBuilder3D.updateStacks(rig: rig, leftSheets: leftSheets, rightSheets: rightSheets)

        var sheetForPool: [Int: Int] = [:]
        for sheet in bound {
            sheetForPool[PagePool.poolSlot(forSheet: sheet) % pages.count] = sheet
        }

        for (index, page) in pages.enumerated() {
            guard let sheet = sheetForPool[index] else {
                page.entity.isEnabled = false
                page.entity.components.remove(PageComponent.self)
                continue
            }

            let restT = PagePool.restProgress(sheet: sheet, spread: spreadIndex)
            let layer = PagePool.stackLayer(sheet: sheet, spread: spreadIndex)
            let restLift = 2 * CurlParams.restRadius // curl height of a settled left page

            // Right rest height: top of the right stack as it would be with
            // this sheet on top; left rest height: ditto for the left stack.
            // For the resting pose these are exact; for the *other* end they
            // are the predicted post-flip heights, so a turning page lands
            // exactly where the rebound stacks will put it.
            let restYRight: Float
            let restYLeft: Float
            if restT == 0 {
                restYRight = BinderBuilder3D.stackTopY(sheets: rightSheets) + Self.layerLift(layer)
                restYLeft = BinderBuilder3D.stackTopY(sheets: leftSheets + 1) + Self.layerLift(0) - restLift
            } else {
                restYLeft = BinderBuilder3D.stackTopY(sheets: leftSheets) + Self.layerLift(layer) - restLift
                restYRight = BinderBuilder3D.stackTopY(sheets: rightSheets + 1) + Self.layerLift(0)
            }

            // Never clobber an in-flight drag on this entity (a settle of a
            // different sheet can rebind mid-drag).
            let keepPhase: Bool
            if let existing = page.entity.components[PageComponent.self],
               existing.sheetIndex == sheet,
               activeDragIndex == index {
                keepPhase = true
            } else {
                keepPhase = false
            }

            var component = page.entity.components[PageComponent.self] ?? PageComponent(
                sheetIndex: sheet,
                occupiedBothSides: 0,
                phase: .rest(t: restT)
            )
            component.sheetIndex = sheet
            component.occupiedBothSides = contentSource.occupiedCount(sheet: sheet)
            if !keepPhase {
                component.phase = .rest(t: restT)
                component.gesturePsi = 0
            }
            component.restYRight = restYRight
            component.restYLeft = restYLeft
            component.appliedParams = nil // force one deformer refresh

            page.entity.components.set(component)
            page.entity.position = SIMD3<Float>(
                PageFactory.pageOriginX,
                restT == 0 ? restYRight : restYLeft,
                PageFactory.pageOriginZ
            )
            page.entity.isEnabled = true
        }

        // Pick zones ride the stack tops; a side with no page to grab turns off.
        rightPick.position.y = BinderBuilder3D.stackTopY(sheets: rightSheets) + 0.003
        rightPick.isEnabled = rightSheets > 0
        leftPick.position.y = BinderBuilder3D.stackTopY(sheets: leftSheets) + 0.003
        leftPick.isEnabled = leftSheets > 0

        Self.log.info("Rebound spread \(self.spreadIndex, privacy: .public): left \(leftSheets, privacy: .public) right \(rightSheets, privacy: .public) sheets \(bound.map(String.init).joined(separator: ","), privacy: .public)")

        if let onRebound {
            let states: [(entity: ModelEntity, sheet: Int?)] = pages.map { page in
                let sheet = page.entity.isEnabled ? page.entity.components[PageComponent.self]?.sheetIndex : nil
                return (page.entity, sheet)
            }
            onRebound(states)
        }
    }

    /// OBB pick zones mirroring the collision boxes, for the analytic tester.
    func analyticZones() -> [(kind: HitZoneKind, obb: OBB)] {
        var zones: [(kind: HitZoneKind, obb: OBB)] = []
        let stackCenterX = BinderBuilder3D.stackInnerX + BinderBuilder3D.pageStackWidth / 2
        let half = SIMD3<Float>(
            BinderBuilder3D.pageStackWidth / 2,
            0.003,
            BinderBuilder3D.pageStackDepth / 2
        )
        if rightPick.isEnabled {
            zones.append((.rightPage, OBB(
                center: SIMD3<Float>(stackCenterX, rightPick.position.y, 0),
                halfExtents: half
            )))
        }
        if leftPick.isEnabled {
            zones.append((.leftPage, OBB(
                center: SIMD3<Float>(-stackCenterX, leftPick.position.y, 0),
                halfExtents: half
            )))
        }
        let coverHalf = SIMD3<Float>(
            BinderBuilder3D.coverWidth / 2,
            BinderBuilder3D.coverThickness / 2,
            BinderBuilder3D.coverDepth / 2
        )
        zones.append((.leftCover, OBB(center: rig.leftCover.position, halfExtents: coverHalf)))
        zones.append((.rightCover, OBB(center: rig.rightCover.position, halfExtents: coverHalf)))
        return zones
    }

    // MARK: Drag lifecycle (called by GestureRouter)

    /// Starts a drag in the given direction. Returns the page's current curl
    /// progress (the gesture's starting t), or nil if no page can flip that
    /// way right now. Re-grabbing a springing page is allowed and picks up
    /// its live t.
    func beginDrag(direction: GestureRouter.FlipDirection, psi: Float) -> Float? {
        let sheet = direction == .forward ? spreadIndex : spreadIndex - 1
        guard sheet >= 0, sheet < sheetCount else { return nil }
        guard let index = poolIndex(forSheet: sheet) else { return nil }

        var component = pages[index].entity.components[PageComponent.self]!
        let startT = component.currentT
        component.phase = .dragging(t: startT)
        component.gesturePsi = psi
        pages[index].entity.components.set(component)
        activeDragIndex = index
        return startT
    }

    func updateDrag(t: Float, psi: Float) {
        guard let index = activeDragIndex,
              var component = pages[index].entity.components[PageComponent.self] else { return }
        component.phase = .dragging(t: t)
        component.gesturePsi = psi
        pages[index].entity.components.set(component)
    }

    /// Releases the drag: springs to 0 or 1 (position + flick), with the
    /// spring slowed by the sheet's occupancy (omega = omega0/sqrt(mass)).
    func endDrag(t: Float, velocity: Float) {
        defer { activeDragIndex = nil }
        guard let index = activeDragIndex,
              var component = pages[index].entity.components[PageComponent.self] else { return }
        let target = GestureMath.releaseTarget(t: t, velocity: velocity)
        let clamped = min(max(velocity, -GestureMath.maxSpringVelocity), GestureMath.maxSpringVelocity)
        component.phase = .springing(FlipSpring(
            t: t,
            velocity: clamped,
            target: target,
            omega: PageDynamics.omega(occupiedSlots: component.occupiedBothSides)
        ))
        pages[index].entity.components.set(component)
    }

    // MARK: Debug hooks

    /// -curl: freeze the active right page mid-curl.
    func freezeCurl(_ progress: Float) {
        guard spreadIndex < sheetCount, let index = poolIndex(forSheet: spreadIndex),
              var component = pages[index].entity.components[PageComponent.self] else { return }
        component.phase = .rest(t: min(max(progress, 0), 1))
        pages[index].entity.components.set(component)
    }

    /// -autoFlip: one scripted forward flip driven through the exact gesture
    /// path a finger would take — a drag ramp to t = 0.6 over ~0.8 s, then
    /// the standard occupancy-weighted release spring (~0.9 s). The slow
    /// linear ramp keeps the page visibly airborne for most of the flight,
    /// which makes the screenshot timing robust against launch jitter.
    func startAutoFlip() {
        guard beginDrag(direction: .forward, psi: 0.22) != nil else { return }
        Self.log.info("autoFlip started on sheet \(self.spreadIndex, privacy: .public)")

        let rampDuration: Float = 0.8
        let rampTarget: Float = 0.6
        Task { [weak self] in
            let start = Date.now
            while true {
                guard let self else { return }
                let elapsed = Float(Date.now.timeIntervalSince(start))
                let fraction = min(1, elapsed / rampDuration)
                self.updateDrag(t: rampTarget * fraction, psi: 0.22 * (1 - 0.3 * fraction))
                if fraction >= 1 { break }
                try? await Task.sleep(for: .milliseconds(16))
            }
            self?.endDrag(t: rampTarget, velocity: 1.0)
        }
    }

    // MARK: Settle handling

    private func handleSettled(entity: Entity, component: PageComponent) {
        let target: Float = component.currentT > 0.5 ? 1 : 0
        if component.sheetIndex == spreadIndex, target == 1 {
            rebind(spread: spreadIndex + 1) // forward flip completed
        } else if component.sheetIndex == spreadIndex - 1, target == 0 {
            rebind(spread: spreadIndex - 1) // backward flip completed
        } else {
            rebind(spread: spreadIndex) // cancelled flip: restore rest pose
        }
    }

    private func poolIndex(forSheet sheet: Int) -> Int? {
        pages.indices.first { index in
            pages[index].entity.isEnabled
                && pages[index].entity.components[PageComponent.self]?.sheetIndex == sheet
        }
    }
}
