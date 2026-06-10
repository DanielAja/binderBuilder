//
//  CardComponents.swift
//  binderBuilder
//
//  ECS state for cards seated in binder pockets. A card is a rigid child entity
//  of its pooled page (a real card does not bend), re-posed each frame at its
//  pocket's curl frame by CardPlacementSystem so it rides the page deformation.
//

import RealityKit
import simd

/// Attached to every card entity sitting in a page pocket.
struct CardSlotComponent: Component {
    var ref: CardRef
    var slot: Int
    var side: PageSide
    /// Page-local flat pocket center (pre-curl); CurlFunction is evaluated here.
    var flatCenter: SIMD3<Float>
    /// Curl params last used to pose this card; skip re-pose when unchanged.
    var lastParams: CurlParams?
    /// True once the real art (not the placeholder) has been bound.
    var hasArt: Bool = false
}
