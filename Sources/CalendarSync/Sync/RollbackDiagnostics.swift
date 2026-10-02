import Foundation
import EventKit
import CryptoKit
import AppKit

/// A read-only support command. Reports counts, never event titles or identifiers.
@MainActor
enum RollbackDiagnostics {
    private struct RecoveryDocument: Decodable { let state: CalendarSyncState }

    /// Explicit full reset requested by the user. Capture current owned images,
    /// then use the same durable, revalidating deletion path as rollback.
    static func removeAllGeneratedEvents(to url: URL) async throws {
        let stateStore = SyncStateStore()
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try await store.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarSyncError.fullAccessRequired }
        let repository = EventRepository(store: store)
        let result = try GeneratedResetController(stateStore: stateStore, repository: repository).run()
        let report: [String: Any] = ["completed": result.completedCount, "remaining": result.remainingCount,
                                    "messages": result.messages, "currentRecords": stateStore.state.records.count,
                                    "automaticBlockingEnabled": stateStore.state.automaticBlockingEnabled]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func cleanVerifiedLeftovers(evidenceURL: URL, to url: URL) async throws {
        let stateStore = SyncStateStore()
        guard stateStore.recoveryError == nil else { throw RollbackFailure.snapshotUnavailable }
        let history = try JSONDecoder().decode(RecoveryDocument.self, from: Data(contentsOf: evidenceURL)).state
        var historical = history.creationHistory ?? []
        historical.append(contentsOf: history.rollback?.entries ?? [])
        historical.append(contentsOf: stateStore.state.creationHistory ?? [])
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try await store.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarSyncError.fullAccessRequired }
        let repository = EventRepository(store: store)
        let window = stateStore.state.syncWindow(now: Date())
        let dates = historical.map { $0.record.representedStart }
        let start = min(window.start, dates.min()?.addingTimeInterval(-3 * 86_400) ?? window.start)
        let end = max(window.end, dates.max()?.addingTimeInterval(3 * 86_400) ?? window.end)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: store.calendars(for: .event)))
            .filter { $0.url?.scheme == "calendarsync" }
        let occurrences = Dictionary(grouping: events, by: { $0.url?.host ?? "" })
        var candidates: [RollbackEntry] = []
        for event in events {
            guard let token = event.url?.host, occurrences[token]?.count == 1,
                  !stateStore.state.records.contains(where: { $0.id == token }),
                  let entry = historical.last(where: { $0.before == nil && $0.after != nil && $0.record.id == token
                      && $0.record.destinationCalendarID == event.calendar.calendarIdentifier }) else { continue }
            var record = entry.record
            record.eventID = event.eventIdentifier
            let candidate = RollbackEntry(record: record, previousRecord: nil, before: nil, after: entry.after)
            if LeftoverCleanupController.action(for: candidate, currentRecords: stateStore.state.records,
                                                evidence: historical,
                                                lookup: repository.lookupForRollback(candidate)) == .remove {
                candidates.append(candidate)
            }
        }
        let rollbackID = stateStore.state.rollback?.id
        let result = LeftoverCleanupController(stateStore: stateStore, repository: repository).apply(candidates: candidates, evidence: historical)
        let report: [String: Any] = ["completed": result.completedCount, "remaining": result.remainingCount,
                                    "messages": result.messages, "currentRecords": stateStore.state.records.count,
                                    "latestRollbackPreserved": stateStore.state.rollback?.id == rollbackID,
                                    "automaticBlockingEnabled": stateStore.state.automaticBlockingEnabled]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Audit historical creations without changing calendars or recovery state.
    static func auditLeftovers(evidenceURL: URL, to url: URL) async throws {
        let stateStore = SyncStateStore()
        guard stateStore.recoveryError == nil else { throw RollbackFailure.snapshotUnavailable }
        let state = stateStore.state
        let history = try JSONDecoder().decode(RecoveryDocument.self, from: Data(contentsOf: evidenceURL)).state
        var historical = history.creationHistory ?? []
        historical.append(contentsOf: history.rollback?.entries ?? [])
        historical.append(contentsOf: state.creationHistory ?? [])
        let historicalCreations = historical.filter { $0.before == nil && $0.after != nil }
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            _ = try await store.requestFullAccessToEvents()
        }
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else { throw CalendarSyncError.fullAccessRequired }
        let repository = EventRepository(store: store)
        let now = Date()
        let window = state.syncWindow(now: now)
        let historyDates = historicalCreations.map { $0.record.representedStart }
        let start = min(now.addingTimeInterval(-30 * 86_400), historyDates.min()?.addingTimeInterval(-3 * 86_400) ?? window.start)
        let end = max(window.end, historyDates.max()?.addingTimeInterval(3 * 86_400) ?? now.addingTimeInterval(90 * 86_400))
        let calendars = store.calendars(for: .event)
        let events = store.events(matching: store.predicateForEvents(withStart: start, end: end, calendars: calendars))
            .filter { $0.url?.scheme == "calendarsync" }
        let occurrences = Dictionary(grouping: events, by: { $0.url?.host ?? "" })
        var counts: [String: Int] = [:]
        var calendarsByCategory: [String: [String: Int]] = [:]
        for event in events {
            let token = event.url?.host ?? ""
            let category: String
            let current = state.records.filter { $0.id == token }
            if current.contains(where: { $0.destinationCalendarID == event.calendar.calendarIdentifier }) {
                category = occurrences[token, default: []].count > 1 ? "current mapping: duplicate marker" : "current mapping: tracked"
            } else if !current.isEmpty {
                category = "current mapping: different destination"
            } else if let entry = historicalCreations.first(where: {
                $0.record.id == token && $0.record.destinationCalendarID == event.calendar.calendarIdentifier
            }) {
                if occurrences[token, default: []].count > 1 { category = "historical leftover: duplicate marker" }
                else {
                    var candidate = entry
                    candidate.record.eventID = event.eventIdentifier
                    switch repository.lookupForRollback(candidate) {
                    case let .found(_, image):
                        category = image.matches(entry.after!) ? "historical leftover: verified unchanged creation" : "historical leftover: content changed"
                    case .absent: category = "historical leftover: lookup absent"
                    case let .conflict(reason): category = "historical leftover: blocked: \(reason)"
                    }
                }
            } else {
                category = historicalCreations.contains(where: { $0.record.id == token })
                    ? "historical marker: different destination" : "unknown marker: no historical evidence"
            }
            counts[category, default: 0] += 1
            let name = "\(event.calendar.source.title) / \(event.calendar.title)"
            calendarsByCategory[category, default: [:]][name, default: 0] += 1
        }
        let report: [String: Any] = ["generatedEventsScanned": events.count, "currentRecords": state.records.count,
                                    "historicalCreations": historicalCreations.count, "counts": counts,
                                    "calendarsByCategory": calendarsByCategory,
                                    "scanStart": ISO8601DateFormatter().string(from: start), "scanEnd": ISO8601DateFormatter().string(from: end)]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    static func write(to url: URL) async throws {
        let state = SyncStateStore().state
        let entries = state.rollback?.entries ?? []
        let store = EKEventStore()
        if EKEventStore.authorizationStatus(for: .event) == .notDetermined {
            // This explicitly invoked support command may need to renew access
            // after a local ad-hoc signed update. Ask from a launched foreground
            // app, rather than during MenuBarExtra scene initialization.
            try? await Task.sleep(for: .seconds(1))
            NSApplication.shared.setActivationPolicy(.regular)
            NSApplication.shared.activate(ignoringOtherApps: true)
            _ = try await store.requestFullAccessToEvents()
        }
        let authorized = EKEventStore.authorizationStatus(for: .event) == .fullAccess
        var counts: [String: Int] = [:]
        var originalSourceDigest = ""
        var originalSourceCount = 0
        var remainingGeneratedEventsInWindow = 0
        var routing: [String: Any] = [:]
        func count(_ key: String) { counts[key, default: 0] += 1 }
        if authorized {
            for entry in entries {
                let kind = entry.record.kind.rawValue
                guard let event = EventRepository(store: store).ownedEvent(record: entry.record) else {
                    count("\(kind): owner not found")
                    continue
                }
                count("\(kind): owned event found")
                if !(event.attendees?.isEmpty ?? true) { count("\(kind): attendees") }
                if !(event.recurrenceRules?.isEmpty ?? true) { count("\(kind): recurrence") }
                if !(event.alarms?.isEmpty ?? true) { count("\(kind): alarms") }
                if event.structuredLocation?.geoLocation != nil { count("\(kind): geographic location") }
                guard let expected = entry.after else { continue }
                if event.title != expected.title { count("\(kind): title differs") }
                if event.startDate != expected.start { count("\(kind): start differs") }
                if event.endDate != expected.end { count("\(kind): end differs") }
                if event.isAllDay != expected.isAllDay { count("\(kind): all-day differs") }
                if event.location != expected.location { count("\(kind): location differs") }
                if event.notes != expected.notes { count("\(kind): notes differs") }
                if event.url?.absoluteString != expected.url { count("\(kind): URL differs") }
                if event.availability.rawValue != expected.availability {
                    count("\(kind): availability \(expected.availability) -> \(event.availability.rawValue)")
                }
                if event.timeZone?.identifier != expected.timeZoneID {
                    count("\(kind): timezone \(expected.timeZoneID ?? "floating") -> \(event.timeZone?.identifier ?? "floating")")
                }
                switch EventRepository(store: store).lookupForRollback(entry) {
                case let .conflict(reason): count("\(kind): blocked: \(reason)")
                case .absent: count("\(kind): absent on lookup")
                case let .found(_, image):
                    switch RollbackController.action(for: entry, lookup: .found(eventID: "redacted", image: image)) {
                    case .remove: count("\(kind): can remove")
                    case .restore: count("\(kind): can restore")
                    case .alreadyRestored: count("\(kind): already restored")
                    case let .blocked(reason): count("\(kind): blocked: \(reason)")
                    }
                }
            }
            do {
                let window = state.syncWindow(now: Date())
                let start = window.start
                let end = window.end
                let repository = EventRepository(store: store)
                remainingGeneratedEventsInWindow = repository.snapshots(
                    calendarIDs: state.sourceCalendarIDs.union(state.unifiedOutputCalendarIDs),
                    from: start, to: end, managedRecords: state.records
                ).filter { $0.ownershipToken != nil }.count
                let sources = repository.snapshots(calendarIDs: state.sourceCalendarIDs,
                                                   from: start, to: end, managedRecords: state.records)
                let originals = sources.filter { $0.ownershipToken == nil }
                let calendars = store.calendars(for: .event)
                let names = Dictionary(uniqueKeysWithValues: calendars.map {
                    ($0.calendarIdentifier, "\($0.source.title) / \($0.title)")
                })
                let writable = Set(calendars.filter(\.allowsContentModifications).map(\.calendarIdentifier))
                let expected = ReconciliationPlanner(blockTentative: state.blockTentative).plan(
                    sources: originals, sharingCalendarIDs: state.busySharingCalendarIDs,
                    writableCalendarIDs: writable, unifiedCalendarID: state.unifiedCalendarID,
                    unifiedDestinations: state.unifiedDestinations, existing: [], now: Date(),
                    windowStart: start, windowEnd: end
                )
                let expectedBlocks = Set(expected.operations.filter {
                    if case .create(_, .blocker, _) = $0 { true } else { false }
                })
                var liveBlocks: Set<ReconciliationOperation> = []
                var availabilityByDestination: [String: [String: Int]] = [:]
                for record in state.records where record.kind == .blocker {
                    guard let event = repository.ownedEvent(record: record) else { continue }
                    liveBlocks.insert(.create(source: record.source, kind: .blocker, calendarID: record.destinationCalendarID))
                    let name = names[record.destinationCalendarID] ?? "Unavailable calendar"
                    let availability: String
                    switch event.availability {
                    case .busy: availability = "busy"
                    case .free: availability = "free"
                    case .tentative: availability = "tentative"
                    case .unavailable: availability = "unavailable"
                    case .notSupported: availability = "notSupported"
                    @unknown default: availability = "unknown"
                    }
                    availabilityByDestination[name, default: [:]][availability, default: 0] += 1
                }
                let sourceChecks: [[String: Any]] = state.sourceCalendarIDs.sorted().map { id in
                    let events = originals.filter { $0.calendarID == id && $0.start >= start && $0.start < end }
                    let availabilityCounts = Dictionary(grouping: events, by: { $0.availability.rawValue }).mapValues(\.count)
                    let details = events.compactMap { expected.sourceSummaries[$0.key]?.blockerDetail }
                    return ["calendar": names[id] ?? "Unavailable calendar",
                            "role": state.busySharingCalendarIDs.contains(id) ? "Block + view" : "View only",
                            "writable": writable.contains(id), "sourceEvents": events.count,
                            "availabilityCounts": availabilityCounts,
                            "blockingReasons": Dictionary(grouping: details, by: { $0 }).mapValues(\.count)]
                }
                routing = ["expectedBusyBlocks": expectedBlocks.count, "liveMappedBusyBlocks": liveBlocks.count,
                           "missingExpectedBusyBlocks": expectedBlocks.subtracting(liveBlocks).count,
                           "unexpectedMappedBusyBlocks": liveBlocks.subtracting(expectedBlocks).count,
                           "liveBusyAvailabilityByDestination": availabilityByDestination, "sources": sourceChecks]
                originalSourceCount = originals.count
                let payload = originals.map { source in
                    [source.calendarID, source.title, String(source.start.timeIntervalSince1970), String(source.end.timeIntervalSince1970),
                     String(source.isAllDay), source.location ?? "", source.availability.rawValue].joined(separator: "\u{1f}")
                }.sorted().joined(separator: "\u{1e}")
                originalSourceDigest = SHA256.hash(data: Data(payload.utf8)).map { String(format: "%02x", $0) }.joined()
                for source in sources where source.isAllDay && source.ownershipToken == nil {
                    count("source: all-day event")
                    guard let outputID = state.unifiedDestination(for: source.calendarID),
                          let calendar = store.calendar(withIdentifier: outputID) else {
                        count("source: all-day output unconfigured")
                        continue
                    }
                    do {
                        let token = UUID().uuidString.lowercased()
                        let unsaved = try repository.preparedGeneratedEvent(source, kind: .unified, to: calendar, recordID: token)
                        _ = try repository.rollbackImage(of: unsaved, recordID: token)
                        count("source: all-day copy snapshot prepared without saving")
                    } catch { count("source: all-day snapshot failed: \(error.localizedDescription)") }
                }
            }
        }
        let report: [String: Any] = ["fullCalendarAccess": authorized, "authorizationStatus": EKEventStore.authorizationStatus(for: .event).rawValue, "pendingEntries": entries.count,
                                    "automaticBlockingEnabled": state.automaticBlockingEnabled, "counts": counts,
                                    "originalSourceCount": originalSourceCount, "originalSourceDigest": originalSourceDigest,
                                    "remainingGeneratedEventsInWindow": remainingGeneratedEventsInWindow,
                                    "routing": routing]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// Resume only a rollback already confirmed by the user in the app.
    static func resumePreviouslyConfirmedRollback(to url: URL) throws {
        let stateStore = SyncStateStore()
        guard stateStore.recoveryError == nil, stateStore.state.rollback?.rollbackStarted == true else {
            throw RollbackFailure.changed
        }
        let controller = RollbackController(stateStore: stateStore, repository: EventRepository(store: EKEventStore()))
        guard let preview = controller.preview() else { throw RollbackFailure.changed }
        let result = controller.apply(preview: preview)
        let report: [String: Any] = ["completed": result.completedCount, "remaining": result.remainingCount,
                                    "messages": result.messages, "automaticBlockingEnabled": stateStore.state.automaticBlockingEnabled]
        try JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
