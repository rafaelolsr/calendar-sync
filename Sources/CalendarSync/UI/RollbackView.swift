import SwiftUI

struct RollbackView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore
    @State private var confirmRollback = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Label("Rollback latest sync", systemImage: "arrow.uturn.backward")
                .font(.title2.bold())
            Text("Remove events created by this sync and restore generated events it updated or deleted. Original source events remain untouched. Automatic Blocking will be turned off.")
                .foregroundStyle(.secondary)
            Text("Only the latest sync that attempted changes is saved. A later sync replaces this snapshot. Events changed outside CalendarSync are left untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let preview = model.rollbackPreview {
                Text("Sync \(preview.startedAt.formatted(date: .abbreviated, time: .shortened)) · \(preview.actionableCount) recoverable · \(preview.blockedCount) blocked")
                    .font(.headline)
                List(preview.items) { item in
                    VStack(alignment: .leading, spacing: 4) {
                        HStack {
                            Text(item.entry.label).fontWeight(.medium)
                            Spacer()
                            Text(calendarName(item.entry.record.destinationCalendarID))
                                .foregroundStyle(.secondary)
                        }
                        if let image = item.entry.before ?? item.entry.after {
                            Text("\(image.title ?? "Untitled") · \(image.start.formatted(date: .abbreviated, time: .shortened))")
                                .font(.caption)
                        }
                        switch item.action {
                        case .remove: Text("Will remove the created event.").font(.caption)
                        case .restore: Text("Will restore the previous event.").font(.caption)
                        case .alreadyRestored: Text("Already restored or write never completed; will reconcile its mapping.").font(.caption)
                        case let .blocked(reason): Text(reason).font(.caption).foregroundStyle(.red)
                        }
                    }
                    .padding(.vertical, 4)
                }
            } else {
                Text(model.rollbackResult?.remainingCount == 0 ? "Rollback complete." : "No saved rollback is available for this sync.")
                    .frame(maxWidth: .infinity, minHeight: 120, alignment: .center)
            }

            if let issue = stateStore.recoveryError { Text(issue).foregroundStyle(.red) }
            if let result = model.rollbackResult {
                Text("\(result.completedCount) recovered · \(result.remainingCount) remaining")
                if !result.messages.isEmpty {
                    ScrollView { Text(result.messages.joined(separator: "\n")).foregroundStyle(.red).frame(maxWidth: .infinity, alignment: .leading) }
                        .frame(maxHeight: 100)
                }
            }

            HStack {
                Button("Refresh preview") { model.previewRollback() }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Roll back…", role: .destructive) { confirmRollback = true }
                    .disabled(model.rollbackPreview?.actionableCount ?? 0 == 0 || stateStore.recoveryError != nil)
            }
        }
        .padding(22)
        .frame(width: 760, height: 590)
        .confirmationDialog("Roll back the latest sync?", isPresented: $confirmRollback, titleVisibility: .visible) {
            Button("Roll back verified changes", role: .destructive) { model.rollbackLatestSync() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This will change \(model.rollbackPreview?.actionableCount ?? 0) generated-event record(s). Blocked events will remain untouched. Automatic Blocking will be turned off; you can retry any failures.")
        }
    }

    private func calendarName(_ id: String) -> String {
        model.calendarStore.calendars.first(where: { $0.id == id })?.displayName ?? "Unavailable calendar"
    }
}
