import Foundation
import AppKit

/// Selbst-Aktualisierung der App.
///
/// Hintergrund: Die App läuft im Sammel-Benutzer, an dessen Sitzung von außen
/// niemand herankommt — macOS erlaubt nicht einmal, dessen Prozess ein Signal
/// zu senden. Jede Codeänderung hätte sonst zwei Handgriffe am Gerät gebraucht.
/// Die App darf aber ihren *eigenen* Prozess beenden und neu starten, und genau
/// das nutzt sie hier.
///
/// Ablauf: Es liegt eine fertig gebaute, signierte Version unter
/// `/Users/Shared/HAScreenTime-Update/`. Unterscheidet sich deren `BUILD-ID` von
/// der eigenen, spawnt die App ein kleines Hilfsskript, beendet sich, und das
/// Skript spiegelt die neue Version über das laufende Bundle und startet es neu.
///
/// Der Bundle-**Pfad bleibt bewusst gleich** (`/Applications/HAScreenTime.app`):
/// Ein Umzug könnte den erteilten Festplattenvollzugriff kosten, und ohne den
/// sammelt die App stumm keine Daten mehr. Damit der Sammel-Benutzer — ein
/// Standardbenutzer ohne Schreibrecht auf `/Applications` — das Bundle ersetzen
/// darf, setzt `Scripts/install-app.sh` einmalig `chmod -R a+w` darauf.
enum Updater {

    static let stagingDirectory = URL(fileURLWithPath: "/Users/Shared/HAScreenTime-Update", isDirectory: true)

    static var stagedBundle: URL { stagingDirectory.appendingPathComponent("HAScreenTime.app") }

    /// Build-Kennung der bereitliegenden Version.
    static var stagedBuildID: String? {
        readBuildID(at: stagedBundle.appendingPathComponent("Contents/Resources/BUILD-ID"))
    }

    /// Build-Kennung der laufenden Version.
    static var runningBuildID: String? {
        guard let res = Bundle.main.resourceURL else { return nil }
        return readBuildID(at: res.appendingPathComponent("BUILD-ID"))
    }

    private static func readBuildID(at url: URL) -> String? {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    /// Liegt eine andere Version bereit als die laufende?
    static var updateAvailable: Bool {
        guard let staged = stagedBuildID else { return false }
        // Fehlt die eigene Kennung (Version von vor diesem Mechanismus), gilt
        // alles Bereitliegende als neuer.
        guard let running = runningBuildID else { return true }
        return staged != running
    }

    /// Prüft und wendet an. Gibt `true` zurück, wenn ein Neustart eingeleitet wurde.
    @MainActor
    static func applyIfAvailable(log: LogStore) -> Bool {
        guard updateAvailable else { return false }

        let staged = stagedBundle
        guard FileManager.default.fileExists(atPath: staged.path) else { return false }

        // Nur eine gültig signierte Version einspielen — sonst riskieren wir ein
        // kaputtes Bundle, das macOS gar nicht mehr startet.
        guard verifySignature(of: staged) else {
            log.appendSystem("Update abgelehnt: Signatur von \(staged.path) ist ungültig.")
            return false
        }

        let target = Bundle.main.bundleURL
        guard FileManager.default.isWritableFile(atPath: target.path) else {
            log.appendSystem("Update nicht möglich: \(target.path) ist nicht beschreibbar "
                             + "(install-app.sh setzt dafür chmod a+w).")
            return false
        }

        log.appendSystem("Update gefunden (\(stagedBuildID ?? "?")), starte neu…")

        guard let helper = writeHelperScript(staged: staged, target: target) else {
            log.appendSystem("Update fehlgeschlagen: Hilfsskript ließ sich nicht anlegen.")
            return false
        }

        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/bin/zsh")
        proc.arguments = [helper.path, String(ProcessInfo.processInfo.processIdentifier)]
        do {
            try proc.run()
        } catch {
            log.appendSystem("Update fehlgeschlagen: \(error.localizedDescription)")
            return false
        }

        // Das Hilfsskript wartet auf unser Ende, bevor es das Bundle anfasst.
        NSApp.terminate(nil)
        return true
    }

    private static func verifySignature(of bundle: URL) -> Bool {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
        proc.arguments = ["--verify", "--strict", bundle.path]
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice
        do { try proc.run() } catch { return false }
        proc.waitUntilExit()
        return proc.terminationStatus == 0
    }

    private static func writeHelperScript(staged: URL, target: URL) -> URL? {
        // rsync --delete statt ditto: das Bundle-Verzeichnis selbst bleibt
        // bestehen (es zu ersetzen bräuchte Schreibrecht auf /Applications),
        // sein Inhalt wird aber exakt gespiegelt — inklusive Entfernen von
        // Dateien, die es in der neuen Version nicht mehr gibt. Bliebe etwas
        // liegen, wäre die Signatur ungültig.
        let script = """
        #!/bin/zsh
        set -u
        PARENT_PID="$1"
        LOG="$HOME/Library/Logs/HAScreenTime/update.log"
        mkdir -p "$(dirname "$LOG")"
        echo "--- $(date '+%F %T') Update gestartet ---" >> "$LOG"

        # Auf das Ende der laufenden App warten (max. 60 s).
        for i in {1..120}; do
          kill -0 "$PARENT_PID" 2>/dev/null || break
          sleep 0.5
        done

        rsync -a --delete "\(staged.path)/" "\(target.path)/" >> "$LOG" 2>&1
        RC=$?
        echo "rsync rc=$RC" >> "$LOG"

        if /usr/bin/codesign --verify --strict "\(target.path)" >> "$LOG" 2>&1; then
          echo "Signatur nach Update gültig" >> "$LOG"
        else
          echo "WARNUNG: Signatur nach Update ungültig" >> "$LOG"
        fi

        /usr/bin/open -a "\(target.path)"
        echo "neu gestartet" >> "$LOG"
        """
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("hascreentime-update-\(UUID().uuidString).sh")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
            return url
        } catch {
            return nil
        }
    }
}
