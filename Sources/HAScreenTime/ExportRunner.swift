import Foundation

/// Ergebnis des letzten Laufs, gelesen aus `status.json` (schreibt der Exporter).
struct RunStatus: Codable, Equatable {
    var totalMinutes: Double
    var topApp: String
    var topAppMinutes: Double
    var sessionCount: Int
    var byDevice: [String: Double]
    var byCategory: [String: Double]
    var byApp: [String: Double]
    var updatedAt: String
    var date: String

    enum CodingKeys: String, CodingKey {
        case totalMinutes = "total_minutes"
        case topApp = "top_app"
        case topAppMinutes = "top_app_minutes"
        case sessionCount = "session_count"
        case byDevice = "by_device"
        case byCategory = "by_category"
        case byApp = "by_app"
        case updatedAt = "updated_at"
        case date
    }
}

enum RunState: Equatable {
    case idle
    case running
    case ok
    case failed(String)
}

/// Führt den gebündelten Python-Lauf (`run.py`) periodisch aus, wertet dessen
/// Status aus und löst die Benachrichtigungen aus.
///
/// Anders als bei den Schwester-Apps läuft hier kein langlebiger Serverprozess,
/// sondern ein kurzer Job pro Intervall — deshalb ein Scheduler + `Process`
/// statt Prozessüberwachung mit Neustart.
@MainActor
final class ExportRunner: ObservableObject {

    @Published private(set) var state: RunState = .idle
    /// Letzter Stand je Kind (Schluessel: Name wie in den Einstellungen).
    @Published private(set) var statuses: [String: RunStatus] = [:]
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSuccess: Date?

    private let settings: AppSettings
    private let log: LogStore
    private let notifier: Notifier

    private var scheduler: NSBackgroundActivityScheduler?
    private var activityToken: NSObjectProtocol?
    private var isRunning = false

    /// Verhindert, dass Schwellwert-/Tagesmail mehrfach am selben Tag rausgeht.
    private var thresholdNotifiedOn: [String: String] = [:]
    private var summarySentOn: String?

    init(settings: AppSettings, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.log = log
        self.notifier = notifier
        reloadStatuses()
    }

    /// Stände in der Reihenfolge der Einstellungen (für Menü und Mails).
    var orderedStatuses: [(child: String, status: RunStatus)] {
        settings.children.compactMap { child in statuses[child].map { (child, $0) } }
    }

    // MARK: - Zeitplan

