import Testing
import Foundation
@testable import CalendarSync

@Suite struct ReconciliationPlannerTests {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func event(
        _ id: String,
        calendar: String = "source-a",
        startOffset: TimeInterval = 3_600,
        availability: EventAvailability = .busy,
        ownership: String? = nil,
        declined: Bool = false
    ) -> CalendarEventSnapshot {
        let start = now.addingTimeInterval(startOffset)
        return CalendarEventSnapshot(
            key: SourceKey(calendarID: calendar, eventID: id, occurrence: start),
            calendarID: calendar,
            title: "Private meeting",
            start: start,
            end: start.addingTimeInterval(3_600),
            isAllDay: false,
            location: "Room 1",
            availability: availability,
            isCancelled: false,
            isDeclined: declined,
            isWorkingLocation: false,
            ownershipToken: ownership
        )
    }

    @Test func testCreatesUnifiedAndAnonymizedBlockersForOtherCalendars() {
        let source = event("one")
        let plan = ReconciliationPlanner().plan(
            sources: [source],
            sharingCalendarIDs: ["source-a", "source-b", "source-c"],
            writableCalendarIDs: ["source-a", "source-b", "source-c"],
            unifiedCalendarID: "unified",
            existing: [],
            now: now
        )
        #expect(plan.operations.count == 3)
        #expect(plan.operations.contains { if case .create(_, .unified, "unified") = $0 { true } else { false } })
        #expect(plan.operations.contains { if case .create(_, .blocker, "source-b") = $0 { true } else { false } })
        #expect(plan.operations.contains { if case .create(_, .blocker, "source-c") = $0 { true } else { false } })
        #expect(plan.sourceSummaries[source.key]?.title == source.title)
        #expect(plan.sourceSummaries[source.key]?.start == source.start)
        #expect(plan.sourceSummaries[source.key]?.blockerDetail == "Busy block changes are listed below.")
    }

    @Test func testGeneratedAndUnifiedEventsNeverBecomeSources() {
        let plan = ReconciliationPlanner().plan(
            sources: [event("generated", ownership: "owned"), event("unified", calendar: "unified")],
            sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"],
            unifiedCalendarID: "unified", existing: [], now: now
        )
        #expect(plan.sourceCount == 0)
        #expect(plan.mutationCount == 0)
    }

