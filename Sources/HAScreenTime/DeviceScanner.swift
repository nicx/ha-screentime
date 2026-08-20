import Foundation

struct ScannedDevice: Identifiable, Decodable {
    let deviceId: String
    let platform: Int?
    let platformName: String
    let model: String
    let lastSync: String
    let isSelf: Bool
    let events: Int
    let topApps: [[ScanValue]]

    var id: String { deviceId }

    /// Top-Apps als lesbare Zeile, z.B. "YouTube (488), Messages (240)".
    var topAppsSummary: String {
        topApps.compactMap { pair -> String? in
            guard pair.count == 2, let name = pair[0].stringValue else { return nil }
            let count = pair[1].intValue ?? 0
            return "\(name) (\(count))"
        }.joined(separator: ", ")
    }

    enum CodingKeys: String, CodingKey {
        case deviceId = "device_id"
        case platform
        case platformName = "platform_name"
        case model
        case lastSync = "last_sync"
        case isSelf = "is_self"
        case events
        case topApps = "top_apps"
    }
}

/// Die Top-Apps kommen als gemischtes Array `[name, anzahl]` aus JSON.
enum ScanValue: Decodable {
    case string(String)
    case int(Int)

    var stringValue: String? { if case .string(let s) = self { return s }; return nil }
    var intValue: Int? { if case .int(let i) = self { return i }; return nil }

    init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        if let i = try? c.decode(Int.self) { self = .int(i) }
        else { self = .string((try? c.decode(String.self)) ?? "") }
    }
}

private struct ScanResult: Decodable {
    let error: String?
    let devices: [ScannedDevice]
}

/// Sucht die synchronisierten Geräte über die gebündelte Runtime.
///
/// Ersetzt das frühere Shell-Skript `devices.sh`, das dafür eine komplette
/// Projektkopie an einem für beide Benutzer lesbaren Ort brauchte.
@MainActor
final class DeviceScanner: ObservableObject {
    @Published private(set) var devices: [ScannedDevice] = []
    @Published private(set) var isScanning = false
    @Published private(set) var error: String?

    private let settings: AppSettings

    init(settings: AppSettings) {
        self.settings = settings
    }

    func scan() async {
        guard !isScanning else { return }
        isScanning = true
        error = nil
        defer { isScanning = false }

        let script = BundledRuntime.payloadRoot.appendingPathComponent("src/scan_devices.py")
        guard FileManager.default.fileExists(atPath: script.path) else {
            error = "scan_devices.py fehlt im Bundle."
            return
        }

        let proc = Process()
        proc.executableURL = BundledRuntime.pythonURL
        proc.arguments = [script.path]
        proc.environment = settings.processEnvironment()

        let outPipe = Pipe()
        proc.standardOutput = outPipe
        proc.standardError = FileHandle.nullDevice

        do {
            try proc.run()
        } catch {
            self.error = "Start fehlgeschlagen: \(error.localizedDescription)"
            return
        }

        let data = await Task.detached { outPipe.fileHandleForReading.readDataToEndOfFile() }.value
        proc.waitUntilExit()

        guard let result = try? JSONDecoder().decode(ScanResult.self, from: data) else {
            error = "Konnte die Geräteliste nicht lesen. Hat die App Festplattenvollzugriff?"
            return
        }
        if let e = result.error {
            error = "\(e) — vermutlich fehlt der Festplattenvollzugriff."
            return
        }
        // Interessant sind Geräte mit Nutzung; der Sammel-Mac selbst nicht.
        devices = result.devices
            .filter { !$0.isSelf }
            .sorted { $0.events > $1.events }
    }
}
