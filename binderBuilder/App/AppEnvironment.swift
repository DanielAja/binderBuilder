//
//  AppEnvironment.swift
//  binderBuilder
//
//  Composition root: owns the bundled catalog, the user database and its
//  stores, the image + texture caches, and the prepared 3D card content for
//  the open binder. Created once by the app; `prepare()` seeds first-run
//  content and snapshots the demo binder for the scene.
//

import Foundation
import OSLog

@MainActor
@Observable
final class AppEnvironment {
    private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "AppEnvironment")

    let catalog: (any CatalogReading)?
    let search: CatalogStore
    let userDatabase: UserDatabase
    let settings: SettingsStore
    let collection: CollectionStore
    let wishlist: WishlistStore
    let groups: GroupStore
    let binders: BinderStore
    let prices: PriceStore
    let alerts: AlertStore
    let stats: CollectionStatsStore
    let cloud: CloudSyncService
    let imageCache: ImageCache
    let textureCache: CardTextureCache

    /// The binder currently rendered in 3D and its prepared card content.
    private(set) var openBinderID: String?
    private(set) var content: BinderCardContent?
    private(set) var isReady = false

    /// The 3D scene, built once and reused across tab switches.
    @ObservationIgnored private var _scene: SceneModel?
    var scene: SceneModel {
        if let _scene { return _scene }
        let made = SceneModel(content: content, textureCache: textureCache)
        _scene = made
        return made
    }

    init() {
        let catalogDB = GRDBCatalogDatabase.bundled()
        catalog = catalogDB
        search = CatalogStore(catalog: catalogDB)
        let database = (try? UserDatabase.openDefault()) ?? (try! UserDatabase.inMemory())
        userDatabase = database
        settings = SettingsStore()
        let collection = CollectionStore(database: database)
        self.collection = collection
        wishlist = WishlistStore(database: database)
        groups = GroupStore(database: database)
        binders = BinderStore(database: database, catalog: catalog, isOwned: { collection.isOwned($0) })
        prices = PriceStore(database: database, catalog: catalog, settings: settings)
        alerts = AlertStore(database: database)
        cloud = CloudSyncService(database: database)
        stats = CollectionStatsStore(catalog: catalog, collection: collection, database: database)
        let cache = ImageCache.standard()
        imageCache = cache
        textureCache = CardTextureCache(imageCache: cache)
    }

    /// Seeds first-run content, picks the binder to open, and snapshots its
    /// card content for the scene. Idempotent enough to call once at launch.
    func prepare() async {
        await DemoSeed.seedIfNeeded(
            settings: settings, catalog: catalog, collection: collection, binders: binders
        )
        guard let binder = binders.binders.first else {
            Self.log.error("No binder to open after seeding")
            isReady = true
            return
        }
        openBinderID = binder.id
        content = await BinderCardContentBuilder.build(binderID: binder.id, store: binders)
        Self.log.info("Prepared binder \(binder.id, privacy: .public) with \(self.content?.sheetCount ?? 0, privacy: .public) sheets")
        // Seed the "known sets" baseline so new-release alerts only fire for
        // sets released after this catalog build.
        if userDatabase.knownSetIDs().isEmpty, let sets = try? await catalog?.allSets() {
            userDatabase.addKnownSets(sets.map(\.id))
        }
        isReady = true
    }

    /// Runs the price-drop + new-release alert checks (on app activation /
    /// "Check now"). No-op unless the user enabled alerts.
    func runAlertChecks() async {
        await AlertChecker(env: self).runAll()
    }

    /// Toggles ownership of a card and persists it (drives the live
    /// color<->grayscale demo from the floating-card control).
    func toggleOwned(_ ref: CardRef) -> Bool {
        let nowOwned = !collection.isOwned(ref)
        collection.setOwned(ref, quantity: nowOwned ? 1 : 0)
        return nowOwned
    }
}
