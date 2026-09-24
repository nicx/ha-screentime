// st-uiread.swift — Prototyp: liest die Bildschirmzeit eines Kindes aus der
// Familien-Ansicht der Systemeinstellungen (macOS 27) ueber die Bedienungshilfen.
//
// Seit iOS 27 bieten die Geraete eines Kinder-Accounts ihre App-Nutzung nicht
// mehr per Biome an; exakte Zahlen stehen nur noch in dieser Ansicht, deren
// Datenbank ein DataVault ist. Apple versieht die Elemente mit festen
// Kennungen (z. B. "progress-bar-application:<bundle-id>"), darauf baut das hier.
//
// Aufruf: swift st-uiread.swift [Kindname]   (Standard: Max)
// Ausgabe: JSON auf stdout, Ablaufprotokoll auf stderr.

import Cocoa
import ApplicationServices

// MARK: - Grundwerkzeuge

func log(_ s: String) { FileHandle.standardError.write(Data((s + "\n").utf8)) }

func fail(_ s: String, code: Int32 = 1) -> Never {
    log("FEHLER: \(s)")
    exit(code)
}

func attr(_ el: AXUIElement, _ name: String) -> AnyObject? {
    var v: AnyObject?
    return AXUIElementCopyAttributeValue(el, name as CFString, &v) == .success ? v : nil
}

func text(_ el: AXUIElement, _ name: String) -> String? {
    guard let v = attr(el, name) else { return nil }
    let s: String
    if let str = v as? String { s = str }
    else if let num = v as? NSNumber { s = num.stringValue }
    else { return nil }
    let clean = s.replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
    return clean.isEmpty ? nil : clean
}

func ident(_ el: AXUIElement) -> String? { text(el, "AXIdentifier") }
func desc(_ el: AXUIElement) -> String? { text(el, kAXDescriptionAttribute) }
func value(_ el: AXUIElement) -> String? { text(el, kAXValueAttribute) }
func role(_ el: AXUIElement) -> String? { text(el, kAXRoleAttribute) }
func kids(_ el: AXUIElement) -> [AXUIElement] { (attr(el, kAXChildrenAttribute) as? [AXUIElement]) ?? [] }

/// Alle Elemente in Dokumentreihenfolge (Tiefensuche) -- die Reihenfolge wird
/// gebraucht, um z. B. Beschriftung und Wert einander zuzuordnen.
func flatten(_ roots: [AXUIElement], limit: Int = 60_000) -> [AXUIElement] {
    var out: [AXUIElement] = []
    func walk(_ el: AXUIElement, _ depth: Int) {
        if out.count >= limit || depth > 80 { return }
        out.append(el)
        for k in kids(el) { walk(k, depth + 1) }
    }
    for r in roots { walk(r, 0) }
    return out
}

func waitFor(_ what: String, timeout: TimeInterval = 10, _ probe: () -> AXUIElement?) -> AXUIElement? {
    let deadline = Date().addingTimeInterval(timeout)
    repeat {
        if let el = probe() { return el }
        Thread.sleep(forTimeInterval: 0.25)
    } while Date() < deadline
    log("Zeitueberschreitung: \(what)")
    return nil
}

@discardableResult
func press(_ el: AXUIElement, _ what: String) -> Bool {
    let r = AXUIElementPerformAction(el, kAXPressAction as CFString)
    if r == .success { log("gedrueckt: \(what)") } else { log("Druecken fehlgeschlagen (\(what)): \(r.rawValue)") }
    return r == .success
}

/// "1h 5min", "29min", "53s", "27 Minuten", "2 Std. 3 Min." -> Sekunden
func seconds(_ s: String) -> Int? {
    let re = try! NSRegularExpression(
        pattern: #"(\d+)\s*(stunden|stunde|std\.?|h|minuten|minute|min\.?|sekunden|sekunde|sek\.?|s)(?![a-z])"#,
        options: [.caseInsensitive])
    var total = 0, found = false
    for m in re.matches(in: s, range: NSRange(s.startIndex..., in: s)) {
        guard let n = Int(s[Range(m.range(at: 1), in: s)!]) else { continue }
        let unit = s[Range(m.range(at: 2), in: s)!].lowercased()
        if unit.hasPrefix("h") || unit.hasPrefix("std") || unit.hasPrefix("stund") { total += n * 3600 }
        else if unit.hasPrefix("m") { total += n * 60 }
        else { total += n }
        found = true
    }
    return found ? total : nil
}

