#if canImport(AppIntents)
import AppIntents
import EventKit

@available(macOS 13.0, *)
struct SyncCalendarsIntent: AppIntent {
    static let title: LocalizedStringResource = "Sync Calendars"
    static let description = IntentDescription("Safely reconcile CalendarSync calendars. Calendar changes require explicit validation and enablement in the app.")
    static let openAppWhenRun = false

    func perform() async throws -> some IntentResult {
        let summary = await MainActor.run {
            let store = SyncStateStore()
            let result = SyncEngine(eventStore: EKEventStore(), stateStore: store).run(dryRun: false)
            return result.applied
                ? "CalendarSync finished with \(result.errorCount) reported issue(s)."
                : (result.messages.first ?? "No calendar changes were made. Confirm validation and enable Automatic Blocking in CalendarSync first.")
        }
        return .result(dialog: IntentDialog(stringLiteral: summary))
    }
}

@available(macOS 13.0, *)
struct CalendarSyncShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(intent: SyncCalendarsIntent(), phrases: ["Sync my calendars with \(.applicationName)", "Run \(.applicationName)"], shortTitle: "Sync Calendars", systemImageName: "calendar.badge.clock")
    }
}
#endif
