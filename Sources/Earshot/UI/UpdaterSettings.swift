import SwiftUI

/// Settings card: version, update preferences, Check Now.
struct UpdaterSettingsView: View {
    @Bindable private var updater = Updater.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            CardHeader(title: "Updates", icon: "arrow.triangle.2.circlepath") {
                Text(updater.build.map { "Version \(updater.version) (\($0))" } ?? "Version \(updater.version)")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
            }
            SwitchRow(title: "Check automatically", isOn: $updater.automaticallyChecksForUpdates)
            SwitchRow(title: "Download and install automatically", isOn: $updater.automaticallyDownloadsUpdates)
                .disabled(!updater.automaticallyChecksForUpdates)
            HStack {
                Text(status).font(.callout).foregroundStyle(.secondary)
                Spacer()
                Button("Check Now") { updater.checkForUpdates() }
                    .buttonStyle(.glass)
                    .disabled(!updater.canCheckForUpdates)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .card(padding: 16)
        .onAppear { updater.refresh() }
    }

    private var status: String {
        guard updater.isAvailable else { return "Updates work in the packaged app only." }
        guard let last = updater.lastCheck else { return "Not checked yet." }
        return "Last checked \(last.formatted(.relative(presentation: .named)))."
    }
}

/// "Check for Updates…" for the app menu and the menu bar panel.
struct CheckForUpdatesButton: View {
    private var updater = Updater.shared

    var body: some View {
        Button("Check for Updates…") { updater.checkForUpdates() }
            .disabled(!updater.canCheckForUpdates)
    }
}
