import EventKit
import Foundation
import Combine

@MainActor
final class CalendarStore: ObservableObject {
    let store = EKEventStore()
    @Published var calendars: [CalendarChoice] = []
    @Published var authorizationMessage = "Calendar access not requested"
    @Published private(set) var authorizationStatus = EKEventStore.authorizationStatus(for: .event)

    func requestAccessAndReload() async {
        do {
            let granted: Bool
            if #available(macOS 14.0, *) {
                granted = try await store.requestFullAccessToEvents()
            } else {
                granted = try await store.requestAccess(to: .event)
            }
            authorizationMessage = granted ? "Full calendar access granted" : "Calendar access denied"
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
            if granted {
                store.reset()
                reload()
            }
        } catch {
            authorizationMessage = "Calendar access error: \(error.localizedDescription)"
            authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        }
    }

    func reload() {
        authorizationStatus = EKEventStore.authorizationStatus(for: .event)
        guard authorizationStatus == .fullAccess else {
            calendars = []
            switch authorizationStatus {
            case .notDetermined:
                authorizationMessage = "Calendar access not requested"
            case .denied:
                authorizationMessage = "Calendar access denied in System Settings"
            case .restricted:
                authorizationMessage = "Calendar access is restricted"
            case .writeOnly:
                authorizationMessage = "Full calendar access is required"
            default:
                authorizationMessage = "Full calendar access is required"
            }
            return
        }
        calendars = store.calendars(for: .event)
            .map { calendar in
                CalendarChoice(
                    id: calendar.calendarIdentifier,
                    title: calendar.title,
                    sourceTitle: calendar.source.title,
                    type: String(describing: calendar.type),
                    isWritable: calendar.allowsContentModifications,
                    color: calendar.color
                )
            }
            .sorted { ($0.sourceTitle, $0.title) < ($1.sourceTitle, $1.title) }
    }

    func calendar(id: String) -> EKCalendar? {
        store.calendar(withIdentifier: id)
    }

    func createUnifiedCalendar() throws -> EKCalendar {
        let calendar = EKCalendar(for: .event, eventStore: store)
        calendar.title = "Unified"
        guard let source = store.sources.first(where: { $0.sourceType == .local }) else {
            throw CalendarSyncError.noLocalCalendarSource
        }
        calendar.source = source
        try store.saveCalendar(calendar, commit: true)
        reload()
        return calendar
    }
}
