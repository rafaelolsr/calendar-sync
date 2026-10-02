import EventKit
import Foundation
import OSLog
import Combine

struct CalendarSyncState: Codable {
    // Legacy persisted selection. Kept so existing user settings still decode.
    var participatingCalendarIDs: Set<String> = []
    // Nil means the user has not converted the legacy selection to explicit roles yet.
    var shareAvailabilityCalendarIDs: Set<String>?
    var unifiedOnlyCalendarIDs: Set<String>?
    var unifiedCalendarID: String?
    // Nil preserves the original single-output mode; an empty map enables
    // per-source mode before the user assigns any destinations.
    var unifiedDestinations: [String: String]?
    var savedUnifiedDestinations: [String: String]?
    var records: [ManagedEventRecord] = []
    var validationCalendarID: String?
    var validationConfirmed = false
    var automaticBlockingEnabled = false
    var blockTentative = false
    var pastDays = 7
    // Retained for decoding settings from versions that used days.
    var futureDays = 90
    var futureMonths: Int?
    var testEventID: String?
    var testEventToken: String?
    var testCalendarID: String?
    var lastSync: Date?
    var rollback: RollbackJournal?
    // Creation evidence survives rollback and later syncs, including delayed
    // provider reappearance of events whose active mapping was removed.
    var creationHistory: [RollbackEntry]?
    var leftoverCleanup: [RollbackEntry]?
    var generatedResetJournalID: UUID?
    // Added independently so upgrades preserve every existing sync setting.
    var schedule: SyncSchedule?

    mutating func rememberCreations(_ entries: [RollbackEntry]) {
        var history = creationHistory ?? []
        for entry in entries where entry.before == nil && entry.after != nil {
            if let index = history.firstIndex(where: { $0.record.id == entry.record.id }) {
                history[index] = entry
            } else { history.append(entry) }
        }
        creationHistory = history
    }

    var lookAheadMonths: Int {
        min(36, max(1, futureMonths ?? Int(ceil(Double(futureDays) / 30))))
    }

    func syncWindow(now: Date, calendar: Calendar = .current) -> DateInterval {
        let start = calendar.date(byAdding: .day, value: -pastDays, to: now) ?? now
        let end = calendar.date(byAdding: .month, value: lookAheadMonths, to: now) ?? now
        return DateInterval(start: start, end: end)
    }

    var configuredSourceCalendarIDs: Set<String> {
        (shareAvailabilityCalendarIDs ?? participatingCalendarIDs).union(unifiedOnlyCalendarIDs ?? [])
    }

    var unifiedOutputCalendarIDs: Set<String> {
        if let unifiedDestinations { return Set(unifiedDestinations.values) }
        return Set([unifiedCalendarID].compactMap { $0 })
    }

    func unifiedDestination(for sourceID: String) -> String? {
        if let unifiedDestinations { return unifiedDestinations[sourceID] }
        return unifiedCalendarID
    }

    var hasUnifiedConfiguration: Bool {
        guard !configuredSourceCalendarIDs.isEmpty,
              configuredSourceCalendarIDs.isDisjoint(with: unifiedOutputCalendarIDs) else { return false }
        if let unifiedDestinations {
            let destinations = configuredSourceCalendarIDs.compactMap { unifiedDestinations[$0] }
            return destinations.count == configuredSourceCalendarIDs.count
        }
        return unifiedCalendarID != nil
    }

    var busySharingCalendarIDs: Set<String> {
        (shareAvailabilityCalendarIDs ?? participatingCalendarIDs).subtracting(unifiedOutputCalendarIDs)
    }

    var sourceCalendarIDs: Set<String> {
        configuredSourceCalendarIDs.subtracting(unifiedOutputCalendarIDs)
    }

    func role(for calendarID: String, unifiedID: String?) -> CalendarRole {
        if unifiedOutputCalendarIDs.contains(calendarID) || (unifiedDestinations == nil && calendarID == unifiedID) { return .unifiedOutput }
        if busySharingCalendarIDs.contains(calendarID) { return .shareAvailability }
        if unifiedOnlyCalendarIDs?.contains(calendarID) == true { return .unifiedOnly }
        return .excluded
    }
}

enum CalendarRole: String, CaseIterable, Identifiable {
    case excluded
    case unifiedOnly
    case shareAvailability
    case unifiedOutput

    var id: String { rawValue }
    var label: String {
        switch self {
        case .excluded: "Not included"
        case .unifiedOnly: "View only"
        case .shareAvailability: "Block + view"
        case .unifiedOutput: "Unified output"
        }
    }
}

