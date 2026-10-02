import Foundation
import EventKit
import Darwin

enum SyncScheduleMode: String, Codable, CaseIterable {
    case off, daily, severalTimes
    var label: String {
        switch self {
        case .off: "Off"
        case .daily: "Daily"
        case .severalTimes: "Several times daily"
        }
    }
}

struct SyncSchedule: Codable, Equatable {
    var mode: SyncScheduleMode = .off
    // Minutes since local midnight. Stored independently of time zone and date.
    var dailyMinute = 9 * 60
    var multipleMinutes = [9 * 60, 13 * 60, 17 * 60]

    var isEnabled: Bool { mode != .off }
    var minutes: [Int] {
        switch mode {
        case .off: []
        case .daily: [dailyMinute]
        case .severalTimes: Array(Set(multipleMinutes)).sorted()
        }
    }

    func validate() throws {
        guard !isEnabled || (!minutes.isEmpty && minutes.count <= 8 && minutes.allSatisfy { (0..<1440).contains($0) }) else {
            throw ScheduleFailure.invalidTimes
        }
    }

    func nextRun(after now: Date, calendar: Calendar = .current) -> Date? {
        guard isEnabled else { return nil }
        return minutes.compactMap { minute in
            calendar.nextDate(after: now, matching: DateComponents(hour: minute / 60, minute: minute % 60),
                              matchingPolicy: .nextTime, repeatedTimePolicy: .first)
        }.min()
    }

    func launchAgentPropertyList(appURL: URL, errorLogURL: URL) throws -> Data {
        try validate()
        guard isEnabled, appURL.isFileURL, appURL.pathExtension == "app" else { throw ScheduleFailure.appBundleRequired }
        let job: [String: Any] = [
            "Label": LaunchAgentScheduler.label,
            "ProgramArguments": ["/usr/bin/open", "-g", "-n", appURL.path, "--args", "--scheduled-sync"],
            "StartCalendarInterval": minutes.map { ["Hour": $0 / 60, "Minute": $0 % 60] },
            "LimitLoadToSessionType": "Aqua",
            "ProcessType": "Background",
            "StandardOutPath": "/dev/null",
            "StandardErrorPath": errorLogURL.path
        ]
        return try PropertyListSerialization.data(fromPropertyList: job, format: .xml, options: 0)
    }
}

enum ScheduleFailure: LocalizedError {
    case invalidTimes, appBundleRequired, registration(String)
    var errorDescription: String? {
        switch self {
        case .invalidTimes: "Choose between one and eight valid daily times."
        case .appBundleRequired: "Open the packaged CalendarSync app before enabling its schedule."
        case let .registration(message): "The schedule could not be registered with macOS: \(message)"
        }
    }
}

protocol ScheduleInstalling {
    func configure(_ schedule: SyncSchedule) throws
}

struct LaunchAgentScheduler: ScheduleInstalling {
    static let label = "com.datageek.CalendarSync.scheduled-sync"
    let appURL: URL
    private var domain: String { "gui/\(getuid())" }
    private var jobTarget: String { "\(domain)/\(Self.label)" }
    var jobURL: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents/\(Self.label).plist")
    }
    static var supportURL: URL {
        FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("com.datageek.CalendarSync", isDirectory: true)
    }
    static var runReportURL: URL { supportURL.appendingPathComponent("scheduled-run.json") }

    private func launchctl(_ arguments: [String]) throws -> (Int32, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/launchctl")
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        let errors = Pipe()
        process.standardError = errors
        try process.run()
        let data = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return (process.terminationStatus, String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))
    }

    var isLoaded: Bool { (try? launchctl(["print", jobTarget]).0) == 0 }

    private func unload() throws {
        guard isLoaded else { return }
        let (code, message) = try launchctl(["bootout", jobTarget])
        guard code == 0 else { throw ScheduleFailure.registration(message) }
    }

    private func load() throws {
        let (code, message) = try launchctl(["bootstrap", domain, jobURL.path])
        guard code == 0 else { throw ScheduleFailure.registration(message) }
    }

    func configure(_ schedule: SyncSchedule) throws {
        try schedule.validate()
        let data = schedule.isEnabled ? try schedule.launchAgentPropertyList(
            appURL: appURL, errorLogURL: Self.supportURL.appendingPathComponent("scheduler-launch.log")) : nil
        let previousData = try? Data(contentsOf: jobURL)
        let wasLoaded = isLoaded
        try unload()
        do {
            if let data {
                try FileManager.default.createDirectory(at: jobURL.deletingLastPathComponent(), withIntermediateDirectories: true)
                try FileManager.default.createDirectory(at: Self.supportURL, withIntermediateDirectories: true,
                                                       attributes: [.posixPermissions: 0o700])
                try data.write(to: jobURL, options: .atomic)
                try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: jobURL.path)
                try load()
            } else if FileManager.default.fileExists(atPath: jobURL.path) {
                try FileManager.default.removeItem(at: jobURL)
            }
        } catch {
            try? unload()
            if let previousData {
                try? previousData.write(to: jobURL, options: .atomic)
                if wasLoaded { try? load() }
            } else { try? FileManager.default.removeItem(at: jobURL) }
            throw error
        }
    }
}

