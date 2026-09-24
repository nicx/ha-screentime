import Foundation

/// Löst die gebündelte, autarke Python-Runtime und die mitgelieferten Skripte auf.
///
/// Layout aus `Scripts/bundle-runtime.sh` bzw. `Scripts/make-app.sh` (im `.app`
/// unter `Contents/Resources/`):
/// ```
/// Runtime/python/bin/python3                 relocatable CPython 3.13 (arm64)
/// Runtime/python/lib/python3.13/…            Stdlib + site-packages
/// payload/run.py, payload/src/…              unser Collector/Exporter
/// ```
/// Anders als bei den Schwester-Apps (esphome/home-assistant) gibt es **keine**
/// venv in `~/Library` und keine Installation beim ersten Start: alle
/// Abhängigkeiten stecken bereits in `Runtime`. Die App ist damit sofort
/// lauffähig und unabhängig von jeder Python-Installation auf dem System.
///
/// Overrides für die Entwicklung: `HASCREENTIME_RUNTIME_DIR`, `HASCREENTIME_PAYLOAD_DIR`.
enum BundledRuntime {

    enum RuntimeError: LocalizedError {
        case pythonMissing(String)
        case payloadMissing(String)

        var errorDescription: String? {
            switch self {
            case .pythonMissing(let path):
                return "Gebündelte Python-Runtime fehlt (\(path)). Scripts/bundle-runtime.sh ausführen."
            case .payloadMissing(let path):
                return "run.py fehlt im Bundle (\(path))."
            }
        }
    }

    /// Package-Wurzel, aus dem Speicherort dieser Datei abgeleitet.
    /// BundledRuntime.swift -> HAScreenTime -> Sources -> <packageRoot>
    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// Verzeichnis mit `python/`.
    static var runtimeRoot: URL {
        if let override = ProcessInfo.processInfo.environment["HASCREENTIME_RUNTIME_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("Runtime", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("python").path) {
                return bundled
            }
        }
        return packageRoot.appendingPathComponent("Runtime", isDirectory: true)
    }

    /// Verzeichnis mit `run.py` und `src/`.
    static var payloadRoot: URL {
        if let override = ProcessInfo.processInfo.environment["HASCREENTIME_PAYLOAD_DIR"] {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        if let resources = Bundle.main.resourceURL {
            let bundled = resources.appendingPathComponent("payload", isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.appendingPathComponent("run.py").path) {
                return bundled
            }
        }
        // Dev-Fallback: die Skripte liegen direkt im Repo-Root.
        return packageRoot
    }

    static var pythonURL: URL { runtimeRoot.appendingPathComponent("python/bin/python3") }
    static var runScriptURL: URL { payloadRoot.appendingPathComponent("run.py") }

    /// Schreibbares Datenverzeichnis im Benutzer-Home (CSV, Wasserzeichen, status.json).
    /// Liegt bewusst im Home des ausführenden Benutzers.
    static var dataDirectory: URL {
        let base = FileManager.default.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library")
        return base.appendingPathComponent("HAScreenTime/data", isDirectory: true)
    }

    /// Gemeinsame Diagnose aller Kinder (wird als sensor.screentime_diagnose gespiegelt).
    static var diagnosticsURL: URL { dataDirectory.appendingPathComponent("diagnostics.json") }

    /// Datenverzeichnis eines Kindes: Tagesdateien, CSV, status.json.
    static func childDirectory(_ child: String) -> URL {
        dataDirectory.appendingPathComponent("children/\(slug(child))", isDirectory: true)
    }

    static func statusFileURL(_ child: String) -> URL {
        childDirectory(child).appendingPathComponent("status.json")
    }

    /// Namensteil fuer Entity-IDs -- dieselbe Regel wie `slugify` im Python-Teil:
    /// Kleinbuchstaben, Umlaute ausgeschrieben, alles andere wird zu "_".
    static func slug(_ name: String) -> String {
        var s = name.lowercased()
        for (from, to) in [("ä", "ae"), ("ö", "oe"), ("ü", "ue"), ("ß", "ss")] {
            s = s.replacingOccurrences(of: from, with: to)
        }
        s = s.folding(options: .diacriticInsensitive, locale: Locale(identifier: "en_US_POSIX"))
        let mapped = s.unicodeScalars.map { ("a"..."z").contains($0) || ("0"..."9").contains($0) ? Character($0) : "_" }
        let collapsed = String(mapped).split(separator: "_").joined(separator: "_")
        return collapsed.isEmpty ? "unknown" : collapsed
    }

    static func validate() throws {
        guard FileManager.default.isExecutableFile(atPath: pythonURL.path) else {
            throw RuntimeError.pythonMissing(pythonURL.path)
        }
        guard FileManager.default.fileExists(atPath: runScriptURL.path) else {
            throw RuntimeError.payloadMissing(runScriptURL.path)
        }
    }
}
