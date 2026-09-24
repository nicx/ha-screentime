import AppKit
import ApplicationServices

/// Tagesstand eines Kindes, wie ihn die Bildschirmzeit-Ansicht zeigt.
/// Wird als JSON (snake_case) nach `data/children/<kind>/days/<datum>.json`
/// geschrieben und vom Python-Teil (`ui_import.py`) weiterverarbeitet.
struct DaySnapshot: Codable {
    struct App: Codable { var bundleId: String; var name: String; var seconds: Int? }
    struct Web: Codable { var domain: String; var seconds: Int? }
    /// Apples Kategorie mit fester Kennung (z. B. `DH1003` = Unterhaltung);
    /// seit iOS 27 lassen sich auch eigene anlegen.
    struct Category: Codable { var id: String; var name: String; var seconds: Int? }

    var child: String
    var date: String            // yyyy-MM-dd
    var label: String?          // z. B. "Heute, 24. September"
    var appleUpdated: String?   // z. B. "Heute um 15:45 aktualisiert"
    var device: String
    var totalSeconds: Int?
    var apps: [App]
    var web: [Web]
    var categories: [Category]
    var pickups: [String]
    var readAt: String
}

enum ScreenTimeReaderError: LocalizedError {
    case notTrusted
    case settingsInUse
    case launchFailed
    case notFound(String)
    case wrongView(String)
    case implausible(String)

    var errorDescription: String? {
        switch self {
        case .notTrusted:
            return "Bedienungshilfen-Berechtigung fehlt (Systemeinstellungen → Datenschutz & Sicherheit → Bedienungshilfen → HAScreenTime)."
        case .settingsInUse:
            return "Systemeinstellungen sind gerade geöffnet – Auslesen übersprungen."
        case .launchFailed:
            return "Systemeinstellungen ließen sich nicht starten."
        case .notFound(let what):
            return "Nicht gefunden: \(what)"
        case .wrongView(let what):
            return "Falsche Ansicht: \(what)"
        case .implausible(let what):
            return "Unplausible Werte: \(what)"
        }
    }
}

/// Liest die Bildschirmzeit von Kindern aus der Familien-Ansicht der
/// Systemeinstellungen (macOS 27) über die Bedienungshilfen.
///
/// Warum so: Seit iOS 27 bieten die Geräte eines Kinder-Accounts ihre
/// App-Nutzung nicht mehr über Biome an; exakte Zahlen stehen nur noch in
/// dieser Ansicht, und deren Datenbank ist ein DataVault (auch mit
/// Festplattenvollzugriff nicht lesbar). Apple versieht die Elemente mit
/// festen Kennungen wie `progress-bar-application:<bundle-id>` — darauf baut das.
///
/// Arbeitet synchron mit kurzen Wartezeiten; nur außerhalb des Main-Threads aufrufen.
final class ScreenTimeReader {

    /// Einträge im Menü „Darstellungsoptionen“ über der Liste.
    private static let appsMode = "Apps & Websites"
    private static let categoriesMode = "App-Kategorien"
    private static let bundleID = "com.apple.systempreferences"

    private let log: (String) -> Void
    private var appEl: AXUIElement?
    private var settingsApp: NSRunningApplication?
    private var launchedByUs = false

    init(log: @escaping (String) -> Void) {
        self.log = log
    }

    static var isTrusted: Bool { AXIsProcessTrusted() }

    /// Zeigt den System-Dialog, der zur Freigabe in den Bedienungshilfen führt.
    static func requestTrust() {
        let opt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
        _ = AXIsProcessTrustedWithOptions(opt)
    }

    /// Liest je Kind die angegebenen Tage (0 = heute, 1 = gestern, …).
    ///
    /// Scheitert ein Kind, bekommt nur dieses einen Fehler, die anderen werden
    /// trotzdem gelesen. Nur Probleme, die alle betreffen (Berechtigung,
    /// Systemeinstellungen in Benutzung), werfen.
    func read(_ plan: [(child: String, dayOffsets: [Int])]) throws -> [String: Result<[DaySnapshot], Error>] {
        guard Self.isTrusted else { throw ScreenTimeReaderError.notTrusted }
        // Sind die Systemeinstellungen schon offen, benutzt sie vermutlich
        // gerade jemand -- dann nicht fernsteuern, lieber einen Lauf auslassen.
        guard NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleID).isEmpty else {
            throw ScreenTimeReaderError.settingsInUse
        }
        try launchSettings()
        defer { cleanup() }

