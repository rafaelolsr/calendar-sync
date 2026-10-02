import Foundation
import Testing
@testable import CalendarSync

@Suite struct SyncWindowTests {
    private var calendar: Calendar {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0)!
        return calendar
    }

    private func date(_ year: Int, _ month: Int, _ day: Int, calendar: Calendar) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: 12))!
    }

    @Test func testCalendarMonthsHandleDifferentLengthsLeapYearsAndYearBoundaries() {
        let cases = [
            (2026, 1, 31, 1, 2026, 2, 28),
            (2028, 1, 31, 1, 2028, 2, 29),
            (2026, 1, 31, 2, 2026, 3, 31),
            (2026, 10, 1, 1, 2026, 11, 1),
            (2026, 12, 31, 2, 2027, 2, 28)
        ]
        for (year, month, day, monthsAhead, endYear, endMonth, endDay) in cases {
            var state = CalendarSyncState()
            state.pastDays = 0
            state.futureMonths = monthsAhead
            let now = date(year, month, day, calendar: calendar)
            let window = state.syncWindow(now: now, calendar: calendar)
            #expect(window.start == now)
            #expect(window.end == date(endYear, endMonth, endDay, calendar: calendar))
        }
    }

    @Test func testCalendarMonthPreservesLocalTimeAcrossDaylightSaving() throws {
        var calendar = calendar
        calendar.timeZone = try #require(TimeZone(identifier: "America/New_York"))
        var state = CalendarSyncState()
        state.pastDays = 7
        state.futureMonths = 1
        let now = date(2026, 3, 1, calendar: calendar)
        let window = state.syncWindow(now: now, calendar: calendar)
        #expect(window.start == date(2026, 2, 22, calendar: calendar))
        #expect(window.end == date(2026, 4, 1, calendar: calendar))
        #expect(window.end.timeIntervalSince(now) == 31 * 86_400 - 3_600)
    }

    @Test func testLegacyDaysConvertToWholeMonthsAndExplicitMonthsTakePrecedence() throws {
        for (days, months) in [(15, 1), (30, 1), (45, 2), (60, 2), (90, 3), (365, 13)] {
            var legacy = CalendarSyncState()
            legacy.futureDays = days
            let decoded = try JSONDecoder().decode(CalendarSyncState.self, from: JSONEncoder().encode(legacy))
            #expect(decoded.futureMonths == nil)
            #expect(decoded.lookAheadMonths == months)
            var selected = decoded
            selected.futureMonths = 6
            #expect(selected.lookAheadMonths == 6)
        }
    }
}
