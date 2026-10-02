import EventKit
import Foundation
import CoreLocation

struct EventRepository: RollbackEventRepository {
    let store: EKEventStore

    func snapshots(calendarIDs: Set<String>, from start: Date, to end: Date, managedRecords: [ManagedEventRecord]) -> [CalendarEventSnapshot] {
        let calendars = store.calendars(for: .event).filter { calendarIDs.contains($0.calendarIdentifier) }
        guard !calendars.isEmpty else { return [] }
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        return store.events(matching: predicate).compactMap { event in
            let key = SourceKey(calendarID: event.calendar.calendarIdentifier, eventID: event.eventIdentifier, occurrence: event.occurrenceDate ?? event.startDate)
            let marker = event.url.flatMap { $0.scheme == "calendarsync" ? $0.host : nil }
            if event.url?.scheme == "calendarsync-test" { return nil }
            let idOwner = managedRecords.first(where: { $0.eventID == event.eventIdentifier })?.id
            let ownershipToken: String?
            if let marker, let idOwner, marker != idOwner { ownershipToken = "conflict-\(idOwner)" }
            else { ownershipToken = marker ?? idOwner }
            return CalendarEventSnapshot(
                key: key,
                calendarID: event.calendar.calendarIdentifier,
                title: event.title ?? "(No title)",
                start: event.startDate,
                end: event.endDate,
                isAllDay: event.isAllDay,
                location: event.location,
                availability: Self.availability(event.availability),
                isCancelled: event.status == .canceled,
                isDeclined: event.attendees?.contains(where: { $0.isCurrentUser && $0.participantStatus == .declined }) ?? false,
                isWorkingLocation: false,
                ownershipToken: ownershipToken
            )
        }
    }

