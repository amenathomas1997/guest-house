// ProblemReporter.swift
// Guest House — accessible virtual machines
//
// Help > Report a Problem… (2026-10-26): one step from "something went
// wrong" to a GitHub issue with what a fix needs. Guest House puts a report on the
// clipboard (Guest House, macOS and Mac versions, and the last part of the
// diagnostic log, sanitized as always: no user name, no keystrokes), then
// opens a new issue in the browser, whose text says to paste it in. The
// report never goes into the web address, so it stays out of browser
// history and isn't cut short. Nothing is sent until the user submits the
// issue on GitHub, after reading and changing it as they like.
// Save Diagnostic Log still gives the whole log as files.

import AppKit

@MainActor
enum ProblemReporter {

    // The template named in the address (2026-10-29, seventh audit): with
    // templates in the repository, a bare issues/new is GitHub's chooser
    // page, one more step before the form.
    static let newIssueURL = "https://github.com/amenathomas1997/guest-house/issues/new?template=report-a-problem.md"
    /// Lines from the end of the log; enough for the last start, short
    /// enough to read before submitting.
    static let logLines = 120

    static func reportAProblem() {
        // THE QUESTIONS (2026-11-24, ProblemReportLogic): three short ones and
        // the machine, in the same window, all optional. Fields with their
        // questions as their labels, so VoiceOver reads each.
        let machines = VMStore.shared?.configurations ?? []
        let running = machines.filter { MachineSessions.shared.sessions[$0.id]?.isRunning == true }
        let alert = NSAlert()
        alert.messageText = "Report a problem"
        alert.informativeText = "Answer what you can; every question can be left empty. Guest House then puts a report on the clipboard: your answers, the machine's system and version, your Guest House, macOS and Mac versions, and the last part of the diagnostic log, which never has your user name or anything you typed in a machine. Copy Report and Open GitHub opens a new issue in your browser: paste the report with Command-V and submit. You need to be signed in to GitHub. Or Email the Whole Log puts every log file, zipped, in a new email in your mail app. Nothing is sent until you send it, and you can read and change everything first."
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        let width: CGFloat = 380
        func label(_ text: String) -> NSTextField {
            let label = NSTextField(labelWithString: text)
            label.font = .boldSystemFont(ofSize: NSFont.systemFontSize)
            return label
        }
        let machineQuestion = "Which machine is it about?"
        let popup = NSPopUpButton(frame: NSRect(x: 0, y: 0, width: width, height: 26), pullsDown: false)
        popup.addItem(withTitle: "Not about one machine")
        for machine in machines {
            popup.addItem(withTitle: machine.name + (running.contains(where: { $0.id == machine.id }) ? ", running" : ""))
        }
        // The running machine, when there is just one: most often the one.
        if running.count == 1, let index = machines.firstIndex(where: { $0.id == running[0].id }) {
            popup.selectItem(at: index + 1)
        }
        popup.setAccessibilityLabel(machineQuestion)
        stack.addArrangedSubview(label(machineQuestion))
        stack.addArrangedSubview(popup)
        var fields: [NSTextField] = []
        for question in ProblemReportLogic.questions {
            let field = NSTextField(frame: NSRect(x: 0, y: 0, width: width, height: 44))
            field.usesSingleLineMode = false
            field.cell?.wraps = true
            field.cell?.isScrollable = false
            field.setAccessibilityLabel(question)
            field.translatesAutoresizingMaskIntoConstraints = false
            field.widthAnchor.constraint(equalToConstant: width).isActive = true
            field.heightAnchor.constraint(equalToConstant: 44).isActive = true
            stack.addArrangedSubview(label(question))
            stack.addArrangedSubview(field)
            fields.append(field)
        }
        stack.frame = NSRect(x: 0, y: 0, width: width, height: stack.fittingSize.height)
        alert.accessoryView = stack
        alert.addButton(withTitle: "Copy Report and Open GitHub")
        // Or the whole log by email (2026-10-30): a tester's problem took
        // Save Diagnostic Log, zipping the folder and attaching it by hand.
        alert.addButton(withTitle: "Email the Whole Log…")
        alert.addButton(withTitle: "Cancel")
        alert.layout()
        alert.window.initialFirstResponder = popup
        let answer = alert.runModal()
        guard answer == .alertFirstButtonReturn || answer == .alertSecondButtonReturn else { return }
        let answers = fields.map(\.stringValue)
        let chosen = popup.indexOfSelectedItem > 0 ? machines[popup.indexOfSelectedItem - 1] : nil
        let byEmail = answer == .alertSecondButtonReturn
        Task { @MainActor in
            let opening = ProblemReportLogic.opening(answers: answers, machine: await describe(chosen),
                                                     voiceOverOnMac: NSWorkspace.shared.isVoiceOverEnabled)
            if byEmail {
                await emailWholeLog(opening: opening)
            } else {
                copyAndOpenGitHub(opening: opening)
            }
        }
    }

