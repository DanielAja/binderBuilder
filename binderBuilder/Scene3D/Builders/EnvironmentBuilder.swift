//
//  EnvironmentBuilder.swift
//  binderBuilder
//
//  Image-based lighting from the bundled studio HDR (studio.exr) so leather,
//  paper, wood, and the card holo pick up soft studio reflections and ambient
//  fill — the difference between "lit void" and "real room". Loaded async and
//  attached when ready; if it fails the explicit key/fill lights still carry
//  the scene.
//

import OSLog
import RealityKit

@MainActor
enum EnvironmentBuilder {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "Environment")

    /// Loads the studio IBL and makes `root` (and its hierarchy) receive it.
    static func applyIBL(to root: Entity, intensityExponent: Float = 1.4) {
        Task {
            do {
                let resource = try await EnvironmentResource(named: "studio")
                let ibl = Entity()
                ibl.name = "StudioIBL"
                ibl.components.set(ImageBasedLightComponent(
                    source: .single(resource), intensityExponent: intensityExponent))
                root.addChild(ibl)
                root.components.set(ImageBasedLightReceiverComponent(imageBasedLight: ibl))
                log.info("Studio IBL applied")
            } catch {
                log.error("Studio IBL unavailable: \(String(describing: error), privacy: .public)")
            }
        }
    }
}
