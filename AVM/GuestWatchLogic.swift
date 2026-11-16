// GuestWatchLogic.swift
// Guest House — accessible virtual machines
//
// What GuestWatch.swift decides from (2026-10-31): its settings, what a
// machine's process list says is running, and whether its screen changed. Apart from the loop, so the logic tests
// reach it.

import AppKit
import CoreGraphics
import Foundation

/// Windows Setup's report on the UNATTEND volume (AVMSTATUS.TXT).
nonisolated enum WindowsSetupReport {
    /// Specialize begun and not finished (2026-11-10, audit of that day
    /// #4). The pass's last command replaces the report with
    /// "specialize-done", and a retired report always holds that line.
    static func stoppedInSpecialize(_ report: String) -> Bool {
        report.contains("specialize-started") && !report.contains("specialize-done") && !report.contains("first-sign-in-done")
    }
}

nonisolated enum GuestWatchSettings {
    static let restartReaderKey = "AVMRestartStoppedScreenReader"
    static let pointBeforeUpdatesKey = "AVMRestorePointBeforeUpdates"
    /// Guest House's updates held while the keyboard is in a machine whose screen
    /// reader is running, and said when it comes back (Announcer, 2026-10-31).
    static let holdWhileInMachineKey = "AVMHoldUpdatesInMachine"
    /// Off by default: each new machine gets the saved screen reader setup.
    static let useSavedSetupKey = "AVMUseSavedScreenReaderSetup"

    /// On unless turned off, except the restore point before updates: off
    /// until turned on (2026-10-31). Twice in tests, Windows didn't come
    /// back from the restart that followed a point taken while it ran, and
    /// came back every time without one; on until that's understood would
    /// strand someone mid-update.
    static func isOn(_ key: String) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? (key != pointBeforeUpdatesKey)
    }
}

// MARK: - What the machine is running

/// The screen readers and desktop seen in a machine's process list.
nonisolated struct GuestProcesses: Equatable {
    /// A user is signed in: Windows' Explorer, or a Linux desktop.
    var signedIn = false
    /// The screen readers running, by their spoken names.
    var screenReaders: Set<String> = []
    /// GNOME, where Orca has a shortcut to start it.
    var gnome = false
    /// Different after every restart (2026-10-31): Windows' smss.exe, the
    /// first process it starts, by its process number; Linux's boot_id.
    /// A restart shorter than the 16 seconds between listings got no
    /// "no answer" in between, so it went unnoticed.
    var boot: String?

    /// From `tasklist /fo csv /nh` (Windows), or the boot_id and then
    /// `ps -eo comm` (Linux).
    static func parse(_ listing: String, windows: Bool) -> GuestProcesses {
        var found = GuestProcesses()
        for raw in listing.split(whereSeparator: \.isNewline) {
            var name = raw.trimmingCharacters(in: .whitespaces)
            if windows {
                // "nvda.exe","1234","Console","1","50,000 K"
                let fields = name.split(separator: ",", omittingEmptySubsequences: false)
                    .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: "\"")) }
                guard name.hasPrefix("\""), let first = fields.first else { continue }
                name = first
                if name.lowercased() == "smss.exe", fields.count > 1 { found.boot = fields[1] }
            } else if found.boot == nil, name.count == 36, name.filter({ $0 == "-" }).count == 4 {
                found.boot = name
                continue
            }
            switch name.lowercased() {
            case "explorer.exe": found.signedIn = true
            case "nvda.exe": found.screenReaders.insert("NVDA")
            case "jfw.exe": found.screenReaders.insert("JAWS")
            case "narrator.exe": found.screenReaders.insert("Narrator")
            case "orca": found.screenReaders.insert("Orca")
            case "gnome-shell": found.signedIn = true; found.gnome = true
            case "plasmashell", "xfce4-session", "mate-session", "cinnamon", "lxqt-session": found.signedIn = true
            default: break
            }
        }
        return found
    }
}

// MARK: - Guest House's keys with the keyboard in a machine

/// Guest House's menu keys that answer or act from the Mac (2026-11-02): with the keyboard
/// in a machine, the screens that need Read Screen are right there, and these
/// reached Windows as Windows-Shift keys instead. Only these: the rest of Command
/// is still the machine's Windows key.
nonisolated enum AVMKeysInMachine {
    private static let plain: Set<UInt16> = [31, 34, 9, 2]      // O, I, V, D
    private static let withOption: Set<UInt16> = [31, 34, 8]    // O, I, C

    /// Control with an arrow, Home, End, Page Up or Page Down, and no Command:
    /// the machine's, not the Mac's Window menu.
    static func isControlMoving(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.control) && !modifiers.contains(.command) && movingKeys.contains(keyCode)
    }
    private static let movingKeys: Set<UInt16> = [123, 124, 125, 126, 115, 119, 116, 121]

    /// Control with any key, and no Command. With the keyboard in a machine
    /// every one is the machine's. Control with Command stays as it was:
    /// Command is the Windows key, and Control-Command-Escape is the way back.
    static func isControlKey(modifiers: NSEvent.ModifierFlags) -> Bool {
        modifiers.contains(.control) && !modifiers.contains(.command)
    }

    static func isAVMs(keyCode: UInt16, modifiers: NSEvent.ModifierFlags) -> Bool {
        switch modifiers.intersection([.control, .command, .option, .shift]) {
        case [.command, .shift]: return plain.contains(keyCode)
        case [.command, .option, .shift]: return withOption.contains(keyCode)
        default: return false
        }
    }
}

