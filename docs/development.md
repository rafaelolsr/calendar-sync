# Development guide

[← Back to CalendarSync](../README.md)

## Source layout

| Path | Responsibility |
| :--- | :--- |
| `Sources/CalendarSync/App/` | Application entry points and background launch modes |
| `Sources/CalendarSync/UI/` | Settings, mappings, schedule, menu bar, and rollback interface |
| `Sources/CalendarSync/EventKit/` | Calendar discovery, event access, and generated-event writes |
| `Sources/CalendarSync/Models/` | Calendar choices |
| `Sources/CalendarSync/Sync/` | Planning, persistent state, scheduling, ownership checks, and recovery |
| `Sources/CalendarSync/Intents/` | App Intent implementation for syncing |
| `Tests/CalendarSyncTests/` | Swift Testing suites using synthetic data |
| `Scripts/` | Testing, packaging, and app-icon rendering |
| `Resources/` | App icon and bundle configuration |

The source includes a Sync Calendars App Intent. Its discovery in Shortcuts depends on the build's App Intents metadata registration; the shell packaging workflow does not explicitly extract that metadata. Use the app's built-in scheduler for documented automation.

## Build and test

On macOS 14 or newer with Swift 6 or newer:

```sh
sh Scripts/test.sh
sh Scripts/package-app.sh
```

The packaging script builds a release executable, assembles `.build/CalendarSync.app`, creates its icon, and applies an ad hoc signature. It does not register a schedule, change saved calendar configuration, or run a sync.

### SDK workaround

Some macOS 27 Command Line Tools installations report a missing `SwiftUIMacros` plug-in. If the macOS 26.5 SDK is installed at the following path, use:

```sh
sh Scripts/test.sh \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --build-system native

sh Scripts/package-app.sh \
  --sdk /Library/Developer/CommandLineTools/SDKs/MacOSX26.5.sdk \
  --build-system native
```

Adjust the SDK path to an SDK actually installed on your machine. Full Xcode is optional when compatible Command Line Tools are available.

## Updating an installed app

Quit the foreground app before replacing the installed bundle. Preserve the existing bundle as a backup and install the new bundle at the same location used by the LaunchAgent. Building alone does not update the installed app. Keep recovery files in place; configuration lives outside the app bundle.

Ad hoc signing can change the app's permission identity between builds. After an update, reopen the app and verify Calendar Access before relying on scheduled runs. If needed, grant it under **System Settings → Privacy & Security → Calendars**. Background runs never display permission dialogs.

Developer ID signing and notarization are separate distribution steps and are not included in the packaging script.

## Read-only support checks

Use absolute paths for reports, and launch the installed app so checks use its normal Calendar Access identity.

### Scheduled-path preview

```sh
open -g -n /Applications/CalendarSync.app --args \
  --verify-scheduled-sync /absolute/path/schedule-report.json
```

This checks the saved setup using scheduling gates and writes an aggregate report. It does not change calendar events or recovery state. An enabled schedule, validated configuration, Automatic Blocking, and Calendar Access are still required by this path.

### Recovery diagnostics

```sh
open -n /Applications/CalendarSync.app --args \
  --diagnose-rollback /absolute/path/recovery-report.json
```

This reads calendars and exports aggregate diagnostics, including a source-content digest, without event titles or identifiers in the report. On first use, this foreground support path can request Calendar Access. It exits when finished.

See the [recovery guide](recovery.md) for commands that apply recovery changes. Those commands are explicit mutations, not diagnostics.

## Scheduler entry points

The LaunchAgent starts the installed app with `--scheduled-sync`, the actual apply entry point. It checks the saved safety gates and uses the same engine and recovery lock as manual sync.

`--enable-default-schedule` saves and registers the default 09:00, 13:00, and 17:00 schedule. It does not immediately sync, but it authorizes future runs at those times. Prefer the Schedule UI for ordinary setup.

The LaunchAgent runs in the logged-in user's Aqua session. Overlapping scheduled instances and concurrent recovery writes are guarded by file locks. Scheduled outcomes contain aggregate counts rather than event details.

## Working on the banner

The README banner lives at [`assets/calendar-sync-banner.png`](assets/calendar-sync-banner.png). Its generation prompt and tool provenance are in [`assets/banner-prompt.md`](assets/banner-prompt.md).

Do not use real calendar screenshots, recovery exports, or account identifiers in public documentation. Keep generated build files and local recovery evidence out of Git.
