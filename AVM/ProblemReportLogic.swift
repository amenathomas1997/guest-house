// ProblemReportLogic.swift
// Guest House — accessible virtual machines
//
// What Report a Problem asks and adds by itself (2026-11-24). A report of
// "people can't type in Linux" came with no Linux name, no Guest House
// version and no log, and couldn't be made to happen here. So Report a
// Problem now asks three short questions and which machine it is about,
// and adds that machine's system and version without the person having
// to know them. The words here; the window is ProblemReporter.swift.

import Foundation

nonisolated enum ProblemReportLogic {

    /// The three questions, in the order they're asked.
    static let questions = [
        "What were you doing?",
        "What did you expect to happen?",
        "What happened instead?",
    ]

    /// A machine as the report names it: its system and how it's set up,
    /// never its name, which can be a person's or a computer's own.
    struct Machine: Equatable, Sendable {
        /// "Ubuntu", "Windows", and so on.
        var system: String
        /// From the machine itself while it runs, such as "Ubuntu 26.04.1
        /// LTS, kernel 7.0.0-44-generic"; nil when it isn't running or
        /// didn't answer.
        var version: String?
        var running: Bool
    }

    /// The command that asks a running Linux machine its version.
    static let linuxVersionCommand = #". /etc/os-release 2>/dev/null; printf '%s, kernel %s' "${PRETTY_NAME:-Linux}" "$(uname -r)""#
    /// The same for Windows, through PowerShell.
    static let windowsVersionCommand = #"$o = Get-CimInstance Win32_OperatingSystem; $d = (Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue).DisplayVersion; "$($o.Caption) $d, build $($o.BuildNumber)""#

    /// A version as a machine printed it, cut to one tidy line; nil if
    /// there's nothing useful in it.
    static func cleanVersion(_ raw: String?) -> String? {
        guard let raw else { return nil }
        let line = raw.split(whereSeparator: \.isNewline).first.map(String.init)?
            .trimmingCharacters(in: .whitespaces) ?? ""
        guard !line.isEmpty, line.count <= 200 else { return nil }
        return line.replacingOccurrences(of: "  ", with: " ")
    }

    /// The report's opening: the person's answers, then what Guest House
    /// adds. Empty answers keep the old prompt, so a report sent without
    /// them still asks on GitHub.
    static func opening(answers: [String], machine: Machine?, voiceOverOnMac: Bool) -> String {
        var lines: [String] = []
        let cleaned = answers.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        if cleaned.allSatisfy(\.isEmpty) {
            lines.append("What happened, and what you expected:")
            lines.append("")
            lines.append("")
        } else {
            for (question, answer) in zip(questions, cleaned) {
                lines.append("**\(question)**")
                lines.append(answer.isEmpty ? "(not answered)" : answer)
                lines.append("")
            }
        }
        lines.append("**The machine:** " + machineLine(machine))
        lines.append("**VoiceOver on the Mac:** " + (voiceOverOnMac ? "on" : "off"))
        lines.append("")
        return lines.joined(separator: "\n")
    }

    static func machineLine(_ machine: Machine?) -> String {
        guard let machine else { return "not about one machine" }
        var line = machine.system
        if let version = machine.version {
            line += " (\(version))"
        } else {
            line += machine.running ? " (it didn't say its version)" : " (not running, so its version wasn't read)"
        }
        return line
    }
}
