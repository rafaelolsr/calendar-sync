import Foundation
import Darwin

/// Prevent an app window and a Shortcuts invocation from replacing each other's journal.
final class RecoveryWriteLock {
    private var descriptor: Int32?

    init(url: URL) throws {
        let fd = open(url.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard fd >= 0 else { throw RollbackFailure.snapshotUnavailable }
        guard flock(fd, LOCK_EX | LOCK_NB) == 0 else {
            close(fd)
            throw RollbackFailure.busy
        }
        descriptor = fd
    }

    func release() {
        if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
        descriptor = nil
    }

    deinit {
        if let descriptor { flock(descriptor, LOCK_UN); close(descriptor) }
    }
}

struct OwnedLocationImage: Codable, Hashable {
    var title: String?
    var latitude: Double?
    var longitude: Double?
    var radius: Double
}

struct OwnedAlarmImage: Codable, Hashable {
    var absoluteDate: Date?
    var relativeOffset: TimeInterval
    var soundName: String?
    var location: OwnedLocationImage?
    var proximity: Int
}

/// Only fields of a CalendarSync-owned event, never a backup of a source event.
struct OwnedEventImage: Codable, Equatable {
    var title: String?
    var start: Date
    var end: Date
    var isAllDay: Bool
    var location: String?
    var notes: String?
    var url: String
    var availability: Int
    var timeZoneID: String?
    // Optional for compatibility with recovery files written before metadata capture.
    var alarms: [OwnedAlarmImage]?
    var structuredLocation: OwnedLocationImage?
    var metadataVersion: Int?

    func matches(_ expected: OwnedEventImage) -> Bool {
        // EventKit can report .notSupported (-1) for a newly saved event, then
        // expose the provider's default availability after hydration. It is an
        // unknown value, not an observed before/after change.
        guard title == expected.title, start == expected.start, end == expected.end,
              isAllDay == expected.isAllDay, location == expected.location,
              notes == expected.notes, url == expected.url, timeZoneID == expected.timeZoneID,
              expected.availability == -1 || availability == expected.availability else { return false }
        if expected.metadataVersion != nil {
            // Providers can reorder alarms without changing them.
            let actualAlarms = Dictionary((alarms ?? []).map { ($0, 1) }, uniquingKeysWith: +)
            let expectedAlarms = Dictionary((expected.alarms ?? []).map { ($0, 1) }, uniquingKeysWith: +)
            return actualAlarms == expectedAlarms && structuredLocation == expected.structuredLocation
        }
        // The previous format did not save alarms or structured locations. Do
        // not mistake provider-added metadata for an ownership conflict.
        return true
    }
}

struct RollbackEntry: Codable, Identifiable {
    let id: UUID
    var record: ManagedEventRecord
    let previousRecord: ManagedEventRecord?
    let before: OwnedEventImage?
    var after: OwnedEventImage?

    init(record: ManagedEventRecord, previousRecord: ManagedEventRecord?, before: OwnedEventImage?, after: OwnedEventImage?) {
        id = UUID()
        self.record = record
        self.previousRecord = previousRecord
        self.before = before
        self.after = after
    }

    var label: String {
        let kind = record.kind == .blocker ? "Busy block" : "Unified copy"
        return before == nil ? "Remove \(kind)" : "Restore \(kind)"
    }
}

struct RollbackJournal: Codable {
    let id: UUID
    let startedAt: Date
    let previousLastSync: Date?
    var rollbackStarted = false
    var entries: [RollbackEntry] = []

    init(previousLastSync: Date?) {
        id = UUID()
        startedAt = Date()
        self.previousLastSync = previousLastSync
    }
}

enum OwnedEventLookup {
    case found(eventID: String, image: OwnedEventImage)
    case absent
    case conflict(String)
}

@MainActor
protocol RollbackEventRepository {
    func lookupForRollback(_ entry: RollbackEntry) -> OwnedEventLookup
    func deleteForRollback(_ entry: RollbackEntry) throws
    func restoreForRollback(_ image: OwnedEventImage, entry: RollbackEntry) throws -> String
}

enum RollbackAction: Equatable {
    case remove
    case restore
    case alreadyRestored
    case blocked(String)

    var canApply: Bool {
        if case .blocked = self { return false }
        return true
    }
}

struct RollbackPreviewItem: Identifiable {
    let entry: RollbackEntry
    let action: RollbackAction
    var id: UUID { entry.id }
}

struct RollbackPreview {
    let journalID: UUID
    let startedAt: Date
    let items: [RollbackPreviewItem]
    var blockedCount: Int { items.filter { !$0.action.canApply }.count }
    var actionableCount: Int { items.count - blockedCount }
}

struct RollbackResult {
    let completedCount: Int
    let remainingCount: Int
    let messages: [String]
}

enum RollbackFailure: LocalizedError {
    case changed
    case snapshotUnavailable
    case busy