@MainActor
final class SyncStateStore: ObservableObject {
    @Published private(set) var state: CalendarSyncState
    @Published private(set) var recoveryError: String?
    private let defaults: UserDefaults
    private let recoveryURL: URL
    private let key = "CalendarSync.State.v1"

    private struct RecoveryCheckpoint: Codable {
        let state: CalendarSyncState
    }

    init(defaults: UserDefaults = .standard, recoveryURL: URL? = nil) {
        self.defaults = defaults
        self.recoveryURL = recoveryURL ?? FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.datageek.CalendarSync", isDirectory: true)
            .appendingPathComponent("recovery.json")
        if let data = defaults.data(forKey: key), let value = try? JSONDecoder().decode(CalendarSyncState.self, from: data) {
            state = value
        } else {
            state = CalendarSyncState()
        }
        reloadRecovery()
    }

    func update(_ mutation: (inout CalendarSyncState) -> Void) {
        do {
            let lock = try acquireRecoveryLock()
            defer { lock.release() }
            reloadRecovery()
            try checkpoint(mutation)
        } catch {
            recoveryError = "Local settings could not be saved: \(error.localizedDescription)"
        }
    }

    func reloadRecovery() {
        guard FileManager.default.fileExists(atPath: recoveryURL.path) else { return }
        do {
            let saved = try JSONDecoder().decode(RecoveryCheckpoint.self, from: Data(contentsOf: recoveryURL))
            state = saved.state
            recoveryError = nil
        } catch {
            recoveryError = "The saved recovery record cannot be read. Sync is paused to preserve it: \(error.localizedDescription)"
        }
    }

    /// Write the recovery journal and mappings atomically BEFORE an EventKit commit.
    /// Preferences are mirrored for compatibility; this file is authoritative.
    func checkpoint(_ mutation: (inout CalendarSyncState) -> Void) throws {
        guard recoveryError == nil else { throw RollbackFailure.snapshotUnavailable }
        var next = state
        mutation(&next)
        let data = try JSONEncoder().encode(RecoveryCheckpoint(state: next))
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        try data.write(to: recoveryURL, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: recoveryURL.path)
        state = next
        if let data = try? JSONEncoder().encode(next) { defaults.set(data, forKey: key) }
    }

    func acquireRecoveryLock() throws -> RecoveryWriteLock {
        try FileManager.default.createDirectory(at: recoveryURL.deletingLastPathComponent(), withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        return try RecoveryWriteLock(url: recoveryURL.appendingPathExtension("lock"))
    }
}

struct SyncRunResult {
    let plan: ReconciliationPlan
    let applied: Bool
    let messages: [String]
    var successfulUnifiedChanges = 0
    var successfulBlockerChanges = 0
    var successfulChangeCount: Int { successfulUnifiedChanges + successfulBlockerChanges }
    var errorCount: Int { messages.count + plan.operations.filter { if case .error = $0 { true } else { false } }.count }
}

@MainActor
final class SyncEngine {
    private let eventStore: EKEventStore
    private let stateStore: SyncStateStore
    private let logger = Logger(subsystem: "CalendarSync", category: "Reconciliation")

    init(eventStore: EKEventStore, stateStore: SyncStateStore) {
        self.eventStore = eventStore
        self.stateStore = stateStore
    }

