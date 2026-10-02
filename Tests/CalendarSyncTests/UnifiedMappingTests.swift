import Testing
import Foundation
import EventKit
@testable import CalendarSync

@Suite struct UnifiedMappingTests {
    private func configuredState() -> CalendarSyncState {
        var state = CalendarSyncState()
        state.shareAvailabilityCalendarIDs = ["work"]
        state.unifiedOnlyCalendarIDs = ["personal"]
        state.unifiedCalendarID = "legacy-output"
        return state
    }

    @Test func testPerSourceConfigurationRequiresCompleteNonSourceDestinations() {
        var state = configuredState()
        #expect(state.hasUnifiedConfiguration)
        for invalid in [[:], ["work": "work-output"],
                        ["work": "personal", "personal": "personal-output"]] {
            state.unifiedDestinations = invalid
            #expect(!state.hasUnifiedConfiguration)
        }
        state.unifiedDestinations = ["work": "work-output", "personal": "personal-output"]
        #expect(state.hasUnifiedConfiguration)
        #expect(state.sourceCalendarIDs == ["work", "personal"])
        #expect(state.busySharingCalendarIDs == ["work"])
        #expect(state.unifiedOutputCalendarIDs == ["work-output", "personal-output"])
        #expect(state.unifiedDestination(for: "personal") == "personal-output")
        #expect(state.role(for: "personal-output", unifiedID: state.unifiedCalendarID) == .unifiedOutput)
        state.unifiedDestinations = ["work": "shared-output", "personal": "shared-output"]
        #expect(state.hasUnifiedConfiguration)
        #expect(state.unifiedOutputCalendarIDs == ["shared-output"])
        #expect(state.unifiedDestination(for: "work") == "shared-output")
        #expect(state.unifiedDestination(for: "personal") == "shared-output")
    }

    @Test func testLegacySettingsDecodeInSingleModeAndEmptyMapSurvivesEncoding() throws {
        let legacy = configuredState()
        var json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(legacy)) as? [String: Any])
        json.removeValue(forKey: "unifiedDestinations")
        json.removeValue(forKey: "savedUnifiedDestinations")
        let decoded = try JSONDecoder().decode(CalendarSyncState.self, from: JSONSerialization.data(withJSONObject: json))
        #expect(decoded.unifiedDestinations == nil)
        #expect(decoded.unifiedDestination(for: "work") == "legacy-output")
        #expect(decoded.hasUnifiedConfiguration)
        var separate = legacy
        separate.unifiedDestinations = [:]
        let roundTrip = try JSONDecoder().decode(CalendarSyncState.self, from: JSONEncoder().encode(separate))
        #expect(roundTrip.unifiedDestinations?.isEmpty == true)
        #expect(roundTrip.unifiedDestination(for: "work") == nil)
        #expect(!roundTrip.hasUnifiedConfiguration)
    }

    @Test @MainActor func testMappingsPersistAcrossRestartAndIncompleteConfigCannotApply() throws {
        let suite = "UnifiedMappingTests.\(UUID())"
        let defaults = try #require(UserDefaults(suiteName: suite))
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(suite)
        let url = directory.appendingPathComponent("recovery.json")
        defer {
            defaults.removePersistentDomain(forName: suite)
            try? FileManager.default.removeItem(at: directory)
        }
        let store = SyncStateStore(defaults: defaults, recoveryURL: url)
        try store.checkpoint {
            $0 = configuredState()
            $0.unifiedDestinations = ["work": "work-output", "personal": "personal-output"]
            $0.savedUnifiedDestinations = $0.unifiedDestinations
        }
        let reloaded = SyncStateStore(defaults: defaults, recoveryURL: url)
        #expect(reloaded.state.unifiedDestination(for: "work") == "work-output")
        #expect(reloaded.state.savedUnifiedDestinations == reloaded.state.unifiedDestinations)
        try reloaded.checkpoint {
            $0.unifiedDestinations = ["work": "work-output"]
            $0.validationConfirmed = true
            $0.automaticBlockingEnabled = true
        }
        let result = SyncEngine(eventStore: EKEventStore(), stateStore: reloaded).run(dryRun: false)
        #expect(!result.applied)
        #expect(result.errorCount == 1)
        #expect(result.plan.mutationCount == 0)
        #expect(reloaded.state.records.isEmpty)
        #expect(reloaded.state.rollback == nil)
    }
}