    var errorDescription: String? {
        switch self {
        case .changed: "The event or rollback preview changed. Refresh the preview; no unverified event was modified."
        case .snapshotUnavailable: "The recovery record could not be saved. No new calendar write was attempted."
        case .busy: "Another sync or rollback is running. Try again when it finishes."
        }
    }
}

@MainActor
final class RollbackController {
    private let stateStore: SyncStateStore
    private let repository: any RollbackEventRepository

    init(stateStore: SyncStateStore, repository: any RollbackEventRepository) {
        self.stateStore = stateStore
        self.repository = repository
    }

    static func action(for entry: RollbackEntry, lookup: OwnedEventLookup) -> RollbackAction {
        switch lookup {
        case let .conflict(reason): return .blocked(reason)
        case .absent:
            if entry.before == nil { return .alreadyRestored }
            if entry.after == nil { return .restore }
            return .blocked("The event to restore is missing; it may have been deleted outside CalendarSync.")
        case let .found(_, image):
            if let before = entry.before, image.matches(before) { return .alreadyRestored }
            guard let after = entry.after, image.matches(after) else {
                return .blocked("This event changed after the sync; it will be left untouched.")
            }
            return entry.before == nil ? .remove : .restore
        }
    }

    func preview() -> RollbackPreview? {
        stateStore.reloadRecovery()
        guard let journal = stateStore.state.rollback, !journal.entries.isEmpty else { return nil }
        return RollbackPreview(journalID: journal.id, startedAt: journal.startedAt, items: journal.entries.reversed().map {
            RollbackPreviewItem(entry: $0, action: Self.action(for: $0, lookup: repository.lookupForRollback($0)))
        })
    }

    func apply(preview: RollbackPreview) -> RollbackResult {
        let lock: RecoveryWriteLock
        do { lock = try stateStore.acquireRecoveryLock() }
        catch { return RollbackResult(completedCount: 0, remainingCount: preview.items.count, messages: [error.localizedDescription]) }
        defer { lock.release() }
        stateStore.reloadRecovery()
        guard stateStore.recoveryError == nil, let journal = stateStore.state.rollback,
              journal.id == preview.journalID,
              Set(journal.entries.map(\.id)) == Set(preview.items.map(\.id)) else {
            return RollbackResult(completedCount: 0, remainingCount: stateStore.state.rollback?.entries.count ?? 0,
                                  messages: [stateStore.recoveryError ?? RollbackFailure.changed.localizedDescription])
        }
        do {
            try stateStore.checkpoint {
                $0.rememberCreations(journal.entries)
                $0.automaticBlockingEnabled = false
                $0.rollback?.rollbackStarted = true
            }
        } catch {
            return RollbackResult(completedCount: 0, remainingCount: journal.entries.count, messages: [error.localizedDescription])
        }

        var completed = 0
        var messages: [String] = []
        for item in preview.items {
            do {
                // Revalidate at apply time. An event can change while the preview is open.
                let lookup = repository.lookupForRollback(item.entry)
                let action = Self.action(for: item.entry, lookup: lookup)
                if case let .blocked(reason) = action { messages.append(reason); continue }
                guard item.action.canApply else { messages.append("Refresh the preview before retrying a previously blocked event."); continue }
                var restoredRecord = item.entry.previousRecord
                switch action {
                case .remove:
                    try repository.deleteForRollback(item.entry)
                case .restore:
                    guard let before = item.entry.before else { throw RollbackFailure.changed }
                    let eventID = try repository.restoreForRollback(before, entry: item.entry)
                    restoredRecord?.eventID = eventID
                case .alreadyRestored:
                    if case let .found(eventID, _) = lookup { restoredRecord?.eventID = eventID }
                case .blocked: break
                }
                // If this checkpoint fails, the entry stays pending. A retry recognizes
                // the already restored/deleted event instead of writing a duplicate.
                try stateStore.checkpoint { state in
                    state.records.removeAll { $0.id == item.entry.record.id }
                    if let restoredRecord { state.records.append(restoredRecord) }
                    state.rollback?.entries.removeAll { $0.id == item.id }
                    if state.rollback?.entries.isEmpty == true {
                        state.lastSync = journal.previousLastSync
                    }
                }
                completed += 1
            } catch { messages.append(error.localizedDescription) }
        }
        return RollbackResult(completedCount: completed, remainingCount: stateStore.state.rollback?.entries.count ?? 0, messages: messages)
    }
}
