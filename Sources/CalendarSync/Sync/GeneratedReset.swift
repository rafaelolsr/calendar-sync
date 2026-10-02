import Foundation

@MainActor
final class GeneratedResetController {
    private let stateStore: SyncStateStore
    private let repository: any RollbackEventRepository

    init(stateStore: SyncStateStore, repository: any RollbackEventRepository) {
        self.stateStore = stateStore
        self.repository = repository
    }

    /// All currently mapped generated events, including earlier sync runs.
    /// Captures current owned content before staging any deletion.
    func run() throws -> RollbackResult {
        let lock = try stateStore.acquireRecoveryLock()
        do {
            defer { lock.release() }
            stateStore.reloadRecovery()
            guard stateStore.recoveryError == nil else { throw RollbackFailure.snapshotUnavailable }
            guard stateStore.state.leftoverCleanup?.isEmpty != false else { throw RollbackFailure.busy }
            let pending = stateStore.state.rollback?.rollbackStarted == true && stateStore.state.rollback?.entries.isEmpty == false
            if pending {
                guard stateStore.state.generatedResetJournalID == stateStore.state.rollback?.id else { throw RollbackFailure.busy }
            } else {
                var journal = RollbackJournal(previousLastSync: nil)
                journal.rollbackStarted = true
                for record in stateStore.state.records {
                    let probe = RollbackEntry(record: record, previousRecord: nil, before: nil, after: nil)
                    switch repository.lookupForRollback(probe) {
                    case let .found(eventID, image):
                        var currentRecord = record
                        currentRecord.eventID = eventID
                        journal.entries.append(RollbackEntry(record: currentRecord, previousRecord: nil, before: nil, after: image))
                    case .absent: journal.entries.append(probe)
                    case let .conflict(reason):
                        throw NSError(domain: "CalendarSync.GeneratedReset", code: 1,
                                      userInfo: [NSLocalizedDescriptionKey: reason])
                    }
                }
                try stateStore.checkpoint {
                    $0.rememberCreations($0.rollback?.entries ?? [])
                    $0.rememberCreations(journal.entries)
                    $0.rollback = journal
                    $0.generatedResetJournalID = journal.id
                    $0.automaticBlockingEnabled = false
                }
            }
        }
        // The staged journal blocks sync; release and reacquire via the common
        // rollback path, which revalidates each owner and snapshots each write.
        let controller = RollbackController(stateStore: stateStore, repository: repository)
        if let preview = controller.preview() { return controller.apply(preview: preview) }
        return RollbackResult(completedCount: 0, remainingCount: 0, messages: [])
    }
}
