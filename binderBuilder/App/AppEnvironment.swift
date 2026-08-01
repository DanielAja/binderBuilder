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
    let trades: TradeStore
    let tradeList: TradeListStore
    let stats: CollectionStatsStore
    let cloud: CloudSyncService
    let errors: ErrorPresenter
    let imageCache: ImageCache
    let textureCache: CardTextureCache

    /// A problem detected during init (e.g. the on-disk DB couldn't open and we
    /// fell back to a temporary store), surfaced once the UI is up.
    @ObservationIgnored private var launchWarning: String?

    /// The binder currently rendered in 3D, and its prepared card content. The
    /// content is a live holder (see LiveBinderCardContent): the running scene
    /// reads through it, so a single-pocket edit can refresh it in place
    /// instead of forcing a scene rebuild.
    private(set) var openBinderID: String?
    let content = LiveBinderCardContent()
    private(set) var isReady = false

    /// The 3D scene, built once and reused across tab switches.
    @ObservationIgnored private var _scene: SceneModel?
    var scene: SceneModel {
        if let _scene { return _scene }
        let made = SceneModel(
            content: content.sheetCount > 0 ? content : nil, textureCache: textureCache)
        _scene = made
        return made
    }

    /// Bumped whenever the open binder's card content is re-snapshotted.
    /// RootTabView keys the Binder tab on it, so the scene is rebuilt from the
    /// fresh snapshot the next time that tab's body is evaluated.
    private(set) var sceneGeneration = 0

    init() {
        let catalogDB = GRDBCatalogDatabase.bundled()
        catalog = catalogDB
        search = CatalogStore(catalog: catalogDB)
        // Open the on-disk store; if it's missing/corrupt, fall back to a
        // temporary in-memory store so the app still launches (and tell the
        // user their changes won't be saved) instead of crashing.
        let database: UserDatabase
        var warning: String?
        do {
            database = try UserDatabase.openDefault()
        } catch {
            Self.log.fault("openDefault failed: \(String(describing: error), privacy: .public)")
            do {
                database = try UserDatabase.inMemory()
                warning = "Couldn't open your saved collection, so it's running in temporary mode — changes won't be saved. Reinstalling may fix this."
            } catch {
                Self.log.fault("inMemory fallback failed: \(String(describing: error), privacy: .public)")
                fatalError("Unable to initialize the database: \(error)")
            }
        }
        userDatabase = database
        launchWarning = warning
        errors = ErrorPresenter()
        settings = SettingsStore()
        let collection = CollectionStore(database: database)
        self.collection = collection
        wishlist = WishlistStore(database: database)
        groups = GroupStore(database: database)
        binders = BinderStore(database: database, catalog: catalog, isOwned: { collection.isOwned($0) })
        prices = PriceStore(database: database, catalog: catalog, settings: settings)
        alerts = AlertStore(database: database)
        trades = TradeStore(database: database)
        tradeList = TradeListStore(database: database)
        cloud = CloudSyncService(database: database)
        stats = CollectionStatsStore(catalog: catalog, collection: collection, database: database)
        let cache = ImageCache.standard()
        imageCache = cache
        textureCache = CardTextureCache(imageCache: cache)
    }

    /// Seeds first-run content, picks the binder to open, and snapshots its
    /// card content for the scene. Idempotent enough to call once at launch.
    func prepare() async {
        // Load every store's in-memory mirror off the main thread, concurrently,
        // behind ContentView's launch screen — so init stays cheap and a large
        // collection/library never blocks the first frame.
        async let c: Void = collection.load()
        async let w: Void = wishlist.load()
        async let g: Void = groups.load()
        async let b: Void = binders.load()
        async let a: Void = alerts.load()
        async let t: Void = trades.load()
        async let tl: Void = tradeList.load()
        _ = await (c, w, g, b, a, t, tl)

        await DemoSeed.seedIfNeeded(
            settings: settings, catalog: catalog, collection: collection, binders: binders
        )
        guard let binder = binders.binders.first else {
            Self.log.error("No binder to open after seeding")
            isReady = true
            return
        }
        openBinderID = binder.id
        content.replace(with: await BinderCardContentBuilder.build(binderID: binder.id, store: binders))
        Self.log.info("Prepared binder \(binder.id, privacy: .public) with \(self.content.sheetCount, privacy: .public) sheets")
        // Seed the "known sets" baseline so new-release alerts only fire for
        // sets released after this catalog build.
        if userDatabase.knownSetIDs().isEmpty, let sets = try? await catalog?.allSets() {
            userDatabase.addKnownSets(sets.map(\.id))
        }
        isReady = true
        if let launchWarning { errors.show(launchWarning) }
    }

    /// Re-snapshots the open binder and drops the cached scene, so the Binder
    /// tab rebuilds its 3D content with the binder's new card order. A no-op
    /// unless `binderID` is the binder currently rendered in 3D.
    ///
    /// Use this for whole-binder changes (a sort). A single pocket edit should
    /// use `reloadOpenBinderContent` instead — rebuilding the scene also resets
    /// the camera and the open spread, which is far too much for one card.
    func refreshOpenBinder(_ binderID: String) async {
        guard binderID == openBinderID else { return }
        await reloadOpenBinderContent(binderID)
        _scene = nil
        sceneGeneration += 1
    }

    /// Re-snapshots the open binder IN PLACE: the live content holder picks up
    /// the new pockets, but the scene is left standing. Callers rebind the page
    /// pool afterwards so the change shows immediately while the camera, the
    /// open spread and any on-screen mode all survive. Returns false when
    /// `binderID` isn't the binder currently rendered in 3D.
    @discardableResult
    func reloadOpenBinderContent(_ binderID: String) async -> Bool {
        guard binderID == openBinderID else { return false }
        content.replace(with: await BinderCardContentBuilder.build(binderID: binderID, store: binders))
        return true
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
