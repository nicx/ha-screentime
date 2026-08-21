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
    @Published private(set) var status: RunStatus?
    @Published private(set) var lastRun: Date?
    @Published private(set) var lastSuccess: Date?

    private let settings: AppSettings
    private let log: LogStore
    private let notifier: Notifier

    private var scheduler: NSBackgroundActivityScheduler?
    private var activityToken: NSObjectProtocol?
    private var isRunning = false

    /// Verhindert, dass Schwellwert-/Tagesmail mehrfach am selben Tag rausgeht.
    private var thresholdNotifiedOn: String?
    private var summarySentOn: String?

    init(settings: AppSettings, log: LogStore, notifier: Notifier) {
        self.settings = settings
        self.log = log
        self.notifier = notifier
        self.status = Self.readStatus()
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

        try? FileManager.default.createDirectory(at: BundledRuntime.dataDirectory,
                                                 withIntermediateDirectories: true)

        let result = await execute()
        lastRun = Date()
        isRunning = false

        if result.exitCode == 0 {
            state = .ok
            lastSuccess = Date()
            status = Self.readStatus()
            notifier.report(ScreenTimeConditions.run, healthy: true)
            checkThreshold()
            checkDailySummary()
        } else {
            let detail = result.tail.isEmpty
                ? "run.py endete mit Code \(result.exitCode)."
                : "run.py endete mit Code \(result.exitCode):\n\n\(result.tail)"
            state = .failed("Lauf fehlgeschlagen (Code \(result.exitCode))")
            notifier.report(ScreenTimeConditions.run, healthy: false, detail: detail)
        }
    }

    private func execute() async -> (exitCode: Int32, tail: String) {
        let proc = Process()
        proc.executableURL = BundledRuntime.pythonURL
        proc.arguments = [BundledRuntime.runScriptURL.path]
        proc.currentDirectoryURL = BundledRuntime.payloadRoot
        proc.environment = settings.processEnvironment()

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

    private static func readStatus() -> RunStatus? {
        guard let data = try? Data(contentsOf: BundledRuntime.statusFileURL) else { return nil }
        return try? JSONDecoder().decode(RunStatus.self, from: data)
    }

    private func checkThreshold() {
        guard settings.notifyOnThreshold, let status else { return }
        let today = Self.todayKey()
        guard status.date == today else { return }
        guard status.totalMinutes >= Double(settings.thresholdMinutes) else {
            // Neuer Tag bzw. wieder unter der Grenze: erneut scharf schalten.
            if thresholdNotifiedOn != today { thresholdNotifiedOn = nil }
            return
        }
        guard thresholdNotifiedOn != today else { return }
        thresholdNotifiedOn = today

        notifier.oneShot(
            subject: "Screen Time: Limit überschritten (\(Int(status.totalMinutes)) min)",
            body: """
            Heutige Bildschirmzeit: \(format(status.totalMinutes))
            Grenze: \(format(Double(settings.thresholdMinutes)))

            \(summaryBody(status))
            """)
    }

    private func checkDailySummary() {
        guard settings.dailySummary, let status else { return }
        let today = Self.todayKey()
        guard summarySentOn != today else { return }

        // Erst ab der eingestellten Uhrzeit senden.
        let parts = settings.dailySummaryTime.split(separator: ":")
        let hour = parts.count == 2 ? Int(parts[0]) ?? 20 : 20
        let minute = parts.count == 2 ? Int(parts[1]) ?? 0 : 0
        let now = Calendar.current.dateComponents([.hour, .minute], from: Date())
        guard let h = now.hour, let m = now.minute,
              (h > hour || (h == hour && m >= minute)) else { return }

        summarySentOn = today
        notifier.oneShot(
            subject: "Screen Time: Tagesbericht (\(format(status.totalMinutes)))",
            body: summaryBody(status))
    }

    private func summaryBody(_ status: RunStatus) -> String {
        var out = "Bildschirmzeit gesamt: \(format(status.totalMinutes))\n"
        if !status.byDevice.isEmpty {
            out += "\nGeräte:\n"
            for (name, minutes) in status.byDevice.sorted(by: { $0.value > $1.value }) {
                out += "  \(name): \(format(minutes))\n"
            }
        }
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
