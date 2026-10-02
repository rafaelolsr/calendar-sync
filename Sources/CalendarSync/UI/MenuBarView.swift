import SwiftUI
import AppKit

enum MenuBarPresentation {
    static let preferenceKey = "CalendarSync.MenuBarOnly"
    static let windowID = "CalendarSyncMain"
}

struct CalendarSyncMenuBarView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open CalendarSync") {
            model.restoreMainWindow()
            openWindow(id: MenuBarPresentation.windowID)
        }
        Button("Sync now") { model.syncNow() }
            .disabled(!stateStore.state.hasUnifiedConfiguration || !stateStore.state.automaticBlockingEnabled)
        Text(stateStore.state.schedule?.isEnabled == true ? "Scheduled sync is on" : "Scheduled sync is off")
        if let report = model.scheduledRunReport {
            Text("Last scheduled run: \(report.finishedAt.formatted(date: .omitted, time: .shortened))")
        }
        Divider()
        Button("Minimize to menu bar") { model.minimizeToMenuBar() }
        Toggle("Show in Dock", isOn: Binding(
            get: { !model.menuBarOnly }, set: { model.setMenuBarOnly(!$0) }
        ))
        Divider()
        Text("Scheduled sync continues after quitting.")
        Button("Quit CalendarSync") { NSApplication.shared.terminate(nil) }
    }
}