/// "DuckDuckGo, optional Duck.ai, 2min" -> ("DuckDuckGo, optional Duck.ai", 120).
/// Der Name kann selbst Kommas enthalten, die Dauer steht immer hinter dem letzten.
func nameAndSeconds(_ d: String) -> (String, Int?) {
    guard let r = d.range(of: ", ", options: .backwards) else { return (d, nil) }
    return (String(d[..<r.lowerBound]), seconds(String(d[r.upperBound...])))
}

// MARK: - Start

let childName = CommandLine.arguments.dropFirst().first ?? "Max"
let started = Date()

let promptOpt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(promptOpt) else {
    fail("Keine Bedienungshilfen-Berechtigung fuer dieses Programm.", code: 2)
}

let bundleID = "com.apple.systempreferences"
var settingsApp = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).first
var launchedByUs = false
if settingsApp == nil {
    guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
        fail("Systemeinstellungen nicht gefunden")
    }
    let cfg = NSWorkspace.OpenConfiguration()
    cfg.activates = false          // nicht in den Vordergrund holen
    let done = DispatchSemaphore(value: 0)
    NSWorkspace.shared.openApplication(at: url, configuration: cfg) { app, err in
        if let err { log("Start fehlgeschlagen: \(err)") }
        settingsApp = app
        done.signal()
    }
    done.wait()
    launchedByUs = true
    log("Systemeinstellungen im Hintergrund gestartet")
}
guard let pid = settingsApp?.processIdentifier else { fail("Systemeinstellungen laufen nicht") }

let appEl = AXUIElementCreateApplication(pid)
AXUIElementSetMessagingTimeout(appEl, 5)

func windows() -> [AXUIElement] { (attr(appEl, kAXWindowsAttribute) as? [AXUIElement]) ?? [] }
func all() -> [AXUIElement] { flatten(windows()) }
func first(id: String) -> AXUIElement? { all().first { ident($0) == id } }

_ = waitFor("Fenster der Systemeinstellungen", timeout: 15) { windows().first }
    ?? { fail("Kein Fenster der Systemeinstellungen") }()

// MARK: - Navigation (jeder Schritt wird uebersprungen, wenn er schon erreicht ist)

func detailOpen() -> AXUIElement? { first(id: "day-picker-segment") }

func selectSidebar(_ el: AXUIElement) {
    if press(el, "Seitenleiste: Familie") { return }
    // Manche Seitenleisten-Eintraege lassen sich nur ueber die Zeile auswaehlen.
    var cur: AXUIElement? = el
    while let c = cur, role(c) != "AXRow" {
        cur = attr(c, kAXParentAttribute).map { $0 as! AXUIElement }
    }
    if let row = cur {
        AXUIElementSetAttributeValue(row, kAXSelectedAttribute as CFString, kCFBooleanTrue)
        log("Zeile ausgewaehlt: Familie")
    }
}

if detailOpen() == nil {
    var overview = first(id: "weekly-usage-summary-chart")
    if overview == nil {
        let memberPrefix = childName + ","
        func memberRow() -> AXUIElement? {
            all().first { (ident($0) ?? "").hasPrefix("FAMILY_MEMBER_ROW_") && (desc($0) ?? "").hasPrefix(memberPrefix) }
        }
        if memberRow() == nil {
            guard let fam = waitFor("Familie in der Seitenleiste", { first(id: "com.apple.settings.family") }) else {
                fail("Eintrag 'Familie' nicht gefunden")
            }
            selectSidebar(fam)
        }
        guard let row = waitFor("Familienmitglied \(childName)", memberRow) else {
            fail("Familienmitglied '\(childName)' nicht gefunden")
        }
        press(row, "Familienmitglied \(childName)")
        overview = waitFor("Bildschirmzeit-Uebersicht") { first(id: "weekly-usage-summary-chart") }
    }
    guard let ov = overview else { fail("Bildschirmzeit-Uebersicht nicht erreicht") }
    press(ov, "Bildschirmzeit-Uebersicht")
    if waitFor("Detailansicht", timeout: 6, detailOpen) == nil,
       let alt = first(id: "most-used-header-link") {
        press(alt, "Am haeufigsten verwendet")
    }
    guard waitFor("Detailansicht", detailOpen) != nil else { fail("Detailansicht nicht erreicht") }
}

// MARK: - Ansicht einstellen: Tag, Heute, Geraet

