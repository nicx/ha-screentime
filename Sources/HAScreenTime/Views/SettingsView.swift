import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var runner: ExportRunner
    @EnvironmentObject private var loginItem: LoginItemManager
    @EnvironmentObject private var scanner: DeviceScanner

    @State private var mailTestResult: String?

    var body: some View {
        TabView {
            generalTab.tabItem { Label("Allgemein", systemImage: "gearshape") }
            devicesTab.tabItem { Label("Geräte", systemImage: "iphone") }
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

    // MARK: Geräte

    private var devicesTab: some View {
        Form {
            Section("Zu erfassende Geräte") {
                TextField("Geräte", text: $settings.devices, axis: .vertical)
                    .lineLimit(3...6)
                Text("Format: Name:UUID, Name:UUID — der Name bestimmt die Entity-ID in Home Assistant (z. B. „Kind iPhone“ → sensor.screentime_kind_iphone).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Eigene Sensoren für einzelne Apps") {
                TextField("Beobachtete Apps", text: $settings.watchedApps, axis: .vertical)
                    .lineLimit(2...5)
                Text("Kommagetrennt, z. B. „YouTube, ChatGPT“. Jede bekommt einen eigenen Sensor (sensor.screentime_app_youtube) — auch an Tagen mit 0 Minuten, damit der Verlauf keine Lücken bekommt. Kategorien bekommen automatisch eigene Sensoren.")
                    .font(.caption).foregroundStyle(.secondary)

                if let status = runner.status, !status.byApp.isEmpty {
                    Text("Zuletzt gesehen — zum Hinzufügen klicken:")
                        .font(.caption).foregroundStyle(.secondary)
                    HStack {
                        ForEach(status.byApp.sorted(by: { $0.value > $1.value }).prefix(5), id: \.key) { name, _ in
                            Button(name) { watch(name) }
                                .buttonStyle(.link)
                                .disabled(settings.watchedApps.contains(name))
                        }
                    }
                }
            }

            Section("Dieser Mac") {
                Toggle("Nutzung dieses Macs mitzählen", isOn: $settings.collectMac)
                Text("Standard aus: dieser Mac sammelt nur, seine eigene „Nutzung“ sind Wartungssitzungen und würde die Werte verfälschen.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section("Geräte-IDs ermitteln") {
                HStack {
                    Button("Geräte suchen") {
                        Task { await scanner.scan() }
                    }
                    .disabled(scanner.isScanning)
                    if scanner.isScanning {
                        ProgressView().controlSize(.small)
                        Text("suche…").font(.caption).foregroundStyle(.secondary)
                    }
                }

                if let err = scanner.error {
                    Text(err).font(.caption).foregroundStyle(.red)
                }

                if !scanner.devices.isEmpty {
                    Text("Die Gerätenamen sind bei Apple meist leer — erkennbar sind die Geräte an ihren Apps.")
                        .font(.caption).foregroundStyle(.secondary)

                    ForEach(scanner.devices) { device in
                        VStack(alignment: .leading, spacing: 2) {
                            HStack {
                                Text("\(device.platformName) · \(device.events) Ereignisse")
                                    .font(.callout)
                                Spacer()
                                Button("Übernehmen") { add(device) }
                                    .disabled(settings.devices.contains(device.deviceId))
                            }
                            if !device.topAppsSummary.isEmpty {
                                Text(device.topAppsSummary)
                                    .font(.caption).foregroundStyle(.secondary)
                                    .lineLimit(2)
                            }
                            Text(device.deviceId)
                                .font(.system(.caption2, design: .monospaced))
                                .foregroundStyle(.tertiary)
                                .textSelection(.enabled)
                        }
                        .padding(.vertical, 2)
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
                Text("Der Ausfall der Erfassung selbst (z. B. weil dieser Benutzer nach einem Neustart nicht angemeldet wurde) kann die App nicht melden — dann läuft sie ja nicht. Das übernimmt eine Automation in Home Assistant, die prüft, ob die Sensoren noch aktualisiert werden.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    /// Ein gefundenes Gerät in die Konfiguration übernehmen. Der Name ist ein
    /// Vorschlag (z.B. "iPhone") und bestimmt die Entity-ID in Home Assistant —
    /// er lässt sich im Textfeld darüber anpassen.
    private func add(_ device: ScannedDevice) {
        let name = device.platformName
        let entry = "\(name):\(device.deviceId)"
        let current = settings.devices.trimmingCharacters(in: .whitespacesAndNewlines)
        settings.devices = current.isEmpty ? entry : current + "," + entry
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
