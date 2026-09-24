import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runner: ExportRunner
    @EnvironmentObject private var loginItem: LoginItemManager

    @State private var mailTestResult: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("Allgemein", systemImage: "gearshape") }
            captureTab.tabItem { Label("Erfassung", systemImage: "person.crop.circle") }
            notifyTab.tabItem { Label("Benachrichtigung", systemImage: "envelope") }
        }
        .frame(width: 520)
        .padding(20)
    }

    // MARK: Allgemein

    private var generalTab: some View {
        Form {
            Section("Home Assistant") {
                TextField("URL", text: $settings.haURL, prompt: Text("http://localhost:8123"))
                SecureField("Long-Lived Token", text: $settings.haToken)
                Text("Profil → Sicherheit → Langlebige Zugriffstokens")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Zeitplan") {
                Stepper("Alle \(settings.intervalMinutes) Minuten",
                        value: $settings.intervalMinutes, in: 5...240, step: 5)
                    .onChange(of: settings.intervalMinutes) { _, _ in runner.rescheduleIfNeeded() }
            }

            Section("Start") {
                Toggle("Bei der Anmeldung starten", isOn: Binding(
                    get: { loginItem.isEnabled },
                    set: { loginItem.setEnabled($0) }))
                if let err = loginItem.lastError {
                    Text(err).font(.caption).foregroundStyle(.red)
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Erfassung

    private var captureTab: some View {
        Form {
            Section("Kinder") {
                TextField("Namen", text: $settings.childNames, prompt: Text("z. B. Kind1, Kind2"))
                Text("Kommagetrennt, so wie die Kinder unter Systemeinstellungen → Familie aufgeführt sind (der Teil vor dem Komma). Je Kind entstehen eigene Sensoren, z. B. sensor.screentime_kind1_total. Erfasst wird die Summe über alle Geräte des Kindes, samt der Nutzungszeiten (App-Gruppen mit Tageslimit).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Berechtigung") {
                if ScreenTimeReader.isTrusted {
                    Label("Bedienungshilfen freigegeben", systemImage: "checkmark.circle")
                        .foregroundStyle(.green)
                } else {
                    Label("Bedienungshilfen nicht freigegeben", systemImage: "exclamationmark.triangle")
                        .foregroundStyle(.orange)
                    Button("Freigabe anfordern…") { ScreenTimeReader.requestTrust() }
                }
                Text("Die App liest die Werte aus den Systemeinstellungen (Familie → Bildschirmzeit). Dafür öffnet sie diese kurz im Hintergrund und schließt sie wieder. Sind die Systemeinstellungen gerade geöffnet, wird der Lauf ausgelassen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Eigene Sensoren für einzelne Apps") {
                TextField("Beobachtete Apps", text: $settings.watchedApps, axis: .vertical)
                    .lineLimit(2...5)
                Text("Kommagetrennt, z. B. „YouTube, ChatGPT“. Jede bekommt je Kind einen eigenen Sensor (sensor.screentime_kind1_app_youtube) — auch an Tagen mit 0 Minuten, damit der Verlauf keine Lücken bekommt. Jede Nutzungszeit bekommt automatisch einen eigenen Sensor.")
                    .font(.caption).foregroundStyle(.secondary)

                let seen = runner.statuses.values
                    .flatMap { $0.byApp }
                    .reduce(into: [String: Double]()) { $0[$1.key, default: 0] += $1.value }
                if !seen.isEmpty {
                    Text("Zuletzt gesehen — zum Hinzufügen klicken:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(seen.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { name, _ in
                            Button(name) { watch(name) }
                                .buttonStyle(.link)
                                .disabled(settings.watchedApps.contains(name))
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Benachrichtigung

    private var notifyTab: some View {
        Form {
            Section("Mail (lokaler MailRelay)") {
                TextField("SMTP-Host", text: $settings.smtpHost, prompt: Text("::1"))
                TextField("Port", value: $settings.smtpPort, format: .number)
                TextField("Absender", text: $settings.mailSender)
                TextField("Empfänger", text: $settings.mailRecipient)
                Text("Hinweis: nicht 127.0.0.1 verwenden — über den reinen IPv4-Loopback nimmt der Relay pro Idle-Phase nur eine Verbindung an. ::1 oder die LAN-IP des Rechners funktionieren.")
                    .font(.caption).foregroundStyle(.secondary)

                HStack {
                    Button("Testmail senden") { sendTestMail() }
                        .disabled(settings.mailRecipient.trimmingCharacters(in: .whitespaces).isEmpty)
                    if let result = mailTestResult {
                        Text(result).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }

            Section("Wann melden") {
                Toggle("Bei Problemen (Lauf fehlgeschlagen)", isOn: $settings.notifyOnProblem)

                Toggle("Wenn das Tageslimit überschritten wird", isOn: $settings.notifyOnThreshold)
                if settings.notifyOnThreshold {
                    Stepper("Limit: \(settings.thresholdMinutes) Minuten",
                            value: $settings.thresholdMinutes, in: 30...900, step: 15)
                }

                Toggle("Täglicher Bericht", isOn: $settings.dailySummary)
                if settings.dailySummary {
                    TextField("Uhrzeit (HH:mm)", text: $settings.dailySummaryTime)
                }
            }

            Section {
                Text("Der Ausfall der Erfassung selbst (z. B. weil nach einem Neustart niemand angemeldet ist) kann die App nicht melden — dann läuft sie ja nicht. Das übernimmt eine Automation in Home Assistant, die prüft, ob die Sensoren noch aktualisiert werden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Eine App in die Beobachtungsliste aufnehmen.
    private func watch(_ name: String) {
        let current = settings.watchedApps.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.watchedApps = current.isEmpty ? name : current + ", " + name
    }

    private func sendTestMail() {
        mailTestResult = "sende…"
        let s = settings
        Task { @MainActor in
            let ok = await Mailer.send(
                subject: "Screen Time: Testmail",
                body: "Diese Testmail kommt aus der HA-Screen-Time-App.",
                settings: s)
            mailTestResult = ok ? "verschickt ✓" : "fehlgeschlagen ✗"
        }
    }
}
