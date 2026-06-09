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
