import Foundation

enum GeneratedKind: String, Codable, Hashable { case unified, blocker }

struct SourceKey: Codable, Hashable, CustomStringConvertible {
    let calendarID: String
    let eventID: String
    let occurrence: Date

    var description: String { "\(calendarID):\(eventID):\(Int(occurrence.timeIntervalSince1970))" }
}

struct CalendarEventSnapshot: Hashable {
    let key: SourceKey
    let calendarID: String
    let title: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let location: String?
    let availability: EventAvailability
    let isCancelled: Bool
    let isDeclined: Bool
    let isWorkingLocation: Bool
    let ownershipToken: String?
}

struct SourceEventSummary: Hashable {
    let title: String
    let calendarID: String
    let start: Date
    let end: Date
    let isAllDay: Bool
    let blockerDetail: String
}

enum EventAvailability: String, Codable, Hashable { case busy, unavailable, tentative, free, unknown }

struct ManagedEventRecord: Codable, Hashable, Identifiable {
    let id: String
    let source: SourceKey
    let kind: GeneratedKind
    let destinationCalendarID: String
    var representedStart: Date
    var eventID: String?
    var fingerprint: String
    var updatedAt: Date
}

enum ReconciliationOperation: Hashable, Identifiable {
    case create(source: SourceKey, kind: GeneratedKind, calendarID: String)
    case update(recordID: String, source: SourceKey, kind: GeneratedKind, calendarID: String)
    case delete(recordID: String, source: SourceKey, kind: GeneratedKind, calendarID: String)
    case skip(source: SourceKey, reason: String)
    case error(source: SourceKey?, calendarID: String?, reason: String)

    var id: String {
        switch self {
        case let .create(source, kind, calendar): "create|\(source)|\(kind.rawValue)|\(calendar)"
        case let .update(record, _, _, _): "update|\(record)"
        case let .delete(record, _, _, _): "delete|\(record)"
        case let .skip(source, reason): "skip|\(source)|\(reason)"
        case let .error(source, calendar, reason): "error|\(source?.description ?? "")|\(calendar ?? "")|\(reason)"
        }
    }
}

struct ReconciliationPlan {
    let operations: [ReconciliationOperation]
    let sourceCount: Int
    let skippedCount: Int
    let sourceSummaries: [SourceKey: SourceEventSummary]

    var mutationCount: Int { operations.filter { if case .skip = $0 { false } else if case .error = $0 { false } else { true } }.count }
}

struct ReconciliationPlanner {
    var blockTentative = false

