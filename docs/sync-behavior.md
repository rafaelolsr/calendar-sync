# How synchronization works

[← Back to CalendarSync](../README.md)


- Choose the upcoming range in **Sync window → Look ahead** on the main screen: 1–12 months, 18, 24, or 36 months, or **Custom…** for 1–36 months. These are calendar months from the current date and time, not fixed 30-day periods; a missing day at the end of a month uses that month's last day. Set **Include past** to 0 for upcoming events only. The initial defaults are 7 days in the past and 3 months ahead. Older day-based settings convert to months by rounding up days divided by 30 (30 days becomes 1 month; 45 days becomes 2).
- Preview changes, Sync now, and Shortcuts use the same saved window. Only events starting inside that window produce new Unified copies or Busy blocks; recurring occurrences are checked individually. Event durations are preserved. Reducing the range does not delete generated events outside it; use rollback to undo the latest sync.
- EventKit supplies concrete recurring occurrences in the scan window; CalendarSync does not clone recurrence rules. Each occurrence is tracked independently, including moved occurrences that EventKit returns in the window.
- Busy and Out of Office events produce blockers in other selected writable calendars. Free events appear in Unified but do not block. Tentative events appear in Unified and do not block by default. Declined and cancelled events do not produce new projections. EventKit does not expose a working-location classification, so CalendarSync does not infer one; events follow their EventKit availability, and unknown or unsupported availability never creates blockers. All-day events follow their EventKit availability state.
- Generated event ownership is tied to durable local records and a marker URL. If ownership cannot be verified, the app leaves the event untouched and reports the issue.
- Stale cleanup is deferred for a source calendar that returns no events in the active scan window. This prevents a temporarily empty/unavailable EventKit view from triggering bulk deletion; cleanup can resume when that calendar returns events.
- Failed destination writes are reported independently; successful destinations are retained for idempotent retry.
- Apple Calendar remains the calendar UI. Showing Unified and hiding source calendars is a user-controlled display preference.

Automatic Blocking is an explicit apply gate for manual Sync Now, Shortcuts, and scheduled runs; validation never turns it on automatically.
