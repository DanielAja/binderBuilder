//
//  SettingsStore.swift
//  binderBuilder
//
//  App settings. Plain flags live in UserDefaults; the user's eBay
//  developer credentials live in the Keychain.
//

import Foundation
import Observation

@MainActor @Observable final class SettingsStore {
    private enum DefaultsKey {
        static let ebayEnabled = "ebayEnabled"
        static let demoSeeded = "demoSeeded"
        static let priceAlerts = "priceAlertsEnabled"
        static let newReleaseAlerts = "newReleaseAlertsEnabled"
        static let icloudSync = "icloudSyncEnabled"
    }

    private enum KeychainKey {
        static let ebayAppID = "ebayAppID"
        static let ebayCertID = "ebayCertID"
    }

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let keychain: any KeychainStoring

    /// Whether the optional eBay Browse API price source is active.
    var ebayEnabled: Bool {
        didSet { defaults.set(ebayEnabled, forKey: DefaultsKey.ebayEnabled) }
    }

    /// Whether the first-run demo content has already been seeded.
    var demoSeeded: Bool {
        didSet { defaults.set(demoSeeded, forKey: DefaultsKey.demoSeeded) }
    }

    /// Notify when a watched card's price drops below its target / %.
    var priceAlertsEnabled: Bool {
        didSet { defaults.set(priceAlertsEnabled, forKey: DefaultsKey.priceAlerts) }
    }

    /// Notify when new sets are released.
    var newReleaseAlertsEnabled: Bool {
        didSet { defaults.set(newReleaseAlertsEnabled, forKey: DefaultsKey.newReleaseAlerts) }
    }

    /// Back up the collection to the user's iCloud (CloudKit).
    var icloudSyncEnabled: Bool {
        didSet { defaults.set(icloudSyncEnabled, forKey: DefaultsKey.icloudSync) }
    }

    /// eBay application id (client id), Keychain-backed. nil/empty deletes.
    var ebayAppID: String? {
        didSet { writeCredential(ebayAppID, key: KeychainKey.ebayAppID) }
    }

    /// eBay certificate id (client secret), Keychain-backed. nil/empty deletes.
    var ebayCertID: String? {
        didSet { writeCredential(ebayCertID, key: KeychainKey.ebayCertID) }
    }

    init(defaults: UserDefaults = .standard, keychain: any KeychainStoring = KeychainStore()) {
        self.defaults = defaults
        self.keychain = keychain
        self.ebayEnabled = defaults.bool(forKey: DefaultsKey.ebayEnabled)
        self.demoSeeded = defaults.bool(forKey: DefaultsKey.demoSeeded)
        self.priceAlertsEnabled = defaults.bool(forKey: DefaultsKey.priceAlerts)
        self.newReleaseAlertsEnabled = defaults.bool(forKey: DefaultsKey.newReleaseAlerts)
        self.icloudSyncEnabled = defaults.bool(forKey: DefaultsKey.icloudSync)
        self.ebayAppID = keychain.string(for: KeychainKey.ebayAppID)
        self.ebayCertID = keychain.string(for: KeychainKey.ebayCertID)
    }

    /// True when eBay pricing is both switched on and fully configured.
    var ebayConfigured: Bool {
        ebayEnabled
            && !(ebayAppID ?? "").isEmpty
            && !(ebayCertID ?? "").isEmpty
    }

    private func writeCredential(_ value: String?, key: String) {
        if let value, !value.isEmpty {
            keychain.set(value, for: key)
        } else {
            keychain.delete(key: key)
        }
    }
}
