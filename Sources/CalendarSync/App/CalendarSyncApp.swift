import SwiftUI
import AppKit

@main
enum CalendarSyncLauncher {
    @MainActor static func main() {
        let arguments = CommandLine.arguments
        let backgroundMode = arguments.contains("--scheduled-sync") || arguments.contains("--verify-scheduled-sync")
            || arguments.contains("--enable-default-schedule")
        guard backgroundMode else { CalendarSyncApp.main(); return }
        let app = NSApplication.shared
        app.setActivationPolicy(.prohibited)
        Task { @MainActor in
            do {
                if arguments.contains("--enable-default-schedule") {
                    var schedule = SyncSchedule()
                    schedule.mode = .severalTimes
                    try ScheduleController(stateStore: SyncStateStore(), installer: LaunchAgentScheduler(appURL: Bundle.main.bundleURL)).save(schedule)
                } else {
                    let verify = arguments.contains("--verify-scheduled-sync")
                    let flag = verify ? "--verify-scheduled-sync" : "--scheduled-sync"
                    let reportURL = arguments.firstIndex(of: flag).flatMap { index in
                        index + 1 < arguments.count ? URL(fileURLWithPath: arguments[index + 1]) : nil
                    }
                    try ScheduledSyncRunner.execute(verifyOnly: verify, reportURL: reportURL)
                }
            } catch {
                FileHandle.standardError.write(Data("CalendarSync background command failed: \(error.localizedDescription)\n".utf8))
            }
            app.terminate(nil)
        }
        app.run()
    }
}

struct CalendarSyncApp: App {
    @StateObject private var model = AppModel()

    init() {
        if CommandLine.arguments.contains("--menu-bar") {
            UserDefaults.standard.set(true, forKey: MenuBarPresentation.preferenceKey)
        }
        if UserDefaults.standard.bool(forKey: MenuBarPresentation.preferenceKey) {
            NSApplication.shared.setActivationPolicy(.accessory)
        }
        if let index = CommandLine.arguments.firstIndex(of: "--menu-bar-report"), index + 1 < CommandLine.arguments.count {
            let url = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                try? await Task.sleep(for: .seconds(1))
                let report: [String: Any] = [
                    "menuBarOnly": UserDefaults.standard.bool(forKey: MenuBarPresentation.preferenceKey),
                    "dockHidden": NSApplication.shared.activationPolicy() == .accessory,
                    "visibleMainWindows": NSApplication.shared.windows.filter { $0.canBecomeMain && $0.isVisible }.count
                ]
                try? JSONSerialization.data(withJSONObject: report, options: [.prettyPrinted, .sortedKeys]).write(to: url, options: .atomic)
            }
        }
        if let index = CommandLine.arguments.firstIndex(of: "--remove-all-generated-events"), index + 1 < CommandLine.arguments.count {
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await RollbackDiagnostics.removeAllGeneratedEvents(to: reportURL) }
                catch { FileHandle.standardError.write(Data("Generated-event reset failed: \(error.localizedDescription)\n".utf8)) }
                NSApplication.shared.terminate(nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--clean-verified-leftovers"), index + 2 < CommandLine.arguments.count {
            let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                do { try await RollbackDiagnostics.cleanVerifiedLeftovers(evidenceURL: evidenceURL, to: reportURL) }
                catch { FileHandle.standardError.write(Data("Leftover cleanup failed: \(error.localizedDescription)\n".utf8)) }
                NSApplication.shared.terminate(nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--audit-leftovers"), index + 2 < CommandLine.arguments.count {
            let evidenceURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 2])
            Task { @MainActor in
                do { try await RollbackDiagnostics.auditLeftovers(evidenceURL: evidenceURL, to: reportURL) }
                catch { FileHandle.standardError.write(Data("Leftover audit failed: \(error.localizedDescription)\n".utf8)) }
                NSApplication.shared.terminate(nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--diagnose-rollback"), index + 1 < CommandLine.arguments.count {
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try await RollbackDiagnostics.write(to: reportURL) }
                catch { FileHandle.standardError.write(Data("Rollback diagnostics failed: \(error.localizedDescription)\n".utf8)) }
                NSApplication.shared.terminate(nil)
            }
        } else if let index = CommandLine.arguments.firstIndex(of: "--resume-confirmed-rollback"), index + 1 < CommandLine.arguments.count {
            let reportURL = URL(fileURLWithPath: CommandLine.arguments[index + 1])
            Task { @MainActor in
                do { try RollbackDiagnostics.resumePreviouslyConfirmedRollback(to: reportURL) }
                catch { FileHandle.standardError.write(Data("Rollback recovery failed: \(error.localizedDescription)\n".utf8)) }
                NSApplication.shared.terminate(nil)
            }
        }
        guard let iconURL = Bundle.main.url(forResource: "CalendarSyncIcon", withExtension: "png"),
              let source = NSImage(contentsOf: iconURL) else { return }

        // The 1024-pixel PNG is a 512-point @2x app icon. Keep its logical
        // size at 512 points so Dock lays it out at the same size as other apps.
        let iconSize = NSSize(width: 512, height: 512)
        source.size = iconSize
        let dockIcon = NSImage(size: iconSize)
        dockIcon.lockFocus()
        let bounds = NSRect(origin: .zero, size: iconSize)
        NSBezierPath(roundedRect: bounds, xRadius: 110, yRadius: 110).addClip()
        source.draw(in: bounds, from: bounds, operation: .copy, fraction: 1)
        dockIcon.unlockFocus()
        NSApplication.shared.applicationIconImage = dockIcon
    }

    var body: some Scene {
        WindowGroup("CalendarSync", id: MenuBarPresentation.windowID) {
            SettingsView()
                .environmentObject(model)
                .environmentObject(model.stateStore)
                .frame(minWidth: 1040, minHeight: 700)
        }
        .commands {
            CommandGroup(after: .appInfo) {
                Button("Minimize to menu bar") { model.minimizeToMenuBar() }
                    .keyboardShortcut("m", modifiers: [.command, .shift])
                Button("Grant Calendar Access") {
                    Task { await model.requestAccess() }
                }
                Button("Calendar Validation…") {
                    model.showValidation = true
                }
                Button("Safety & Blocking…") {
                    model.showSafetySettings = true
                }
            }
        }
        MenuBarExtra("CalendarSync", systemImage: "calendar.badge.clock") {
            CalendarSyncMenuBarView()
                .environmentObject(model)
                .environmentObject(model.stateStore)
        }
        .menuBarExtraStyle(.menu)
    }
}
