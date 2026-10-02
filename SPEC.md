# CalendarSync — Engineering Specification

## Status

Target: macOS
Language: Swift
UI: SwiftUI
Calendar integration: EventKit
Shortcuts integration: App Intents
External services: None

This document records the original design. See README.md and docs/ for the current implemented behavior and operating instructions.

The application should be implemented end-to-end. However, automatic
cross-calendar mutations MUST remain disabled by default until the
user explicitly completes calendar validation.

---

# 1\. Problem

The user works with multiple independent calendars, including multiple
Microsoft 365 / Exchange organizations.

Example:

- Microsoft
- Work
- Company C
- Personal calendars

All of these calendars are already configured in macOS and visible in
Apple Calendar.

The organizations are independent.

A meeting in one organization's calendar does NOT make the user Busy
in another organization's Outlook / Exchange availability.

For example:

```
Microsoft
10:00–11:00 Project Meeting

Work
10:00–11:00 Available

Company C
10:00–11:00 Available
```

People scheduling the user through Work or Company C can therefore book
the same time.

The obvious commercial solutions, such as cross-calendar synchronization
services, may not work because corporate Microsoft 365 tenants can
prohibit third-party OAuth applications.

Apple Calendar, however, already has access to these accounts.

CalendarSync must therefore operate LOCALLY through EventKit.

---

# 2\. Product Goal

CalendarSync is a local calendar reconciliation utility.

It is NOT a replacement calendar application.

Apple Calendar remains the user's calendar UI.

CalendarSync has two responsibilities:

1. Cross-calendar availability blocking.
2. Maintaining a clean Unified calendar for visualization.

Conceptually:

```
                 EventKit
                    │
    ┌───────────────┼───────────────┐
    │               │               │
Microsoft         Work          Company C
    │               │               │
real + busy      real + busy     real + busy
    │               │               │
    └───────────────┬───────────────┘
                    │
              CalendarSync
                /       \
               /         \
        Busy blocking    Unified
                            │
                            ▼
                     Apple Calendar
```

---

# 3\. Desired Behavior

Assume these participating calendars:

- Microsoft
- Work
- Company C

A real event exists:

```
Microsoft
10:00–11:00
Project Meeting
```

CalendarSync should produce:

```
Microsoft
10:00–11:00 Project Meeting
[original event]

Work
10:00–11:00 Busy
[generated blocker]

Company C
10:00–11:00 Busy
[generated blocker]

Unified
10:00–11:00 Project Meeting
[clean projection]
```

The generated Busy events must exist on the destination calendars so
their corresponding Exchange / Outlook systems consider the user
unavailable.

---

# 4\. Unified Calendar

CalendarSync maintains a separate calendar called:

```
Unified
```

Unified is a clean projection of the user's real schedule.

It contains REAL events from participating calendars.

It MUST NOT contain CalendarSync-generated Busy blockers.

The intended Apple Calendar configuration is:

```
Hidden:

○ Microsoft
○ Work
○ Company C
○ other participating source calendars

Visible:

● Unified
```

Hiding a calendar in Apple Calendar only affects presentation.

The underlying account remains configured and continues synchronizing
with Exchange / Google / other providers.

Therefore:

Exchange sees:

```
Microsoft:
    Project Meeting
    Busy
    Busy

Work:
    Busy
    Work Meeting
    Busy

Company C:
    Busy
    Busy
    Company C Meeting
```

The user sees:

```
Unified:
    Project Meeting
    Work Meeting
    Company C Meeting
```

---

# 5\. Technology

Use:

- Swift
- SwiftUI
- EventKit
- App Intents
- native macOS frameworks

Use SwiftData or SQLite for local CalendarSync state if persistence is
required.

Prefer native frameworks and minimal dependencies.

Do NOT use:

- Microsoft Graph
- Exchange APIs
- Google Calendar APIs
- external synchronization services
- browser automation
- cloud backend
- Electron
- Tauri
- custom calendar rendering

No corporate credentials should be stored by CalendarSync.

---

# 6\. Security Boundary

EventKit is the integration boundary.

CalendarSync must NEVER authenticate directly against corporate
Microsoft tenants.

Architecture:

```
Microsoft 365
      ↕
macOS Internet Account
      ↕
   EventKit
      ↕
 CalendarSync
```

This is intentional.

Some corporate tenants reject third-party applications that require
Microsoft Entra / OAuth administrator approval.

