import SwiftUI

struct MenuContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runner: ExportRunner
    @EnvironmentObject private var log: LogStore

    @Environment(\.openSettings) private var openSettings
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Text(statusLine)

        if let status = runner.status, status.date == todayKey {
            Text("Heute: \(runner.format(status.totalMinutes))")
            if !status.byDevice.isEmpty {
                ForEach(status.byDevice.sorted(by: { $0.value > $1.value }), id: \.key) { name, minutes in
                    Text("   \(name): \(runner.format(minutes))")
                }
            }
            if status.topApp != "-" && !status.topApp.isEmpty {
                Text("Top: \(status.topApp) (\(runner.format(status.topAppMinutes)))")
            }
        } else {
            Text("Noch keine Daten für heute")
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
