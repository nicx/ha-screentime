// st-axdump.swift — Machbarkeitstest: liest den Bedienungshilfen-Baum (AX) der
// Systemeinstellungen aus und schreibt ihn in eine Textdatei. Klickt nichts an,
// veraendert nichts. Die gewuenschte Ansicht (Bildschirmzeit des Kindes) muss
// vorher von Hand geoeffnet sein.
//
// Aufruf ueber Scripts/st-axdump.sh; das ausfuehrende Terminal braucht die
// Bedienungshilfen-Berechtigung.

import Cocoa
import ApplicationServices

let outPath = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "/tmp/ax-dump.txt"

let prompt = [kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String: true] as CFDictionary
guard AXIsProcessTrustedWithOptions(prompt) else {
    print("""
    Keine Bedienungshilfen-Berechtigung.
    Systemeinstellungen -> Datenschutz & Sicherheit -> Bedienungshilfen -> Terminal einschalten,
    Terminal beenden und neu oeffnen, dann erneut ausfuehren.
    """)
    exit(2)
}

guard let app = NSRunningApplication.runningApplications(
    withBundleIdentifier: "com.apple.systempreferences").first else {
    print("Die Systemeinstellungen laufen nicht -- bitte zuerst die Bildschirmzeit-Ansicht oeffnen.")
    exit(3)
}

let root = AXUIElementCreateApplication(app.processIdentifier)
AXUIElementSetMessagingTimeout(root, 5)

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

let fields: [(String, String)] = [
    ("sub", kAXSubroleAttribute), ("id", "AXIdentifier"), ("title", kAXTitleAttribute),
    ("value", kAXValueAttribute), ("desc", kAXDescriptionAttribute),
    ("valdesc", "AXValueDescription"), ("help", kAXHelpAttribute),
]

var lines: [String] = []
var visited = 0

func walk(_ el: AXUIElement, depth: Int) {
    visited += 1
    // Schutz vor endlosen oder riesigen Baeumen.
    if visited > 40_000 || depth > 80 { return }
    var parts = [text(el, kAXRoleAttribute) ?? "?"]
    for (label, key) in fields {
        if let s = text(el, key) { parts.append("\(label)=\"\(s)\"") }
    }
    lines.append(String(repeating: "  ", count: depth) + parts.joined(separator: " "))
    if let kids = attr(el, kAXChildrenAttribute) as? [AXUIElement] {
        for kid in kids { walk(kid, depth: depth + 1) }
    }
}

// Nur die Fenster -- die Menueleiste interessiert hier nicht.
if let windows = attr(root, kAXWindowsAttribute) as? [AXUIElement], !windows.isEmpty {
    for w in windows { walk(w, depth: 0) }
} else {
    walk(root, depth: 0)
}

do {
    try lines.joined(separator: "\n").write(toFile: outPath, atomically: true, encoding: .utf8)
    print("\(visited) Elemente gelesen -> \(outPath)")
} catch {
    print("Konnte \(outPath) nicht schreiben: \(error)")
    exit(4)
}