CalendarSync must operate only on calendars already exposed to EventKit
by macOS.

---

# 7\. Calendar Configuration

CalendarSync must NOT automatically synchronize every calendar visible
to EventKit.

The user explicitly selects participating calendars.

Settings should show something similar to:

```
Calendar                       Participate
------------------------------------------------
Microsoft / Calendar               ✓
Work / Calendar                   ✓
Company C / Calendar                 ✓
Personal                           optional
Birthdays                          ✗
Holidays                           ✗
Todoist                            ✗
Unified                            NEVER SOURCE
```

For each calendar display:

- calendar title
- account/source name
- calendar type
- writable/read-only status

Calendar names are NOT globally unique.

Use EventKit identifiers/source information internally.

Only writable calendars may receive blockers.

Unified MUST never participate as a source calendar.

---

# 8\. Core Invariant

For every qualifying REAL event E on participating calendar C:

1. E remains untouched on C.
2. One representation of E exists in Unified.
3. Every other eligible participating work calendar receives one
   anonymized Busy blocker representing E.
4. Generated blockers NEVER generate additional blockers.
5. Generated blockers NEVER appear in Unified.
6. Unified events NEVER generate blockers.

Conceptually:

```
             REAL EVENT
                 │
        ┌────────┼─────────┐
        │        │         │
        ▼        ▼         ▼
     Unified   Busy B    Busy C
                          ...
                     Busy N
```

---

# 9\. Original Events Are Immutable

CalendarSync MUST NOT modify source meetings.

Never modify:

- title
- time
- attendees
- organizer
- location
- notes
- recurrence
- conferencing information
- availability

of an original event.

CalendarSync observes source events.

It only modifies events it owns.

---

# 10\. Generated Blockers

A blocker should contain approximately:

```
title: Busy
start: source.start
end: source.end
availability: busy
```

Do NOT copy:

- source meeting title
- source description
- attendees
- organizer
- Teams URL
- Zoom URL
- meeting URL
- location
- notes
- attachments

The destination organization should learn only:

```
"The user is unavailable during this interval."
```

---

# 11\. Never Send Invitations

This is a critical safety requirement.

Generated events MUST NOT:

- contain attendees
- invite participants
- send meeting updates
- manipulate organizer information
- send email notifications

Unified events are projections.

Busy events are availability blockers.

Neither is a meeting invitation.

---

# 12\. Generated Event Ownership

Do NOT identify generated events solely by:

```
title == "Busy"
```

A legitimate event may be named Busy.

CalendarSync must reliably identify events it owns.

Maintain durable mappings such as:

```
Source:
    Microsoft:event123

Generated:
    Unified:event987
    Work:blocker456
    Company C:blocker789
```

The local mapping should contain enough information to safely reconcile
the relationship.

Possible model:

```
EventMapping

id
sourceCalendarID
sourceEventID
sourceOccurrenceDate
unifiedCalendarID
unifiedEventID
blockerMappings[]
fingerprint
createdAt
updatedAt
```

EventKit identifiers may change due to provider synchronization.

Do not assume identifiers are permanently stable.

Use defensive reconciliation and fingerprints where appropriate.

If CalendarSync cannot prove ownership of an event:

```
DO NOT MODIFY IT.
DO NOT DELETE IT.
```

Report the ambiguity instead.

---

# 13\. Loop Prevention

Loop prevention is mandatory.

Without protection:

```
Microsoft real event
        ↓
   Work Busy
        ↓
interpreted as real
        ↓
  Microsoft Busy
        ↓
        ...
```

Generated blockers must therefore be excluded from source discovery.

Unified must also never be considered a source.

The following must hold:

```
isGeneratedBlocker(event) == true
    → never source

calendar == Unified
    → never source
```

---

# 14\. Idempotency

Synchronization MUST be idempotent.

Running:

```
sync()
sync()
sync()
```

must result in the same calendar state as:

```
sync()
```

It must NOT create duplicate Unified events or duplicate blockers.

---

# 15\. Create Reconciliation

Given:

```
Microsoft
10:00–11:00 Project Meeting
```

CalendarSync creates:

```
Unified
10:00–11:00 Project Meeting

Work
10:00–11:00 Busy

Company C
10:00–11:00 Busy
```

Only generated events are written.

The original Microsoft event is untouched.

---

# 16\. Update Reconciliation

