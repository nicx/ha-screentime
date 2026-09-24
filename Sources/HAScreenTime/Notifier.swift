import Foundation
import UserNotifications

/// Eine überwachte Bedingung mit ihren Betreffzeilen.
struct NotifierCondition {
    let id: String
    let problemSubject: String
    let recoverySubject: String
}

enum ScreenTimeConditions {
    static let run = NotifierCondition(
        id: "run",
        problemSubject: "Screen Time: Lauf fehlgeschlagen",
        recoverySubject: "Screen Time: Lauf wieder erfolgreich")
    static let read = NotifierCondition(
        id: "read",
        problemSubject: "Screen Time: Auslesen der Bildschirmzeit fehlgeschlagen",
        recoverySubject: "Screen Time: Auslesen klappt wieder")
    static let dataFlow = NotifierCondition(
        id: "data_flow",
        problemSubject: "Screen Time: keine neuen Daten",
        recoverySubject: "Screen Time: Daten fließen wieder")
}

/// Entprellter Störungsmelder nach dem Muster der Schwester-Apps: mailt (über den
/// lokalen MailRelay) und zeigt eine Mitteilung nur beim echten Zustandswechsel —
/// eine Dauerstörung erzeugt also eine Mail statt einer pro Lauf — plus eine
/// „wieder ok“-Mail beim Abklingen.
@MainActor
final class Notifier: ObservableObject {
    private let settings: AppSettings
    private let log: LogStore
    private var inProblem: [String: Bool] = [:]

    init(settings: AppSettings, log: LogStore) {
        self.settings = settings
        self.log = log
    }

    /// Zustand einer Bedingung melden. Sendet nur bei einem Wechsel.
    func report(_ condition: NotifierCondition, healthy: Bool, detail: String = "") {
        if healthy {
            guard inProblem[condition.id] == true else { return }
            inProblem[condition.id] = false
            emit(subject: condition.recoverySubject, body: condition.recoverySubject)
        } else {
            guard inProblem[condition.id] != true else { return }
            inProblem[condition.id] = true
            let body = detail.isEmpty ? condition.problemSubject : "\(condition.problemSubject)\n\n\(detail)"
            emit(subject: condition.problemSubject, body: body)
        }
    }

    /// Einmalige Meldung außerhalb der Zustandslogik (Schwellwert, Tagesbericht).
    func oneShot(subject: String, body: String) {
        emit(subject: subject, body: body)
    }

    private func emit(subject: String, body: String) {
        postDesktopNotification(subject: subject, body: body)
        guard settings.notifyOnProblem,
              !settings.mailRecipient.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        let s = settings
        Task { @MainActor in
            let ok = await Mailer.send(subject: subject, body: body, settings: s)
            log.appendSystem(ok
                ? "Mail verschickt: \(subject)"
                : "Mail fehlgeschlagen (\(s.smtpHost):\(s.smtpPort)): \(subject)")
        }
    }

    private func postDesktopNotification(subject: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = subject
        content.body = body
        let req = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(req)
    }
}
