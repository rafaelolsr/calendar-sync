import Testing
import Foundation
import EventKit
@testable import CalendarSync

@Suite @MainActor
struct SyncRollbackTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func record(_ id: String) -> ManagedEventRecord {
        ManagedEventRecord(id: id, source: SourceKey(calendarID: "original", eventID: "source-\(id)", occurrence: now),
                           kind: .blocker, destinationCalendarID: "destination", representedStart: now,
                           eventID: "event-\(id)", fingerprint: "before", updatedAt: now)
    }

    private func image(_ id: String, title: String = "Busy") -> OwnedEventImage {
        OwnedEventImage(title: title, start: now, end: now.addingTimeInterval(3600), isAllDay: false,
                        location: nil, notes: nil, url: "calendarsync://\(id)", availability: 2, timeZoneID: nil)
    }

    private func fixture(_ entries: [RollbackEntry]) throws -> (SyncStateStore, UserDefaults, URL, () -> Void) {
        let suite = "CalendarSyncRollbackTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite, isDirectory: true)
        let url = directory.appendingPathComponent("recovery.json")
        let store = SyncStateStore(defaults: defaults, recoveryURL: url)
        var journal = RollbackJournal(previousLastSync: now.addingTimeInterval(-86400))
        journal.entries = entries
        try store.checkpoint {
            $0.rollback = journal
            $0.records = entries.filter { $0.after != nil }.map(\.record)
            $0.automaticBlockingEnabled = true
            $0.lastSync = now
        }
        let cleanup = {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        return (store, defaults, url, cleanup)
    }

    @Test func testFullResetRemovesEventsFromEarlierSyncsAndKeepsOriginals() async throws {
        let latest = RollbackEntry(record: record("latest"), previousRecord: nil, before: nil, after: image("latest"))
        let (store, _, _, cleanup) = try fixture([latest])
        defer { cleanup() }
        try store.checkpoint { $0.records.append(record("earlier")) }
        let repository = FakeRollbackRepository()
        var hydrated = image("latest")
        hydrated.metadataVersion = 1
        hydrated.alarms = [OwnedAlarmImage(absoluteDate: nil, relativeOffset: -900, soundName: nil, location: nil, proximity: 0)]
        repository.events = ["latest": ("latest-id", hydrated), "earlier": ("earlier-id", image("earlier")),
                             "original": ("source-id", image("original", title: "Original appointment"))]
        let result = try GeneratedResetController(stateStore: store, repository: repository).run()
        #expect(result.completedCount == 2)
        #expect(result.remainingCount == 0)
        #expect(Set(repository.writes) == ["delete:earlier", "delete:latest"])
        #expect(repository.events["original"]?.1.title == "Original appointment")
        #expect(store.state.records.isEmpty)
        #expect(store.state.lastSync == nil)
        #expect(!store.state.automaticBlockingEnabled)
        #expect(Set(store.state.creationHistory?.map(\.record.id) ?? []) == ["latest", "earlier"])
    }

    @Test func testFullResetPreflightConflictMakesNoWrites() async throws {
        let entries = ["ok", "conflict"].map { RollbackEntry(record: record($0), previousRecord: nil, before: nil, after: image($0)) }
        let (store, _, _, cleanup) = try fixture(entries)
        defer { cleanup() }
        let journalID = store.state.rollback?.id
        let repository = FakeRollbackRepository()
        repository.events["ok"] = ("ok-id", image("ok"))
        repository.conflicts["conflict"] = "Wrong marker or destination"
        #expect(throws: (any Error).self) { try GeneratedResetController(stateStore: store, repository: repository).run() }
        #expect(repository.writes.isEmpty)
        #expect(store.state.records.count == 2)
        #expect(store.state.rollback?.id == journalID)
    }

    @Test func testFullResetResumesItsOriginalSnapshotsAfterInterruption() async throws {
        let entry = RollbackEntry(record: record("owned"), previousRecord: nil, before: nil, after: image("owned"))
        let (store, defaults, url, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["owned"] = ("owned-id", image("owned"))
        repository.failAfterWrite = ["owned"]
        let first = try GeneratedResetController(stateStore: store, repository: repository).run()
        #expect(first.remainingCount == 1)
        let journalID = store.state.rollback?.id
        let restarted = SyncStateStore(defaults: defaults, recoveryURL: url)
        let second = try GeneratedResetController(stateStore: restarted, repository: repository).run()
        #expect(second.remainingCount == 0)
        #expect(restarted.state.rollback?.id == journalID)
        #expect(restarted.state.records.isEmpty)
        #expect(repository.writes == ["delete:owned"])
    }

    @Test func testLeftoverCleanupPreservesCurrentSyncAndItsRollback() async throws {
        let current = RollbackEntry(record: record("current"), previousRecord: nil, before: nil, after: image("current"))
        let old = RollbackEntry(record: record("old"), previousRecord: nil, before: nil, after: image("old"))
        let (store, _, _, cleanup) = try fixture([current])
        defer { cleanup() }
        let journalID = store.state.rollback?.id
        let repository = FakeRollbackRepository()
        repository.events = ["old": ("old-id", image("old")), "current": ("current-id", image("current"))]
        let result = LeftoverCleanupController(stateStore: store, repository: repository).apply(candidates: [old, current], evidence: [old])
        #expect(result.completedCount == 1)
        #expect(result.remainingCount == 0)
        #expect(repository.writes == ["delete:old"])
        #expect(store.state.records.map(\.id) == ["current"])
        #expect(store.state.rollback?.id == journalID)
        #expect(store.state.rollback?.entries.map(\.record.id) == ["current"])
        #expect(store.state.lastSync == now)
        #expect(!store.state.automaticBlockingEnabled)
        #expect(Set(store.state.creationHistory?.map(\.record.id) ?? []) == ["current", "old"])
    }

    @Test func testLeftoverCleanupRejectsUnprovenEditedAndConflictingEvents() async throws {
        let (store, _, _, cleanup) = try fixture([])
        defer { cleanup() }
        let old = RollbackEntry(record: record("old"), previousRecord: nil, before: nil, after: image("old"))
        let unknown = RollbackEntry(record: record("unknown"), previousRecord: nil, before: nil, after: image("unknown"))
        let conflict = RollbackEntry(record: record("conflict"), previousRecord: nil, before: nil, after: image("conflict"))
        let repository = FakeRollbackRepository()
        repository.events = ["old": ("old-id", image("old", title: "Edited appointment")), "unknown": ("unknown-id", image("unknown"))]
        repository.conflicts["conflict"] = "Ownership conflict"
        let result = LeftoverCleanupController(stateStore: store, repository: repository)
            .apply(candidates: [old, unknown, conflict], evidence: [old, conflict])
        #expect(result.completedCount == 0)
        #expect(result.remainingCount == 3)
        #expect(repository.writes.isEmpty)
    }

    @Test func testInterruptedLeftoverCleanupResumesWithoutAnotherDelete() async throws {
        let (store, defaults, url, cleanup) = try fixture([])
        defer { cleanup() }
        let old = RollbackEntry(record: record("old"), previousRecord: nil, before: nil, after: image("old"))
        let repository = FakeRollbackRepository()
        repository.events["old"] = ("old-id", image("old"))
        repository.failAfterWrite = ["old"]
        let result = LeftoverCleanupController(stateStore: store, repository: repository).apply(candidates: [old], evidence: [old])
        #expect(result.remainingCount == 1)
        let restarted = SyncStateStore(defaults: defaults, recoveryURL: url)
        let retry = LeftoverCleanupController(stateStore: restarted, repository: repository).apply(candidates: [], evidence: [])
        #expect(retry.remainingCount == 0)
        #expect(repository.writes == ["delete:old"])
        #expect(restarted.state.creationHistory?.first?.record.id == "old")
    }

    @Test func testRollsBackCreatesUpdatesAndDeletionsInReverseOrder() async throws {
        let created = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let updated = RollbackEntry(record: record("updated"), previousRecord: record("updated"), before: image("updated"), after: image("updated", title: "Changed"))
        let deleted = RollbackEntry(record: record("deleted"), previousRecord: record("deleted"), before: image("deleted"), after: nil)
        let (store, _, _, cleanup) = try fixture([created, updated, deleted])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events = ["created": ("created-id", image("created")), "updated": ("updated-id", image("updated", title: "Changed")),
                             "unrelated": ("real-id", image("unrelated", title: "Real appointment"))]
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        #expect(repository.writes.count == 0, "Preview must not write calendar events")
        let result = controller.apply(preview: preview)
        #expect(result.remainingCount == 0)
        #expect(result.completedCount == 3)
        #expect(repository.writes == ["restore:deleted", "restore:updated", "delete:created"])
        #expect(repository.events["created"] == nil)
        #expect(repository.events["updated"]?.1 == image("updated"))
        #expect(repository.events["deleted"]?.1 == image("deleted"))
        #expect(repository.events["unrelated"]?.1.title == "Real appointment")
        #expect(Set(store.state.records.map(\.id)) == ["updated", "deleted"])
        #expect(store.state.records.first { $0.id == "deleted" }?.eventID == "restored-deleted")
        #expect(!(store.state.automaticBlockingEnabled))
        #expect(store.state.lastSync == now.addingTimeInterval(-86400))
    }

    @Test func testPartialFailureRetainsOnlyPendingEntryAndRetryIsIdempotent() async throws {
        let entries = ["ok", "fail"].map { RollbackEntry(record: record($0), previousRecord: nil, before: nil, after: image($0)) }
        let (store, defaults, url, cleanup) = try fixture(entries)
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events = ["ok": ("ok-id", image("ok")), "fail": ("fail-id", image("fail"))]
        repository.failBeforeWrite = ["fail"]
        let controller = RollbackController(stateStore: store, repository: repository)
        let first = controller.apply(preview: try #require(controller.preview()))
        #expect(first.completedCount == 1)
        #expect(first.remainingCount == 1)
        #expect(store.state.rollback?.entries.map(\.record.id) == ["fail"])
        #expect(!(store.state.automaticBlockingEnabled))
        var stalePreferences = store.state
        stalePreferences.automaticBlockingEnabled = true
        defaults.set(try JSONEncoder().encode(stalePreferences), forKey: "CalendarSync.State.v1")
        let restarted = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(restarted.state.rollback?.entries.map(\.record.id) == ["fail"])
        #expect(!restarted.state.automaticBlockingEnabled, "The rollback gate must survive stale preferences after a crash")
        let retry = RollbackController(stateStore: restarted, repository: repository)
        let second = retry.apply(preview: try #require(retry.preview()))
        #expect(second.remainingCount == 0)
        #expect(repository.writes.filter { $0 == "delete:ok" }.count == 1)
        #expect(repository.writes.filter { $0 == "delete:fail" }.count == 1)
    }

    @Test func testCrashAfterDeleteBeforeCheckpointCanBeResumedWithoutAnotherDelete() async throws {
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["created"] = ("created-id", image("created"))
        repository.failAfterWrite = ["created"]
        let controller = RollbackController(stateStore: store, repository: repository)
        #expect(controller.apply(preview: try #require(controller.preview())).remainingCount == 1)
        #expect(repository.events["created"] == nil)
        let preview = try #require(controller.preview())
        #expect(preview.items.first?.action == .alreadyRestored)
        #expect(controller.apply(preview: preview).remainingCount == 0)
        #expect(repository.writes == ["delete:created"])
        #expect(store.state.records.isEmpty)
    }

    @Test func testCrashAfterRestoreBeforeCheckpointRecoversNewEventID() async throws {
        let entry = RollbackEntry(record: record("deleted"), previousRecord: record("deleted"), before: image("deleted"), after: nil)
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.failAfterWrite = ["deleted"]
        let controller = RollbackController(stateStore: store, repository: repository)
        #expect(controller.apply(preview: try #require(controller.preview())).remainingCount == 1)
        #expect(controller.apply(preview: try #require(controller.preview())).remainingCount == 0)
        #expect(repository.writes == ["restore:deleted"])
        #expect(store.state.records.first?.eventID == "restored-deleted")
    }

    @Test func testEventsChangedAfterPreviewAreLeftUntouched() async throws {
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["created"] = ("id", image("created"))
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        repository.events["created"] = ("id", image("created", title: "User edited this"))
        let result = controller.apply(preview: preview)
        #expect(result.remainingCount == 1)
        #expect(repository.writes.isEmpty)
        #expect(repository.events["created"]?.1.title == "User edited this")
        #expect(store.state.records.count == 1)
    }

    @Test func testUnavailableOrUnverifiedEventsStayPendingWhileOtherEventsRecover() async throws {
        let entries = ["owned", "conflict", "unavailable"].map { RollbackEntry(record: record($0), previousRecord: nil, before: nil, after: image($0)) }
        let (store, _, _, cleanup) = try fixture(entries)
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["owned"] = ("id", image("owned"))
        repository.conflicts = ["conflict": "Ownership marker changed", "unavailable": "Calendar unavailable"]
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        #expect(preview.blockedCount == 2)
        let result = controller.apply(preview: preview)
        #expect(result.remainingCount == 2)
        #expect(repository.writes == ["delete:owned"])
        let sync = SyncEngine(eventStore: EKEventStore(), stateStore: store).run(dryRun: false)
        #expect(!(sync.applied))
        #expect(sync.messages.first?.contains("pending rollback") == true)
    }

    @Test func testFailedForwardWritesReconcileWithoutCalendarWrites() async throws {
        let created = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let updated = RollbackEntry(record: record("updated"), previousRecord: record("updated"), before: image("updated"), after: image("updated", title: "New"))
        let deleted = RollbackEntry(record: record("deleted"), previousRecord: record("deleted"), before: image("deleted"), after: nil)
        let (store, _, _, cleanup) = try fixture([created, updated, deleted])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events = ["updated": ("old-updated", image("updated")), "deleted": ("old-deleted", image("deleted"))]
        let controller = RollbackController(stateStore: store, repository: repository)
        #expect(controller.apply(preview: try #require(controller.preview())).remainingCount == 0)
        #expect(repository.writes.isEmpty)
        #expect(Set(store.state.records.map(\.id)) == ["updated", "deleted"])
    }

    @Test func testMissingUpdatedEventIsNotRecreated() async throws {
        let entry = RollbackEntry(record: record("updated"), previousRecord: record("updated"), before: image("updated"), after: image("updated", title: "New"))
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        let controller = RollbackController(stateStore: store, repository: repository)
        #expect(try #require(controller.preview()).blockedCount == 1)
        #expect(controller.apply(preview: try #require(controller.preview())).remainingCount == 1)
        #expect(repository.writes.isEmpty)
    }

    @Test func testStalePreviewCannotUndoAnotherSync() async throws {
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["created"] = ("id", image("created"))
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        try store.checkpoint { $0.rollback = RollbackJournal(previousLastSync: now) }
        #expect(controller.apply(preview: preview).completedCount == 0)
        #expect(repository.writes.isEmpty)
        #expect(store.state.automaticBlockingEnabled)
    }

    @Test func testRecoveryFileOverridesStalePreferencesAfterRestart() async throws {
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let (_, defaults, url, cleanup) = try fixture([entry])
        defer { cleanup() }
        defaults.set(try JSONEncoder().encode(CalendarSyncState()), forKey: "CalendarSync.State.v1")
        let restarted = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(restarted.state.rollback?.entries.first?.record.id == "created")
        #expect(restarted.state.records.first?.id == "created")
        let permissions = try FileManager.default.attributesOfItem(atPath: url.path)[.posixPermissions] as? NSNumber
        #expect(permissions?.intValue == 0o600)
    }

    @Test func testCorruptRecoveryFileBlocksWritesAndIsNotOverwritten() async throws {
        let (store, _, url, cleanup) = try fixture([])
        defer { cleanup() }
        let invalid = Data("broken recovery file".utf8)
        try invalid.write(to: url)
        store.reloadRecovery()
        #expect(store.recoveryError != nil)
        #expect(throws: (any Error).self) { try store.checkpoint { $0.records = [] } }
        let result = SyncEngine(eventStore: EKEventStore(), stateStore: store).run(dryRun: false)
        #expect(!(result.applied))
        #expect(try Data(contentsOf: url) == invalid)
    }

    @Test func testConcurrentSyncOrRollbackCannotOverwriteJournal() async throws {
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: image("created"))
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        let repository = FakeRollbackRepository()
        repository.events["created"] = ("id", image("created"))
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        let lock = try store.acquireRecoveryLock()
        defer { lock.release() }
        #expect(controller.apply(preview: preview).completedCount == 0)
        #expect(repository.writes.isEmpty)
        #expect(store.state.rollback?.entries.count == 1)
        #expect(!(SyncEngine(eventStore: EKEventStore(), stateStore: store).run(dryRun: false).applied))
    }

    @Test func testCannotPersistCheckpointLeavesInMemoryStateUnchanged() async throws {
        let (store, _, url, cleanup) = try fixture([])
        defer { cleanup() }
        try FileManager.default.removeItem(at: url)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
        #expect(throws: (any Error).self) { try store.checkpoint { $0.records = [record("never-written")] } }
        #expect(store.state.records.isEmpty)
    }

    @Test func testLegacyPreferencesMigrateWithoutInventingRollbackHistory() async throws {
        let (_, defaults, url, cleanup) = try fixture([])
        defer { cleanup() }
        try FileManager.default.removeItem(at: url)
        var legacy = CalendarSyncState()
        legacy.participatingCalendarIDs = ["work"]
        legacy.records = [record("pre-upgrade")]
        legacy.futureDays = 30
        var payload = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        payload.removeValue(forKey: "rollback")
        defaults.set(try JSONSerialization.data(withJSONObject: payload), forKey: "CalendarSync.State.v1")
        let migrated = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(migrated.state.records.first?.id == "pre-upgrade")
        #expect(migrated.state.busySharingCalendarIDs == ["work"])
        #expect(migrated.state.rollback == nil)
        migrated.update { $0.blockTentative = true }
        let restarted = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(restarted.state.blockTentative)
        #expect(restarted.state.futureDays == 30)
        #expect(restarted.state.lookAheadMonths == 1)
        #expect(restarted.state.records.first?.id == "pre-upgrade")
        restarted.update { $0.futureMonths = 2 }
        let monthSettings = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(monthSettings.state.lookAheadMonths == 2)
        #expect(monthSettings.state.records.first?.id == "pre-upgrade")
    }

    @Test func testLegacySnapshotAllowsProviderAlertsAndHydratedAvailability() async throws {
        var saved = image("created")
        saved.availability = EKEventAvailability.notSupported.rawValue
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: saved)
        let (store, _, _, cleanup) = try fixture([entry])
        defer { cleanup() }
        var actual = saved
        actual.availability = EKEventAvailability.busy.rawValue
        actual.alarms = [OwnedAlarmImage(absoluteDate: nil, relativeOffset: -900, soundName: nil, location: nil, proximity: 0)]
        actual.metadataVersion = 1
        let repository = FakeRollbackRepository()
        repository.events["created"] = ("id", actual)
        let controller = RollbackController(stateStore: store, repository: repository)
        let preview = try #require(controller.preview())
        #expect(preview.blockedCount == 0)
        #expect(controller.apply(preview: preview).remainingCount == 0)
        #expect(repository.writes == ["delete:created"])
    }

    @Test func testObservedAvailabilityEditsRemainProtected() async throws {
        var saved = image("created")
        saved.availability = EKEventAvailability.busy.rawValue
        var edited = saved
        edited.availability = EKEventAvailability.free.rawValue
        let entry = RollbackEntry(record: record("created"), previousRecord: nil, before: nil, after: saved)
        #expect(!edited.matches(saved))
        if case .blocked = RollbackController.action(for: entry, lookup: .found(eventID: "id", image: edited)) {} else {
            Issue.record("A changed observed availability must stay protected")
        }
    }

    @Test func testLegacyMetadataCompatibilityStillProtectsEventContent() async throws {
        var saved = image("created")
        saved.availability = EKEventAvailability.notSupported.rawValue
        let alarm = OwnedAlarmImage(absoluteDate: nil, relativeOffset: -900, soundName: nil, location: nil, proximity: 0)
        var actual = saved
        actual.alarms = [alarm]
        actual.availability = EKEventAvailability.busy.rawValue
        #expect(actual.matches(saved))
        actual.notes = "User notes added after sync"
        #expect(!actual.matches(saved))
        actual.notes = nil
        actual.start = actual.start.addingTimeInterval(3600)
        #expect(!actual.matches(saved))
    }

    @Test func testNewSnapshotsProtectAlarmEditsButAllowReordering() async throws {
        let first = OwnedAlarmImage(absoluteDate: nil, relativeOffset: -900, soundName: nil, location: nil, proximity: 0)
        let second = OwnedAlarmImage(absoluteDate: nil, relativeOffset: -3600, soundName: "Basso", location: nil, proximity: 0)
        var saved = image("created")
        saved.metadataVersion = 1
        saved.alarms = [first, second]
        var actual = saved
        actual.alarms = [second, first]
        #expect(actual.matches(saved))
        actual.alarms = [first]
        #expect(!actual.matches(saved))
    }

    @Test func testSnapshotCapturesDisplayAndAudioAlarmsAndMapLocations() async throws {
        let eventStore = EKEventStore()
        let event = EKEvent(eventStore: eventStore)
        event.calendar = EKCalendar(for: .event, eventStore: eventStore)
        event.title = "Owned diagnostic event"
        event.startDate = now
        event.endDate = now.addingTimeInterval(3600)
        event.url = URL(string: "calendarsync://owned")
        let display = EKAlarm(relativeOffset: -900)
        let audio = EKAlarm(absoluteDate: now.addingTimeInterval(-3600))
        audio.soundName = "Basso"
        event.alarms = [display, audio]
        event.structuredLocation = EKStructuredLocation(title: "Test location")
        let snapshot = try EventRepository(store: eventStore).rollbackImage(of: event, recordID: "owned")
        #expect(snapshot.alarms?.count == 2)
        #expect(snapshot.alarms?.contains { $0.soundName == "Basso" } == true)
        #expect(snapshot.structuredLocation?.title == "Test location")
        #expect(snapshot.metadataVersion == 1)
        let decoded = try JSONDecoder().decode(OwnedEventImage.self, from: JSONEncoder().encode(snapshot))
        #expect(decoded == snapshot)
        #expect(throws: CalendarSyncError.self) {
            try EventRepository(store: eventStore).rollbackImage(of: event, recordID: "wrong-owner")
        }
    }

    @Test func testLegacyRecoveryImagesDecodeWithoutMetadata() async throws {
        let old = image("created")
        let data = try JSONEncoder().encode(old)
        let decoded = try JSONDecoder().decode(OwnedEventImage.self, from: data)
        #expect(decoded.metadataVersion == nil)
        #expect(decoded.alarms == nil)
        #expect(decoded.matches(old))
    }

    @Test func testGeneratedAllDayCopyCanBePreparedAndSnapshottedWithoutSaving() async throws {
        let eventStore = EKEventStore()
        let calendar = EKCalendar(for: .event, eventStore: eventStore)
        let source = CalendarEventSnapshot(key: SourceKey(calendarID: "source", eventID: "all-day", occurrence: now),
                                           calendarID: "source", title: "All-day event", start: now, end: now.addingTimeInterval(86400),
                                           isAllDay: true, location: nil, availability: .busy, isCancelled: false,
                                           isDeclined: false, isWorkingLocation: false, ownershipToken: nil)
        let repository = EventRepository(store: eventStore)
        let prepared = try repository.preparedGeneratedEvent(source, kind: .unified, to: calendar, recordID: "owned")
        let snapshot = try repository.rollbackImage(of: prepared, recordID: "owned")
        #expect(snapshot.isAllDay)
        #expect(snapshot.alarms?.isEmpty == true)
        #expect(prepared.eventIdentifier == nil, "The test must not save any calendar event")
    }
}