    func plan(
        sources: [CalendarEventSnapshot],
        sharingCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        unifiedCalendarID: String?,
        unifiedDestinations: [String: String]? = nil,
        existing: [ManagedEventRecord],
        visibleOwnershipTokens: Set<String> = [],
        now: Date = Date(),
        windowStart: Date = .distantPast,
        windowEnd: Date = .distantFuture
    ) -> ReconciliationPlan {
        let outputIDs = unifiedDestinations.map { Set($0.values) } ?? Set([unifiedCalendarID].compactMap { $0 })
        // EventKit queries return overlapping events too. Enforce the selected
        // start-date window here for every generated copy and busy block.
        let validSources = sources.filter {
            !outputIDs.contains($0.calendarID) && $0.ownershipToken == nil
                && $0.start >= windowStart && $0.start < windowEnd
        }
        var desired: [String: (SourceKey, GeneratedKind, String, String)] = [:]
        let recordByID = Dictionary(existing.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var operations: [ReconciliationOperation] = sources.compactMap { event in
            guard let token = event.ownershipToken, recordByID[token]?.destinationCalendarID != event.calendarID else { return nil }
            return .error(source: event.key, calendarID: event.calendarID, reason: "CalendarSync ownership marker has no matching destination mapping; left untouched")
        }

        for event in validSources {
            guard !event.isCancelled else { continue }
            if event.isDeclined || event.isWorkingLocation {
                operations.append(.skip(source: event.key, reason: event.isDeclined ? "Declined event" : "Working location is unsupported"))
                continue
            }
            guard event.end > event.start else {
                operations.append(.skip(source: event.key, reason: "Invalid event interval"))
                continue
            }

            let outputID = unifiedDestinations == nil ? unifiedCalendarID : unifiedDestinations?[event.calendarID]
            guard let outputID else {
                operations.append(.error(source: event.key, calendarID: nil, reason: "Choose an output calendar for this source."))
                continue
            }
            let unifiedFingerprint = fingerprint(for: event, kind: .unified)
            let unifiedKey = recordKey(source: event.key, kind: .unified, calendarID: outputID)
            desired[unifiedKey] = (event.key, .unified, outputID, unifiedFingerprint)

            guard sharingCalendarIDs.contains(event.calendarID), event.end > now else { continue }
            guard event.availability == .busy || event.availability == .unavailable || (event.availability == .tentative && blockTentative) else { continue }
            for destination in sharingCalendarIDs.subtracting(outputIDs).subtracting([event.calendarID]) where writableCalendarIDs.contains(destination) {
                let key = recordKey(source: event.key, kind: .blocker, calendarID: destination)
                desired[key] = (event.key, .blocker, destination, fingerprint(for: event, kind: .blocker))
            }
        }

        let recordsByKey = Dictionary(grouping: existing, by: { recordKey(source: $0.source, kind: $0.kind, calendarID: $0.destinationCalendarID) })
        for (key, (source, kind, calendarID, fingerprint)) in desired {
                let records = recordsByKey[key, default: []]
            if records.count > 1 {
                operations.append(.error(source: source, calendarID: calendarID, reason: "Multiple ownership records match; left events untouched"))
            } else if let record = records.first {
                if record.fingerprint != fingerprint || record.eventID == nil || !visibleOwnershipTokens.contains(record.id) {
                    operations.append(.update(recordID: record.id, source: source, kind: kind, calendarID: calendarID))
                }
            } else {
                operations.append(.create(source: source, kind: kind, calendarID: calendarID))
            }
        }

        let desiredKeys = Set(desired.keys)
        for record in existing where !desiredKeys.contains(recordKey(source: record.source, kind: record.kind, calendarID: record.destinationCalendarID)) {
            guard record.representedStart >= windowStart && record.representedStart < windowEnd else { continue }
            if let eventID = record.eventID, visibleOwnershipTokens.contains(record.id), !eventID.isEmpty {
                operations.append(.delete(recordID: record.id, source: record.source, kind: record.kind, calendarID: record.destinationCalendarID))
            } else {
                operations.append(.error(source: record.source, calendarID: record.destinationCalendarID, reason: "Owned event could not be positively verified; left untouched"))
            }
        }

        var summaries: [SourceKey: SourceEventSummary] = [:]
        for source in validSources where !source.isCancelled {
            let blockerOperations = operations.filter { operation in
                switch operation {
                case let .create(key, .blocker, _): key == source.key
                case let .update(_, key, .blocker, _), let .delete(_, key, .blocker, _): key == source.key
                default: false
                }
            }
            let detail = blockerDetail(
                for: source,
                sharingCalendarIDs: sharingCalendarIDs,
                writableCalendarIDs: writableCalendarIDs,
                outputIDs: outputIDs,
                now: now,
                hasBlockerChanges: !blockerOperations.isEmpty
            )
            summaries[source.key] = SourceEventSummary(
                title: source.title,
                calendarID: source.calendarID,
                start: source.start,
                end: source.end,
                isAllDay: source.isAllDay,
                blockerDetail: detail
            )
        }
        return ReconciliationPlan(
            operations: operations.sorted { $0.id < $1.id },
            sourceCount: validSources.count,
            skippedCount: operations.filter { if case .skip = $0 { true } else { false } }.count,
            sourceSummaries: summaries
        )
    }

    func fingerprint(for event: CalendarEventSnapshot, kind: GeneratedKind) -> String {
        let title = kind == .blocker ? "Busy" : event.title
        let location = kind == .unified ? (event.location ?? "") : ""
        return [kind.rawValue, title, String(event.start.timeIntervalSince1970), String(event.end.timeIntervalSince1970), String(event.isAllDay), location, event.availability.rawValue].joined(separator: "\u{1f}")
    }

    private func blockerDetail(
        for event: CalendarEventSnapshot,
        sharingCalendarIDs: Set<String>,
        writableCalendarIDs: Set<String>,
        outputIDs: Set<String>,
        now: Date,
        hasBlockerChanges: Bool
    ) -> String {
        guard sharingCalendarIDs.contains(event.calendarID) else {
            return "This calendar is View only; it appears in Unified without blocking other calendars."
        }
        guard event.end > now else {
            return "This event is in the past; no new busy blocks are created for past events."
        }
        switch event.availability {
        case .free:
            return "This event is marked Free, so it does not block time."
        case .unknown:
            return "The event's availability is unknown, so CalendarSync skips blocking it."
        case .tentative where !blockTentative:
            return "This event is Tentative; turn on Include tentative events as busy to block it."
        case .busy, .unavailable, .tentative:
            break
        }
        let destinations = sharingCalendarIDs
            .subtracting(outputIDs).subtracting([event.calendarID])
            .intersection(writableCalendarIDs)
        guard !destinations.isEmpty else {
            return "No other writable calendars are set to Block + view."
        }
        if !hasBlockerChanges {
            return "Busy blocks are already up to date in the other Block + view calendars."
        }
        return "Busy block changes are listed below."
    }

    private func recordKey(source: SourceKey, kind: GeneratedKind, calendarID: String) -> String {
        "\(source.description)|\(kind.rawValue)|\(calendarID)"
    }
}