    func ownedEvent(record: ManagedEventRecord) -> EKEvent? {
        if let id = record.eventID, let event = store.event(withIdentifier: id),
           event.calendar.calendarIdentifier == record.destinationCalendarID, marker(of: event) == record.id { return event }
        let calendars = store.calendars(for: .event).filter { $0.calendarIdentifier == record.destinationCalendarID }
        guard let calendar = calendars.first else { return nil }
        let start = record.representedStart.addingTimeInterval(-60 * 60 * 24 * 3)
        let end = record.representedStart.addingTimeInterval(60 * 60 * 24 * 3)
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: [calendar])
        return store.events(matching: predicate).first { marker(of: $0) == record.id }
    }

    func saveGenerated(_ eventSnapshot: CalendarEventSnapshot, kind: GeneratedKind, to calendar: EKCalendar, recordID: String, existing: EKEvent? = nil,
                       beforeCommit: (OwnedEventImage) throws -> Void) throws -> (eventID: String, image: OwnedEventImage) {
        let event = try preparedGeneratedEvent(eventSnapshot, kind: kind, to: calendar, recordID: recordID, existing: existing)
        do {
            try beforeCommit(rollbackImage(of: event, recordID: recordID))
            try store.save(event, span: .thisEvent, commit: true)
        } catch {
            store.reset()
            throw error
        }
        return (event.eventIdentifier, try rollbackImage(of: event, recordID: recordID))
    }

    /// Construct an unsaved event; also used by read-only diagnostics.
    func preparedGeneratedEvent(_ eventSnapshot: CalendarEventSnapshot, kind: GeneratedKind, to calendar: EKCalendar,
                                recordID: String, existing: EKEvent? = nil) throws -> EKEvent {
        guard calendar.allowsContentModifications else { throw CalendarSyncError.readOnlyCalendar }
        if let existing, !(existing.attendees?.isEmpty ?? true) { throw CalendarSyncError.ownershipUnverified }
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = kind == .blocker ? "Busy" : eventSnapshot.title
        event.startDate = eventSnapshot.start
        event.endDate = eventSnapshot.end
        event.isAllDay = eventSnapshot.isAllDay
        event.availability = kind == .blocker ? .busy : ekAvailability(eventSnapshot.availability)
        event.location = kind == .unified ? eventSnapshot.location : nil
        event.notes = nil
        event.url = URL(string: "calendarsync://\(recordID)")
        // Generated copies and blockers should not create extra notifications.
        // An explicit empty list also suppresses calendar-default alerts.
        if existing == nil { event.alarms = [] }
        return event
    }

    func rollbackImage(of event: EKEvent, recordID: String) throws -> OwnedEventImage {
        guard marker(of: event) == recordID else { throw CalendarSyncError.ownershipUnverified }
        guard event.attendees?.isEmpty ?? true else { throw CalendarSyncError.eventHasAttendees }
        guard event.recurrenceRules?.isEmpty ?? true else { throw CalendarSyncError.recurringGeneratedEvent }
        guard let start = event.startDate, let end = event.endDate,
              let url = event.url?.absoluteString else { throw CalendarSyncError.incompleteGeneratedEvent }
        let alarms = try (event.alarms ?? []).map { alarm -> OwnedAlarmImage in
            guard alarm.type == .display || alarm.type == .audio else { throw CalendarSyncError.unsupportedAlarm }
            return OwnedAlarmImage(absoluteDate: alarm.absoluteDate, relativeOffset: alarm.relativeOffset,
                                   soundName: alarm.soundName, location: locationImage(alarm.structuredLocation),
                                   proximity: alarm.proximity.rawValue)
        }
        return OwnedEventImage(title: event.title, start: start, end: end, isAllDay: event.isAllDay,
                               location: event.location, notes: event.notes, url: url,
                               availability: event.availability.rawValue, timeZoneID: event.timeZone?.identifier,
                               alarms: alarms, structuredLocation: locationImage(event.structuredLocation), metadataVersion: 1)
    }

    private func locationImage(_ location: EKStructuredLocation?) -> OwnedLocationImage? {
        guard let location else { return nil }
        return OwnedLocationImage(title: location.title, latitude: location.geoLocation?.coordinate.latitude,
                                  longitude: location.geoLocation?.coordinate.longitude, radius: location.radius)
    }

    private func restoredLocation(_ image: OwnedLocationImage?) -> EKStructuredLocation? {
        guard let image else { return nil }
        let location = EKStructuredLocation(title: image.title ?? "")
        if let latitude = image.latitude, let longitude = image.longitude {
            location.geoLocation = CLLocation(latitude: latitude, longitude: longitude)
        }
        location.radius = image.radius
        return location
    }

    private func rollbackEvent(_ entry: RollbackEntry) throws -> EKEvent? {
        guard EKEventStore.authorizationStatus(for: .event) == .fullAccess else {
            throw CalendarSyncError.fullAccessRequired
        }
        guard let calendar = store.calendar(withIdentifier: entry.record.destinationCalendarID) else {
            throw CalendarSyncError.calendarNotFound
        }
        guard calendar.allowsContentModifications else { throw CalendarSyncError.readOnlyCalendar }
        var candidates: [String: EKEvent] = [:]
        // A changed marker or calendar is a conflict, never proof that an event is absent.
        let ids = Set([entry.record.eventID, entry.previousRecord?.eventID].compactMap { $0 })
        for id in ids {
            if let event = store.event(withIdentifier: id) {
                guard event.calendar.calendarIdentifier == calendar.calendarIdentifier,
                      marker(of: event) == entry.record.id else { throw CalendarSyncError.ownershipUnverified }
                candidates[event.eventIdentifier] = event
            }
        }
        let dates = Set([entry.before?.start, entry.after?.start, entry.record.representedStart].compactMap { $0 })
        for date in dates {
            let predicate = store.predicateForEvents(withStart: date.addingTimeInterval(-3 * 86_400),
                                                     end: date.addingTimeInterval(3 * 86_400), calendars: [calendar])
            for event in store.events(matching: predicate) where marker(of: event) == entry.record.id {
                candidates[event.eventIdentifier] = event
            }
        }
        guard candidates.count <= 1 else { throw CalendarSyncError.ownershipUnverified }
        return candidates.values.first
    }

    func lookupForRollback(_ entry: RollbackEntry) -> OwnedEventLookup {
        do {
            guard let event = try rollbackEvent(entry) else { return .absent }
            return .found(eventID: event.eventIdentifier, image: try rollbackImage(of: event, recordID: entry.record.id))
        } catch { return .conflict(error.localizedDescription) }
    }

    func deleteForRollback(_ entry: RollbackEntry) throws {
        guard let event = try rollbackEvent(entry), let after = entry.after,
              try rollbackImage(of: event, recordID: entry.record.id).matches(after) else { throw RollbackFailure.changed }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    func restoreForRollback(_ image: OwnedEventImage, entry: RollbackEntry) throws -> String {
        let existing = try rollbackEvent(entry)
        if let existing {
            let current = try rollbackImage(of: existing, recordID: entry.record.id)
            if current.matches(image) { return existing.eventIdentifier }
            guard let after = entry.after, current.matches(after) else { throw RollbackFailure.changed }
        } else if entry.after != nil { throw RollbackFailure.changed }
        guard let calendar = store.calendar(withIdentifier: entry.record.destinationCalendarID),
              calendar.allowsContentModifications, image.url == "calendarsync://\(entry.record.id)",
              let availability = EKEventAvailability(rawValue: image.availability) else { throw RollbackFailure.changed }
        let event = existing ?? EKEvent(eventStore: store)
        event.calendar = calendar
        event.timeZone = image.timeZoneID.flatMap { TimeZone(identifier: $0) }
        event.title = image.title
        event.startDate = image.start
        event.endDate = image.end
        event.isAllDay = image.isAllDay
        event.location = image.location
        if image.metadataVersion != nil { event.structuredLocation = restoredLocation(image.structuredLocation) }
        event.notes = image.notes
        event.url = URL(string: image.url)
        if availability != .notSupported { event.availability = availability }
        if let savedAlarms = image.alarms {
            event.alarms = savedAlarms.map { saved in
                let alarm = saved.absoluteDate.map { EKAlarm(absoluteDate: $0) } ?? EKAlarm(relativeOffset: saved.relativeOffset)
                alarm.soundName = saved.soundName
                alarm.structuredLocation = restoredLocation(saved.location)
                alarm.proximity = EKAlarmProximity(rawValue: saved.proximity) ?? .none
                return alarm
            }
        } else {
            // Legacy snapshots were only accepted when the event had no alarms.
            event.alarms = []
        }
        do { try store.save(event, span: .thisEvent, commit: true) }
        catch { store.reset(); throw error }
        return event.eventIdentifier
    }

    func removeOwned(_ record: ManagedEventRecord) throws -> Bool {
        guard let event = ownedEvent(record: record), marker(of: event) == record.id,
              event.attendees?.isEmpty ?? true else { return false }
        try store.remove(event, span: .thisEvent, commit: true)
        return true
    }

    @discardableResult
    func createBusyTestEvent(in calendar: EKCalendar, start: Date, durationMinutes: Int = 15) throws -> (eventID: String, token: String) {
        guard calendar.allowsContentModifications else { throw CalendarSyncError.readOnlyCalendar }
        let token = UUID().uuidString.lowercased()
        let event = EKEvent(eventStore: store)
        event.calendar = calendar
        event.title = "CalendarSync Test - Busy"
        event.startDate = start
        event.endDate = start.addingTimeInterval(TimeInterval(durationMinutes * 60))
        event.availability = .busy
        event.url = URL(string: "calendarsync-test://\(token)")
        event.notes = nil
        try store.save(event, span: .thisEvent, commit: true)
        return (event.eventIdentifier, token)
    }

    func deleteTestEvent(eventID: String, token: String, calendarID: String) throws {
        let byID = store.event(withIdentifier: eventID).flatMap { $0.calendar.calendarIdentifier == calendarID ? $0 : nil }
        let candidate = byID ?? findTestEvent(token: token)
        guard let event = candidate,
              event.title == "CalendarSync Test - Busy",
              event.attendees?.isEmpty ?? true,
              (event.eventIdentifier == eventID && event.calendar.calendarIdentifier == calendarID
                || (event.url?.scheme == "calendarsync-test" && event.url?.host == token)) else {
            throw CalendarSyncError.ownershipUnverified
        }
        try store.remove(event, span: .thisEvent, commit: true)
    }

    private func findTestEvent(token: String) -> EKEvent? {
        let start = Calendar.current.date(byAdding: .day, value: -1, to: Date()) ?? Date()
        let end = Calendar.current.date(byAdding: .day, value: 365, to: Date()) ?? Date()
        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: nil)
        return store.events(matching: predicate).first { $0.url?.scheme == "calendarsync-test" && $0.url?.host == token }
    }

    private func marker(of event: EKEvent) -> String? {
        guard event.url?.scheme == "calendarsync" else { return nil }
        return event.url?.host
    }

    private static func availability(_ value: EKEventAvailability) -> EventAvailability {
        switch value {
        case .busy: .busy
        case .unavailable: .unavailable
        case .tentative: .tentative
        case .free: .free
        case .notSupported: .unknown
        @unknown default: .unknown
        }
    }

    private func ekAvailability(_ value: EventAvailability) -> EKEventAvailability {
        switch value {
        case .busy: .busy
        case .unavailable: .unavailable
        case .tentative: .tentative
        case .free, .unknown: .busy
        }
    }
}