    /// The chosen machine's system, and its version from the machine
    /// itself if it's running and answers within ten seconds.
    private static func describe(_ configuration: VMConfiguration?) async -> ProblemReportLogic.Machine? {
        guard let configuration else { return nil }
        let guest = configuration.guestOS
        var machine = ProblemReportLogic.Machine(system: guest.displayName, version: nil, running: false)
        guard let session = MachineSessions.shared.sessions[configuration.id], session.isRunning else { return machine }
        machine.running = true
        let manager = session.manager
        switch guest {
        case .windows:
            machine.version = ProblemReportLogic.cleanVersion(try? await manager.agentRun("powershell.exe", ["-NoProfile", "-Command", ProblemReportLogic.windowsVersionCommand], limit: .seconds(10)))
        case .macOS:
            break
        default:
            machine.version = ProblemReportLogic.cleanVersion(try? await manager.agentRun("/bin/sh", ["-c", ProblemReportLogic.linuxVersionCommand], limit: .seconds(10)))
        }
        AVMLog.write("Guest House: Report a Problem — about a \(guest.displayName) machine; its version \(machine.version == nil ? "wasn't read" : "was read").")
        return machine
    }

    private static func copyAndOpenGitHub(opening: String) {
        let report = opening + makeReport()
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(report, forType: .string)
        AVMLog.write("Guest House: Report a Problem — report copied (\(report.count) characters); opening a new GitHub issue.")

        var components = URLComponents(string: newIssueURL)
        // Added to the template item, not in its place. The answers stay on
        // the clipboard, out of the web address and the browser's history.
        var items = components?.queryItems ?? []
        items.append(URLQueryItem(name: "body", value: "Paste Guest House's report below with Command-V. It has your answers in it.\n\n"))
        components?.queryItems = items
        if let url = components?.url {
            NSWorkspace.shared.open(url)
        }
        Announcer.shared.announce("The report, with your answers, is on the clipboard, and GitHub's new issue page is opening in your browser. Paste the report with Command-V, add a title, and submit.", tone: .info)
    }

    /// The whole diagnostic log, zipped, in a new email in the Mac's mail
    /// app, with the short report as its text. Nothing is sent until the
    /// user sends it.
    static func emailWholeLog(opening: String = ProblemReportLogic.opening(answers: [], machine: nil, voiceOverOnMac: false)) async {
        let zip: URL
        do {
            guard let made = try await DiagnosticLogExporter.makeZip() else {
                Announcer.shared.announce("There is no diagnostic log to send yet.", tone: .info)
                return
            }
            zip = made
        } catch {
            Announcer.shared.announce("The log couldn't be prepared. Reason: \(error.localizedDescription)", tone: .failure)
            return
        }
        let text = opening + makeReport()
        if let mail = NSSharingService(named: .composeEmail), mail.canPerform(withItems: [text, zip]) {
            mail.subject = "Guest House problem report"
            mail.perform(withItems: [text, zip])
            AVMLog.write("Guest House: Report a Problem — whole log attached to a new email.")
            Announcer.shared.announce("A new email is open with the whole log attached. Add who it's for and what happened, then send it.", tone: .info)
        } else {
            // No mail app set up: the zip is shown, to attach by hand.
            NSWorkspace.shared.activateFileViewerSelecting([zip])
            Announcer.shared.announce("No mail app is set up, so the zipped log is shown in the Finder instead: \(zip.lastPathComponent). Attach it to a message by hand.", tone: .info)
        }
    }

    static func makeReport() -> String {
        let info = Bundle.main.infoDictionary
        let version = "\(info?["CFBundleShortVersionString"] as? String ?? "?") (build \(info?["CFBundleVersion"] as? String ?? "?"))"
        var log = "(no diagnostic log yet)"
        if let url = AVMLog.currentLogURL(), let text = try? String(contentsOf: url, encoding: .utf8) {
            let tail = text.split(separator: "\n", omittingEmptySubsequences: false).suffix(logLines).joined(separator: "\n")
            log = AVMLog.sanitize(tail)
        }
        return """
        Guest House \(version) · macOS \(ProcessInfo.processInfo.operatingSystemVersionString) · \(macModel())

        <details><summary>Diagnostic log, last \(logLines) lines</summary>

        ```
        \(log)
        ```
        </details>
        """
    }

    private static func macModel() -> String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var model = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &model, &size, nil, 0)
        return String(cString: model)
    }
}
