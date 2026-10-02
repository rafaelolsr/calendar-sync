import SwiftUI
import EventKit
import AppKit

@MainActor
final class AppModel: ObservableObject {
    @Published var selectedTestCalendarID: String?
    @Published var testStart = Calendar.current.date(byAdding: .hour, value: 1, to: Date()) ?? Date()
    @Published var status = "Ready. Calendar access has not been requested."
    @Published var latestResult: SyncRunResult?
    @Published var showEnableWarning = false
    @Published var showValidation = false
    @Published var showSafetySettings = false
    @Published var showRollback = false
    @Published var rollbackPreview: RollbackPreview?
    @Published var rollbackResult: RollbackResult?
    @Published var scheduledRunReport: ScheduledRunReport?
    @Published var scheduleJobLoaded = false
    @Published var menuBarOnly = UserDefaults.standard.bool(forKey: MenuBarPresentation.preferenceKey)
    private var hideOnFirstAppearance = UserDefaults.standard.bool(forKey: MenuBarPresentation.preferenceKey)
    private var restoreRequested = false
    let calendarStore = CalendarStore()
    let stateStore = SyncStateStore()
    private var engine: SyncEngine { SyncEngine(eventStore: calendarStore.store, stateStore: stateStore) }
    private var rollbackController: RollbackController {
        RollbackController(stateStore: stateStore, repository: EventRepository(store: calendarStore.store))
    }

    func mainWindowAppeared() {
        guard hideOnFirstAppearance else { return }
        hideOnFirstAppearance = false
        DispatchQueue.main.async {
            if self.hideOnFirstAppearance == false && !self.restoreRequested { self.minimizeToMenuBar() }
        }
    }

    func setMenuBarOnly(_ enabled: Bool) {
        menuBarOnly = enabled
        UserDefaults.standard.set(enabled, forKey: MenuBarPresentation.preferenceKey)
        NSApplication.shared.setActivationPolicy(enabled ? .accessory : .regular)
    }

    func minimizeToMenuBar() {
        // Keep the status item available; hide only the app's main windows/sheets.
        for window in NSApplication.shared.windows where window.canBecomeMain || window.isSheet {
            window.orderOut(nil)
        }
        setMenuBarOnly(true)
    }

    func restoreMainWindow() {
        hideOnFirstAppearance = false
        restoreRequested = true
        reload()
        DispatchQueue.main.async {
            let app = NSApplication.shared
            app.unhide(nil)
            for window in app.windows where window.canBecomeMain {
                window.makeKeyAndOrderFront(nil)
            }
            app.activate(ignoringOtherApps: true)
        }
    }

    func reload() {
        refreshScheduleStatus()
        calendarStore.reload()
        synchronizeSelectionFromState()
        updateAccessStatus()
    }

    func refreshScheduleStatus() {
        stateStore.reloadRecovery()
        scheduledRunReport = (try? Data(contentsOf: LaunchAgentScheduler.runReportURL))
            .flatMap { try? JSONDecoder().decode(ScheduledRunReport.self, from: $0) }
        scheduleJobLoaded = LaunchAgentScheduler(appURL: Bundle.main.bundleURL).isLoaded
    }

    func saveSchedule(_ schedule: SyncSchedule) {
        do {
            try ScheduleController(stateStore: stateStore, installer: LaunchAgentScheduler(appURL: Bundle.main.bundleURL)).save(schedule)
            status = schedule.isEnabled ? "Schedule saved. Scheduled runs use your current calendar configuration." : "Scheduled sync is off."
        } catch { status = error.localizedDescription }
        refreshScheduleStatus()
    }

    func requestAccess() async {
        if calendarStore.authorizationStatus == .denied || calendarStore.authorizationStatus == .restricted {
            status = "Calendar access is off. Enable CalendarSync under System Settings → Privacy & Security → Calendars."
            openCalendarSettings()
            return
        }
        await calendarStore.requestAccessAndReload()
        synchronizeSelectionFromState()
        updateAccessStatus()
    }