If:

```
Project Meeting
10:00–11:00
```

changes to:

```
Project Meeting
11:00–12:00
```

CalendarSync updates its existing:

- Unified representation
- Work blocker
- Company C blocker

It must NOT create new duplicates.

Changes that may require reconciliation include:

- start time
- end time
- all-day state
- title for Unified
- location for Unified if supported
- availability state
- cancellation

Cross-company blockers remain anonymized.

---

# 17\. Delete Reconciliation

If a source event disappears or is cancelled:

CalendarSync removes:

- its Unified representation
- its generated Busy blockers

CalendarSync must NEVER delete an unrelated event.

Deletion requires positive CalendarSync ownership.

If ownership is uncertain:

```
leave the event untouched
report the issue
```

---

# 18\. Legitimate Overlapping Meetings

Do NOT merge real overlapping events.

Example:

```
Work
10:00–11:00 Meeting A

Microsoft
10:30–11:30 Meeting B
```

Both are real.

Unified must contain BOTH.

The purpose of CalendarSync is to remove synthetic availability
duplication, not legitimate scheduling conflicts.

---

# 19\. Availability Rules

V1 should have explicit availability behavior.

Recommended default:

```
Busy
    → block other calendars

Out of Office
    → block other calendars

Free
    → do not create blockers
```

Tentative behavior should be configurable or explicitly documented.

Also explicitly handle:

- declined meetings
- cancelled meetings
- all-day events
- working location events
- focus events where applicable

Do not silently guess unsupported states.

---

# 20\. All-Day Events

All-day events require explicit handling.

Not every all-day event should necessarily block an entire day.

Examples:

```
Holiday
Birthday
Travel
OOO
```

CalendarSync should respect the event's availability state rather than
assuming all all-day events block availability.

Unified may still display appropriate real all-day events.

---

# 21\. Recurring Events

Recurring events are high risk.

Handle:

- recurring series
- individual occurrences
- modified occurrences
- deleted occurrences
- moved occurrences

Do NOT blindly clone recurrence rules before EventKit behavior is
validated.

Prefer reconciling concrete occurrences inside the active sync horizon
if this provides safer behavior.

The implementation must document the recurrence strategy.

No recurrence behavior should risk deleting or modifying original
meetings.

---

# 22\. Synchronization Window

Do not scan unlimited calendar history.

Use a configurable horizon.

Recommended initial values:

```
past: 7 days
future: 90 days
```

Historical events should generally not result in newly created blockers.

Past events may be inspected for reconciliation/cleanup purposes.

---

# 23\. Unified Event Representation

Unified is the user's private projection.

Unlike cross-company blockers, Unified may preserve useful information.

V1 may preserve:

- title
- start
- end
- all-day status
- location where appropriate
- source calendar identity

Do NOT copy attendees into Unified.

Do NOT create invitations.

Consider prefixing or otherwise exposing the source account in local
metadata/UI rather than altering sensitive meeting titles.

---

# 24\. Dry Run

CalendarSync MUST support Dry Run.

Dry Run performs full reconciliation planning without modifying
EventKit.

Example:

```
CalendarSync — Dry Run

Source events: 17

CREATE

Unified
  10:00–11:00 Project Meeting

Work
  10:00–11:00 Busy

Company C
  10:00–11:00 Busy

UPDATE

  Unified: 2
  Blockers: 3

DELETE

  CalendarSync-owned blockers: 1

Original events modified: 0
```

Dry Run should clearly distinguish:

- CREATE
- UPDATE
- DELETE
- SKIP
- ERROR

It should identify destination calendars without exposing unnecessary
sensitive information in logs.

Dry Run must be available before automatic blocking can be enabled.

---

# 25\. Validation Mode

CalendarSync MUST provide a Validation Mode.

Cross-calendar automatic writes are disabled by default.

Validation Mode allows:

1. Select ONE writable calendar.
2. Select a future test time.
3. Create:

    ```
    CalendarSync Test - Busy
    ```

4. Set availability to Busy.
5. Save through EventKit.
6. Display resulting EventKit identifiers.
7. Provide:

    ```
    Delete Test Event
    ```

The first production validation target is the configured primary work calendar.

Manual validation flow:

```
CalendarSync
      ↓
   EventKit
      ↓
macOS account
      ↓
Work Exchange
      ↓
   Outlook
      ↓
Scheduling Assistant
```

