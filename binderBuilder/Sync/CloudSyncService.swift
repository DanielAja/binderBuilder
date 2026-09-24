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
//  iCloud. Cross-device restore replaces local data; the caller reloads the
//  in-memory stores afterwards.
//
//  There is exactly ONE cloud record, so a push is a whole-collection
//  overwrite. Pushes are therefore guarded (see `PushDecision`): a temporary
//  in-memory database never pushes, and a device only overwrites the cloud
//  copy it last pushed or restored itself. If the record is newer than that —
//  or this device has never synced and a backup already exists — the push is
//  held back as a `.conflict` and the user picks restore vs replace.
//

import CloudKit
import Foundation
import Observation
import UIKit
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
        /// iCloud holds a backup this device didn't write (or newer than the
        /// one it last synced), so an automatic push was held back. Carries
        /// the cloud copy's `modifiedAt` when known.
        case conflict(Date?)
    }

    /// Whether a push may overwrite the single cloud record. Pure, so the
    /// rules that protect the real backup are unit-tested.
    nonisolated enum PushDecision: Equatable {
        case push
        /// The local store is the throwaway in-memory fallback — pushing it
        /// would replace the user's real backup with an empty collection.
        case refuseTemporaryDatabase
        /// Another device (or an earlier install) wrote a backup this device
        /// hasn't seen; ask before overwriting it.
        case askUser

        /// Allowance for Date precision lost on the CloudKit round trip.
        static let clockSlack: TimeInterval = 1

        static func decide(
            isTemporaryDatabase: Bool, cloudModifiedAt: Date?, cloudRecordExists: Bool,
            lastSyncedAt: Date?, force: Bool
        ) -> PushDecision {
            if isTemporaryDatabase { return .refuseTemporaryDatabase }
            if force || !cloudRecordExists { return .push }
            // A record exists but this device never pushed/restored it: its
            // contents are unknown here, so don't clobber them silently.
            guard let lastSyncedAt else { return .askUser }
            // A record without a timestamp can't be proven older than ours.
            guard let cloudModifiedAt else { return .askUser }
            return cloudModifiedAt > lastSyncedAt.addingTimeInterval(clockSlack) ? .askUser : .push
        }
    }

    private let database: UserDatabase
    /// True when `database` is the temporary in-memory fallback.
    private let isTemporaryDatabase: Bool
    private let defaults: UserDefaults
    private static let lastSyncedKey = "icloudLastSyncedModifiedAt"
    private let containerID = "iCloud.com.aja.binderBuilder"
    private let recordType = "CollectionBackup"
    private let recordID = CKRecord.ID(recordName: "binderCollection")
    private var container: CKContainer { CKContainer(identifier: containerID) }
    private var cloudDB: CKDatabase { container.privateCloudDatabase }

    @ObservationIgnored private static let log = Logger(subsystem: "com.aja.binderBuilder", category: "CloudSync")
    private(set) var status: Status = .idle

    init(database: UserDatabase, isTemporaryDatabase: Bool = false, defaults: UserDefaults = .standard) {
        self.database = database
        self.isTemporaryDatabase = isTemporaryDatabase
        self.defaults = defaults
    }

    /// The cloud record's `modifiedAt` as of this device's last push/restore.
    private var lastSyncedAt: Date? {
        get { defaults.object(forKey: Self.lastSyncedKey) as? Date }
        set { defaults.set(newValue, forKey: Self.lastSyncedKey) }
    }

    var hasConflict: Bool { if case .conflict = status { true } else { false } }

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
    ///
    /// Guarded by `PushDecision`: refuses from the temporary database, and
    /// holds back (status `.conflict`) instead of overwriting a cloud copy
    /// this device hasn't synced. `force` is only for the user's explicit
    /// "Replace iCloud backup" choice in that conflict dialog.
    func push(force: Bool = false) async {
        if isTemporaryDatabase {
            status = .failed("Your collection is in temporary mode, so it wasn't backed up.")
            Self.log.error("Refusing iCloud push from the in-memory fallback database")
            return
        }
        guard await availableOrReport() else { return }
        status = .syncing
        do {
            // Fetch first: a failed lookup (other than "no record yet") must
            // not fall through to creating a fresh record over the real one.
            let existing: CKRecord?
            do {
                existing = try await cloudDB.record(for: recordID)
            } catch let ckError as CKError where ckError.code == .unknownItem {
                existing = nil
            }
            let decision = PushDecision.decide(
                isTemporaryDatabase: isTemporaryDatabase,
                cloudModifiedAt: existing?["modifiedAt"] as? Date,
                cloudRecordExists: existing != nil,
                lastSyncedAt: lastSyncedAt, force: force)
            switch decision {
            case .push: break
            case .refuseTemporaryDatabase:
                status = .failed("Your collection is in temporary mode, so it wasn't backed up.")
                return
            case .askUser:
                status = .conflict(existing?["modifiedAt"] as? Date)
                Self.log.info("Held back iCloud push: the cloud copy is newer or unknown")
                return
            }

            let data = try BackupService.export(database)
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("binder-cloud.json")
            try data.write(to: url)
            let record = existing ?? CKRecord(recordType: recordType, recordID: recordID)
            let now = Date()
            record["payload"] = CKAsset(fileURL: url)
            record["modifiedAt"] = now
            _ = try await cloudDB.save(record)
            lastSyncedAt = now
            status = .synced(now)
            Self.log.info("Pushed collection to iCloud")
        } catch {
            status = .failed(error.localizedDescription)
            Self.log.error("iCloud push failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// The on-background auto backup. Wrapped in a background-task assertion
    /// so the upload isn't frozen mid-save the moment the app is suspended.
    func pushInBackground() {
        let token = BackgroundTaskToken()
        token.id = UIApplication.shared.beginBackgroundTask(withName: "iCloudBackup") {
            token.end()
        }
        Task {
            await push()
            token.end()
        }
    }

    /// Replaces local data with the iCloud copy. Returns true if data was
    /// restored (the caller reloads its stores). No-op if no cloud copy.
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
            // Local now mirrors this cloud copy, so later pushes may replace it.
            lastSyncedAt = (record["modifiedAt"] as? Date) ?? Date()
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

/// Ends a UIApplication background task exactly once, whichever of the
/// expiration handler or the finished push gets there first.
@MainActor
private final class BackgroundTaskToken {
    var id: UIBackgroundTaskIdentifier = .invalid

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
