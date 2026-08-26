import Foundation

/// Verschickt Mail über den lokalen MailRelay (plain SMTP, ohne Auth/TLS —
/// der Relay erledigt Upstream-Auth, STARTTLS und Retries selbst).
///
/// SMTP wird nicht in Swift nachgebaut, sondern über Pythons `smtplib` in der
/// ohnehin gebündelten Runtime gefahren — wie bei den Schwester-Apps. Werte
/// gehen über die Umgebung statt über argv, damit mehrzeilige Texte und
/// Sonderzeichen keine Quoting-Probleme machen.
enum Mailer {

    /// Best effort: liefert `false` statt zu werfen (z.B. wenn der Relay steht).
    @MainActor
    static func send(subject: String, body: String, settings: AppSettings) async -> Bool {
        let recipient = settings.mailRecipient.trimmingCharacters(in: .whitespaces)
        guard !recipient.isEmpty else { return false }
        let sender = settings.mailSender.trimmingCharacters(in: .whitespaces).isEmpty
            ? recipient : settings.mailSender
        return await send(host: settings.smtpHost, port: settings.smtpPort,
                          sender: sender, recipient: recipient,
                          subject: subject, body: body)
    }

    static func send(host: String, port: Int, sender: String, recipient: String,
                     subject: String, body: String) async -> Bool {
        let script = """
        import os, smtplib
        from email.message import EmailMessage
        m = EmailMessage()
        m["From"] = os.environ["MR_FROM"]
        m["To"] = os.environ["MR_TO"]
        m["Subject"] = os.environ["MR_SUBJECT"]
        m.set_content(os.environ["MR_BODY"])
        with smtplib.SMTP(os.environ["MR_HOST"], int(os.environ["MR_PORT"]), timeout=15) as s:
            s.send_message(m)
        """

        let proc = Process()
        proc.executableURL = BundledRuntime.pythonURL
        proc.arguments = ["-c", script]
        var env = ProcessInfo.processInfo.environment
        env["MR_FROM"] = sender
        env["MR_TO"] = recipient
        env["MR_SUBJECT"] = subject
        env["MR_BODY"] = body
        env["MR_HOST"] = host
        env["MR_PORT"] = String(port)
        // s. AppSettings.processEnvironment: kein Bytecode-Cache im Bundle.
        env["PYTHONPYCACHEPREFIX"] = BundledRuntime.dataDirectory
            .deletingLastPathComponent().appendingPathComponent("pycache").path
        proc.environment = env
        proc.standardOutput = FileHandle.nullDevice
        proc.standardError = FileHandle.nullDevice

        return await withCheckedContinuation { (cont: CheckedContinuation<Bool, Never>) in
            proc.terminationHandler = { p in
                cont.resume(returning: p.terminationStatus == 0)
            }
            do { try proc.run() } catch { cont.resume(returning: false) }
        }
    }
}
