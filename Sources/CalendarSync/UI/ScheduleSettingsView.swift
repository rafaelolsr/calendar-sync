import SwiftUI

struct ScheduleSettingsView: View {
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var stateStore: SyncStateStore
    @State private var draft = SyncSchedule()

    private func timeBinding(get: @escaping () -> Int, set: @escaping (Int) -> Void) -> Binding<Date> {
        Binding(get: {
            let minute = get()
            return Calendar.current.date(bySettingHour: minute / 60, minute: minute % 60, second: 0, of: Date()) ?? Date()
        }, set: { date in
            let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
            set((parts.hour ?? 0) * 60 + (parts.minute ?? 0))
        })
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("Run", selection: $draft.mode) {
                    ForEach(SyncScheduleMode.allCases, id: \.self) { Text($0.label).tag($0) }
                }
                .frame(maxWidth: 310)
                Spacer()
                Button("Apply schedule") { model.saveSchedule(draft) }
            }
            if draft.mode == .daily {
                DatePicker("At", selection: timeBinding(get: { draft.dailyMinute }, set: { draft.dailyMinute = $0 }),
                           displayedComponents: .hourAndMinute)
                    .frame(maxWidth: 220)
            } else if draft.mode == .severalTimes {
                ForEach(draft.multipleMinutes.indices, id: \.self) { index in
                    HStack {
                        DatePicker("Run \(index + 1)", selection: timeBinding(
                            get: { draft.multipleMinutes.indices.contains(index) ? draft.multipleMinutes[index] : 9 * 60 },
                            set: { if draft.multipleMinutes.indices.contains(index) { draft.multipleMinutes[index] = $0 } }),
                                   displayedComponents: .hourAndMinute)
                            .frame(maxWidth: 240)
                        Button("Remove") { draft.multipleMinutes.remove(at: index) }
                            .disabled(draft.multipleMinutes.count <= 1)
                    }
                }
                Button("Add time") {
                    let used = Set(draft.multipleMinutes)
                    if let minute = (0..<24).map({ $0 * 60 }).first(where: { !used.contains($0) }) {
                        draft.multipleMinutes.append(minute)
                    }
                }
                .disabled(draft.multipleMinutes.count >= 8)
            }
            Text("Uses your saved calendar setup and sync window. Times follow this Mac's time zone. Scheduled sync runs while you are logged in, and catches up after sleep. It pauses when Automatic Blocking is off or recovery is pending.")
                .font(.callout)
                .foregroundStyle(.secondary)

            let saved = stateStore.state.schedule ?? SyncSchedule()
            if saved.isEnabled {
                if model.scheduleJobLoaded {
                    if let next = saved.nextRun(after: Date()) {
                        Text("Next run: \(next.formatted(date: .abbreviated, time: .shortened))")
                            .font(.callout)
                    }
                } else {
                    Label("The schedule is not active in macOS. Apply schedule to register it again.", systemImage: "exclamationmark.triangle")
                        .font(.callout).foregroundStyle(.orange)
                }
                if !stateStore.state.automaticBlockingEnabled {
                    Text("Scheduled changes are paused because Automatic Blocking is off.")
                        .font(.caption).foregroundStyle(.orange)
                }
            } else {
                Text("Scheduled sync is off.").font(.callout).foregroundStyle(.secondary)
            }
            if let report = model.scheduledRunReport {
                Text("Last scheduled run: \(report.finishedAt.formatted(date: .abbreviated, time: .shortened))")
                    .font(.caption).foregroundStyle(.secondary)
                Text(report.summary)
                    .font(.callout)
                    .foregroundStyle(report.issueCount > 0 ? Color.orange : Color.secondary)
                if report.issueCount > 0 {
                    Text("Use Preview changes to inspect current issues.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .onAppear { draft = stateStore.state.schedule ?? SyncSchedule() }
        .onChange(of: stateStore.state.schedule) { _, schedule in draft = schedule ?? SyncSchedule() }
    }
}