// MARK: - The update feed

nonisolated enum UpdateFeed {
    /// The newest build the feed offers this copy: an early item only with its
    /// channel allowed.
    static func newestBuild(in feed: String, channels: Set<String>) -> Int? {
        feed.components(separatedBy: "<item>").dropFirst().compactMap { item -> Int? in
            if let channel = between("<sparkle:channel>", "</sparkle:channel>", in: item), !channels.contains(channel) { return nil }
            return between("<sparkle:version>", "</sparkle:version>", in: item).flatMap(Int.init)
        }.max()
    }

    /// Once per version: after that, Sparkle's own reminder has it.
    static func shouldOffer(newest: Int?, current: Int, offered: Int?) -> Bool {
        guard let newest else { return false }
        return newest > max(current, offered ?? 0)
    }

    private static func between(_ open: String, _ close: String, in text: String) -> String? {
        guard let start = text.range(of: open), let end = text.range(of: close, range: start.upperBound..<text.endIndex) else { return nil }
        return String(text[start.upperBound..<end.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - A changed screen

nonisolated enum ScreenChange {
    /// A screen as 64 by 36 grey levels, enough to tell a new page from a
    /// blinking cursor or a spinner.
    static func thumbnail(of image: CGImage) -> [UInt8]? {
        let w = 64, h = 36
        var pixels = [UInt8](repeating: 0, count: w * h)
        let drawn = pixels.withUnsafeMutableBytes { buffer -> Bool in
            guard let context = CGContext(data: buffer.baseAddress, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w,
                                          space: CGColorSpaceCreateDeviceGray(), bitmapInfo: CGImageAlphaInfo.none.rawValue) else { return false }
            context.interpolationQuality = .medium
            context.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
            return true
        }
        return drawn ? pixels : nil
    }

    /// True when enough of the thumbnail moved to be a new screen: a
    /// spinner or a cursor moves a few cells, a new page many.
    static func isNewScreen(_ a: [UInt8], _ b: [UInt8]) -> Bool {
        guard a.count == b.count else { return true }
        let moved = zip(a, b).filter { abs(Int($0) - Int($1)) > 24 }.count
        return moved > a.count / 50
    }

    /// Windows' stop screen.
    static func isStopScreen(_ lines: [String]) -> Bool {
        lines.contains { $0.localizedCaseInsensitiveContains("ran into a problem") }
            && lines.contains { $0.localizedCaseInsensitiveContains("stop code") }
    }
}

/// "This machine looks stuck" (2026-11-01, the user's request): a person who
/// can't see a frozen boot can't know to reset it. A sign of life is its agent
/// answering, or its screen changing. Said once per freeze.
nonisolated struct StuckWatch: Sendable {
    /// Long enough for Windows' slowest quiet restarts, as a first restart
    /// after the 3D driver, which take several minutes.
    static let limit: TimeInterval = 600
    /// Longer than this between looks, Guest House wasn't looking: the Mac slept, or
    /// the machine was paused.
    static let longestGap: TimeInterval = 60

    enum Change: Equatable, Sendable { case none, stuck, alive }

    let limit: TimeInterval
    private var lastSign: Date
    private var lastLook: Date
    private var told = false
    /// An agent that has never answered is no sign of a freeze (2026-11-09,
    /// fifth audit #9): a healthy machine without one, on a still desktop,
    /// was told to reset, losing unsaved work.
    private var agentHasAnswered = false

    init(limit: TimeInterval = StuckWatch.limit, now: Date = Date()) {
        self.limit = limit
        lastSign = now
        lastLook = now
    }

    mutating func look(agentAnswered: Bool, screenChanged: Bool, now: Date = Date()) -> Change {
        defer { lastLook = now }
        if agentAnswered { agentHasAnswered = true }
        if agentAnswered || screenChanged || now.timeIntervalSince(lastLook) > Self.longestGap {
            lastSign = now
            if told, agentAnswered || screenChanged {
                told = false
                return .alive
            }
            return .none
        }
        guard agentHasAnswered, !told, now.timeIntervalSince(lastSign) >= limit else { return .none }
        told = true
        return .stuck
    }
}

/// What Check This Machine found, from its script's key=value lines.
nonisolated struct MachineCheckResult: Sendable {
    struct Problem: Equatable, Sendable {
        let what: String
        let next: String
    }
    private(set) var problems: [Problem] = []
    private(set) var fine: [String] = []

    init(agentAnswered: Bool, output: String, windows: Bool, soundLevels: (left: Int, right: Int)?) {
        guard agentAnswered else {
            problems.append(Problem(what: "it isn't answering Guest House", next: "wait for it to finish starting. If it's been more than a few minutes, press Command-Shift-R to reset it"))
            return
        }
        var values: [String: String] = [:]
        for line in output.split(whereSeparator: \.isNewline) {
            let parts = line.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false)
            if parts.count == 2 { values[parts[0].trimmingCharacters(in: .whitespaces)] = parts[1].trimmingCharacters(in: .whitespaces) }
        }
        fine.append("it's answering")
        let signedIn = values["signedin"] == "1"
        if signedIn {
            fine.append("someone is signed in")
        } else {
            problems.append(Problem(what: "nobody is signed in", next: "press Command-Shift-E and sign in. Its screen reader and clipboard start after that"))
        }
        if signedIn {
            if let reader = values["reader"], !reader.isEmpty {
                let names = reader.split(separator: ",").map { Self.readerName(String($0).lowercased()) }
                fine.append("\(names.joined(separator: " and ")) is running")
            } else {
                problems.append(Problem(what: "no screen reader is running", next: windows ? "press Command-Shift-E, then Control-Alt-N to start NVDA" : "press Command-Shift-E, then Super-Alt-S to start Orca"))
            }
        }
        // Linux has no sound to ask about until someone's signed in.
        if signedIn || windows {
            if values["sound"] == "1" && values["sounddevice"] == "1" {
                fine.append("sound is working")
            } else {
                problems.append(Problem(what: "its sound isn't working", next: "restart it. If that doesn't help, choose Report a Problem in the Help menu"))
            }
        }
        if let soundLevels {
            if soundLevels.left == 0 && soundLevels.right == 0 {
                problems.append(Problem(what: "its volume is set to zero in Guest House", next: "turn it up in its Settings, under Display and Sound"))
            } else if soundLevels.left == 0 {
                fine.append("its sound goes to your right ear only")
            } else if soundLevels.right == 0 {
                fine.append("its sound goes to your left ear only")
            }
        }
        if signedIn {
            if values["clipboard"] == "1" {
                fine.append("the clipboard agent is running")
            } else {
                problems.append(Problem(what: "the clipboard agent isn't running", next: windows ? "install spice-vdagent from spice-space.org in it" : "sign out of it and back in"))
            }
        }
        if values["sharedfolder"] == "1" {
            fine.append("the shared folder service is running")
        } else {
            problems.append(Problem(what: "the shared folder service isn't running", next: windows ? "install spice-webdavd from spice-space.org in it" : "choose Virtual Machine, Repair for Guest House, if it's offered, or restart it"))
        }
    }

    private static func readerName(_ raw: String) -> String {
        switch raw {
        case "nvda": return "NVDA"
        case "jfw": return "JAWS"
        case "narrator": return "Narrator"
        case "orca": return "Orca"
        default: return raw
        }
    }

    func words(machine: String) -> String {
        if problems.isEmpty { return "\(machine) looks good: \(fine.joined(separator: ", "))." }
        let list = problems.map { "\($0.what). Next: \($0.next)." }.joined(separator: " ")
        let count = problems.count == 1 ? "one problem" : "\(problems.count) problems"
        return "\(machine) has \(count): \(list)" + (fine.isEmpty ? "" : " Fine: \(fine.joined(separator: ", ")).")
    }
}

/// Command-Option in place of Control-Option, while the Mac's VoiceOver is on
/// (2026-11-16, the user's report: Control-Option with the arrows didn't
/// reach Windows until VoiceOver was turned off). Control-Option is
/// VoiceOver's own pair of keys, so VoiceOver takes them before any app sees
/// them, and in Windows and Linux the same two keys are Control-Alt: table
/// navigation in NVDA and JAWS, Control-Alt-N to start NVDA, Control-Alt-T
/// in Linux. Command-Option is one key to the right, VoiceOver leaves it
/// alone, and what it is in Windows (the Windows key with Alt) is hardly
/// used. So with VoiceOver on, Guest House turns it into Control-Alt.
/// With VoiceOver off nothing changes: Control-Option reaches the machine
/// by itself, and Command-Option stays the Windows key with Alt.
nonisolated enum ControlAltStandIn {
    static let control: Int32 = 0x1D

    /// Command and Option, with or without Shift, and VoiceOver on.
    static func applies(modifiers: NSEvent.ModifierFlags, voiceOverOn: Bool) -> Bool {
        let held = modifiers.intersection([.control, .command, .option, .shift])
        return voiceOverOn && (held == [.command, .option] || held == [.command, .option, .shift])
    }

    struct Step: Equatable, Sendable {
        let press: Bool
        let code: Int32
    }

    /// The machine already has Alt down (Option was sent as it was pressed)
    /// and, the first time, the Windows key (Command). Control goes down
    /// BEFORE the Windows key comes up: a Windows key let go with no other
    /// key pressed since it went down opens the Start menu, and Control is
    /// that other key. Then the key itself, then Control up. Alt is let go
    /// when the person lets go of Option, after other keys, so Windows
    /// doesn't take it for Alt alone either. `windowsKeyDown` is the
    /// Windows key's code while the machine still has it down.
    static func steps(key: Int32, windowsKeyDown: Int32?) -> [Step] {
        var steps = [Step(press: true, code: control)]
        if let windowsKey = windowsKeyDown { steps.append(Step(press: false, code: windowsKey)) }
        steps += [Step(press: true, code: key), Step(press: false, code: key), Step(press: false, code: control)]
        return steps
    }

    static let hint = "VoiceOver is on, and it keeps Control-Option keys for itself. For Control-Alt in the machine, hold Command-Option instead: Command-Option-Right Arrow is Control-Alt-Right Arrow. Or press Command-F5 to turn VoiceOver off; Guest House turns it back on when you return to the Mac."
    /// Settings, under Keyboard (2026-11-16: the user proved it with real
    /// keys and asked for it to be easier to find).
    static let settingsHeading = "Control-Alt keys with VoiceOver on"
    static let settingsWords = "Your Mac's VoiceOver keeps keys held with Control-Option for itself, so with VoiceOver on, Control-Alt keys never reach Windows or Linux. While VoiceOver is on and your keyboard is in a machine, hold Command-Option instead: Command-Option-Right Arrow is sent as Control-Alt-Right Arrow, and Command-Option-N as Control-Alt-N. Add Shift for Control-Alt-Shift. With VoiceOver off, nothing changes. If you turn VoiceOver off with Command-F5 while in a machine, Guest House turns it back on when you return to the Mac."
    /// The Virtual Machine menu's reminder, said on demand.
    static func reminder(voiceOverOn: Bool) -> String {
        voiceOverOn
            ? "VoiceOver is on. For Control-Alt in a machine, hold Command-Option: Command-Option-Right Arrow is Control-Alt-Right Arrow. Add Shift for Control-Alt-Shift."
            : "VoiceOver is off, so Control-Option reaches the machine as Control-Alt by itself. With VoiceOver on, hold Command-Option instead."
    }
}

/// Control keys the Mac itself takes before any app sees them (2026-11-16):
/// its own shortcuts for Mission Control, Spaces and input sources. These
/// never arrive at Guest House at all. With Accessibility allowed, Guest House
/// turns them off while the keyboard is in a machine
/// (MacShortcutsInMachine); without it, it says which are on and where
/// to turn them off.
/// Each is Apple's number in com.apple.symbolichotkeys with the key it has
/// by default; one that isn't in the list is at its default.
nonisolated enum MacKeptKeys {
    struct Shortcut: Equatable, Sendable {
        let number: String
        let keyCode: Int
        let name: String
        /// Where it is turned off, under Keyboard Shortcuts.
        let pane: String
        let onByDefault: Bool
    }

    static let all: [Shortcut] = [
        Shortcut(number: "32", keyCode: 126, name: "Control-Up Arrow", pane: "Mission Control", onByDefault: true),
        Shortcut(number: "33", keyCode: 125, name: "Control-Down Arrow", pane: "Mission Control", onByDefault: true),
        Shortcut(number: "79", keyCode: 123, name: "Control-Left Arrow", pane: "Mission Control", onByDefault: true),
        Shortcut(number: "81", keyCode: 124, name: "Control-Right Arrow", pane: "Mission Control", onByDefault: true),
        // Not Control-F1 to F8, the Mac's keyboard-focus shortcuts: the app is
        // offered those first (measured 2026-11-16: a real Control-F4 and
        // Control-F6 arrived and were claimed), so Guest House takes them.
        // Only acts with more than one input source, and is then written to the list.
        Shortcut(number: "60", keyCode: 49, name: "Control-Space", pane: "Input Sources", onByDefault: false),
    ]

    /// The ones the Mac holds now: on, still on their default key, with Control alone.
    static func kept(_ hotKeys: [String: Any]?) -> [Shortcut] {
        all.filter { shortcut in
            guard let entry = hotKeys?[shortcut.number] as? [String: Any] else { return shortcut.onByDefault }
            if (entry["enabled"] as? NSNumber)?.boolValue == false { return false }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return shortcut.onByDefault }
            let modifiers = parameters[2].intValue
            let control = 0x40000, otherModifiers = 0x20000 | 0x80000 | 0x100000
            return parameters[1].intValue == shortcut.keyCode && modifiers & control != 0 && modifiers & otherModifiers == 0
        }
    }

    /// "Control-F1 to Control-F8" for a run of function keys; the rest by name.
    static func names(_ kept: [Shortcut]) -> String {
        let functionKeys = kept.filter { $0.name.hasPrefix("Control-F") }
        var names = kept.filter { !$0.name.hasPrefix("Control-F") }.map(\.name)
        if functionKeys.count >= 3, let first = functionKeys.first, let last = functionKeys.last {
            names.append("\(first.name) to \(last.name)")
        } else {
            names += functionKeys.map(\.name)
        }
        return names.count <= 1 ? names.joined() : names.dropLast().joined(separator: ", ") + " and " + (names.last ?? "")
    }

    static func words(machine: String, kept: [Shortcut]) -> String {
        var panes: [String] = []
        for shortcut in kept where !panes.contains(shortcut.pane) { panes.append(shortcut.pane) }
        let places = panes.count <= 1 ? panes.joined() : panes.dropLast().joined(separator: ", ") + " and " + (panes.last ?? "")
        return "Your Mac keeps \(names(kept)) for its own shortcuts, so \(kept.count == 1 ? "it" : "they") won't reach \(machine). In Windows these move by word and by paragraph, and Control-Space selects. Next: open Guest House's Settings, go to Keyboard, and choose Give Machines the Mac's Shortcut Keys; Guest House then turns them off only while your keyboard is in a machine. Or turn them off yourself in System Settings, under Keyboard, Keyboard Shortcuts, then \(places)."
    }
}

/// Control with the Left and Right arrows, which the Mac can take before a
/// machine sees them (2026-11-02, the user's report): macOS has them on by
/// default for moving between Spaces. In Windows and Linux they move by word.
nonisolated enum MacSpacesShortcuts {
    /// Apple's numbers for "Move left a space" and "Move right a space", in
    /// com.apple.symbolichotkeys, with the key codes they use by default.
    private static let shortcuts = [("79", 123), ("81", 124)]

    /// An entry that isn't there is a shortcut still at its default, so on.
    /// One moved to other keys is out of the way.
    static func takeControlArrows(_ hotKeys: [String: Any]?) -> Bool {
        shortcuts.contains { number, keyCode in
            guard let entry = hotKeys?[number] as? [String: Any] else { return true }
            if (entry["enabled"] as? NSNumber)?.boolValue == false { return false }
            guard let value = entry["value"] as? [String: Any],
                  let parameters = value["parameters"] as? [NSNumber], parameters.count == 3 else { return true }
            let modifiers = parameters[2].intValue
            let control = 0x40000, otherModifiers = 0x20000 | 0x80000 | 0x100000
            return parameters[1].intValue == keyCode && modifiers & control != 0 && modifiers & otherModifiers == 0
        }
    }

    static func words(machine: String) -> String {
        "Your Mac keeps Control-Left Arrow and Control-Right Arrow for moving between Spaces, so they won't reach \(machine), where they move by word. Next: in System Settings, go to Keyboard, Keyboard Shortcuts, Mission Control, and turn off Move left a space and Move right a space."
    }
}

/// Which of the feed's early releases this copy of Guest House takes.
nonisolated enum UpdateChannels {
    static let earlyKey = "AVMEarlyUpdates"
    static var allowed: Set<String> {
        UserDefaults.standard.bool(forKey: earlyKey) ? ["early"] : []
    }
}

/// How a running QEMU is doing on the Mac, and what's worth saying about it.
nonisolated struct MachineHealth: Sendable {
    struct Reading: Sendable {
        var openFiles: Int
        var fileLimit: Int
        var memoryBytes: UInt64
        var macMemoryBytes: UInt64
        var faults: Int
    }
    struct Warning: Equatable, Sendable {
        let kind: String
        let words: String
    }
    let warnings: [Warning]

    init(_ reading: Reading) {
        var found: [Warning] = []
        if reading.fileLimit > 0, reading.openFiles * 10 >= reading.fileLimit * 8 {
            found.append(Warning(kind: "files", words: "it's near the most connections and files your Mac allows it, \(reading.openFiles) of \(reading.fileLimit). New connections may fail. Next: close what's using the network in it, or restart it."))
        }
        if reading.macMemoryBytes > 0, reading.memoryBytes * 10 >= reading.macMemoryBytes * 9 {
            found.append(Warning(kind: "memory", words: "it's using nearly all your Mac's memory. Next: shut it down and give it less, in its Settings."))
        }
        if reading.faults > 0 {
            found.append(Warning(kind: "faults", words: "the program that runs it, QEMU, has reported a fault since it started. It may stop working. Next: save your work, and choose Report a Problem in the Help menu."))
        }
        warnings = found
    }

    /// For Check This Machine.
    var words: String {
        warnings.isEmpty ? "Guest House's own health check found nothing wrong." : "Guest House's own health check: " + warnings.map(\.words).joined(separator: " ")
    }
}

/// QEMU's messages that say nothing's wrong (2026-11-02): a 3D session's log was
/// nine tenths these. DXMT's unimplemented Windows calls and virglrenderer's
/// debug lines, not its errors. Whole lines, so anything else still gets through.
nonisolated enum QEMUStderrNoise {
    private static let harmless = [
        "warn:  GetCurrentThread not implemented", "warn:  SetThreadPriority not implemented",
        "warn:  GetModuleHandle not implemented", "warn:  D3DKMTOpenAdapterFromLuid not implemented",
        "warn:  Failed to open D3DKMT adapter", "warn:  D3D11Resource(tex2d): Unknown interface query",
        "err:   Not implemented", "info:  ",
    ]

    static func isHarmless(_ line: String) -> Bool {
        if harmless.contains(where: { line.hasPrefix($0) }) { return true }
        guard line.contains("virgl_render_server["), line.contains("<Debug>:") else { return false }
        let lower = line.lowercased()
        if lower.contains("d3d12") { return true }
        return !lower.contains("error") && !lower.contains("fail")
    }

    /// The chunk with its harmless lines out, and how many went. Nil when
    /// nothing's left.
    static func filter(_ chunk: String) -> (kept: String?, dropped: Int) {
        let lines = chunk.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        let kept = lines.filter { !isHarmless($0) }
        let dropped = lines.count - kept.count
        if dropped == 0 { return (chunk, 0) }
        let text = kept.joined(separator: "\n")
        return (text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : text, dropped)
    }
}

/// Whether the Mac can reach the IPv6 internet, and QEMU's network line from it.
nonisolated enum MacIPv6 {
    /// A global address, 2000::/3. A router's own fd00:: addresses aren't one:
    /// a Mac can have those with an ISP that has no IPv6.
    static func isGlobal(_ address: [UInt8]) -> Bool {
        address.count == 16 && address[0] & 0xE0 == 0x20
    }

    /// Connecting a UDP socket sends nothing: it only asks for a route, and
    /// which of the Mac's addresses that route would use.
    static var isReachable: Bool {
        let fd = socket(AF_INET6, SOCK_DGRAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        var target = sockaddr_in6()
        target.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
        target.sin6_family = sa_family_t(AF_INET6)
        target.sin6_port = in_port_t(53).bigEndian
        guard inet_pton(AF_INET6, "2606:4700:4700::1111", &target.sin6_addr) == 1 else { return false }
        let size = socklen_t(MemoryLayout<sockaddr_in6>.size)
        let connected = withUnsafePointer(to: &target) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, size) } }
        guard connected == 0 else { return false }
        var local = sockaddr_in6()
        var length = size
        let named = withUnsafeMutablePointer(to: &local) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        guard named == 0 else { return false }
        return isGlobal(withUnsafeBytes(of: local.sin6_addr) { Array($0) })
    }

    static func netdev(windows: Bool, macHasIPv6: Bool) -> String {
        windows && !macHasIPv6 ? "user,id=net0,ipv6=off" : "user,id=net0"
    }
}