    /// Startet den periodischen Lauf.
    ///
    /// Bewusst `NSBackgroundActivityScheduler` statt eines `Timer` auf der
    /// Main-Runloop: Die App ist eine Hintergrund-App (`LSUIElement`) und läuft
    /// in einer Benutzersitzung, die nicht die aktive Konsolensitzung ist.
    /// macOS drosselt solche Prozesse per App Nap — ein Timer feuert dann
    /// schlicht nicht mehr (in der Praxis: nach dem Start-Lauf kam über Stunden
    /// kein einziger weiterer). Der Scheduler ist genau für periodische
    /// Hintergrundarbeit gedacht und weckt die App dafür auf; zusätzlich melden
    /// wir laufende Aktivität an, damit wir gar nicht erst eingeschläfert werden.
    func startScheduling() {
        stopScheduling()

        // Verhindert App Nap, erlaubt dem Mac aber weiterhin, selbst zu schlafen.
        activityToken = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiatedAllowingIdleSystemSleep],
            reason: "Screen-Time-Export im Zeitplan")

        let interval = TimeInterval(max(1, settings.intervalMinutes) * 60)
        let s = NSBackgroundActivityScheduler(identifier: "de.nicx.hascreentime.export")
        s.repeats = true
        s.interval = interval
        // Toleranz schont die Energieverwaltung; der genaue Zeitpunkt ist egal.
        s.tolerance = interval * 0.1
        s.qualityOfService = .utility
        s.schedule { [weak self] completion in
            Task { @MainActor in
                await self?.runOnce(trigger: "Zeitplan")
                completion(.finished)
            }
        }
        scheduler = s
        log.appendSystem("Zeitplan aktiv: alle \(settings.intervalMinutes) Minuten")
    }

    func stopScheduling() {
        scheduler?.invalidate()
        scheduler = nil
        if let token = activityToken {
            ProcessInfo.processInfo.endActivity(token)
            activityToken = nil
        }
    }

    /// Nach Änderung des Intervalls neu aufsetzen.
    func rescheduleIfNeeded() {
        guard scheduler != nil else { return }
        startScheduling()
    }

    // MARK: - Lauf

    func runOnce(trigger: String) async {
        guard !isRunning else {
            log.appendSystem("Lauf läuft bereits – \(trigger) übersprungen")
            return
        }
        if let problem = settings.configurationProblem {
            state = .failed(problem)
            log.appendSystem("Nicht konfiguriert: \(problem)")
            return
        }
        do {
            try BundledRuntime.validate()
        } catch {
            let message = error.localizedDescription
            state = .failed(message)
            log.appendSystem(message)
            notifier.report(ScreenTimeConditions.run, healthy: false, detail: message)
            return
        }

        isRunning = true
        state = .running
        log.appendSystem("Lauf gestartet (\(trigger))")
        let children = settings.children

        // Erst auslesen, dann exportieren. Scheitert das Auslesen, laeuft der
        // Export trotzdem mit den vorhandenen Tageswerten -- sonst verschwaenden
        // die per REST gesetzten Sensoren nach dem naechsten HA-Neustart.
        let readProblem = await readScreenTime(children)

        var failures: [String] = []
        for child in children {
            let result = await execute(child: child)
            if result.exitCode != 0 {
                failures.append(result.tail.isEmpty
                    ? "\(child): run.py endete mit Code \(result.exitCode)."
                    : "\(child): run.py endete mit Code \(result.exitCode):\n\n\(result.tail)")
            }
        }
        lastRun = Date()
        isRunning = false

        // Nach dem Lauf pruefen, ob eine neuere Version bereitliegt. Bewusst
        // danach und nicht davor: erst die Arbeit erledigen, dann neu starten.
        if Updater.applyIfAvailable(log: log) { return }

        reloadStatuses()
        if failures.isEmpty {
            state = readProblem.map { .failed($0) } ?? .ok
            lastSuccess = Date()
            notifier.report(ScreenTimeConditions.run, healthy: true)
            checkThresholds()
            checkDailySummary()
        } else {
            state = .failed("Lauf fehlgeschlagen")
            notifier.report(ScreenTimeConditions.run, healthy: false, detail: failures.joined(separator: "\n\n"))
        }
    }

    // MARK: - Auslesen der Bildschirmzeit

    /// Wie viele vergangene Tage nachgeholt werden, falls sie fehlen (erster
    /// Lauf, Ausfall). Reicht Apples Verlauf weniger weit, bricht der Leser
    /// dort ab und behaelt, was er hat.
    private static let backfillDays = 14
    private static let lastReadSuccessKey = "lastUIReadSuccess"

    private static func daysDirectory(_ child: String) -> URL {
        BundledRuntime.childDirectory(child).appendingPathComponent("days", isDirectory: true)
    }

    private static func dayKey(offset: Int) -> String {
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: day)
    }

    private static func dayFile(_ child: String, _ key: String) -> URL {
        daysDirectory(child).appendingPathComponent("\(key).json")
    }

    /// Heute immer; den Vortag bis 6 Uhr erneut (Apple meldet die Abendnutzung
    /// oft verspaetet); dazu jeden fehlenden Tag der letzten zwei Wochen.
    private func dayOffsetsToRead(_ child: String) -> [Int] {
        var offsets: Set<Int> = [0]
        if Calendar.current.component(.hour, from: Date()) < 6 { offsets.insert(1) }
        for off in 1...Self.backfillDays
        where !FileManager.default.fileExists(atPath: Self.dayFile(child, Self.dayKey(offset: off)).path) {
            offsets.insert(off)
        }
        return offsets.sorted()
    }

    /// Liest die Bildschirmzeit aller Kinder aus den Systemeinstellungen und
    /// legt je Kind und Tag eine Datei ab. Rueckgabe: Fehlermeldung fuer die
    /// Statusanzeige, sonst nil.
    private func readScreenTime(_ children: [String]) async -> String? {
        let plan = children.map { (child: $0, dayOffsets: dayOffsetsToRead($0)) }
        for child in children {
            try? FileManager.default.createDirectory(at: Self.daysDirectory(child), withIntermediateDirectories: true)
        }
        let logSink: (String) -> Void = { [weak self] line in
            Task { @MainActor in self?.log.appendSystem(line) }
        }
        let started = Date()
        let dayCount = plan.map(\.dayOffsets.count).reduce(0, +)
        log.appendSystem("Lese Bildschirmzeit: \(children.joined(separator: ", ")) (\(dayCount) Tage)")

        let outcome: Result<[String: Result<[DaySnapshot], Error>], Error> = await Task.detached(priority: .utility) {
            Result { try ScreenTimeReader(log: logSink).read(plan) }
        }.value

        var diag: [String: Any] = [
            "quelle": "ui",
            "written_at": ISO8601DateFormatter().string(from: Date()),
            "dauer_s": (Date().timeIntervalSince(started) * 10).rounded() / 10,
            "hard_error": false,
        ]
        let enc = JSONEncoder()
        enc.keyEncodingStrategy = .convertToSnakeCase
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]

        var problems: [String] = []
        switch outcome {
        case .success(let perChild):
            var kinder: [String: Any] = [:]
            for child in children {
                var info: [String: Any] = [:]
                switch perChild[child] {
                case .success(let snapshots)?:
                    for snap in snapshots {
                        if let data = try? enc.encode(snap) {
                            try? data.write(to: Self.dayFile(child, snap.date), options: .atomic)
                        }
                    }
                    info["tage_gelesen"] = snapshots.map(\.date)
                    info["apple_aktualisiert"] = snapshots.first?.appleUpdated
                    info["geraet"] = snapshots.first?.device
                case .failure(let error)?:
                    info["fehler"] = error.localizedDescription
                    problems.append("\(child): \(error.localizedDescription)")
                    log.appendSystem("Auslesen \(child): \(error.localizedDescription)")
                case nil:
                    info["fehler"] = "nicht gelesen"
                    problems.append("\(child): nicht gelesen")
                }
                kinder[child] = info
            }
            diag["kinder"] = kinder
            if problems.isEmpty {
                UserDefaults.standard.set(Date(), forKey: Self.lastReadSuccessKey)
                notifier.report(ScreenTimeConditions.read, healthy: true)
            } else {
                diag["hard_error"] = true
                notifier.report(ScreenTimeConditions.read, healthy: false, detail: problems.joined(separator: "\n"))
            }
        case .failure(let error):
            let message = error.localizedDescription
            log.appendSystem("Auslesen: \(message)")
            diag["fehler"] = message
            if case ScreenTimeReaderError.settingsInUse = error {
                // Kein Fehler: jemand benutzt gerade die Systemeinstellungen.
            } else {
                diag["hard_error"] = true
                notifier.report(ScreenTimeConditions.read, healthy: false, detail: message)
                problems.append(message)
            }
        }
        if let last = UserDefaults.standard.object(forKey: Self.lastReadSuccessKey) as? Date {
            diag["letzter_erfolg"] = ISO8601DateFormatter().string(from: last)
        }
        if let data = try? JSONSerialization.data(withJSONObject: diag, options: [.prettyPrinted, .sortedKeys]) {
            try? data.write(to: BundledRuntime.diagnosticsURL, options: .atomic)
        }
        return problems.isEmpty ? nil : problems.joined(separator: "; ")
    }

    // MARK: - Python-Lauf

    private func execute(child: String) async -> (exitCode: Int32, tail: String) {
        let proc = Process()
        proc.executableURL = BundledRuntime.pythonURL
        proc.arguments = [BundledRuntime.runScriptURL.path]
        proc.currentDirectoryURL = BundledRuntime.payloadRoot
        proc.environment = settings.processEnvironment(child: child)

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        // Letzte Ausgabezeilen für die Fehlermail sammeln.
        var recent: [String] = []

        pipe.fileHandleForReading.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            Task { @MainActor in
                self?.log.append(text)
                for line in text.split(separator: "\n", omittingEmptySubsequences: true) {
                    recent.append(String(line))
                }
                if recent.count > 25 { recent.removeFirst(recent.count - 25) }
            }
        }

        return await withCheckedContinuation { (cont: CheckedContinuation<(Int32, String), Never>) in
            proc.terminationHandler = { p in
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    cont.resume(returning: (p.terminationStatus, recent.joined(separator: "\n")))
                }
            }
            do {
                try proc.run()
            } catch {
                pipe.fileHandleForReading.readabilityHandler = nil
                Task { @MainActor in
                    self.log.appendSystem("Start fehlgeschlagen: \(error.localizedDescription)")
                    cont.resume(returning: (-1, error.localizedDescription))
                }
            }
        }
    }

    // MARK: - Auswertung

    private func reloadStatuses() {
        var out: [String: RunStatus] = [:]
        for child in settings.children {
            if let data = try? Data(contentsOf: BundledRuntime.statusFileURL(child)),
               let st = try? JSONDecoder().decode(RunStatus.self, from: data) {
                out[child] = st
            }
        }
        statuses = out
    }

    private func checkThresholds() {
        guard settings.notifyOnThreshold else { return }
        let today = Self.todayKey()
        for (child, status) in orderedStatuses where status.date == today {
            guard status.totalMinutes >= Double(settings.thresholdMinutes) else { continue }
            guard thresholdNotifiedOn[child] != today else { continue }
            thresholdNotifiedOn[child] = today
            notifier.oneShot(
                subject: "Screen Time \(child): Limit überschritten (\(Int(status.totalMinutes)) min)",
                body: """
                Heutige Bildschirmzeit von \(child): \(format(status.totalMinutes))
                Grenze: \(format(Double(settings.thresholdMinutes)))

                \(summaryBody(status))
                """)
        }
    }

    private func checkDailySummary() {
        guard settings.dailySummary else { return }
        let today = Self.todayKey()
        guard summarySentOn != today else { return }
        let current = orderedStatuses.filter { $0.status.date == today }
        guard !current.isEmpty else { return }

        // Erst ab der eingestellten Uhrzeit senden.
        let parts = settings.dailySummaryTime.split(separator: ":")
        let hour = parts.count == 2 ? Int(parts[0]) ?? 20 : 20
        let minute = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let h = now.hour, let m = now.minute,
              (h > hour || (h == hour && m >= minute)) else { return }

        summarySentOn = today
        let headline = current.map { "\($0.child) \(format($0.status.totalMinutes))" }.joined(separator: ", ")
        let body = current.map { "=== \($0.child) ===\n\(summaryBody($0.status))" }.joined(separator: "\n")
        notifier.oneShot(subject: "Screen Time: Tagesbericht (\(headline))", body: body)
    }

    private func summaryBody(_ status: RunStatus) -> String {
        var out = "Bildschirmzeit gesamt: \(format(status.totalMinutes))\n"
        if !status.byApp.isEmpty {
            out += "\nTop-Apps:\n"
            for (name, minutes) in status.byApp.sorted(by: { $0.value > $1.value }).prefix(10) {
                out += "  \(name): \(format(minutes))\n"
            }
        }
        if !status.byCategory.isEmpty {
            out += "\nKategorien:\n"
            for (name, minutes) in status.byCategory.sorted(by: { $0.value > $1.value }) {
                out += "  \(name): \(format(minutes))\n"
            }
        }
        return out
    }

    func format(_ minutes: Double) -> String {
        let total = Int(minutes.rounded())
        return total >= 60 ? "\(total / 60) h \(total % 60) min" : "\(total) min"
    }

    private static func todayKey() -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: Date())
    }
}
