import AppKit
import SwiftUI

@main
struct EarshotApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var state = AppState.shared

    var body: some Scene {
        Window("Earshot", id: "main") {
            MainWindow()
                .environment(state)
                .background(WindowActions())
                .preferredColorScheme(state.colorScheme)
        }
        .windowBackgroundDragBehavior(.enabled)
        .defaultSize(width: 1280, height: 820)

        SwiftUI.Settings {
            SettingsWindow().environment(state)
        }

        MenuBarExtra {
            MenuPanel().environment(state).preferredColorScheme(state.colorScheme)
        } label: {
            Image(systemName: state.meeting != nil ? "person.wave.2.fill"
                : state.isRecording ? "record.circle.fill"
                : state.activeJobs > 0 ? "waveform.badge.magnifyingglass" : "waveform")
        }
        .menuBarExtraStyle(.window)
    }
}

/// Hands SwiftUI's window actions to AppState so non-view code (menu bar, URL scheme, notifications) can open windows.
private struct WindowActions: View {
    @Environment(\.openWindow) private var openWindow
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Color.clear.onAppear {
            AppState.shared.openWindowAction = { openWindow(id: $0) }
            AppState.shared.openSettingsAction = { openSettings() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        API.start()
        Task { @MainActor in
            AppState.shared.bootstrap()
            Notifier.requestAuthorization()
            CalendarLookup.requestAccess()
            MeetingDetector.shared.start()
            FolderWatcher.shared.reload()
        }
    }

    /// Quitting mid-meeting stops and saves the meeting first (at most ~15 s; anything left is recovered at the next launch).
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        MainActor.assumeIsolated {
            let meetings = MeetingController.shared
            guard meetings.session != nil || meetings.isStopping else { return .terminateNow }
            Task { @MainActor in
                await meetings.stopForQuit(timeout: 15)
                sender.reply(toApplicationShouldTerminate: true)
            }
            return .terminateLater
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        if !flag { Task { @MainActor in AppState.shared.showMainWindow() } }
        return true
    }

    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in urls.forEach(URLScheme.handle) }
    }
}