        var results: [String: Result<[DaySnapshot], Error>] = [:]
        for (child, offsets) in plan {
            results[child] = Result { try readChild(child, dayOffsets: offsets) }
            closeSheets()
        }
        return results
    }

    // MARK: - Ein Kind

    private func readChild(_ child: String, dayOffsets: [Int]) throws -> [DaySnapshot] {
        try openDetail(child)
        try ensureDayMode()
        if let today = first(id: "today-button") { press(today, "Heute") }
        pause(0.5)

        var snapshots: [DaySnapshot] = []
        var current = 0
        for offset in Set(dayOffsets).sorted() {
            do {
                while current < offset {
                    try stepBack()
                    current += 1
                }
                snapshots.append(try readCurrentDay(child: child, offset: offset))
            } catch where offset > 0 {
                // Vergangene Tage sind Zugabe: reicht Apples Verlauf nicht so weit
                // zurück oder hakt ein älterer Tag, bleiben die gelesenen erhalten.
                log("\(child): vergangene Tage ab \(offset) Tag(en) zurück übersprungen: \(error.localizedDescription)")
                break
            }
        }
        // Die Ansicht so hinterlassen, wie man sie von Hand vorfindet.
        try? setListMode(Self.appsMode)
        return snapshots
    }

    // MARK: - Start/Ende

    private func launchSettings() throws {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: Self.bundleID) else {
            throw ScreenTimeReaderError.launchFailed
        }
        let cfg = NSWorkspace.OpenConfiguration()
        cfg.activates = false          // nicht in den Vordergrund holen
        cfg.addsToRecentItems = false
        let done = DispatchSemaphore(value: 0)
        var launched: NSRunningApplication?
        NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, _ in
            launched = app
            done.signal()
        }
        done.wait()
        guard let app = launched else { throw ScreenTimeReaderError.launchFailed }
        settingsApp = app
        launchedByUs = true
        let el = AXUIElementCreateApplication(app.processIdentifier)
        AXUIElementSetMessagingTimeout(el, 5)
        appEl = el
        guard waitFor("Fenster der Systemeinstellungen", timeout: 15, { self.windows().first }) != nil else {
            throw ScreenTimeReaderError.notFound("Fenster der Systemeinstellungen")
        }
    }

    /// Alle Dialoge schließen, bis die Familienliste wieder frei ist.
    private func closeSheets() {
        for _ in 0..<4 {
            // Der innerste Dialog steht in Dokumentreihenfolge zuletzt.
            guard let done = all().last(where: { role($0) == "AXButton" && desc($0) == "Fertig" }) else { break }
            press(done, "Fertig")
            pause(0.6)
        }
    }

    private func cleanup() {
        closeSheets()
        if launchedByUs { settingsApp?.terminate() }
        appEl = nil
        settingsApp = nil
        launchedByUs = false
    }

    // MARK: - Navigation

    private func openDetail(_ child: String) throws {
        let prefix = child + ","
        let memberRow = {
            self.all().first { (self.ident($0) ?? "").hasPrefix("FAMILY_MEMBER_ROW_")
                && (self.desc($0) ?? "").hasPrefix(prefix) }
        }
        if memberRow() == nil {
            guard let family = waitFor("Familie in der Seitenleiste", { self.first(id: "com.apple.settings.family") }) else {
                throw ScreenTimeReaderError.notFound("Eintrag „Familie“ in der Seitenleiste")
            }
            selectSidebar(family)
        }
        guard let row = waitFor("Familienmitglied \(child)", memberRow) else {
            throw ScreenTimeReaderError.notFound("Familienmitglied „\(child)“")
        }
        press(row, "Familienmitglied")

        // Über „Heute am häufigsten verwendet“ öffnet sich die Detailansicht in
        // der Tagesansicht; das Wochendiagramm ist nur der Ausweichweg.
        guard waitFor("Bildschirmzeit-Übersicht", {
            self.first(id: "most-used-header-link") ?? self.first(id: "weekly-usage-summary-chart")
        }) != nil else {
            throw ScreenTimeReaderError.notFound("Bildschirmzeit-Übersicht von „\(child)“")
        }
        if let link = first(id: "most-used-header-link") {
            press(link, "Heute am häufigsten verwendet")
        } else if let chart = first(id: "weekly-usage-summary-chart") {
            press(chart, "Wochendiagramm")
        }
        guard waitFor("Detailansicht", { self.first(id: "day-picker-segment") }) != nil else {
            throw ScreenTimeReaderError.notFound("Detailansicht von „\(child)“")
        }
    }

    private func selectSidebar(_ el: AXUIElement) {
        if press(el, "Seitenleiste: Familie") { return }
        // Manche Seitenleisten-Einträge lassen sich nur über die Zeile auswählen.
        var cur: AXUIElement? = el
        while let c = cur, role(c) != "AXRow" {
            cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
        }
        if let row = cur {
            AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        }
    }

    /// Tagesansicht erzwingen und prüfen -- ein gedrückter Knopf heißt nicht,
    /// dass die Ansicht umgeschaltet hat (so geschehen im ersten Prototyp-Lauf).
    private func ensureDayMode() throws {
        for attempt in 1...3 {
            guard let seg = first(id: "day-picker-segment") else { break }
            if value(seg) == "1" { return }
            switch attempt {
            case 1: press(seg, "Tag")
            case 2: AXUIElementSetAttributeValue(seg, kAXValueAttribute as CFString, 1 as CFNumber)
            default: AXUIElementSetAttributeValue(seg, kAXSelectedAttribute as CFString, kCFBooleanTrue)
            }
            if waitFor("Tagesansicht", timeout: 3, {
                self.first(id: "day-picker-segment").flatMap { self.value($0) == "1" ? $0 : nil }
            }) != nil { return }
        }
        throw ScreenTimeReaderError.wrongView("Tagesansicht lässt sich nicht einstellen")
    }

    /// Liste unter „Am häufigsten verwendet“ auf Apps oder Kategorien stellen.
    private func setListMode(_ title: String) throws {
        guard let picker = first(id: "most-used-item-type-picker") else {
            throw ScreenTimeReaderError.notFound("Menü „Darstellungsoptionen“")
        }
        if value(picker) == title { return }
        press(picker, "Darstellungsoptionen")
        guard let item = waitFor("Menüpunkt „\(title)“", timeout: 3, {
            self.menuItems(near: picker).first { self.text($0, kAXTitleAttribute) == title }
        }) else {
            // Offenes Menü nicht stehen lassen.
            for menu in menus(near: picker) { AXUIElementPerformAction(menu, kAXCancelAction as CFString) }
            throw ScreenTimeReaderError.notFound("Menüpunkt „\(title)“")
        }
        press(item, title)
        guard waitFor("Darstellung „\(title)“", timeout: 4, {
            self.first(id: "most-used-item-type-picker").flatMap { self.value($0) == title ? $0 : nil }
        }) != nil else {
            throw ScreenTimeReaderError.wrongView("Darstellung „\(title)“ lässt sich nicht einstellen")
        }
        pause(0.4)
    }

    /// Das Menü eines Aufklappmenüs hängt je nach Version am Menü selbst oder
    /// am Programm-Element.
    private func menus(near picker: AXUIElement) -> [AXUIElement] {
        let local = flatten([picker]).filter { role($0) == "AXMenu" }
        if !local.isEmpty { return local }
        guard let appEl else { return [] }
        return ((attr(appEl, kAXChildrenAttribute) as? [AXUIElement]) ?? []).filter { role($0) == "AXMenu" }
    }

    private func menuItems(near picker: AXUIElement) -> [AXUIElement] {
        flatten(menus(near: picker)).filter { role($0) == "AXMenuItem" }
    }

    /// Einen Tag zurück; wartet, bis sich die Datumsbeschriftung ändert.
    private func stepBack() throws {
        let before = dateLabel()
        guard let prev = first(id: "previous_date_chevron") else {
            throw ScreenTimeReaderError.notFound("Knopf „Zurück“")
        }
        press(prev, "Einen Tag zurück")
        guard waitFor("Datumswechsel", timeout: 5, {
            let now = self.dateLabel()
            return (now != nil && now != before) ? prev : nil
        }) != nil else {
            throw ScreenTimeReaderError.wrongView("Datum ändert sich nicht (älter als Apples Verlauf?)")
        }
        pause(0.4)
    }

    /// „Mehr anzeigen“ drücken, bis die Liste vollständig ist (5 → 15 → …).
    private func expandList() {
        var rounds = 0
        while rounds < 40, let more = first(id: "show-more-for-screen-usage") {
            let before = barCount()
            press(more, "Mehr anzeigen")
            rounds += 1
            let deadline = Date().addingTimeInterval(5)
            while Date() < deadline, barCount() == before { pause(0.25) }
            if barCount() == before { break }
        }
    }

    // MARK: - Auslesen

    private func readCurrentDay(child: String, offset: Int) throws -> DaySnapshot {
        let day = Calendar.current.date(byAdding: .day, value: -offset, to: Date())!
        let dayOfMonth = Calendar.current.component(.day, from: day)

        // Erst die Apps …
        try setListMode(Self.appsMode)
        expandList()
        let els = all()
        let label = dateLabel(in: els)
        // Das Datum steht als "…, 24. September" in der Beschriftung; die
        // Ziffer davor darf keine weitere sein, sonst passte "4." auch auf "24.".
        guard let label, label.range(of: "(?<!\\d)\(dayOfMonth)\\.", options: .regularExpression) != nil else {
            throw ScreenTimeReaderError.wrongView("erwartet Tag \(dayOfMonth), angezeigt „\(label ?? "?")“")
        }
        guard !label.lowercased().contains("durchschnitt"),
              els.first(where: { ident($0) == "day-picker-segment" }).flatMap(value) == "1" else {
            throw ScreenTimeReaderError.wrongView("nicht in der Tagesansicht (\(label))")
        }

        func values(_ id: String, in list: [AXUIElement]) -> [String] {
            list.filter { ident($0) == id }.compactMap(value)
        }
        let total = values("usage-chart-header-value", in: els).first.flatMap(Self.seconds)

        var apps: [DaySnapshot.App] = []
        var web: [DaySnapshot.Web] = []
        for el in els {
            guard let id = ident(el), id.hasPrefix("progress-bar-"), let d = desc(el) else { continue }
            let (name, secs) = Self.nameAndSeconds(d)
            if id.hasPrefix("progress-bar-application:") {
                apps.append(.init(bundleId: String(id.dropFirst("progress-bar-application:".count)),
                                  name: name, seconds: secs))
            } else if id.hasPrefix("progress-bar-webDomain:") {
                web.append(.init(domain: String(id.dropFirst("progress-bar-webDomain:".count)), seconds: secs))
            }
        }

        // … dann Apples Kategorien.
        try setListMode(Self.categoriesMode)
        expandList()
        var categories: [DaySnapshot.Category] = []
        for el in all() {
            guard let id = ident(el), id.hasPrefix("progress-bar-category:"), let d = desc(el) else { continue }
            let (name, secs) = Self.nameAndSeconds(d)
            categories.append(.init(id: String(id.dropFirst("progress-bar-category:".count)), name: name, seconds: secs))
        }

        // Lieber keine Zahlen als falsche: in der Wochenansicht lägen einzelne
        // Einträge über der vermeintlichen Tagessumme.
        let maxEntry = (apps.compactMap(\.seconds) + categories.compactMap(\.seconds)).max() ?? 0
        if let total, maxEntry > total + 60 {
            throw ScreenTimeReaderError.implausible("Eintrag \(maxEntry) s über Tagessumme \(total) s")
        }
        if let total, total >= 120, categories.isEmpty {
            throw ScreenTimeReaderError.implausible("\(total / 60) min Nutzung, aber keine Kategorien")
        }

        let device = els.first { role($0) == "AXPopUpButton" && ident($0) == nil }.flatMap(value) ?? "?"
        let updated = els.compactMap { role($0) == "AXStaticText" ? value($0) : nil }
            .first { $0.contains("aktualisiert") }

        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        log("\(child): \(label) – \(apps.count) Apps, \(categories.count) Kategorien, gesamt \(total.map { "\($0 / 60) min" } ?? "?")")
        return DaySnapshot(
            child: child, date: f.string(from: day), label: label, appleUpdated: updated, device: device,
            totalSeconds: total, apps: apps, web: web, categories: categories,
            pickups: values("activity-legend-pickups", in: els),
            readAt: ISO8601DateFormatter().string(from: Date()))
    }

    private func barCount() -> Int { all().filter { (ident($0) ?? "").hasPrefix("progress-bar-") }.count }

    /// Datumsbeschriftung der Bildschirmzeit: der letzte Text vor der ersten Gesamtzeit.
    private func dateLabel(in els: [AXUIElement]? = nil) -> String? {
        let list = els ?? all()
        guard let idx = list.firstIndex(where: { ident($0) == "usage-chart-header-value" }) else { return nil }
        return list[..<idx].reversed().first { role($0) == "AXStaticText" && value($0) != nil }.flatMap(value)
    }

    // MARK: - Zeitangaben

    /// "1h 5min", "29min", "53s", "27 Minuten", "2 Std. 3 Min." → Sekunden
    static func seconds(_ s: String) -> Int? {
        let re = try! NSRegularExpression(
            pattern: #"(\d+)\s*(stunden|stunde|std\.?|h|minuten|minute|min\.?|sekunden|sekunde|sek\.?|s)(?![a-z])"#,
            options: [.caseInsensitive])
        var total = 0, found = false
        for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
            guard let nr = Range(m.range(at: 1), in: s), let ur = Range(m.range(at: 2), in: s),
                  let n = Int(s[nr]) else { continue }
            let unit = s[ur].lowercased()
            if unit.hasPrefix("h") || unit.hasPrefix("std") || unit.hasPrefix("stund") { total += n * 3600 }
            else if unit.hasPrefix("m") { total += n * 60 }
            else { total += n }
            found = true
        }
        return found ? total : nil
    }

    /// "DuckDuckGo, optional Duck.ai, 2min" → ("DuckDuckGo, optional Duck.ai", 120).
    /// Der Name kann selbst Kommas enthalten; die Dauer steht hinter dem letzten.
    static func nameAndSeconds(_ d: String) -> (String, Int?) {
        guard let r = d.range(of: ", ", options: .backwards) else { return (d, nil) }
        return (String(d[..<r.lowerBound]), seconds(String(d[r.upperBound...])))
    }

    // MARK: - AX-Grundwerkzeuge

    private func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
        var v: AnyObject?
        return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
    }

    private func text(_ el: AXUIElement, _ name: String) -> String? {
        guard let v = attr(el, name) else { return nil }
        let s: String
        if let str = v as? String { s = str }
        else if let num = v as? NSNumber { s = num.stringValue }
        else { return nil }
        let clean = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
        return clean.isEmpty ? nil : clean
    }

    private func ident(_ el: AXUIElement) -> String? { text(el, "AXIdentifier") }
    private func desc(_ el: AXUIElement) -> String? { text(el, kAXDescriptionAttribute) }
    private func value(_ el: AXUIElement) -> String? { text(el, kAXValueAttribute) }
    private func role(_ el: AXUIElement) -> String? { text(el, kAXRoleAttribute) }

    private func windows() -> [AXUIElement] {
        guard let appEl else { return [] }
        return (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? []
    }

    /// Elemente in Dokumentreihenfolge -- die Reihenfolge ordnet Beschriftungen
    /// und Werte einander zu.
    private func flatten(_ roots: [AXUIElement]) -> [AXUIElement] {
        var out: [AXUIElement] = []
        func walk(_ el: AXUIElement, _ depth: Int) {
            if out.count >= 60_000 || depth > 80 { return }
            out.append(el)
            for k in (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] { walk(k, depth + 1) }
        }
        for r in roots { walk(r, 0) }
        return out
    }

    private func all() -> [AXUIElement] { flatten(windows()) }

    private func first(id: String) -> AXUIElement? { all().first { ident($0) == id } }

    private func waitFor(_ what: String, timeout: TimeInterval = 10, _ probe: () -> AXUIElement?) -> AXUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        repeat {
            if let el = probe() { return el }
            pause(0.25)
        } while Date() < deadline
        log("Zeitüberschreitung: \(what)")
        return nil
    }

    @discardableResult
    private func press(_ el: AXUIElement, _ what: String) -> Bool {
        AXUIElementPerformAction(el, kAXPressAction as CFString) == .success
    }

    private func pause(_ s: TimeInterval) { Thread.sleep(forTimeInterval: s) }
}