if let day = first(id: "day-picker-segment"), value(day) != "1" {
    press(day, "Tag")
    Thread.sleep(forTimeInterval: 0.8)
}
if let today = first(id: "today-button") {
    press(today, "Heute")          // schlaegt fehl, wenn schon "Heute" -- harmlos
    Thread.sleep(forTimeInterval: 0.5)
}

// Die Geraeteauswahl hat keine Kennung; es ist das Aufklappmenue ohne ID.
let devicePopup = all().first { role($0) == "AXPopUpButton" && ident($0) == nil }
var device = devicePopup.flatMap(value) ?? "?"
if let popup = devicePopup, device != "Alle Geräte" {
    press(popup, "Geraeteauswahl oeffnen")
    Thread.sleep(forTimeInterval: 0.5)
    if let item = flatten([popup]).first(where: { role($0) == "AXMenuItem" && text($0, kAXTitleAttribute) == "Alle Geräte" }) {
        press(item, "Alle Geraete")
        Thread.sleep(forTimeInterval: 1.0)
        device = value(popup) ?? device
    } else {
        log("Menuepunkt 'Alle Geraete' nicht gefunden -- lese mit '\(device)'")
    }
}

// MARK: - Liste vollstaendig aufklappen

func appBars() -> Int { all().filter { (ident($0) ?? "").hasPrefix("progress-bar-") }.count }
var rounds = 0
while rounds < 30, let more = first(id: "show-more-for-screen-usage") {
    let before = appBars()
    press(more, "Mehr anzeigen (\(before) Eintraege)")
    rounds += 1
    let deadline = Date().addingTimeInterval(5)
    while Date() < deadline, appBars() == before { Thread.sleep(forTimeInterval: 0.25) }
    if appBars() == before { log("Liste waechst nicht mehr -- Abbruch"); break }
}

// MARK: - Auslesen

let els = all()
func values(id: String) -> [String] { els.filter { ident($0) == id }.compactMap(value) }

// Datum/Zeitraum: der letzte Text vor der ersten Gesamtzeit-Angabe.
var dateLabel: String?
if let idx = els.firstIndex(where: { ident($0) == "usage-chart-header-value" }) {
    dateLabel = els[..<idx].reversed().first { role($0) == "AXStaticText" && value($0) != nil }.flatMap(value)
}

let totalText = values(id: "usage-chart-header-value").first
let legend = values(id: "category-legend-screen-usage")
var categories: [[String: Any]] = []
stride(from: 0, to: legend.count - 1, by: 2).forEach {
    categories.append(["name": legend[$0], "seconds": seconds(legend[$0 + 1]) ?? NSNull()])
}

var apps: [[String: Any]] = []
var web: [[String: Any]] = []
for el in els {
    guard let id = ident(el), id.hasPrefix("progress-bar-"), let d = desc(el) else { continue }
    let (name, secs) = nameAndSeconds(d)
    if id.hasPrefix("progress-bar-application:") {
        apps.append(["bundle_id": String(id.dropFirst("progress-bar-application:".count)),
                     "name": name, "seconds": secs ?? NSNull()])
    } else if id.hasPrefix("progress-bar-webDomain:") {
        web.append(["domain": String(id.dropFirst("progress-bar-webDomain:".count)),
                    "seconds": secs ?? NSNull()])
    }
}

let updated = els.compactMap { role($0) == "AXStaticText" ? value($0) : nil }.first { $0.contains("aktualisiert") }
let pickups = values(id: "activity-legend-pickups")

let result: [String: Any] = [
    "child": childName,
    "device": device,
    "date_label": dateLabel ?? NSNull(),
    "updated": updated ?? NSNull(),
    "total_text": totalText ?? NSNull(),
    "total_seconds": totalText.flatMap(seconds) ?? NSNull(),
    "categories": categories,
    "apps": apps,
    "web": web,
    "pickups": pickups,
    "show_more_rounds": rounds,
    "elapsed_seconds": (Date().timeIntervalSince(started) * 10).rounded() / 10,
]

// MARK: - Aufraeumen: Ansichten schliessen, selbst gestartete App beenden

for _ in 0..<3 {
    // Der innerste Dialog steht in Dokumentreihenfolge zuletzt.
    guard let done = all().last(where: { role($0) == "AXButton" && desc($0) == "Fertig" }) else { break }
    press(done, "Fertig")
    Thread.sleep(forTimeInterval: 0.6)
}
if launchedByUs {
    settingsApp?.terminate()
    log("Systemeinstellungen wieder beendet")
}

let json = try! JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
print(String(decoding: json, as: UTF8.self))