    func openCalendarSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Calendars") else { return }
        NSWorkspace.shared.open(url)
    }

    func openAccountsSettings() {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.InternetAccounts") else { return }
        NSWorkspace.shared.open(url)
    }

    func setCalendarRole(_ calendarID: String, role: CalendarRole) {
        guard !stateStore.state.unifiedOutputCalendarIDs.contains(calendarID), role != .unifiedOutput else { return }
        stateStore.update { state in
            var sharing = state.shareAvailabilityCalendarIDs ?? state.participatingCalendarIDs
            var unifiedOnly = state.unifiedOnlyCalendarIDs ?? []
            sharing.remove(calendarID)
            unifiedOnly.remove(calendarID)
            switch role {
            case .excluded, .unifiedOutput:
                break
            case .unifiedOnly:
                unifiedOnly.insert(calendarID)
            case .shareAvailability:
                sharing.insert(calendarID)
            }
            state.shareAvailabilityCalendarIDs = sharing
            state.unifiedOnlyCalendarIDs = unifiedOnly
            if role == .excluded {
                state.unifiedDestinations?.removeValue(forKey: calendarID)
                state.savedUnifiedDestinations?.removeValue(forKey: calendarID)
            }
            state.automaticBlockingEnabled = false
        }
        latestResult = nil
        status = "Source selection changed. Check output mappings and preview before enabling Automatic Blocking."
    }

    func setUnified(_ id: String?) {
        stateStore.update { state in
            var sharing = state.shareAvailabilityCalendarIDs ?? state.participatingCalendarIDs
            var unifiedOnly = state.unifiedOnlyCalendarIDs ?? []
            if let old = state.unifiedCalendarID {
                sharing.remove(old)
                unifiedOnly.remove(old)
            }
            state.unifiedCalendarID = id
            if let id {
                sharing.remove(id)
                unifiedOnly.remove(id)
                state.participatingCalendarIDs.remove(id)
            }
            state.shareAvailabilityCalendarIDs = sharing
            state.unifiedOnlyCalendarIDs = unifiedOnly
            state.automaticBlockingEnabled = false
        }
        latestResult = nil
        status = "Output calendar changed. Preview before enabling Automatic Blocking."
    }

    func setSeparateOutputs(_ enabled: Bool) {
        guard (stateStore.state.unifiedDestinations != nil) != enabled else { return }
        stateStore.update { state in
            if enabled { state.unifiedDestinations = state.savedUnifiedDestinations ?? [:] }
            else {
                state.savedUnifiedDestinations = state.unifiedDestinations
                state.unifiedDestinations = nil
            }
            if !enabled, let id = state.unifiedCalendarID {
                state.shareAvailabilityCalendarIDs?.remove(id)
                state.participatingCalendarIDs.remove(id)
                state.unifiedOnlyCalendarIDs?.remove(id)
            }
            state.automaticBlockingEnabled = false
        }
        latestResult = nil
        status = "Output mode changed. Choose destinations and preview before enabling Automatic Blocking."
    }

    func setOutput(_ destinationID: String?, for sourceID: String) {
        guard stateStore.state.unifiedDestinations != nil,
              stateStore.state.configuredSourceCalendarIDs.contains(sourceID) else { return }
        if let destinationID {
            guard !stateStore.state.configuredSourceCalendarIDs.contains(destinationID),
                  calendarStore.calendar(id: destinationID)?.allowsContentModifications == true else { return }
        }
        stateStore.update {
            $0.unifiedDestinations?[sourceID] = destinationID
            $0.automaticBlockingEnabled = false
        }
        latestResult = nil
        status = "Output mapping saved. Preview changes before enabling Automatic Blocking."
    }

    func createUnified() {
        do {
            let calendar = try calendarStore.createUnifiedCalendar()
            setUnified(calendar.calendarIdentifier)
            status = "Created a local Unified calendar."
        } catch { status = error.localizedDescription }
    }

    func createValidationEvent() {
        guard let id = selectedTestCalendarID, let calendar = calendarStore.calendar(id: id) else {
            status = "Select one writable calendar for validation."
            return
        }
        guard testStart > Date() else { status = "Choose a future test time."; return }
        do {
            let created = try EventRepository(store: calendarStore.store).createBusyTestEvent(in: calendar, start: testStart)
            stateStore.update { $0.testEventID = created.eventID; $0.testEventToken = created.token; $0.testCalendarID = id; $0.validationCalendarID = nil; $0.validationConfirmed = false }
            status = "Validation event saved. Check its Busy status in Apple Calendar and Outlook Scheduling Assistant, then confirm below."
        } catch { status = error.localizedDescription }
    }

    func confirmValidation() {
        guard stateStore.state.testEventID != nil, let id = stateStore.state.testCalendarID else { return }
        stateStore.update { $0.validationCalendarID = id; $0.validationConfirmed = true }
        status = "Validation confirmed for \(calendarStore.calendars.first(where: { $0.id == id })?.displayName ?? "selected calendar"). Automatic Blocking remains off until you explicitly enable it."
    }

    func deleteValidationEvent() {
        guard let id = stateStore.state.testEventID, let token = stateStore.state.testEventToken else { return }
        do {
            guard let calendarID = stateStore.state.testCalendarID else { throw CalendarSyncError.ownershipUnverified }
            try EventRepository(store: calendarStore.store).deleteTestEvent(eventID: id, token: token, calendarID: calendarID)
            stateStore.update { $0.testEventID = nil; $0.testEventToken = nil; $0.testCalendarID = nil }
            status = "CalendarSync validation event deleted."
        } catch { status = error.localizedDescription }
    }

    func dryRun() {
        let result = engine.run(dryRun: true)
        latestResult = result
        status = "Dry Run complete: \(result.plan.sourceCount) source events, \(result.plan.mutationCount) planned changes. No EventKit changes were made."
    }

    func syncNow() {
        let result = engine.run(dryRun: false)
        latestResult = result
        status = result.applied
            ? "Reconciliation finished with \(result.errorCount) reported issue(s)."
            : (result.messages.first ?? "No calendar changes were made.")
    }

    func previewRollback() {
        calendarStore.reload()
        calendarStore.store.reset()
        rollbackPreview = rollbackController.preview()
        rollbackResult = nil
        showRollback = true
    }

    func rollbackLatestSync() {
        guard let preview = rollbackPreview else { return }
        let result = rollbackController.apply(preview: preview)
        rollbackResult = result
        rollbackPreview = rollbackController.preview()
        latestResult = nil
        status = result.remainingCount == 0
            ? "Rollback complete. Automatic Blocking is off."
            : "Rollback restored \(result.completedCount) change(s); \(result.remainingCount) remain. Automatic Blocking is off."
    }

    func setAutomaticBlocking(_ enabled: Bool) {
        if enabled { showEnableWarning = true }
        else { stateStore.update { $0.automaticBlockingEnabled = false }; status = "Automatic Blocking is off." }
    }

    func confirmEnableAutomaticBlocking() {
        guard stateStore.state.validationConfirmed else { return }
        stateStore.update { $0.automaticBlockingEnabled = true }
        status = "Automatic Blocking enabled. Manual sync, Shortcuts, and enabled scheduled runs can now apply changes."
    }

    private func synchronizeSelectionFromState() {
        if selectedTestCalendarID == nil { selectedTestCalendarID = stateStore.state.testCalendarID ?? stateStore.state.validationCalendarID }
    }

    private func updateAccessStatus() {
        guard calendarStore.calendars.isEmpty else { return }
        switch calendarStore.authorizationStatus {
        case .notDetermined:
            status = "Ready. Calendar access has not been requested."
        case .denied:
            status = "Calendar access is off. Enable it in System Settings → Privacy & Security → Calendars."
        case .restricted:
            status = "Calendar access is restricted by macOS or device policy."
        case .writeOnly:
            status = "CalendarSync needs full calendar access to list your calendars."
        default:
            status = "No calendars are available. Check Calendar accounts in System Settings."
        }
    }
}