    func run(dryRun: Bool, scheduled: Bool = false) -> SyncRunResult {
        let lock: RecoveryWriteLock?
        do { lock = dryRun ? nil : try stateStore.acquireRecoveryLock() }
        catch {
            let plan = ReconciliationPlan(operations: [], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: [error.localizedDescription])
        }
        defer { lock?.release() }
        stateStore.reloadRecovery()
        let state = stateStore.state
        if scheduled && state.schedule?.isEnabled != true {
            let plan = ReconciliationPlan(operations: [], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: ["Scheduling is off."])
        }
        if (!dryRun || scheduled), let issue = stateStore.recoveryError ?? (state.leftoverCleanup?.isEmpty == false
            ? "Finish the pending leftover cleanup before starting another sync." : nil) ?? (state.rollback?.rollbackStarted == true && state.rollback?.entries.isEmpty == false
            ? "Finish the pending rollback before starting another sync." : nil) {
            let plan = ReconciliationPlan(operations: [], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: [issue])
        }
        guard state.hasUnifiedConfiguration else {
            let reason = state.unifiedDestinations == nil ? "Choose a Unified output calendar and at least one source."
                : "Map every included source to an output calendar. Outputs cannot also be sources."
            let plan = ReconciliationPlan(operations: [.error(source: nil, calendarID: nil, reason: reason)], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: [])
        }
        if (!dryRun || scheduled) && (!state.validationConfirmed || !state.automaticBlockingEnabled) {
            let plan = ReconciliationPlan(operations: [.error(source: nil, calendarID: nil, reason: "Automatic Blocking is locked")], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: ["No calendar changes were made. Confirm Validation Mode and explicitly enable Automatic Blocking to apply changes."])
        }
        if (!dryRun || scheduled) && EKEventStore.authorizationStatus(for: .event) != .fullAccess {
            let plan = ReconciliationPlan(operations: [], sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: [CalendarSyncError.fullAccessRequired.localizedDescription])
        }

        let calendars = eventStore.calendars(for: .event)
        let byID = Dictionary(uniqueKeysWithValues: calendars.map { ($0.calendarIdentifier, $0) })
        let invalidOutputs = state.unifiedOutputCalendarIDs.filter { byID[$0]?.allowsContentModifications != true }
        if !invalidOutputs.isEmpty {
            let plan = ReconciliationPlan(operations: invalidOutputs.map {
                .error(source: nil, calendarID: $0, reason: "The mapped output is unavailable or read-only. Choose a writable destination.")
            }, sourceCount: 0, skippedCount: 0, sourceSummaries: [:])
            return SyncRunResult(plan: plan, applied: false, messages: [])
        }
        let configuredIDs = state.sourceCalendarIDs.union(state.busySharingCalendarIDs)
        let missing = configuredIDs.subtracting(byID.keys)
        let sourceIDs = state.sourceCalendarIDs.intersection(byID.keys)
        let sharingIDs = state.busySharingCalendarIDs.intersection(byID.keys)
        let destinationWritable = Set(sharingIDs.compactMap { id -> String? in
            guard let calendar = byID[id], calendar.allowsContentModifications else { return nil }
            return id
        })
        var messages: [String] = []
        if !missing.isEmpty { messages.append("\(missing.count) selected calendar(s) are unavailable; their mappings were retained.") }
        logger.info("Reconciliation started; source calendars: \(sourceIDs.count, privacy: .public), availability-sharing calendars: \(sharingIDs.count, privacy: .public)")

        let now = Date()
        let window = state.syncWindow(now: now)
        let start = window.start
        let end = window.end
        let repository = EventRepository(store: eventStore)
        let snapshots = repository.snapshots(calendarIDs: sourceIDs, from: start, to: end, managedRecords: state.records)
        let calendarsWithEvents = Set(snapshots.map(\.calendarID))
        let availableRecords = state.records.filter {
            sourceIDs.contains($0.source.calendarID)
                && byID[$0.destinationCalendarID] != nil
                && (calendarsWithEvents.contains($0.source.calendarID) || $0.representedStart < start || $0.representedStart >= end)
        }
        let retainedRecords = state.records.filter { !availableRecords.contains($0) }
        if !retainedRecords.isEmpty { messages.append("\(retainedRecords.count) ownership mapping(s) were retained because a source or destination calendar is unavailable, no longer selected, or returned no events in this scan window.") }
        let visible = Set(availableRecords.compactMap { repository.ownedEvent(record: $0) == nil ? nil : $0.id })
        let planner = ReconciliationPlanner(blockTentative: state.blockTentative)
        let plan = planner.plan(
            sources: snapshots,
            sharingCalendarIDs: sharingIDs,
            writableCalendarIDs: destinationWritable,
            unifiedCalendarID: state.unifiedCalendarID,
            unifiedDestinations: state.unifiedDestinations,
            existing: availableRecords,
            visibleOwnershipTokens: visible,
            now: now,
            windowStart: start,
            windowEnd: end
        )
        if !missing.isEmpty {
            // A missing calendar is not evidence that its mappings should be deleted.
            messages.append("Unavailable calendar mappings were excluded from this reconciliation.")
        }
        guard !dryRun else {
            logger.info("Dry run complete; sources: \(plan.sourceCount, privacy: .public), planned changes: \(plan.mutationCount, privacy: .public)")
            return SyncRunResult(plan: plan, applied: false, messages: messages)
        }

        var records = state.records
        var journalStarted = false
        var successfulUnifiedChanges = 0
        var successfulBlockerChanges = 0
        let snapshotsByKey = Dictionary(grouping: snapshots, by: \.key)
        for operation in plan.operations {
            do {
                switch operation {
                case let .create(sourceKey, kind, calendarID), let .update(recordID: _, source: sourceKey, kind: kind, calendarID: calendarID):
                    guard let source = snapshotsByKey[sourceKey]?.first,
                          let calendar = byID[calendarID], calendar.allowsContentModifications else {
                        messages.append("Skipped a write because its source or writable destination is unavailable.")
                        continue
                    }
                    let existingRecord = records.first { $0.source == sourceKey && $0.kind == kind && $0.destinationCalendarID == calendarID }
                    let recordID = existingRecord?.id ?? UUID().uuidString.lowercased()
                    let existingEvent = existingRecord.flatMap { repository.ownedEvent(record: $0) }
                    let before = try existingEvent.map { try repository.rollbackImage(of: $0, recordID: recordID) }
                    let fingerprint = planner.fingerprint(for: source, kind: kind)
                    let provisional = ManagedEventRecord(id: recordID, source: sourceKey, kind: kind, destinationCalendarID: calendarID, representedStart: source.start, eventID: nil, fingerprint: fingerprint, updatedAt: Date())
                    var entryID: UUID?
                    let savedEvent = try repository.saveGenerated(source, kind: kind, to: calendar, recordID: recordID, existing: existingEvent) { after in
                        let entry = RollbackEntry(record: provisional, previousRecord: existingRecord, before: before, after: after)
                        try stateStore.checkpoint { saved in
                            if !journalStarted {
                                saved.rememberCreations(saved.rollback?.entries ?? [])
                                saved.rollback = RollbackJournal(previousLastSync: state.lastSync)
                            }
                            saved.rollback?.entries.append(entry)
                            saved.rememberCreations([entry])
                            saved.records.removeAll { $0.id == recordID }
                            saved.records.append(provisional)
                        }
                        journalStarted = true
                        entryID = entry.id
                        records = stateStore.state.records
                    }
                    let eventID = savedEvent.eventID
                    if kind == .unified { successfulUnifiedChanges += 1 } else { successfulBlockerChanges += 1 }
                    let record = ManagedEventRecord(id: recordID, source: sourceKey, kind: kind, destinationCalendarID: calendarID, representedStart: source.start, eventID: eventID, fingerprint: fingerprint, updatedAt: Date())
                    if let index = records.firstIndex(where: { $0.id == recordID }) { records[index] = record } else { records.append(record) }
                    try stateStore.checkpoint { saved in
                        saved.records = records
                        if let index = saved.rollback?.entries.firstIndex(where: { $0.id == entryID }) {
                            saved.rollback?.entries[index].record = record
                            saved.rollback?.entries[index].after = savedEvent.image
                            if before == nil { saved.rememberCreations([saved.rollback!.entries[index]]) }
                        }
                    }
                    logger.info("Saved owned \(kind.rawValue, privacy: .public) event in calendar \(calendarID, privacy: .private(mask: .hash)); event ID \(eventID, privacy: .private(mask: .hash))")
                case let .delete(recordID, _, _, _):
                    guard let record = records.first(where: { $0.id == recordID }) else { continue }
                    guard let event = repository.ownedEvent(record: record) else {
                        messages.append("Ownership could not be verified; an event was left untouched.")
                        continue
                    }
                    let before = try repository.rollbackImage(of: event, recordID: recordID)
                    let entry = RollbackEntry(record: record, previousRecord: record, before: before, after: nil)
                    try stateStore.checkpoint { saved in
                        if !journalStarted {
                            saved.rememberCreations(saved.rollback?.entries ?? [])
                            saved.rollback = RollbackJournal(previousLastSync: state.lastSync)
                        }
                        saved.rollback?.entries.append(entry)
                    }
                    journalStarted = true
                    if try repository.removeOwned(record) {
                        if record.kind == .unified { successfulUnifiedChanges += 1 } else { successfulBlockerChanges += 1 }
                        records.removeAll { $0.id == recordID }
                        try stateStore.checkpoint { $0.records = records }
                        logger.info("Removed owned event; record \(recordID, privacy: .private(mask: .hash))")
                    } else {
                        messages.append("Ownership could not be verified; an event was left untouched.")
                    }
                case let .error(_, calendarID, reason):
                    logger.error("Ownership or configuration conflict in \(calendarID ?? "unknown calendar", privacy: .private(mask: .hash)): \(reason, privacy: .public)")
                case .skip:
                    break
                }
            } catch {
                messages.append("A destination write failed: \(error.localizedDescription)")
                logger.error("Reconciliation operation failed: \(error.localizedDescription, privacy: .public)")
            }
        }
        do { try stateStore.checkpoint { $0.records = records; $0.lastSync = Date() } }
        catch { messages.append("Recovery checkpoint failed: \(error.localizedDescription)") }
        logger.info("Reconciliation finished; mappings: \(records.count, privacy: .public), errors: \(messages.count, privacy: .public)")
        return SyncRunResult(plan: plan, applied: true, messages: messages,
                             successfulUnifiedChanges: successfulUnifiedChanges, successfulBlockerChanges: successfulBlockerChanges)
    }
}