/// When a machine's automatic backup is due, and which old ones go.
nonisolated enum BackupSchedule {
    static let folderKey = "AVMBackupFolder"
    static let keep = 3

    static func isDue(every: String?, last: Date?, now: Date) -> Bool {
        let period: TimeInterval
        switch every {
        case "daily": period = 86_400
        case "weekly": period = 7 * 86_400
        default: return false
        }
        guard let last else { return true }
        // An hour's grace: the look is hourly, and a daily backup shouldn't creep.
        return now.timeIntervalSince(last) >= period - 3600
    }

    /// A new backup's name: sorts by date, and never clashes within a minute.
    static func name(base: String, ext: String, date: Date) -> String {
        let format = DateFormatter()
        format.locale = Locale(identifier: "en_US_POSIX")
        format.dateFormat = "yyyy-MM-dd HHmm"
        return "\(base) backup \(format.string(from: date)).\(ext)"
    }

    /// Of a folder's names, this machine's backups past the newest `keep`.
    /// Exactly "<base> backup yyyy-MM-dd HHmm.<ext>" (2026-11-05 audit): a
    /// prefix alone took "Ubuntu backup backup …", another machine's, for
    /// Ubuntu's, and as those sorted last, Ubuntu's own were the ones removed.
    /// The caller also checks each package's machine id, for two names that
    /// become the same base.
    static func oldOnes(in names: [String], base: String, ext: String, keep: Int = BackupSchedule.keep) -> [String] {
        let shape = Array("dddd-dd-dd dddd")
        let mine = names.filter { name in
            guard name.hasPrefix("\(base) backup "), name.hasSuffix(".\(ext)") else { return false }
            let middle = Array(name.dropFirst(base.count + " backup ".count).dropLast(ext.count + 1))
            return middle.count == shape.count && zip(middle, shape).allSatisfy { c, s in s == "d" ? c.isASCII && c.isNumber : c == s }
        }.sorted()
        return Array(mine.dropLast(keep))
    }
}