struct SettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore
    @State private var showResult = false
    @State private var calendarSearch = ""
    @State private var targetedDropRoles: Set<CalendarRole> = []

    private var state: CalendarSyncState { stateStore.state }
    private var unifiedChoices: [CalendarChoice] { model.calendarStore.calendars.filter { $0.isWritable } }
    private var filteredCalendars: [CalendarChoice] {
        let query = calendarSearch.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return model.calendarStore.calendars }
        return model.calendarStore.calendars.filter {
            $0.title.localizedCaseInsensitiveContains(query) || $0.sourceTitle.localizedCaseInsensitiveContains(query)
        }
    }
    private var configurableCalendars: [CalendarChoice] {
        filteredCalendars.filter { !state.unifiedOutputCalendarIDs.contains($0.id) }
    }

    private func accountGroups(for role: CalendarRole) -> [CalendarAccountGroup] {
        Dictionary(grouping: configurableCalendars.filter { state.role(for: $0.id, unifiedID: state.unifiedCalendarID) == role }, by: \.sourceTitle)
            .map { CalendarAccountGroup(sourceTitle: $0.key, calendars: $0.value.sorted { $0.title.localizedCaseInsensitiveCompare($1.title) == .orderedAscending }) }
            .sorted { $0.sourceTitle.localizedCaseInsensitiveCompare($1.sourceTitle) == .orderedAscending }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                header

                GroupBox {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack(alignment: .top) {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Choose where events appear and how availability is shared.")
                                    .font(.headline)
                                Text("Block + view copies events to Unified and blocks time across other Block + view calendars. View only adds events to Unified without creating blockers.")
                                    .foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button {
                                model.reload()
                            } label: {
                                Label("Refresh", systemImage: "arrow.clockwise")
                            }
                            .controlSize(.small)
                            .help("Reload calendars from macOS")
                            Button {
                                model.openAccountsSettings()
                            } label: {
                                Label("Add account", systemImage: "person.crop.circle.badge.plus")
                            }
                            .controlSize(.small)
                            .help("Add a calendar account in System Settings")
                        }

                        if model.calendarStore.calendars.isEmpty {
                            ContentUnavailableView {
                                Label("Connect your calendars", systemImage: "calendar.badge.exclamationmark")
                            } description: {
                                Text(model.calendarStore.authorizationMessage)
                            } actions: {
                                Button {
                                    if model.calendarStore.authorizationStatus == .denied || model.calendarStore.authorizationStatus == .restricted {
                                        model.openCalendarSettings()
                                    } else {
                                        Task { await model.requestAccess() }
                                    }
                                } label: {
                                    Label(
                                        model.calendarStore.authorizationStatus == .denied || model.calendarStore.authorizationStatus == .restricted
                                            ? "Open Calendar Settings"
                                            : "Grant Calendar Access",
                                        systemImage: model.calendarStore.authorizationStatus == .denied || model.calendarStore.authorizationStatus == .restricted
                                            ? "gear"
                                            : "lock.open"
                                    )
                                }
                            }
                        } else {
                            unifiedDestinationCard

                            HStack {
                                Spacer()
                                VStack(spacing: 2) {
                                    Image(systemName: "arrow.up")
                                        .font(.caption.weight(.semibold))
                                    Text("Included events flow into Unified")
                                        .font(.caption2)
                                }
                                .foregroundStyle(Color.accentColor)
                                Spacer()
                            }

                            HStack {
                                Label("Calendar roles", systemImage: "hand.draw")
                                    .font(.subheadline.weight(.semibold))
                                Spacer()
                                Text("Drag a card to change its role, or use its menu.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }

                            if model.calendarStore.calendars.count > 6 {
                                TextField("Filter calendars or accounts", text: $calendarSearch)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 360)
                            }

                            HStack(alignment: .top, spacing: 12) {
                                roleColumn(.shareAvailability)
                                roleColumn(.unifiedOnly)
                                roleColumn(.excluded)
                            }
                            .animation(.snappy(duration: 0.22), value: state.sourceCalendarIDs)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Calendar setup", systemImage: "calendar.badge.gearshape")
                        .font(.headline)
                }

                GroupBox {
                    SyncWindowSettingsView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } label: {
                    Label("Sync window", systemImage: "calendar.badge.clock")
                        .font(.headline)
                }

                GroupBox {
                    ScheduleSettingsView()
                } label: {
                    Label("Schedule", systemImage: "clock.arrow.circlepath")
                        .font(.headline)
                }

                HStack(spacing: 10) {
                    Button {
                        model.showValidation = true
                    } label: {
                        Label(state.validationConfirmed ? "View validation…" : "Validate calendar…", systemImage: "checkmark.shield")
                    }

                    Button {
                        model.showSafetySettings = true
                    } label: {
                        Label("Safety settings…", systemImage: "lock.shield")
                    }

                    Spacer()

                    Button {
                        model.dryRun()
                        showResult = true
                    } label: {
                        Label("Preview changes", systemImage: "doc.text.magnifyingglass")
                    }

                    Button {
                        model.syncNow()
                        showResult = true
                    } label: {
                        Label("Sync now", systemImage: "arrow.triangle.2.circlepath")
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(!state.hasUnifiedConfiguration)
                    if let lastSync = state.lastSync {
                        Text("Last sync \(lastSync.formatted(date: .abbreviated, time: .shortened))")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                GroupBox {
                    VStack(alignment: .leading, spacing: 6) {
                        Text(model.status)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if let result = model.latestResult {
                            Text("\(result.plan.sourceCount) source events · \(result.plan.mutationCount) planned changes · \(result.plan.skippedCount) skipped · \(result.errorCount) issues")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let issue = stateStore.recoveryError {
                            Text(issue).foregroundStyle(.red)
                        }
                        if let pending = state.leftoverCleanup, !pending.isEmpty {
                            Text("\(pending.count) leftover cleanup item(s) remain. Sync is paused until cleanup finishes.")
                                .font(.caption)
                                .foregroundStyle(.orange)
                        }
                        if let journal = state.rollback, !journal.entries.isEmpty {
                            HStack {
                                Text(journal.rollbackStarted ? "A rollback is pending. Finish it before syncing again." : "The latest sync has a saved rollback snapshot.")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button(journal.rollbackStarted ? "Resume rollback…" : "Rollback latest sync…") {
                                    model.previewRollback()
                                }
                            }
                        }
                    }
                } label: {
                    Label("Activity", systemImage: "text.alignleft")
                        .font(.headline)
                }
            }
        }
        .padding(20)
        .frame(minWidth: 1040, minHeight: 700, alignment: .top)
        .sheet(isPresented: $showResult) {
            if let result = model.latestResult {
                PlanResultView(result: result, calendars: model.calendarStore.calendars, unifiedCalendarID: state.unifiedCalendarID,
                               unifiedDestinations: state.unifiedDestinations)
            }
        }
        .sheet(isPresented: $model.showValidation) {
            ValidationView()
                .environmentObject(model)
                .environmentObject(stateStore)
        }
        .sheet(isPresented: $model.showSafetySettings) {
            SafetySettingsView()
                .environmentObject(model)
                .environmentObject(stateStore)
        }
        .sheet(isPresented: $model.showRollback) {
            RollbackView()
                .environmentObject(model)
                .environmentObject(stateStore)
        }
        .onAppear { model.reload(); model.mainWindowAppeared() }
        .onReceive(Timer.publish(every: 30, on: .main, in: .common).autoconnect()) { _ in
            model.refreshScheduleStatus()
        }
    }

    private var header: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.clock")
                .font(.system(size: 26, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 52, height: 52)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 13))

            VStack(alignment: .leading, spacing: 3) {
                Text("CalendarSync")
                    .font(.largeTitle.bold())
                Text("Bring your availability together, safely.")
                    .foregroundStyle(.secondary)
            }

            Spacer()

            Button {
                model.minimizeToMenuBar()
            } label: {
                Label("Minimize to menu bar", systemImage: "menubar.arrow.up.rectangle")
            }
            .help("Hide the window and Dock icon; reopen CalendarSync from the menu bar.")

            Label(
                state.automaticBlockingEnabled ? "Blocking on" : state.validationConfirmed ? "Validated · off" : "Setup needed",
                systemImage: state.automaticBlockingEnabled ? "checkmark.circle.fill" : state.validationConfirmed ? "checkmark.circle" : "lock.circle"
            )
            .font(.callout.weight(.medium))
            .padding(.horizontal, 11)
            .padding(.vertical, 7)
            .background(Color(nsColor: .controlBackgroundColor), in: Capsule())
        }
    }

    private var unifiedDestinationCard: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Label("Unified outputs", systemImage: "calendar.badge.checkmark")
                    .font(.headline)
                Spacer()
                Picker("Copy events to", selection: Binding(
                    get: { state.unifiedDestinations != nil }, set: { model.setSeparateOutputs($0) }
                )) {
                    Text("One calendar").tag(false)
                    Text("Map each source").tag(true)
                }
                .frame(maxWidth: 340)
            }
            if state.unifiedDestinations != nil {
                Text("Create dedicated output calendars in Apple Calendar, then map each included source below. Multiple sources can share an output. Events use the output calendar's color; use separate outputs to preserve different source colors.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                let sources = model.calendarStore.calendars.filter { state.configuredSourceCalendarIDs.contains($0.id) }
                if sources.isEmpty {
                    Text("Include source calendars using the roles below to add mapping rows.")
                        .foregroundStyle(.secondary)
                }
                ForEach(sources) { source in outputMappingRow(source) }
                if !state.hasUnifiedConfiguration && !sources.isEmpty {
                    Label("Choose a writable output for every included source before syncing.", systemImage: "exclamationmark.triangle")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
            } else {
                singleUnifiedDestination
            }
        }
        .padding(14)
        .background(Color.accentColor.opacity(0.07), in: RoundedRectangle(cornerRadius: 14))
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(Color.accentColor.opacity(0.22), lineWidth: 1)
        }
    }

    private func outputMappingRow(_ source: CalendarChoice) -> some View {
        let destinationID = state.unifiedDestinations?[source.id]
        let choices = unifiedChoices.filter { !state.configuredSourceCalendarIDs.contains($0.id) }
        let destination = model.calendarStore.calendars.first { $0.id == destinationID }
        return HStack(spacing: 12) {
            Circle().fill(Color(nsColor: source.color ?? .secondaryLabelColor)).frame(width: 12, height: 12)
            Text(source.displayName).lineLimit(1).truncationMode(.middle)
                .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "arrow.right").foregroundStyle(.secondary)
            Circle().fill(Color(nsColor: destination?.color ?? .secondaryLabelColor)).frame(width: 12, height: 12)
            Picker("Output for \(source.displayName)", selection: Binding(
                get: { state.unifiedDestinations?[source.id] }, set: { model.setOutput($0, for: source.id) }
            )) {
                Text("Choose an output calendar…").tag(String?.none)
                if let destinationID, !choices.contains(where: { $0.id == destinationID }) {
                    Text("\(destination?.displayName ?? "Unavailable output") — needs attention").tag(Optional(destinationID))
                }
                ForEach(choices) { Text($0.displayName).tag(Optional($0.id)) }
            }
            .labelsHidden()
            .frame(maxWidth: .infinity)
        }
        .padding(.vertical, 3)
    }

    private var singleUnifiedDestination: some View {
        HStack(spacing: 14) {
            Image(systemName: "calendar.badge.checkmark")
                .font(.system(size: 23, weight: .semibold))
                .symbolRenderingMode(.hierarchical)
                .foregroundStyle(Color.accentColor)
                .frame(width: 48, height: 48)
                .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 12))

            VStack(alignment: .leading, spacing: 3) {
                Text("Unified calendar")
                    .font(.headline)
                Text("Your combined schedule appears here. It is never used as a source.")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 12)

            Picker("Unified calendar", selection: Binding(get: { state.unifiedCalendarID }, set: { model.setUnified($0) })) {
                Text("Choose a calendar…").tag(String?.none)
                ForEach(unifiedChoices) { Text($0.displayName).tag(Optional($0.id)) }
            }
            .frame(maxWidth: 300)

            Button {
                model.createUnified()
            } label: {
                Label("Create local", systemImage: "plus")
            }
        }
    }

    private func roleColumn(_ role: CalendarRole) -> some View {
        let groups = accountGroups(for: role)
        let targeted = targetedDropRoles.contains(role)
        let calendars = groups.flatMap(\.calendars)

        return VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 9) {
                Image(systemName: role.symbol)
                    .font(.system(size: 16, weight: .semibold))
                    .foregroundStyle(role.tint)
                    .frame(width: 32, height: 32)
                    .background(role.tint.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 1) {
                    Text(role.label)
                        .font(.headline)
                    Text(role.explanation)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
                Spacer(minLength: 4)
                Text("\(calendars.count)")
                    .font(.caption.weight(.semibold).monospacedDigit())
                    .foregroundStyle(role.tint)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(role.tint.opacity(0.10), in: Capsule())
            }

            Divider()

            if groups.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "tray.and.arrow.down")
                        .font(.title2)
                        .foregroundStyle(role.tint.opacity(0.8))
                    Text("Drag calendars here")
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, minHeight: 140)
            } else {
                ForEach(groups) { group in
                    VStack(alignment: .leading, spacing: 7) {
                        Label(group.sourceTitle, systemImage: "person.crop.square")
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)

                        ForEach(group.calendars) { calendar in
                            calendarCard(calendar, role: role)
                        }
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, minHeight: 240, alignment: .topLeading)
        .background(
            targeted ? role.tint.opacity(0.10) : Color(nsColor: .controlBackgroundColor),
            in: RoundedRectangle(cornerRadius: 14)
        )
        .overlay {
            RoundedRectangle(cornerRadius: 14)
                .strokeBorder(
                    targeted ? role.tint.opacity(0.85) : Color.secondary.opacity(0.16),
                    style: StrokeStyle(lineWidth: targeted ? 2 : 1, dash: targeted ? [] : [6, 4])
                )
        }
        .animation(.easeInOut(duration: 0.15), value: targeted)
        .dropDestination(for: String.self) { calendarIDs, _ in
            let movable = calendarIDs.compactMap { id in model.calendarStore.calendars.first { $0.id == id } }
                .filter { !state.unifiedOutputCalendarIDs.contains($0.id) && (role != .shareAvailability || $0.isWritable) }
            guard !movable.isEmpty else { return false }
            withAnimation(.snappy(duration: 0.22)) {
                movable.forEach { model.setCalendarRole($0.id, role: role) }
            }
            return true
        } isTargeted: { isTargeted in
            if isTargeted { targetedDropRoles.insert(role) }
            else { targetedDropRoles.remove(role) }
        }
    }

    private func calendarCard(_ calendar: CalendarChoice, role: CalendarRole) -> some View {
        HStack(spacing: 9) {
            Image(systemName: calendarSymbol(calendar))
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(role.tint)
                .frame(width: 25)

            VStack(alignment: .leading, spacing: 2) {
                Text(calendar.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(calendar.isWritable ? "Writable" : "Read only")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 2)

            Menu {
                ForEach([CalendarRole.shareAvailability, .unifiedOnly, .excluded], id: \.self) { destinationRole in
                    Button {
                        model.setCalendarRole(calendar.id, role: destinationRole)
                    } label: {
                        Label(destinationRole.label, systemImage: destinationRole.symbol)
                    }
                    .disabled(destinationRole == .shareAvailability && !calendar.isWritable)
                }
            } label: {
                Image(systemName: "ellipsis.circle")
                    .font(.system(size: 16))
                    .foregroundStyle(.secondary)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .help("Change calendar role")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 9)
        .background(Color(nsColor: .windowBackgroundColor), in: RoundedRectangle(cornerRadius: 11))
        .overlay {
            RoundedRectangle(cornerRadius: 11)
                .strokeBorder(Color.secondary.opacity(0.13), lineWidth: 1)
        }
        .contentShape(RoundedRectangle(cornerRadius: 11))
        .draggable(calendar.id)
        .accessibilityLabel("\(calendar.title), \(calendar.isWritable ? "writable" : "read only"), \(role.label)")
        .help("Drag to another column to change its role")
    }

    private func calendarSymbol(_ calendar: CalendarChoice) -> String {
        let title = calendar.title.localizedLowercase
        if title.contains("birthday") { return "gift" }
        if title.contains("holiday") { return "sun.max" }
        return "calendar"
    }
}

private struct CalendarAccountGroup: Identifiable {
    let sourceTitle: String
    let calendars: [CalendarChoice]
    var id: String { sourceTitle }
}

private extension CalendarRole {
    var symbol: String {
        switch self {
        case .shareAvailability: "arrow.left.arrow.right"
        case .unifiedOnly: "eye"
        case .excluded: "minus.circle"
        case .unifiedOutput: "calendar.badge.checkmark"
        }
    }

    var explanation: String {
        switch self {
        case .shareAvailability: "Add to Unified and share Busy time"
        case .unifiedOnly: "Add to Unified only"
        case .excluded: "Leave out of CalendarSync"
        case .unifiedOutput: "Combined calendar destination"
        }
    }

    var tint: Color {
        switch self {
        case .shareAvailability: .accentColor
        case .unifiedOnly: .teal
        case .excluded: .secondary
        case .unifiedOutput: .accentColor
        }
    }
}

private struct SyncWindowSettingsView: View {
    @EnvironmentObject private var stateStore: SyncStateStore
    @State private var useCustomMonths = false
    private let presets = Array(1...12) + [18, 24, 36]
    private var state: CalendarSyncState { stateStore.state }
    private var futureMonths: Binding<Int> {
        Binding(get: { state.lookAheadMonths }, set: { months in
            stateStore.update { $0.futureMonths = months }
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 20) {
                Picker("Look ahead", selection: Binding(
                    get: { useCustomMonths || !presets.contains(state.lookAheadMonths) ? 0 : state.lookAheadMonths },
                    set: { months in
                        useCustomMonths = months == 0
                        if months != 0 { futureMonths.wrappedValue = months }
                    }
                )) {
                    ForEach(presets, id: \.self) { months in Text(months == 1 ? "1 month" : "\(months) months").tag(months) }
                    Text("Custom…").tag(0)
                }
                .frame(maxWidth: 260)
                if useCustomMonths || !presets.contains(state.lookAheadMonths) {
                    Stepper(state.lookAheadMonths == 1 ? "1 month" : "\(state.lookAheadMonths) months", value: futureMonths, in: 1...36)
                        .fixedSize()
                }
                Spacer(minLength: 0)
            }
            Stepper("Include past \(state.pastDays) days", value: Binding(
                get: { state.pastDays }, set: { days in stateStore.update { $0.pastDays = days } }
            ), in: 0...30)
            .fixedSize()
            Text("Uses calendar months from today for Unified copies and Busy blocks in previews, Sync now, and Shortcuts. Set past days to 0 for upcoming events only. Reducing the window leaves existing events outside it untouched.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

private struct SafetySettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore

    private var state: CalendarSyncState { stateStore.state }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Safety & Blocking", systemImage: "lock.shield")
                .font(.title2.bold())
            Text("Automatic blocking is an explicit apply gate. CalendarSync only creates, updates, or removes events it can verify as its own.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Automatic blocking")
                                .font(.headline)
                            Text("Runs from Sync now, Shortcuts, or an enabled schedule.")
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Toggle("", isOn: Binding(get: { state.automaticBlockingEnabled }, set: { model.setAutomaticBlocking($0) }))
                            .labelsHidden()
                            .disabled(!state.validationConfirmed)
                    }

                    if state.validationConfirmed {
                        Label(
                            "Validation confirmed · \(model.calendarStore.calendars.first(where: { $0.id == state.validationCalendarID })?.displayName ?? "calendar")",
                            systemImage: "checkmark.seal.fill"
                        )
                        .font(.callout.weight(.medium))
                        .foregroundStyle(.green)
                    } else {
                        Label("Complete Calendar Validation before enabling blocking. Open it from the CalendarSync menu or use Validate calendar on the main screen.", systemImage: "lock.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }

                    Divider()

                    Toggle("Include tentative events as busy", isOn: Binding(get: { state.blockTentative }, set: { enabled in stateStore.update { $0.blockTentative = enabled } }))
                    Text("Unknown availability is skipped. Working-location status is not available through EventKit.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 680, height: 390)
        .confirmationDialog("Enable Automatic Blocking?", isPresented: $model.showEnableWarning, titleVisibility: .visible) {
            Button("Enable Automatic Blocking", role: .destructive) { model.confirmEnableAutomaticBlocking() }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("CalendarSync will create and maintain anonymized Busy events in the other selected calendars, and update or delete only events it can positively identify as its own. Original events remain untouched. You can turn this off at any time.")
        }
    }
}

private struct ValidationView: View {
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore

    private var state: CalendarSyncState { stateStore.state }
    private var writableChoices: [CalendarChoice] {
        model.calendarStore.calendars.filter { $0.isWritable && !state.unifiedOutputCalendarIDs.contains($0.id) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("Calendar Validation", systemImage: "checkmark.shield")
                .font(.title2.bold())
            Text("Create one temporary Busy event in a writable calendar, confirm Outlook sees the time as unavailable, then remove the test event. This confirmation unlocks the Automatic Blocking opt-in.")
                .foregroundStyle(.secondary)

            GroupBox {
                VStack(alignment: .leading, spacing: 12) {
                    HStack(spacing: 12) {
                        Picker("Test calendar", selection: $model.selectedTestCalendarID) {
                            Text("Choose a writable calendar…").tag(String?.none)
                            ForEach(writableChoices) { Text($0.displayName).tag(Optional($0.id)) }
                        }
                        DatePicker("Future test time", selection: $model.testStart, in: Date()..., displayedComponents: [.date, .hourAndMinute])
                    }

                    HStack(spacing: 8) {
                        Button {
                            model.createValidationEvent()
                        } label: {
                            Label("Create test event", systemImage: "plus.circle")
                        }
                        .disabled(model.selectedTestCalendarID == nil || state.testEventID != nil)

                        if state.testEventID != nil {
                            Button {
                                model.confirmValidation()
                            } label: {
                                Label("Confirm Outlook shows Busy", systemImage: "checkmark.circle")
                            }
                            .disabled(state.validationConfirmed)

                            Button("Delete test event", role: .destructive) {
                                model.deleteValidationEvent()
                            }
                        }
                        Spacer()
                    }

                    Label(
                        state.validationConfirmed
                            ? "Validated: \(model.calendarStore.calendars.first(where: { $0.id == state.validationCalendarID })?.displayName ?? "calendar")"
                            : state.testEventID != nil
                                ? "Test event created. Check Outlook Scheduling Assistant before confirming."
                                : "Not validated yet",
                        systemImage: state.validationConfirmed ? "checkmark.seal.fill" : "hourglass"
                    )
                    .font(.callout.weight(.medium))
                    .foregroundStyle(state.validationConfirmed ? Color.green : Color.secondary)

                    if let id = state.testEventID {
                        DisclosureGroup("Test event details") {
                            Text("Event ID: \(id)\nCalendar ID: \(state.testCalendarID ?? "unknown")")
                                .font(.caption.monospaced())
                                .textSelection(.enabled)
                                .padding(.top, 4)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            HStack {
                Text(model.status)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 720, height: 400)
        .onAppear { model.reload() }
    }
}

private struct PreviewEventGroup: Identifiable {
    let source: SourceKey?
    let summary: SourceEventSummary?
    let operations: [ReconciliationOperation]
    let allOperations: [ReconciliationOperation]

    var id: String {
        source?.description ?? "unscoped:" + operations.map(\.id).sorted().joined(separator: "|")
    }
}

private enum PlanResultFilter: String, CaseIterable, Identifiable {
    case all = "All actions"
    case creates = "Creates"
    case updates = "Updates"
    case removals = "Removals"
    case skipped = "Skipped"
    case issues = "Issues"

    var id: String { rawValue }
}

private struct PlanResultView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var filter: PlanResultFilter = .all
    @State private var searchText = ""
    @State private var expandedGroups: Set<String> = []

    let result: SyncRunResult
    let calendars: [CalendarChoice]
    let unifiedCalendarID: String?
    var unifiedDestinations: [String: String]? = nil

    private var unifiedActions: Int {
        if result.applied { return result.successfulUnifiedChanges }
        return result.plan.operations.filter { operation in
            switch operation {
            case .create(_, .unified, _), .update(_, _, .unified, _), .delete(_, _, .unified, _): true
            default: false
            }
        }.count
    }
    private var busyBlockActions: Int {
        if result.applied { return result.successfulBlockerChanges }
        return result.plan.operations.filter { operation in
            switch operation {
            case .create(_, .blocker, _), .update(_, _, .blocker, _), .delete(_, _, .blocker, _): true
            default: false
            }
        }.count
    }
    private var skipped: Int { result.plan.skippedCount }

    private var groupedEvents: [PreviewEventGroup] {
        Dictionary(grouping: result.plan.operations, by: sourceKey(for:)).map { source, operations in
            PreviewEventGroup(
                source: source,
                summary: source.flatMap { result.plan.sourceSummaries[$0] },
                operations: operations,
                allOperations: operations
            )
        }
        .sorted {
            let leftDate = $0.summary?.start ?? $0.source?.occurrence ?? .distantPast
            let rightDate = $1.summary?.start ?? $1.source?.occurrence ?? .distantPast
            if leftDate != rightDate { return leftDate < rightDate }
            return ($0.summary?.title ?? "").localizedCaseInsensitiveCompare($1.summary?.title ?? "") == .orderedAscending
        }
    }

    private var visibleGroups: [PreviewEventGroup] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return groupedEvents.compactMap { group in
            let groupText = [group.summary?.title, group.summary.map { calendarName($0.calendarID) }]
                .compactMap { $0 }
                .joined(separator: " ")
            let groupMatchesSearch = query.isEmpty || groupText.localizedCaseInsensitiveContains(query)
            let operations = group.operations.filter { operation in
                matchesFilter(operation)
                    && (groupMatchesSearch || query.isEmpty || searchText(for: operation).localizedCaseInsensitiveContains(query))
            }
            guard !operations.isEmpty else { return nil }
            return PreviewEventGroup(source: group.source, summary: group.summary, operations: operations, allOperations: group.allOperations)
        }
    }

    private var visibleActionCount: Int { visibleGroups.reduce(0) { $0 + $1.operations.count } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: result.applied ? (result.errorCount > 0 ? "exclamationmark.triangle.fill" : "checkmark.circle.fill") : "doc.text.magnifyingglass")
                    .font(.system(size: 28))
                    .foregroundStyle(result.applied ? (result.errorCount > 0 ? Color.orange : Color.green) : Color.accentColor)
                VStack(alignment: .leading, spacing: 4) {
                    Text(result.applied ? (result.errorCount > 0 ? "Sync completed with issues" : "Sync summary") : "Preview changes")
                        .font(.title2.bold())
                    Text(result.applied
                         ? "\(result.successfulChangeCount) changes saved. Source events were not edited."
                         : "Preview only — no calendar changes were made. Source events are never edited.")
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }

            HStack(spacing: 10) {
                metric("Events scanned", value: result.plan.sourceCount, symbol: "calendar")
                metric("Unified copies", value: unifiedActions, symbol: "calendar.badge.plus")
                metric("Busy blocks", value: busyBlockActions, symbol: "lock.fill")
                metric("Skipped", value: skipped, symbol: "forward")
                metric("Issues", value: result.errorCount, symbol: "exclamationmark.triangle")
            }

            HStack(spacing: 10) {
                Picker("Show", selection: $filter) {
                    ForEach(PlanResultFilter.allCases) { Text($0.rawValue).tag($0) }
                }
                .frame(width: 150)

                TextField("Search events or calendars", text: $searchText)
                    .textFieldStyle(.roundedBorder)

                Text("\(visibleGroups.count) events · \(visibleActionCount) actions")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if visibleGroups.isEmpty {
                ContentUnavailableView(
                    result.plan.operations.isEmpty ? "Nothing to change" : "No matching actions",
                    systemImage: result.plan.operations.isEmpty ? "checkmark.circle" : "magnifyingglass",
                    description: Text(result.plan.operations.isEmpty ? "The selected calendars are already in sync for this period." : "Try another filter or search term.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(visibleGroups) { group in
                            eventGroupRow(group)
                            if group.id != visibleGroups.last?.id {
                                Divider().padding(.leading, 42)
                            }
                        }
                    }
                }
                .frame(maxHeight: .infinity)
                .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
            }

            if !result.messages.isEmpty {
                VStack(alignment: .leading, spacing: 5) {
                    ForEach(result.messages, id: \.self) { message in
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }

            HStack {
                Text("\(result.plan.mutationCount) planned changes · \(result.errorCount) issues")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(22)
        .frame(width: 880, height: 650)
    }

    private func metric(_ title: String, value: Int, symbol: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Label(title, systemImage: symbol)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Text(value.formatted())
                .font(.title2.weight(.semibold).monospacedDigit())
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(12)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
    }

    private func calendarName(_ id: String) -> String {
        calendars.first(where: { $0.id == id })?.displayName ?? "Unavailable calendar"
    }

    private func matchesFilter(_ operation: ReconciliationOperation) -> Bool {
        switch (filter, operation) {
        case (.all, _), (.creates, .create), (.updates, .update), (.removals, .delete), (.skipped, .skip), (.issues, .error): true
        default: false
        }
    }

    private func searchText(for operation: ReconciliationOperation) -> String {
        let source: SourceKey?
        let destination: String?
        switch operation {
        case let .create(key, _, calendar), let .update(_, key, _, calendar), let .delete(_, key, _, calendar):
            source = key
            destination = calendar
        case let .skip(key, _):
            source = key
            destination = nil
        case let .error(key, calendar, _):
            source = key
            destination = calendar
        }
        let event = source.flatMap { result.plan.sourceSummaries[$0] }
        return [event?.title, event.map { calendarName($0.calendarID) }, destination.map(calendarName), operationDescription(operation)]
            .compactMap { $0 }
            .joined(separator: " ")
    }

    private func operationDescription(_ operation: ReconciliationOperation) -> String {
        switch operation {
        case let .create(_, kind, _): "Create \(kind == .unified ? "Unified copy" : "Busy block")"
        case let .update(_, _, kind, _): "Update \(kind == .unified ? "Unified copy" : "Busy block")"
        case let .delete(_, _, kind, _): "Remove owned \(kind == .unified ? "Unified copy" : "Busy block")"
        case let .skip(_, reason), let .error(_, _, reason): reason
        }
    }

    private func sourceKey(for operation: ReconciliationOperation) -> SourceKey? {
        switch operation {
        case let .create(source, _, _), let .update(_, source, _, _), let .delete(_, source, _, _), let .skip(source, _): source
        case let .error(source, _, _): source
        }
    }

    private func eventGroupRow(_ group: PreviewEventGroup) -> some View {
        DisclosureGroup(isExpanded: Binding(
            get: { expandedGroups.contains(group.id) },
            set: { isExpanded in
                if isExpanded { expandedGroups.insert(group.id) }
                else { expandedGroups.remove(group.id) }
            }
        )) {
            eventGroupDetails(group)
                .padding(.leading, 28)
                .padding(.trailing, 12)
                .padding(.bottom, 10)
        } label: {
            eventGroupHeading(group)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .contentShape(Rectangle())
    }

    private func eventGroupHeading(_ group: PreviewEventGroup) -> some View {
        let eventTitle = group.summary.map(\.title).flatMap { $0.isEmpty ? nil : $0 } ?? "Calendar event"
        return VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline) {
                Text(eventTitle)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                Spacer(minLength: 10)
                Text("\(group.operations.count) \(group.operations.count == 1 ? "action" : "actions")")
                    .font(.caption.weight(.medium))
                    .foregroundStyle(.secondary)
            }
            if let summary = group.summary {
                Text("\(dateText(summary))  ·  From \(calendarName(summary.calendarID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else if let source = group.source {
                Text("\(source.occurrence.formatted(date: .abbreviated, time: .shortened))  ·  From \(calendarName(source.calendarID))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            } else {
                Text("Calendar configuration")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private func eventGroupDetails(_ group: PreviewEventGroup) -> some View {
        let unifiedOperations = group.operations.filter { operation in
            switch operation {
            case .create(_, .unified, _), .update(_, _, .unified, _), .delete(_, _, .unified, _): true
            default: false
            }
        }
        let busyOperations = group.operations.filter { operation in
            switch operation {
            case .create(_, .blocker, _), .update(_, _, .blocker, _), .delete(_, _, .blocker, _): true
            default: false
            }
        }
        let skipOrIssue = group.allOperations.contains { operation in
            switch operation {
            case .skip, .error: true
            default: false
            }
        }
        let hasUnifiedChange = group.allOperations.contains { operation in
            switch operation {
            case .create(_, .unified, _), .update(_, _, .unified, _), .delete(_, _, .unified, _): true
            default: false
            }
        }
        let hasBusyChange = group.allOperations.contains { operation in
            switch operation {
            case .create(_, .blocker, _), .update(_, _, .blocker, _), .delete(_, _, .blocker, _): true
            default: false
            }
        }

        VStack(alignment: .leading, spacing: 8) {
            if let summary = group.summary {
                detailLine(
                    "Source",
                    detail: "Stays as is in \(calendarName(summary.calendarID))",
                    symbol: "arrow.uturn.backward"
                )
            }

            if !unifiedOperations.isEmpty {
                ForEach(unifiedOperations) { operation in operationDetail(operation) }
            } else if group.summary != nil && !skipOrIssue && !hasUnifiedChange {
                detailLine(
                    "Unified",
                    detail: "Already up to date in \((unifiedDestinations == nil ? unifiedCalendarID : group.summary.flatMap { unifiedDestinations?[$0.calendarID] }).map(calendarName) ?? "Unified")",
                    symbol: "checkmark.circle"
                )
            }

            if !busyOperations.isEmpty {
                ForEach(busyOperations) { operation in operationDetail(operation) }
            } else if group.summary != nil && !skipOrIssue && !hasBusyChange {
                detailLine("Busy blocks", detail: group.summary?.blockerDetail ?? "No blocker changes planned", symbol: "lock")
            }

            ForEach(group.operations.filter { operation in
                switch operation {
                case .skip, .error: true
                default: false
                }
            }) { operation in
                operationDetail(operation)
            }
        }
        .padding(.top, 8)
    }

    private func detailLine(_ title: String, detail: String, symbol: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: symbol)
                .frame(width: 16)
                .foregroundStyle(.secondary)
            Text(title).fontWeight(.medium)
            Text(detail).foregroundStyle(.secondary)
        }
        .font(.callout)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    @ViewBuilder
    private func operationDetail(_ operation: ReconciliationOperation) -> some View {
        switch operation {
        case let .create(_, kind, destination):
            detailLine("\(kind == .unified ? "Unified" : "Busy")", detail: kind == .unified ? "Create copy in \(calendarName(destination))" : "Create Busy block in \(calendarName(destination))", symbol: kind == .unified ? "calendar.badge.plus" : "lock.fill")
        case let .update(_, _, kind, destination):
            detailLine("\(kind == .unified ? "Unified" : "Busy")", detail: kind == .unified ? "Update copy in \(calendarName(destination))" : "Update Busy block in \(calendarName(destination))", symbol: "arrow.triangle.2.circlepath")
        case let .delete(_, _, kind, destination):
            detailLine("\(kind == .unified ? "Unified" : "Busy")", detail: "Remove CalendarSync-owned item from \(calendarName(destination))", symbol: "minus.circle")
        case let .skip(_, reason):
            detailLine("Skipped", detail: reason, symbol: "forward")
        case let .error(_, destination, reason):
            detailLine("Needs attention", detail: "\(destination.map(calendarName).map { "\($0) · " } ?? "")\(reason)", symbol: "exclamationmark.triangle")
        }
    }

    private func dateText(_ summary: SourceEventSummary) -> String {
        if summary.isAllDay {
            return summary.start.formatted(date: .abbreviated, time: .omitted) + " · all day"
        }
        return summary.start.formatted(date: .abbreviated, time: .shortened)
            + "–" + summary.end.formatted(date: .omitted, time: .shortened)
    }
}
