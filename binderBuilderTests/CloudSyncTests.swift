//
//  CloudSyncTests.swift
//  binderBuilderTests
//
//  The push guard that keeps the single iCloud record from being clobbered:
//  never from the temporary in-memory DB, never over a backup this device
//  hasn't synced (or one newer than its last sync) unless the user says so.
//

import Foundation
import Testing
@testable import binderBuilder

@Suite struct CloudSyncTests {
    typealias Decision = CloudSyncService.PushDecision
    let synced = Date(timeIntervalSince1970: 1_800_000_000)

    @Test func temporaryDatabaseNeverPushesEvenWhenForced() {
        for force in [false, true] {
            #expect(Decision.decide(isTemporaryDatabase: true, cloudModifiedAt: nil,
                                    cloudRecordExists: false, lastSyncedAt: nil, force: force)
                    == .refuseTemporaryDatabase)
        }
    }

    @Test func firstBackupPushesWhenICloudIsEmpty() {
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: nil,
                                cloudRecordExists: false, lastSyncedAt: nil, force: false) == .push)
    }

    /// Enabling sync on a new device/install must not replace the real backup.
    @Test func existingBackupThisDeviceNeverSyncedAsksFirst() {
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: synced,
                                cloudRecordExists: true, lastSyncedAt: nil, force: false) == .askUser)
    }

    @Test func newerCloudCopyIsNotOverwritten() {
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: synced.addingTimeInterval(60),
                                cloudRecordExists: true, lastSyncedAt: synced, force: false) == .askUser)
    }

    @Test func cloudCopyThisDeviceWroteIsReplaced() {
        // Same stamp, or sub-second drift from the CloudKit round trip.
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: synced,
                                cloudRecordExists: true, lastSyncedAt: synced, force: false) == .push)
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: synced.addingTimeInterval(0.4),
                                cloudRecordExists: true, lastSyncedAt: synced, force: false) == .push)
    }

    @Test func undatedCloudRecordAsksUnlessForced() {
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: nil,
                                cloudRecordExists: true, lastSyncedAt: synced, force: false) == .askUser)
        #expect(Decision.decide(isTemporaryDatabase: false, cloudModifiedAt: nil,
                                cloudRecordExists: true, lastSyncedAt: synced, force: true) == .push)
    }

    /// The service itself refuses before touching CloudKit.
    @MainActor @Test func serviceRefusesPushFromTemporaryDatabase() async throws {
        let service = CloudSyncService(database: try UserDatabase.inMemory(), isTemporaryDatabase: true,
                                       defaults: UserDefaults(suiteName: "CloudSyncTests-\(UUID())")!)
        await service.push(force: true)
        guard case .failed = service.status else {
            Issue.record("expected a refusal, got \(service.status)")
            return
        }
    }
}