// MARK: - Keeping the Mac awake

/// The Mac stays awake through work nobody is at the keyboard for
/// (2026-11-10, audit of that day #11): an unattended install runs 20 to 60
/// minutes and a download as long, a MacBook left alone went to sleep in
/// the middle, and the install stopped, the download dropped, and the
/// minute-counting alarms fired on waking. Idle sleep only: closing the lid
/// still sleeps. One hold per piece of work, by its key.
@MainActor
enum KeepAwake {
    private static var holds: [String: NSObjectProtocol] = [:]

    static func begin(_ key: String, reason: String) {
        guard holds[key] == nil else { return }
        holds[key] = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled], reason: reason)
        AVMLog.write("Guest House: KeepAwake — the Mac stays awake: \(reason)")
    }

    static func end(_ key: String) {
        guard let hold = holds.removeValue(forKey: key) else { return }
        ProcessInfo.processInfo.endActivity(hold)
        AVMLog.write("Guest House: KeepAwake — released (\(key))")
    }
}

// MARK: - Work that may never come back

/// Whether a call that can block for good ends in time (2026-11-11, audit
/// of 2026-11-10 #43). The work runs on a thread of its own, not one of
/// Swift's, so a call that never returns costs that thread and nothing
/// else; it is left to finish by itself.
nonisolated enum Stalls {
    private final class Answer: @unchecked Sendable {
        private let lock = NSLock()
        private var continuation: CheckedContinuation<Bool, Never>?
        init(_ continuation: CheckedContinuation<Bool, Never>) { self.continuation = continuation }
        func give(_ value: Bool) {
            lock.lock(); let waiting = continuation; continuation = nil; lock.unlock()
            waiting?.resume(returning: value)
        }
    }

    /// True when `work` ended within `seconds`.
    static func finishes(within seconds: Double, _ work: @escaping @Sendable () -> Void) async -> Bool {
        await withCheckedContinuation { continuation in
            let answer = Answer(continuation)
            Thread.detachNewThread {
                work()
                answer.give(true)
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { answer.give(false) }
        }
    }
}


// fork-only
/// Anonymous usage counts (2026-11-14, the user's request): how many copies
/// of Guest House are in use, with no name, address or install number, and
/// only when the person has said yes. Once a day at most, a copy sends its
/// version, the macOS version, its language, how many machines of each kind
/// it has, and three answers it works out here from the day it last sent:
/// is this its first message ever, its first this week, its first this
/// month. Those are what let the website count copies a day, a week and a
/// month without anything that links one day's message to the next.
/// The sending is in UsageCountsSender.swift; this is what the tests reach.
nonisolated enum UsageCounts {
    /// "yes" or "no"; not there until the person has answered.
    static let choiceKey = "UsageCountsChoice"
    /// The day of the last message that arrived, as yyyy-MM-dd.
    static let lastSentKey = "UsageCountsLastSent"
    /// "yes" or "no" to the fuller message (2026-11-14, later the same day):
    /// which features were used, whether installs finished, which screen
    /// readers the machines have, unexpected quits, and roughly how long
    /// this copy has been in use. Asked separately of people who had
    /// already said yes to the short one.
    static let detailKey = "UsageCountsDetail"
    /// What has happened since the last message that arrived: a name and
    /// how many times. Kept on this Mac whatever the answers are, and only
    /// ever sent with a yes to the fuller message.
    static let notesKey = "UsageCountsNotes"
    /// The day this copy first ran with usage counts in it.
    static let firstDayKey = "UsageCountsFirstDay"
    /// False while Guest House runs, true once it has quit in good order.
    static let closedCleanlyKey = "UsageCountsClosedCleanly"

    /// Everything that can be noted, by its fixed name. Nothing free-form:
    /// no machine's name, no file's, no text.
    enum Note: String, CaseIterable, Sendable {
        case machineStarted = "machine_started", macMachineStarted = "mac_machine_started"
        case sharedFolder = "shared_folder", windowsKeyboard = "windows_keyboard", remoteDesktop = "remote_desktop"
        case printers, camera
        case saveResume = "save_resume", restorePoint = "restore_point", exportImport = "export_import"
        case sendFile = "send_file", typeClipboard = "type_clipboard", readScreen = "read_screen", describeScreen = "describe_screen"
        case usbDevice = "usb_device", bluetoothDevice = "bluetooth_device", installApps = "install_apps"
        case installStartedWindows = "install_started_windows", installFinishedWindows = "install_finished_windows", installMediaFailedWindows = "install_media_failed_windows"
        case installStartedLinux = "install_started_linux", installFinishedLinux = "install_finished_linux", installMediaFailedLinux = "install_media_failed_linux", installFailedLinux = "install_failed_linux"
        case unexpectedQuit = "unexpected_quit"

        var isInstall: Bool { rawValue.hasPrefix("install_started") || rawValue.hasPrefix("install_finished") || rawValue.contains("_failed_") }
    }

    private static let notesLock = NSLock()

    /// From any thread. One more of this, since the last message.
    static func note(_ note: Note, in defaults: UserDefaults = .standard) {
        notesLock.lock(); defer { notesLock.unlock() }
        var notes = defaults.dictionary(forKey: notesKey) as? [String: Int] ?? [:]
        notes[note.rawValue] = min(999, (notes[note.rawValue] ?? 0) + 1)
        defaults.set(notes, forKey: notesKey)
    }

    static func notes(in defaults: UserDefaults = .standard) -> [String: Int] {
        notesLock.lock(); defer { notesLock.unlock() }
        return defaults.dictionary(forKey: notesKey) as? [String: Int] ?? [:]
    }

    /// Once a message carrying `sent` has arrived: those are taken off, and
    /// what was noted while it travelled stays for the next.
    static func forget(_ sent: [String: Int], in defaults: UserDefaults = .standard) {
        notesLock.lock(); defer { notesLock.unlock() }
        var notes = defaults.dictionary(forKey: notesKey) as? [String: Int] ?? [:]
        for (name, count) in sent {
            let left = (notes[name] ?? 0) - count
            notes[name] = left > 0 ? left : nil
        }
        defaults.set(notes, forKey: notesKey)
    }

    /// How long this copy has been in use, in four rough bands.
    static func age(firstDay: String?, now: Date, zone: TimeZone = .current) -> String {
        guard let firstDay, let first = date(fromDay: firstDay, in: zone) else { return "week" }
        let days = Int(now.timeIntervalSince(first) / 86_400)
        return days < 7 ? "week" : days < 30 ? "month" : days < 90 ? "quarter" : "older"
    }

    /// The fuller message's part, from what was noted. Unknown names are left out.
    struct Detail: Equatable, Sendable {
        var used: [String]
        var installs: [String: Int]
        var unexpectedQuits: Int
        var readers: [String]
        var age: String
    }

    static func detail(notes: [String: Int], readers: [String], age: String) -> Detail {
        let known = notes.filter { Note(rawValue: $0.key) != nil && $0.value > 0 }
        return Detail(used: known.keys.filter { !(Note(rawValue: $0)!.isInstall) && $0 != Note.unexpectedQuit.rawValue }.sorted(),
                      installs: known.filter { Note(rawValue: $0.key)!.isInstall },
                      unexpectedQuits: known[Note.unexpectedQuit.rawValue] ?? 0,
                      readers: Array(Set(readers.map { $0.lowercased() }.filter { ["nvda", "jaws", "orca"].contains($0) })).sorted(),
                      age: age)
    }
    static let address = "https://fullcircleat.com/app/ping/"

    struct Message: Equatable, Sendable {
        var version: String
        var macOS: String
        var language: String
        var firstEver: Bool
        var firstThisWeek: Bool
        var firstThisMonth: Bool
        var windows: Int
        var linux: Int
        var macOSMachines: Int
        /// Only with a yes to the fuller message.
        var detail: Detail? = nil
    }

    /// Weeks from Monday, as the website counts them.
    private static var weeks: Calendar { Calendar(identifier: .iso8601) }

    static func day(_ date: Date, in zone: TimeZone = .current) -> String {
        var calendar = weeks
        calendar.timeZone = zone
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }

    private static func date(fromDay day: String, in zone: TimeZone) -> Date? {
        let numbers = day.split(separator: "-").compactMap { Int($0) }
        guard numbers.count == 3 else { return nil }
        var calendar = weeks
        calendar.timeZone = zone
        return calendar.date(from: DateComponents(year: numbers[0], month: numbers[1], day: numbers[2], hour: 12))
    }

    /// Today's message, or nil when one already went today. A last day that
    /// can't be read, or is after today (the clock was changed), counts as
    /// never having sent, except that it isn't called the first ever.
    static func message(lastSent: String?, now: Date, zone: TimeZone = .current, version: String, macOS: String, language: String,
                        windows: Int, linux: Int, macOSMachines: Int) -> Message? {
        let today = day(now, in: zone)
        if lastSent == today { return nil }
        var calendar = weeks
        calendar.timeZone = zone
        let last = lastSent.flatMap { date(fromDay: $0, in: zone) }.flatMap { $0 <= now.addingTimeInterval(86_400) ? $0 : nil }
        func same(_ parts: Set<Calendar.Component>) -> Bool {
            guard let last else { return false }
            return calendar.dateComponents(parts, from: last) == calendar.dateComponents(parts, from: now)
        }
        return Message(version: version, macOS: macOS, language: String(language.lowercased().prefix(2)),
                       firstEver: lastSent == nil,
                       firstThisWeek: !same([.yearForWeekOfYear, .weekOfYear]),
                       firstThisMonth: !same([.year, .month]),
                       windows: max(0, windows), linux: max(0, linux), macOSMachines: max(0, macOSMachines))
    }

    /// Exactly what is sent: nothing else leaves the Mac.
    static func body(_ message: Message) -> Data {
        let object: [String: Any] = [
            "version": message.version, "macos": message.macOS, "language": message.language,
            "first_ever": message.firstEver, "first_this_week": message.firstThisWeek, "first_this_month": message.firstThisMonth,
            "machines": ["windows": message.windows, "linux": message.linux, "macos": message.macOSMachines],
        ]
        var all = object
        if let detail = message.detail {
            all["used"] = detail.used
            all["installs"] = detail.installs
            all["unexpected_quits"] = detail.unexpectedQuits
            all["readers"] = detail.readers
            all["age"] = detail.age
        }
        return (try? JSONSerialization.data(withJSONObject: all, options: [.sortedKeys])) ?? Data()
    }

    /// For Settings, before any is sent: what it holds today.
    static func summary(_ message: Message) -> String {
        "Guest House \(message.version), macOS \(message.macOS), language \(message.language), \(message.windows) Windows, \(message.linux) Linux and \(message.macOSMachines) macOS machines, and whether it is this copy's first message ever, this week and this month" + detailWords(message.detail)
    }

    /// The fuller message's part, in words.
    static func detailWords(_ detail: Detail?) -> String {
        guard let detail else { return "" }
        func list(_ names: [String]) -> String { names.isEmpty ? "none" : names.map { $0.replacingOccurrences(of: "_", with: " ") }.joined(separator: ", ") }
        let installs = detail.installs.sorted { $0.key < $1.key }.map { "\($0.key.replacingOccurrences(of: "_", with: " ")) \($0.value)" }
        return "; features used since the last message: \(list(detail.used)); installs: \(installs.isEmpty ? "none" : installs.joined(separator: ", ")); unexpected quits: \(detail.unexpectedQuits); screen readers set up: \(list(detail.readers)); in use for: \(detail.age == "week" ? "under a week" : detail.age == "month" ? "under a month" : detail.age == "quarter" ? "under three months" : "three months or more")"
    }

    /// The same, in words, for the log.
    static func words(_ message: Message) -> String {
        "Guest House \(message.version), macOS \(message.macOS), language \(message.language), \(message.windows) Windows, \(message.linux) Linux and \(message.macOSMachines) macOS machines; first ever: \(message.firstEver ? "yes" : "no"), first this week: \(message.firstThisWeek ? "yes" : "no"), first this month: \(message.firstThisMonth ? "yes" : "no")" + detailWords(message.detail)
    }
}
// /fork-only
