//
//  LiveBinderCardContent.swift
//  binderBuilder
//
//  A mutable box around the immutable BinderCardContent snapshot.
//
//  The scene's card layer (CardPlacement) and page pool (BinderFlipController)
//  each capture their content source once, at bootstrap. A whole-binder change
//  (a sort) can afford to rebuild the scene around a fresh snapshot; a
//  single-pocket edit cannot — tearing the RealityView down would reset the
//  camera and snap the binder back to its middle spread just because the user
//  swapped one card. Handing the scene THIS object instead means a pocket edit
//  only has to swap the snapshot inside it and ask the flip controller to
//  rebind: the existing spawn/despawn diff then updates exactly the pockets
//  that changed, in place.
//
//  Reads come from the render loop and writes from the main actor, so the
//  snapshot is guarded by a lock (the protocol is nonisolated by design — the
//  scene layer reads it synchronously every rebind).
//

import Foundation

nonisolated final class LiveBinderCardContent: CardContentProviding, @unchecked Sendable {
    private let lock = NSLock()
    private var content: BinderCardContent

    init(_ content: BinderCardContent = .empty) {
        self.content = content
    }

    var sheetCount: Int {
        lock.withLock { content.sheetCount }
    }

    func snapshot(sheet: Int) -> SheetCardSnapshot {
        lock.withLock { content.snapshot(sheet: sheet) }
    }

    /// Swaps in a freshly built snapshot. Callers that need the change on
    /// screen rebind the page pool afterwards.
    func replace(with content: BinderCardContent) {
        lock.withLock { self.content = content }
    }
}
