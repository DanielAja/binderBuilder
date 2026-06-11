//
//  CloudSyncService.swift
//  binderBuilder
//
//  Opt-in iCloud (CloudKit private database) backup of the whole collection.
//  The full collection is serialized via BackupService into one private-DB
//  record (JSON in a CKAsset); pushed when the app backgrounds / on demand,
//  and restored on demand. Free (the user's iCloud), no server.
//
//  CloudKit is only touched once the user opts in, and every call degrades
//  gracefully when there's no iCloud account, so normal use never depends on
//  iCloud. Cross-device restore replaces local data (relaunch to reload).
//

import CloudKit
import Foundation
import Observation
import os

@MainActor
@Observable
final class CloudSyncService {
    enum Status: Equatable {
        case idle
        case syncing
        case synced(Date)
        case unavailable(String)
        case failed(String)
    }

    private let database: UserDatabase
    private let containerID = "iCloud.com.aja.binderBuilder"
    private let recordType = "CollectionBackup"
    private let recordID = CKRecord.ID(recordName: "binderCollection")
    private var container: CKContainer { CKContainer(identifier: containerID) }
    private var cloudDB: CKDatabase { container.privateCloudDatabase }

    @ObservationIgnored private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CloudSync")
    private(set) var status: Status = .idle

    init(database: UserDatabase) { self.database = database }

    private func availableOrReport() async -> Bool {
        let account = (try? await container.accountStatus()) ?? .couldNotDetermine
        switch account {
        case .available: return true
        case .noAccount: status = .unavailable("Sign in to iCloud in Settings to sync."); return false
        case .restricted: status = .unavailable("iCloud is restricted on this device."); return false
        default: status = .unavailable("iCloud is unavailable right now."); return false
        }
    }

    /// Uploads the current collection to the iCloud private database.
    func push() async {
        guard await availableOrReport() else { return }
        status = .syncing
        do {
            let data = try BackupService.export(database)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("binder-cloud.json")
            try data.write(to: url)
            let record = (try? await cloudDB.record(for: recordID))
                ?? CKRecord(recordType: recordType, recordID: recordID)
            record["payload"] = CKAsset(fileURL: url)
            record["modifiedAt"] = Date()
            _ = try await cloudDB.save(record)
            status = .synced(Date())
            Self.log.info("Pushed collection to iCloud")
        } catch {
            status = .failed(error.localizedDescription)
            Self.log.error("iCloud push failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Replaces local data with the iCloud copy. Returns true if data was
    /// restored (the caller should prompt a relaunch). No-op if no cloud copy.
    @discardableResult
    func restoreFromCloud() async -> Bool {
        guard await availableOrReport() else { return false }
        status = .syncing
        do {
            let record = try await cloudDB.record(for: recordID)
            guard let asset = record["payload"] as? CKAsset, let url = asset.fileURL else {
                status = .synced(Date()); return false
            }
            let data = try Data(contentsOf: url)
            try BackupService.restore(data, into: database)
            status = .synced(Date())
            Self.log.info("Restored collection from iCloud")
            return true
        } catch let ckError as CKError where ckError.code == .unknownItem {
            status = .unavailable("No iCloud backup yet — back up first.")
            return false
        } catch {
            status = .failed(error.localizedDescription)
            return false
        }
    }
}
