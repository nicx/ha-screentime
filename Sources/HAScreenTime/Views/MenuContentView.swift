import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runner: ExportRunner
    @EnvironmentObject private var log: LogStore

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        let today = runner.orderedStatuses.filter { $0.status.date == todayKey }
        if today.isEmpty {
            Text("Noch keine Daten für heute")
        } else {
            ForEach(today, id: \.child) { entry in
                if entry.status.topApp != "-" && !entry.status.topApp.isEmpty {
                    Text("\(entry.child): \(runner.format(entry.status.totalMinutes)) · Top: \(entry.status.topApp) (\(runner.format(entry.status.topAppMinutes)))")
                } else {
                    Text("\(entry.child): \(runner.format(entry.status.totalMinutes))")
                }
            }
        }

        if !ScreenTimeReader.isTrusted {
            Button("⚠︎ Bedienungshilfen freigeben…") { ScreenTimeReader.requestTrust() }
        }

        Divider()

        Button("Jetzt aktualisieren") {
            Task { await runner.runOnce(trigger: "Manuell") }
        }
        .disabled(runner.state == .running)

        if let last = runner.lastRun {
            Text("Letzter Lauf: \(last.formatted(date: .omitted, time: .shortened))")
        }

        Divider()

        if Updater.updateAvailable {
            Button("Update installieren und neu starten") {
                _ = Updater.applyIfAvailable(log: log)
            }
        }

        Button("Einstellungen…") {
            // Nicht `SettingsLink`: als Accessory-App (LSUIElement) werden wir
            // durch das Öffnen eines Fensters nicht aktiviert — das Fenster käme
            // sonst hinter allen anderen hoch.
            NSApp.activate(ignoringOtherApps: true)
            openSettings()
        }

        Button("Logs…") {
            openWindow(id: "logs")
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Beenden") { NSApp.terminate(nil) }
    }

    private var statusLine: String {
        switch runner.state {
        case .idle:              return "Bereit"
        case .running:           return "Lauf läuft…"
        case .ok:                return "OK"
        case .failed(let why):   return "Fehler: \(why)"
        }
    }

    private var todayKey: String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