@MainActor
private final class FakeRollbackRepository: RollbackEventRepository {
    var events: [String: (String, OwnedEventImage)] = [:]
    var conflicts: [String: String] = [:]
    var failBeforeWrite: Set<String> = []
    var failAfterWrite: Set<String> = []
    var writes: [String] = []

    func lookupForRollback(_ entry: RollbackEntry) -> OwnedEventLookup {
        if let reason = conflicts[entry.record.id] { return .conflict(reason) }
        if let (id, image) = events[entry.record.id] { return .found(eventID: id, image: image) }
        return .absent
    }

    func deleteForRollback(_ entry: RollbackEntry) throws {
        try beforeWrite(entry)
        events.removeValue(forKey: entry.record.id)
        writes.append("delete:\(entry.record.id)")
        try afterWrite(entry)
    }

    func restoreForRollback(_ image: OwnedEventImage, entry: RollbackEntry) throws -> String {
        try beforeWrite(entry)
        let id = "restored-\(entry.record.id)"
        events[entry.record.id] = (id, image)
        writes.append("restore:\(entry.record.id)")
        try afterWrite(entry)
        return id
    }

    private func beforeWrite(_ entry: RollbackEntry) throws {
        if failBeforeWrite.remove(entry.record.id) != nil { throw RollbackFailure.snapshotUnavailable }
    }

    private func afterWrite(_ entry: RollbackEntry) throws {
        if failAfterWrite.remove(entry.record.id) != nil { throw RollbackFailure.snapshotUnavailable }
    }
}