    @Test func testPerSourceOutputsRouteCopiesAndNeverReceiveBusyBlocks() {
        let a = event("a")
        let b = event("b", calendar: "source-b")
        let outputs = ["source-a": "output-a", "source-b": "output-b"]
        let plan = ReconciliationPlanner().plan(
            sources: [a, b, event("output", calendar: "output-a"), event("output", calendar: "output-b")],
            sharingCalendarIDs: ["source-a", "source-b", "output-a", "output-b"],
            writableCalendarIDs: ["source-a", "source-b", "output-a", "output-b"],
            unifiedCalendarID: "legacy", unifiedDestinations: outputs, existing: [], now: now
        )
        #expect(plan.sourceCount == 2)
        #expect(Set(plan.operations) == Set([
            .create(source: a.key, kind: .unified, calendarID: "output-a"),
            .create(source: b.key, kind: .unified, calendarID: "output-b"),
            .create(source: a.key, kind: .blocker, calendarID: "source-b"),
            .create(source: b.key, kind: .blocker, calendarID: "source-a")
        ]))
    }

    @Test func testMissingPerSourceOutputDoesNotFallBackToLegacyDestination() {
        let source = event("a")
        let plan = ReconciliationPlanner().plan(
            sources: [source], sharingCalendarIDs: ["source-a", "source-b"],
            writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "legacy",
            unifiedDestinations: [:], existing: [], now: now
        )
        #expect(plan.mutationCount == 0)
        #expect(plan.operations.contains(.error(source: source.key, calendarID: nil, reason: "Choose an output calendar for this source.")))
    }

    @Test func testSharedOutputKeepsCopiesIndependentAcrossRetryAndRemapping() {
        let a = event("a")
        let b = event("b", calendar: "source-b")
        let planner = ReconciliationPlanner()
        let mappings = ["source-a": "shared-output", "source-b": "shared-output"]
        let first = planner.plan(sources: [a, b], sharingCalendarIDs: [], writableCalendarIDs: [],
                                 unifiedCalendarID: nil, unifiedDestinations: mappings, existing: [], now: now)
        #expect(Set(first.operations) == Set([
            .create(source: a.key, kind: .unified, calendarID: "shared-output"),
            .create(source: b.key, kind: .unified, calendarID: "shared-output")
        ]))
        let records = [a, b].map { source in
            ManagedEventRecord(id: source.key.eventID, source: source.key, kind: .unified,
                               destinationCalendarID: "shared-output", representedStart: source.start,
                               eventID: "saved-\(source.key.eventID)",
                               fingerprint: planner.fingerprint(for: source, kind: .unified), updatedAt: now)
        }
        let visible = Set(records.map(\.id))
        let retry = planner.plan(sources: [a, b], sharingCalendarIDs: [], writableCalendarIDs: [],
                                 unifiedCalendarID: nil, unifiedDestinations: mappings,
                                 existing: records, visibleOwnershipTokens: visible, now: now)
        #expect(retry.mutationCount == 0)
        let remapped = planner.plan(sources: [a, b], sharingCalendarIDs: [], writableCalendarIDs: [],
                                    unifiedCalendarID: nil,
                                    unifiedDestinations: ["source-a": "new-output", "source-b": "shared-output"],
                                    existing: records, visibleOwnershipTokens: visible, now: now)
        #expect(Set(remapped.operations) == Set([
            .create(source: a.key, kind: .unified, calendarID: "new-output"),
            .delete(recordID: "a", source: a.key, kind: .unified, calendarID: "shared-output")
        ]))
    }

    @Test func testMappedOutputIsIdempotentAndRemappingCleansOnlyVerifiedOldCopy() {
        let source = event("a")
        let planner = ReconciliationPlanner()
        let record = ManagedEventRecord(id: "owned", source: source.key, kind: .unified,
                                        destinationCalendarID: "output-a", representedStart: source.start,
                                        eventID: "saved-copy", fingerprint: planner.fingerprint(for: source, kind: .unified), updatedAt: now)
        let same = planner.plan(sources: [source], sharingCalendarIDs: [], writableCalendarIDs: [],
                                unifiedCalendarID: nil, unifiedDestinations: ["source-a": "output-a"],
                                existing: [record], visibleOwnershipTokens: [record.id], now: now)
        #expect(same.mutationCount == 0)
        for verified in [false, true] {
            let moved = planner.plan(sources: [source], sharingCalendarIDs: [], writableCalendarIDs: [],
                                     unifiedCalendarID: nil, unifiedDestinations: ["source-a": "output-new"],
                                     existing: [record], visibleOwnershipTokens: verified ? [record.id] : [], now: now)
            #expect(moved.operations.contains(.create(source: source.key, kind: .unified, calendarID: "output-new")))
            #expect(moved.operations.contains(.delete(recordID: record.id, source: source.key, kind: .unified, calendarID: "output-a")) == verified)
            #expect(moved.operations.contains { if case .error = $0 { true } else { false } } == !verified)
        }
    }

    @Test func testExistingMappingsMakeSecondPlanIdempotent() {
        let source = event("one")
        let planner = ReconciliationPlanner()
        let first = planner.plan(sources: [source], sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified", existing: [], now: now)
        let records = first.operations.compactMap { operation -> ManagedEventRecord? in
            guard case let .create(sourceKey, kind, calendarID) = operation else { return nil }
            return ManagedEventRecord(id: UUID().uuidString, source: sourceKey, kind: kind, destinationCalendarID: calendarID, representedStart: source.start, eventID: UUID().uuidString, fingerprint: planner.fingerprint(for: source, kind: kind), updatedAt: now)
        }
        let second = planner.plan(sources: [source], sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified", existing: records, visibleOwnershipTokens: Set(records.map(\.id)), now: now)
        #expect(second.mutationCount == 0)
        #expect(second.sourceSummaries[source.key]?.blockerDetail == "Busy blocks are already up to date in the other Block + view calendars.")
    }

    @Test func testPastEventsDoNotCreateNewBlockers() {
        let source = event("past", startOffset: -7_200)
        let plan = ReconciliationPlanner().plan(sources: [source], sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified", existing: [], now: now)
        #expect(plan.operations.contains { if case .create(_, .unified, _) = $0 { true } else { false } })
        #expect(!(plan.operations.contains { if case .create(_, .blocker, _) = $0 { true } else { false } }))
        #expect(plan.sourceSummaries[source.key]?.blockerDetail == "This event is in the past; no new busy blocks are created for past events.")
    }

    @Test func testOverlappingRealEventsRemainSeparateUnifiedProjections() {
        let first = event("meeting-a", startOffset: 3_600)
        let second = event("meeting-b", calendar: "source-b", startOffset: 5_400)
        let plan = ReconciliationPlanner().plan(
            sources: [first, second],
            sharingCalendarIDs: ["source-a", "source-b"],
            writableCalendarIDs: ["source-a", "source-b"],
            unifiedCalendarID: "unified",
            existing: [], now: now
        )
        #expect(plan.operations.filter { if case .create(_, .unified, _) = $0 { true } else { false } }.count == 2)
    }

    @Test func testFreeAndTentativeEventsAppearOnlyInUnifiedAndDeclinedIsSkipped() {
        let free = event("free", availability: .free)
        let plan = ReconciliationPlanner().plan(
            sources: [free, event("tentative", availability: .tentative), event("declined", declined: true)],
            sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified", existing: [], now: now
        )
        #expect(plan.operations.filter { if case .skip = $0 { true } else { false } }.count == 1)
        #expect(plan.operations.filter { if case .create(_, .unified, _) = $0 { true } else { false } }.count == 2)
        #expect(!(plan.operations.contains { if case .create(_, .blocker, _) = $0 { true } else { false } }))
        #expect(plan.sourceSummaries[free.key]?.blockerDetail == "This event is marked Free, so it does not block time.")
    }

    @Test func testUnifiedOnlyCalendarCreatesProjectionWithoutBusyBlocks() {
        let birthday = event("birthday", calendar: "birthdays")
        let plan = ReconciliationPlanner().plan(
            sources: [birthday],
            sharingCalendarIDs: ["work-a", "work-b"],
            writableCalendarIDs: ["work-a", "work-b"],
            unifiedCalendarID: "unified",
            existing: [],
            now: now
        )

        #expect(plan.operations.contains { if case .create(_, .unified, "unified") = $0 { true } else { false } })
        #expect(!(plan.operations.contains { if case .create(_, .blocker, _) = $0 { true } else { false } }))
        #expect(plan.sourceSummaries[birthday.key]?.blockerDetail == "This calendar is View only; it appears in Unified without blocking other calendars.")
    }

    @Test func testUnownedStaleEventsAreNeverDeleted() {
        let source = event("removed")
        let record = ManagedEventRecord(id: "owner-token", source: source.key, kind: .blocker, destinationCalendarID: "source-b", representedStart: source.start, eventID: "some-event-id", fingerprint: "old", updatedAt: now)
        let plan = ReconciliationPlanner().plan(sources: [], sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified", existing: [record], visibleOwnershipTokens: [], now: now, windowStart: now, windowEnd: now.addingTimeInterval(10_000_000))
        #expect(plan.operations.contains { if case .error = $0 { true } else { false } })
        #expect(!(plan.operations.contains { if case .delete = $0 { true } else { false } }))
    }

    @Test func testVerifiedStaleBlockerCanBeDeletedInsideWindow() {
        let source = event("removed")
        let record = ManagedEventRecord(id: "owner-token", source: source.key, kind: .blocker, destinationCalendarID: "source-b", representedStart: source.start, eventID: "owned-event", fingerprint: "old", updatedAt: now)
        let plan = ReconciliationPlanner().plan(
            sources: [], sharingCalendarIDs: ["source-a", "source-b"], writableCalendarIDs: ["source-a", "source-b"],
            unifiedCalendarID: "unified", existing: [record], visibleOwnershipTokens: [record.id], now: now,
            windowStart: now, windowEnd: now.addingTimeInterval(10_000_000)
        )
        #expect(plan.operations.contains { if case let .delete(recordID, _, .blocker, "source-b") = $0 { recordID == record.id } else { false } })
    }

    @Test(arguments: Array(1...12) + [18, 24, 36])
    func testUpcomingMonthLimitAppliesToCopiesAndRecurringOccurrences(months: Int) {
        var state = CalendarSyncState()
        state.pastDays = 0
        state.futureMonths = months
        let interval = state.syncWindow(now: now).duration
        let first = event("recurring", startOffset: 0)
        let last = event("recurring", startOffset: interval - 1)
        let pastOverlap = event("past-overlap", startOffset: -1)
        let boundary = event("recurring", startOffset: interval)
        let later = event("recurring", startOffset: interval + 86_400)
        let plan = ReconciliationPlanner().plan(
            sources: [first, last, pastOverlap, boundary, later],
            sharingCalendarIDs: ["source-a", "source-b"],
            writableCalendarIDs: ["source-a", "source-b"],
            unifiedCalendarID: "unified", existing: [], now: now,
            windowStart: now, windowEnd: now.addingTimeInterval(interval)
        )
        #expect(plan.sourceCount == 2)
        #expect(plan.mutationCount == 4)
        for source in [first, last] {
            #expect(plan.operations.contains(.create(source: source.key, kind: .unified, calendarID: "unified")))
            #expect(plan.operations.contains(.create(source: source.key, kind: .blocker, calendarID: "source-b")))
        }
        #expect(plan.sourceSummaries[boundary.key] == nil)
        #expect(plan.sourceSummaries[pastOverlap.key] == nil)
    }

    @Test func testSmallerWindowRetainsExistingEventsAtAndBeyondLimit() {
        let interval: TimeInterval = 15 * 86_400
        let records = [event("boundary", startOffset: interval), event("later", startOffset: interval + 86_400)]
            .flatMap { source in
                [GeneratedKind.unified, .blocker].map { kind in
                    ManagedEventRecord(id: "\(source.key.eventID)-\(kind.rawValue)", source: source.key,
                                       kind: kind, destinationCalendarID: kind == .unified ? "unified" : "source-b",
                                       representedStart: source.start, eventID: "saved-\(source.key.eventID)-\(kind.rawValue)",
                                       fingerprint: "old", updatedAt: now)
                }
            }
        let plan = ReconciliationPlanner().plan(
            sources: [], sharingCalendarIDs: ["source-a", "source-b"],
            writableCalendarIDs: ["source-a", "source-b"], unifiedCalendarID: "unified",
            existing: records, visibleOwnershipTokens: Set(records.map(\.id)), now: now,
            windowStart: now, windowEnd: now.addingTimeInterval(interval)
        )
        #expect(plan.operations.isEmpty)
    }
}
