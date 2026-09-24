import Foundation
import SwiftUI

/// Alle Einstellungen, gespeichert in `UserDefaults` des ausführenden Benutzers
/// (`~/Library/Preferences/de.nicx.hascreentime.plist`).
///
/// Bewusst hier und nicht in einer `.env`: der HA-Token ist ein Vollzugriff auf
/// Home Assistant und gehört nicht in eine Datei neben die App.
@MainActor
final class AppSettings: ObservableObject {

    // MARK: Home Assistant
    @AppStorage("haURL") var haURL: String = "http://localhost:8123"
    @AppStorage("haToken") var haToken: String = ""

    /// Name des Kindes, wie er unter Systemeinstellungen → Familie steht
    /// (nur der Vorname vor dem Komma, z. B. „Kind“ aus „Kind, Alter: 12“).
    @AppStorage("childName") var childName: String = ""

    /// Apps, die eigene Sensoren bekommen (kommagetrennt, Anzeigenamen wie in
    /// den Top-Apps). Bewusst eine feste Auswahl statt "jede gesehene App":
    /// sonst sammeln sich über die Wochen hunderte Entities an, die kommen und
    /// gehen, und blähen den Recorder auf.
    @AppStorage("watchedApps") var watchedApps: String = ""

    // MARK: Zeitplan
    /// Intervall zwischen zwei Läufen in Minuten.
    @AppStorage("intervalMinutes") var intervalMinutes: Int = 10

    // MARK: Benachrichtigungen
    @AppStorage("notifyOnProblem") var notifyOnProblem: Bool = true
    @AppStorage("notifyOnThreshold") var notifyOnThreshold: Bool = false
    /// Tagesgrenze in Minuten, ab der gewarnt wird.
    @AppStorage("thresholdMinutes") var thresholdMinutes: Int = 180
    @AppStorage("dailySummary") var dailySummary: Bool = false
    /// Uhrzeit der Tageszusammenfassung, Format "HH:mm".
    @AppStorage("dailySummaryTime") var dailySummaryTime: String = "20:00"

    // MARK: Mail
    /// Standard `::1` statt `127.0.0.1`: der lokale MailRelay nimmt über den
    /// reinen IPv4-Loopback pro Idle-Phase nur eine Verbindung an (bekannter
    /// Bundle-Bug, siehe mailrelay/HANDOFF.md). `::1` und die LAN-IP des Rechners sind
    /// nicht betroffen.
    @AppStorage("smtpHost") var smtpHost: String = "::1"
    @AppStorage("smtpPort") var smtpPort: Int = 2525
    @AppStorage("mailSender") var mailSender: String = ""
    @AppStorage("mailRecipient") var mailRecipient: String = ""

    var trimmedChildName: String { childName.trimmingCharacters(in: .whitespaces) }

    /// Auf Vollständigkeit prüfen, bevor ein Lauf startet.
    var configurationProblem: String? {
        if trimmedChildName.isEmpty {
            return "Kein Kind eingetragen."
        }
        if haToken.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Kein Home-Assistant-Token hinterlegt."
        }
        if haURL.trimmingCharacters(in: .whitespaces).isEmpty {
            return "Keine Home-Assistant-URL hinterlegt."
        }
        return nil
    }

    /// Umgebung für den Python-Lauf. Der Python-Teil liest genau diese Namen
    /// (`load_dotenv` überschreibt gesetzte Variablen nicht), eine `.env` im
    /// Bundle ist damit unnötig.
    func processEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["HA_URL"] = haURL.trimmingCharacters(in: .whitespaces)
        env["HA_TOKEN"] = haToken.trimmingCharacters(in: .whitespaces)
        // Quelle sind die von der App gelesenen Tageswerte (data/days), nicht
        // mehr Biome: dort kommen die Daten eines Kinder-Accounts seit iOS 27
        // nicht mehr an.
        env["SCREENTIME_SOURCE"] = "ui"
        env["SCREENTIME_CHILD"] = trimmedChildName
        env["WATCHED_APPS"] = watchedApps.trimmingCharacters(in: .whitespaces)
        env["SCREENTIME_DATA_DIR"] = BundledRuntime.dataDirectory.path
        // Ausgabe ungepuffert, damit das Log live mitläuft statt am Ende zu klumpen.
        env["PYTHONUNBUFFERED"] = "1"
        // Bytecode-Cache aus dem App-Bundle heraushalten: Python legt sonst
        // __pycache__-Dateien neben den Skripten und in der gebündelten Stdlib
        // an — das bricht bei jedem Lauf das Signatur-Siegel des Bundles
        // ("a sealed resource is missing or invalid") und gefährdet damit
        // erteilte Berechtigungen.
        env["PYTHONPYCACHEPREFIX"] = BundledRuntime.dataDirectory
            .deletingLastPathComponent().appendingPathComponent("pycache").path
        return env
    }
}