@MainActor
struct ScheduleController {
    let stateStore: SyncStateStore
    let installer: any ScheduleInstalling

    func save(_ schedule: SyncSchedule) throws {
        try schedule.validate()
        let lock = try stateStore.acquireRecoveryLock()
        defer { lock.release() }
        stateStore.reloadRecovery()
        guard stateStore.recoveryError == nil else { throw RollbackFailure.snapshotUnavailable }
        let previous = stateStore.state.schedule ?? SyncSchedule()
        try installer.configure(schedule)
        do { try stateStore.checkpoint { $0.schedule = schedule } }
        catch {
            try? installer.configure(previous)
            throw error
        }
    }
}

struct ScheduledRunReport: Codable {
    let startedAt: Date
    let finishedAt: Date
    let outcome: String
    let summary: String
    let sourceCount: Int
    let changeCount: Int
    let issueCount: Int
}

@MainActor
enum ScheduledSyncRunner {
    static func run(stateStore: SyncStateStore, eventStore: EKEventStore, verifyOnly: Bool = false) throws -> ScheduledRunReport {
        let start = Date()
        var outcome = "skipped"
        var summary = "Scheduling is off."
        var sources = 0
        var changes = 0
        var issues = 0
        stateStore.reloadRecovery()
        if stateStore.state.schedule?.isEnabled == true {
            if EKEventStore.authorizationStatus(for: .event) != .fullAccess {
                summary = "Full Calendar Access is required. Open CalendarSync to restore access."
                issues = 1
            } else {
                let result = SyncEngine(eventStore: eventStore, stateStore: stateStore).run(dryRun: verifyOnly, scheduled: true)
                sources = result.plan.sourceCount
                changes = result.successfulChangeCount
                issues = result.errorCount
                if verifyOnly {
                    outcome = "verification"
                    summary = "Read-only verification: \(result.plan.mutationCount) planned changes, \(issues) issues. No events changed."
                } else if result.applied {
                    outcome = issues == 0 ? "success" : "issues"
                    summary = "Synced \(sources) source events; \(changes) changes, \(issues) issues."
                } else {
                    summary = result.messages.first ?? "Sync was skipped. Check calendar setup and Safety settings."
                }
            }
        }
        return ScheduledRunReport(startedAt: start, finishedAt: Date(), outcome: outcome, summary: summary,
                                  sourceCount: sources, changeCount: changes, issueCount: issues)
    }

    static func execute(verifyOnly: Bool = false, reportURL: URL? = nil) throws {
        try FileManager.default.createDirectory(at: LaunchAgentScheduler.supportURL, withIntermediateDirectories: true,
                                               attributes: [.posixPermissions: 0o700])
        let lock = try RecoveryWriteLock(url: LaunchAgentScheduler.supportURL.appendingPathComponent("scheduled-sync.lock"))
        defer { lock.release() }
        let report = try run(stateStore: SyncStateStore(), eventStore: EKEventStore(), verifyOnly: verifyOnly)
        let url = reportURL ?? LaunchAgentScheduler.runReportURL
        try JSONEncoder().encode(report).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
