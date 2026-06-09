//
//  KeychainStore.swift
//  binderBuilder
//
//  Minimal string storage over SecItem generic passwords. Used for the
//  user-supplied eBay developer credentials.
//

import Foundation
import Security
import os

/// Seam for tests (the real keychain is flaky in headless simulators).
nonisolated protocol KeychainStoring {
    func string(for key: String) -> String?
    func set(_ value: String, for key: String)
    func delete(key: String)
}

nonisolated struct KeychainStore: KeychainStoring, Sendable {
    let service: String

    private static let logger = Logger(subsystem: "com.aja.binderBuilder", category: "KeychainStore")

    init(service: String = "com.aja.binderBuilder") {
        self.service = service
    }

    func string(for key: String) -> String? {
        var query = baseQuery(key: key)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne
        var item: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &item)
        guard status == errSecSuccess, let data = item as? Data else {
            if status != errSecSuccess && status != errSecItemNotFound {
                Self.logger.error("keychain read failed for \(key, privacy: .public): \(status)")
            }
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    func set(_ value: String, for key: String) {
        let data = Data(value.utf8)
        let updateStatus = SecItemUpdate(
            baseQuery(key: key) as CFDictionary,
            [kSecValueData as String: data] as CFDictionary)
        guard updateStatus == errSecItemNotFound else {
            if updateStatus != errSecSuccess {
                Self.logger.error("keychain update failed for \(key, privacy: .public): \(updateStatus)")
            }
            return
        }
        var addQuery = baseQuery(key: key)
        addQuery[kSecValueData as String] = data
        addQuery[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(addQuery as CFDictionary, nil)
        if addStatus != errSecSuccess {
            Self.logger.error("keychain add failed for \(key, privacy: .public): \(addStatus)")
        }
    }

    func delete(key: String) {
        let status = SecItemDelete(baseQuery(key: key) as CFDictionary)
        if status != errSecSuccess && status != errSecItemNotFound {
            Self.logger.error("keychain delete failed for \(key, privacy: .public): \(status)")
        }
    }

    private func baseQuery(key: String) -> [String: Any] {
        [kSecClass as String: kSecClassGenericPassword,
         kSecAttrService as String: service,
         kSecAttrAccount as String: key]
    }
}
