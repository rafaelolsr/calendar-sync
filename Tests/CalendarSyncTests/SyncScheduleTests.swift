import Testing
import Foundation
import EventKit
@testable import CalendarSync

@Suite @MainActor struct SyncScheduleTests {
    private func fixture() throws -> (SyncStateStore, UserDefaults, URL, () -> Void) {
        let suite = "SyncScheduleTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("recovery.json")
        let store = SyncStateStore(defaults: defaults, recoveryURL: url)
        try store.checkpoint {
            $0.shareAvailabilityCalendarIDs = ["work", "personal"]
            $0.unifiedDestinations = ["work": "combined", "personal": "combined"]
            $0.unifiedOnlyCalendarIDs = ["birthdays"]
            $0.unifiedDestinations?["birthdays"] = "other-output"
            $0.validationConfirmed = true
            $0.automaticBlockingEnabled = true
            $0.blockTentative = true
            $0.futureMonths = 2
            $0.records = [ManagedEventRecord(id: "owner", source: SourceKey(calendarID: "work", eventID: "original", occurrence: Date(timeIntervalSince1970: 1_800_000_000)),
                                            kind: .blocker, destinationCalendarID: "personal", representedStart: Date(timeIntervalSince1970: 1_800_000_000),
                                            eventID: "created", fingerprint: "saved", updatedAt: Date(timeIntervalSince1970: 1_800_000_000))]
            $0.rollback = RollbackJournal(previousLastSync: nil)
        }
        return (store, defaults, url, {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        })
    }