enum CalendarSyncError: LocalizedError {
    case readOnlyCalendar
    case calendarNotFound
    case noLocalCalendarSource
    case ownershipUnverified
    case automaticBlockingLocked
    case fullAccessRequired
    case eventHasAttendees
    case recurringGeneratedEvent
    case incompleteGeneratedEvent
    case unsupportedAlarm

    var errorDescription: String? {
        switch self {
        case .readOnlyCalendar: "The selected calendar is read-only."
        case .calendarNotFound: "The selected calendar could not be found."
        case .noLocalCalendarSource: "No local calendar source is available for Unified."
        case .ownershipUnverified: "CalendarSync could not verify ownership, so the event was left untouched."
        case .automaticBlockingLocked: "Automatic Blocking is locked until calendar validation is confirmed."
        case .fullAccessRequired: "Full calendar access is required. No rollback changes were made."
        case .eventHasAttendees: "The generated event has attendees. It was left untouched to avoid changing invitations."
        case .recurringGeneratedEvent: "The generated event now has a recurrence rule. It was left untouched."
        case .incompleteGeneratedEvent: "The generated event is missing dates or its ownership URL. It was left untouched."
        case .unsupportedAlarm: "The generated event has an email or procedure alarm that cannot be safely restored. It was left untouched."
        }
    }
}
