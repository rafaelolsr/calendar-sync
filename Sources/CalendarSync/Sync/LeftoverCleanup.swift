import Foundation

/// Separate from the latest-sync rollback: never replaces its journal or mappings.
@MainActor
final class LeftoverCleanupController {
    private let stateStore: SyncStateStore
    private let repository: any RollbackEventRepository

    init(stateStore: SyncStateStore, repository: any RollbackEventRepository) {
        self.stateStore = stateStore
        self.repository = repository
    }

    static func action(for entry: RollbackEntry, currentRecords: [ManagedEventRecord], evidence: [RollbackEntry], lookup: OwnedEventLookup) -> RollbackAction {
        guard entry.before == nil, entry.after != nil, entry.previousRecord == nil else {
            return .blocked("Only historically verified creations can be cleaned up.")
        }
        guard !currentRecords.contains(where: { $0.id == entry.record.id }) else {
            return .blocked("This event belongs to the current sync; it was left untouched.")
        }
        guard evidence.contains(where: { $0.before == nil && $0.after == entry.after
            && $0.record.id == entry.record.id && $0.record.destinationCalendarID == entry.record.destinationCalendarID }) else {
            return .blocked("No saved creation snapshot proves this leftover's ownership.")
        }
        return RollbackController.action(for: entry, lookup: lookup)
    }

    func apply(candidates: [RollbackEntry], evidence: [RollbackEntry]) -> RollbackResult {
        let lock: RecoveryWriteLock
        do { lock = try stateStore.acquireRecoveryLock() }
        catch { return RollbackResult(completedCount: 0, remainingCount: candidates.count, messages: [error.localizedDescription]) }
        defer { lock.release() }
        stateStore.reloadRecovery()
        do {
            try stateStore.checkpoint { state in
                state.rememberCreations(evidence)
                state.rememberCreations(state.rollback?.entries ?? [])
                state.automaticBlockingEnabled = false
                var pending = state.leftoverCleanup ?? []
                for candidate in candidates where !pending.contains(where: { $0.record.id == candidate.record.id }) {
                    // Never stage a token reclaimed by a concurrent sync.
                    if !state.records.contains(where: { $0.id == candidate.record.id }) { pending.append(candidate) }
                }
                state.leftoverCleanup = pending
            }
        } catch {
            return RollbackResult(completedCount: 0, remainingCount: candidates.count, messages: [error.localizedDescription])
        }
        var completed = 0
        var messages: [String] = []
        for entry in stateStore.state.leftoverCleanup ?? [] {
            do {
                let action = Self.action(for: entry, currentRecords: stateStore.state.records,
                                         evidence: stateStore.state.creationHistory ?? [],
                                         lookup: repository.lookupForRollback(entry))
                switch action {
                case .remove: try repository.deleteForRollback(entry)
                case .alreadyRestored: break
                case let .blocked(reason): messages.append(reason); continue
                case .restore: throw RollbackFailure.changed
                }
                // A failed checkpoint leaves the entry pending; an absent event
                // on retry is reconciled without another delete.
                try stateStore.checkpoint { $0.leftoverCleanup?.removeAll { $0.id == entry.id } }
                completed += 1
            } catch { messages.append(error.localizedDescription) }
        }
        return RollbackResult(completedCount: completed, remainingCount: stateStore.state.leftoverCleanup?.count ?? 0, messages: messages)
    }
}