    private func stateWithoutSchedule(_ state: CalendarSyncState) throws -> NSDictionary {
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(state)) as? [String: Any])
        json.removeValue(forKey: "schedule")
        // Codable sets may change iteration order when decoded after restart.
        for key in ["participatingCalendarIDs", "shareAvailabilityCalendarIDs", "unifiedOnlyCalendarIDs"] {
            if let ids = json[key] as? [String] { json[key] = ids.sorted() }
        }
        return json as NSDictionary
    }

    @Test func testEnableChangeDisableAndRestartPreserveWorkingConfiguration() throws {
        let (store, defaults, url, cleanup) = try fixture()
        defer { cleanup() }
        let before = try stateWithoutSchedule(store.state)
        let installer = FakeScheduleInstaller()
        let controller = ScheduleController(stateStore: store, installer: installer)
        var schedule = SyncSchedule()
        schedule.mode = .severalTimes
        try controller.save(schedule)
        #expect(try stateWithoutSchedule(store.state) == before)
        let reloaded = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(reloaded.state.schedule == schedule)
        #expect(try stateWithoutSchedule(reloaded.state) == before)
        schedule.mode = .daily
        schedule.dailyMinute = 8 * 60 + 30
        try controller.save(schedule)
        schedule.mode = .off
        try controller.save(schedule)
        #expect(try stateWithoutSchedule(store.state) == before)
        #expect(installer.configurations.map(\.mode) == [.severalTimes, .daily, .off])
    }

    @Test func testLegacyConfigurationHasSchedulingOff() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let decoded = try JSONDecoder().decode(CalendarSyncState.self, from: JSONEncoder().encode(store.state))
        #expect(decoded.schedule == nil)
        #expect(!(decoded.schedule ?? SyncSchedule()).isEnabled)
        #expect(decoded.automaticBlockingEnabled)
        #expect(decoded.records.count == 1)
    }

    @Test func testRegistrationFailureLeavesSettingsUnchanged() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let before = try JSONEncoder().encode(store.state)
        let installer = FakeScheduleInstaller()
        installer.fail = true
        var schedule = SyncSchedule()
        schedule.mode = .severalTimes
        #expect(throws: ScheduleFailure.self) {
            try ScheduleController(stateStore: store, installer: installer).save(schedule)
        }
        #expect(try stateWithoutSchedule(store.state) == stateWithoutSchedule(JSONDecoder().decode(CalendarSyncState.self, from: before)))
        #expect(store.state.schedule == nil)
    }

    @Test func testConcurrentRecoveryCannotChangeSchedule() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let lock = try store.acquireRecoveryLock()
        defer { lock.release() }
        let installer = FakeScheduleInstaller()
        var schedule = SyncSchedule()
        schedule.mode = .daily
        #expect(throws: RollbackFailure.self) {
            try ScheduleController(stateStore: store, installer: installer).save(schedule)
        }
        #expect(installer.configurations.isEmpty)
        #expect(store.state.schedule == nil)
    }

    @Test func testFailedRecoveryCheckpointRestoresPreviousSchedule() throws {
        let (store, _, url, cleanup) = try fixture()
        defer { cleanup() }
        let before = try stateWithoutSchedule(store.state)
        let installer = FakeScheduleInstaller()
        installer.afterConfigure = {
            try? FileManager.default.removeItem(at: url.deletingLastPathComponent())
            try? Data("Unavailable recovery directory".utf8).write(to: url.deletingLastPathComponent())
        }
        var schedule = SyncSchedule()
        schedule.mode = .daily
        #expect(throws: (any Error).self) {
            try ScheduleController(stateStore: store, installer: installer).save(schedule)
        }
        #expect(installer.configurations.map(\.mode) == [.daily, .off])
        #expect(store.state.schedule == nil)
        #expect(try stateWithoutSchedule(store.state) == before)
    }

    @Test func testLaunchAgentUsesFixedLocalTimesAndBackgroundAppWithoutImmediateSync() throws {
        var schedule = SyncSchedule()
        schedule.mode = .severalTimes
        schedule.multipleMinutes = [17 * 60, 9 * 60, 13 * 60, 9 * 60]
        let data = try schedule.launchAgentPropertyList(appURL: URL(fileURLWithPath: "/Applications/CalendarSync.app"),
                                                      errorLogURL: URL(fileURLWithPath: "/tmp/scheduler.log"))
        let plist = try #require(PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any])
        #expect(plist["ProgramArguments"] as? [String] == ["/usr/bin/open", "-g", "-n", "/Applications/CalendarSync.app", "--args", "--scheduled-sync"])
        #expect(plist["StartCalendarInterval"] as? [[String: Int]] == [["Hour": 9, "Minute": 0], ["Hour": 13, "Minute": 0], ["Hour": 17, "Minute": 0]])
        #expect(plist["RunAtLoad"] == nil)
        #expect(plist["StartInterval"] == nil)
        #expect(plist["LimitLoadToSessionType"] as? String == "Aqua")
    }

    @Test func testNextRunUsesLocalTimeAndRollsOverToTomorrow() throws {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = try #require(TimeZone(identifier: "America/Sao_Paulo"))
        let now = try #require(calendar.date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 13, minute: 1)))
        var schedule = SyncSchedule()
        #expect(schedule.nextRun(after: now, calendar: calendar) == nil)
        schedule.mode = .severalTimes
        let next = try #require(schedule.nextRun(after: now, calendar: calendar))
        #expect(calendar.component(.hour, from: next) == 17)
        #expect(calendar.component(.day, from: next) == 1)
        schedule.mode = .daily
        let tomorrow = try #require(schedule.nextRun(after: now, calendar: calendar))
        #expect(calendar.component(.hour, from: tomorrow) == 9)
        #expect(calendar.component(.day, from: tomorrow) == 2)
    }

    @Test func testInvalidTimesNeverRegisterOrChangeSettings() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let installer = FakeScheduleInstaller()
        for times in [[], [-1], [1440], Array(0...8)] {
            var schedule = SyncSchedule()
            schedule.mode = .severalTimes
            schedule.multipleMinutes = times
            #expect(throws: ScheduleFailure.self) {
                try ScheduleController(stateStore: store, installer: installer).save(schedule)
            }
        }
        #expect(installer.configurations.isEmpty)
        #expect(store.state.schedule == nil)
    }

    @Test func testScheduledPathRespectsOffBlockingAndPendingRecoveryEvenDuringVerification() throws {
        let (store, _, _, cleanup) = try fixture()
        defer { cleanup() }
        let engine = SyncEngine(eventStore: EKEventStore(), stateStore: store)
        let off = engine.run(dryRun: false, scheduled: true)
        #expect(!off.applied)
        #expect(off.messages == ["Scheduling is off."])
        try store.checkpoint {
            var schedule = SyncSchedule()
            schedule.mode = .daily
            $0.schedule = schedule
            $0.automaticBlockingEnabled = false
        }
        let paused = engine.run(dryRun: true, scheduled: true)
        #expect(!paused.applied)
        #expect(paused.plan.mutationCount == 0)
        #expect(paused.messages.first?.contains("explicitly enable Automatic Blocking") == true)
        try store.checkpoint {
            $0.automaticBlockingEnabled = true
            $0.rollback?.rollbackStarted = true
            let record = $0.records[0]
            $0.rollback?.entries = [RollbackEntry(record: record, previousRecord: nil, before: nil,
                after: OwnedEventImage(title: "Busy", start: record.representedStart, end: record.representedStart.addingTimeInterval(3600),
                                       isAllDay: false, location: nil, notes: nil, url: "calendarsync://owner", availability: 2, timeZoneID: nil))]
        }
        let pending = engine.run(dryRun: true, scheduled: true)
        #expect(!pending.applied)
        #expect(pending.messages == ["Finish the pending rollback before starting another sync."])
        #expect(store.state.records.count == 1)
        #expect(store.state.rollback?.entries.count == 1)
    }
}

private final class FakeScheduleInstaller: ScheduleInstalling {
    var configurations: [SyncSchedule] = []
    var fail = false
    var afterConfigure: (() -> Void)?
    func configure(_ schedule: SyncSchedule) throws {
        if fail { throw ScheduleFailure.registration("Test registration failure") }
        configurations.append(schedule)
        afterConfigure?()
    }
}
