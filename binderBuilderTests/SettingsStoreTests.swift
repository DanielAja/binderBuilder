//
//  SettingsStoreTests.swift
//  binderBuilderTests
//
//  KeychainStore itself is deliberately untested (the real keychain is
//  flaky in headless simulator runs); SettingsStore is tested against a
//  UserDefaults suite and the FakeKeychain double.
//

import Foundation
import Testing
@testable import binderBuilder

@MainActor struct SettingsStoreTests {
    private func makeDefaults() throws -> UserDefaults {
        let suiteName = "SettingsStoreTests-\(UUID().uuidString)"
        let defaults = try #require(UserDefaults(suiteName: suiteName))
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    @Test func flagsPersistToUserDefaults() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults, keychain: FakeKeychain())

        #expect(store.ebayEnabled == false)
        #expect(store.demoSeeded == false)

        store.ebayEnabled = true
        store.demoSeeded = true
        #expect(defaults.bool(forKey: "ebayEnabled") == true)
        #expect(defaults.bool(forKey: "demoSeeded") == true)

        // A fresh store sees the persisted values.
        let reloaded = SettingsStore(defaults: defaults, keychain: FakeKeychain())
        #expect(reloaded.ebayEnabled == true)
        #expect(reloaded.demoSeeded == true)
    }

    @Test func credentialsWriteThroughTheKeychain() throws {
        let defaults = try makeDefaults()
        let keychain = FakeKeychain()
        let store = SettingsStore(defaults: defaults, keychain: keychain)

        #expect(store.ebayAppID == nil)
        #expect(store.ebayCertID == nil)

        store.ebayAppID = "app-id-123"
        store.ebayCertID = "cert-id-456"
        #expect(keychain.storage["ebayAppID"] == "app-id-123")
        #expect(keychain.storage["ebayCertID"] == "cert-id-456")

        // nil (and empty string) delete the entries.
        store.ebayAppID = nil
        #expect(keychain.storage["ebayAppID"] == nil)
        store.ebayCertID = ""
        #expect(keychain.storage["ebayCertID"] == nil)
    }

    @Test func initReadsExistingCredentials() throws {
        let defaults = try makeDefaults()
        let keychain = FakeKeychain()
        keychain.storage["ebayAppID"] = "existing-app"
        keychain.storage["ebayCertID"] = "existing-cert"

        let store = SettingsStore(defaults: defaults, keychain: keychain)
        #expect(store.ebayAppID == "existing-app")
        #expect(store.ebayCertID == "existing-cert")
    }

    @Test func ebayConfiguredRequiresToggleAndBothCredentials() throws {
        let defaults = try makeDefaults()
        let store = SettingsStore(defaults: defaults, keychain: FakeKeychain())

        #expect(store.ebayConfigured == false)
        store.ebayEnabled = true
        #expect(store.ebayConfigured == false)
        store.ebayAppID = "app"
        #expect(store.ebayConfigured == false)
        store.ebayCertID = "cert"
        #expect(store.ebayConfigured == true)
        store.ebayEnabled = false
        #expect(store.ebayConfigured == false)
    }
}
