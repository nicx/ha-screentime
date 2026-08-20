import SwiftUI
import UserNotifications

/// Hält alle Manager und verdrahtet sie miteinander.
@MainActor
final class AppEnvironment: ObservableObject {
    let settings: AppSettings
    let log: LogStore
    let loginItem: LoginItemManager
    let notifier: Notifier
    let runner: ExportRunner
    let scanner: DeviceScanner

    init() {
        let settings = AppSettings()
        let log = LogStore()
        let notifier = Notifier(settings: settings, log: log)

        self.settings = settings
        self.log = log
        self.loginItem = LoginItemManager()
        self.notifier = notifier
        self.runner = ExportRunner(settings: settings, log: log, notifier: notifier)
        self.scanner = DeviceScanner(settings: settings)
    }

    func bootstrap() {
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        log.appendSystem("Gestartet – Datenverzeichnis: \(BundledRuntime.dataDirectory.path)")

        if let problem = settings.configurationProblem {
            log.appendSystem("Konfiguration unvollständig: \(problem)")
        }
        runner.startScheduling()
        // Beim Start gleich einmal laufen, damit die Werte nach einer Anmeldung
        // (z.B. nach einem Neustart des Macs) sofort aktuell sind.
        Task { await runner.runOnce(trigger: "Start") }
    }

    func shutdown() {
        runner.stopScheduling()
    }
}

/// Der Delegate besitzt die Umgebung — nur so ist sichergestellt, dass
/// `bootstrap()` beim Start läuft. Würde die App sie über `@StateObject` halten
/// und der Delegate sie sich erst aus einer View holen, liefe der Start-Code
/// erst beim ersten Öffnen des Menüs (oder nie).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let env = AppEnvironment()

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        env.bootstrap()
    }

    func applicationWillTerminate(_ notification: Notification) {
        env.shutdown()
    }
}

@main
struct HAScreenTimeMenuBarApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate

    var body: some Scene {
        let env = delegate.env

        MenuBarExtra {
            MenuContentView()
                .environmentObject(env.settings)
                .environmentObject(env.runner)
                .environmentObject(env.loginItem)
        } label: {
            MenuBarLabel(runner: env.runner)
        }

        Settings {
            SettingsView()
                .environmentObject(env.settings)
                .environmentObject(env.runner)
                .environmentObject(env.loginItem)
                .environmentObject(env.scanner)
        }

        Window("Screen Time Logs", id: "logs") {
            LogView()
                .environmentObject(env.log)
        }
    }
}

/// Menüleisten-Symbol, dessen Zustand den letzten Lauf spiegelt.
struct MenuBarLabel: View {
    @ObservedObject var runner: ExportRunner

    var body: some View {
        Image(systemName: symbol)
    }

    private var symbol: String {
        switch runner.state {
        case .idle:    return "hourglass"
        case .running: return "arrow.triangle.2.circlepath"
        case .ok:      return "hourglass"
        case .failed:  return "exclamationmark.triangle.fill"
        }
    }
}