The user must verify that Outlook sees the period as unavailable.

Validation Mode must cleanly remove its own test event.

---

# 26\. Safety Gate

Automatic cross-calendar mutations MUST be disabled by default.

Example:

```
Validation Mode: AVAILABLE

Dry Run: AVAILABLE

Automatic Blocking: LOCKED
```

Automatic Blocking can only be enabled after successful Validation Mode
confirmation.

The application should persist that validation state.

Do not silently enable automatic synchronization after validation.

The user must explicitly enable it.

Provide a clear warning explaining that CalendarSync will create and
maintain Busy events across selected calendars.

---

# 27\. Initial Application UI

CalendarSync is NOT a calendar UI.

Use a small settings/status application.

Example:

```
CalendarSync

Status
● Ready

Participating Calendars

☑ Microsoft / Calendar
☑ Work / Calendar
☑ Company C / Calendar
☐ Personal

Unified Calendar
[ Unified ]

Validation
Work       ✓ Validated

Automatic Blocking
[ OFF ]

[ Dry Run ]

[ Sync Now ]

Last Sync:
Sep 28, 2026 14:05
```

Optional status information:

```
Source events:       18
Unified events:      18
Active blockers:     31
Planned changes:      0
Errors:               0
```

---

# 28\. App Intents / Shortcuts

Expose an App Intent:

```
Sync Calendars
```

This should become available in macOS Shortcuts.

Running the intent performs one safe reconciliation using the current
configuration.

If automatic mutations have not been enabled, the intent must NOT bypass
the safety gate.

Potential future intents:

```
Dry Run Calendar Sync
```

Do not require shell scripts for normal usage.

---

# 29\. Background Execution

Do NOT make aggressive background execution a prerequisite for V1.

Initial supported execution:

1. Sync Now
2. App Intent / Shortcuts

After correctness is established, investigate appropriate native macOS
background mechanisms.

Correctness and calendar safety are more important than sub-minute
synchronization.

---

# 30\. Logging

Provide useful local diagnostics.

Log:

- synchronization start/end
- calendars processed
- counts
- generated event IDs
- mapping changes
- errors
- skipped operations
- ownership conflicts

Avoid logging sensitive information unnecessarily.

In particular, avoid persisting full:

- meeting descriptions
- attendee lists
- conferencing links
- confidential notes

Logs should help debug reconciliation without becoming another store of
corporate calendar content.

---

# 31\. Failure Isolation

A failure writing to one destination must not corrupt another calendar.

Example:

```
Microsoft source
   ↓
Work blocker ✓
Company C blocker ✗ permission error
```

CalendarSync should:

- retain successful safe operations
- report the failed destination
- retry safely later
- never modify the source event
- never delete unrelated events

The next reconciliation must remain idempotent.

---

# 32\. Calendar Removal / Permission Changes

Calendars may:

- disappear
- be renamed
- become read-only
- lose authentication
- temporarily fail
- change provider state

CalendarSync must handle these cases safely.

Never interpret an inaccessible calendar as authorization to mass-delete
mappings/events.

Surface the problem to the user.

---

# 33\. Safety Rules

These rules are NON-NEGOTIABLE.

1. Never modify an original/source event.
2. Never delete an event unless CalendarSync can positively prove it
   owns that generated event.
3. Never send invitations.
4. Never copy attendees into blockers.
5. Never expose source meeting titles/details across companies.
6. Never use destructive "reset calendar" logic.
7. Never delete all events titled "Busy".
8. Never assume calendar names are globally unique.
9. Unified is never a source.
10. Generated blockers are never sources.
11. Synchronization must be idempotent.
12. Partial destination failures must not corrupt other calendars.
13. If ownership is uncertain, leave the event untouched.
14. No automatic blocking until validation succeeds AND the user
    explicitly enables it.
15. Dry Run must never mutate EventKit.

---

# 34\. Development Architecture

Keep EventKit access separated from reconciliation logic.

A reasonable structure:

```
CalendarSync/
│
├── App/
│   └── CalendarSyncApp.swift
│
├── EventKit/
│   ├── CalendarStore.swift
│   ├── EventRepository.swift
│   └── EventKitAdapter.swift
│
├── Sync/
│   ├── SyncEngine.swift
│   ├── ReconciliationPlanner.swift
│   ├── UnifiedCalendarManager.swift
│   ├
```
