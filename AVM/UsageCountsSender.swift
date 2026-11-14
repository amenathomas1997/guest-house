// UsageCountsSender.swift
// Guest House — accessible virtual machines
//
// Anonymous usage counts (2026-11-14, the user's request). Nobody knew how
// many people use Guest House: GitHub's download numbers count repeats and
// tests, and say nothing of who went on using it. With the person's yes,
// this sends one small message a day to fullcircleat.com saying only that a
// copy is in use: UsageCounts (GuestWatchLogic.swift) says exactly what.
//
// Asked once, in a question that says what is sent and what never is; off
// until answered; changed any time in Settings, General. Every message sent
// is written to the diagnostic log in full, so anyone can check it. No
// name, no install number, nothing typed, no machine names, no file names.
// The website keeps totals only, and not the internet address.

import AppKit

@MainActor
enum UsageCountsSender {
    private static var timer: Timer?
    private static var sending = false
    private static var asking = false

    static var choice: Bool? {
        switch UserDefaults.standard.string(forKey: UsageCounts.choiceKey) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    static func set(_ share: Bool) {
        UserDefaults.standard.set(share ? "yes" : "no", forKey: UsageCounts.choiceKey)
        AVMLog.write("Guest House: usage counts — sharing turned \(share ? "on" : "off")")
        if share { sendIfDue() }
    }

    /// The fuller message: nil until answered.
    static var detail: Bool? {
        switch UserDefaults.standard.string(forKey: UsageCounts.detailKey) {
        case "yes": return true
        case "no": return false
        default: return nil
        }
    }

    static func setDetail(_ share: Bool) {
        UserDefaults.standard.set(share ? "yes" : "no", forKey: UsageCounts.detailKey)
        AVMLog.write("Guest House: usage counts — features and install results turned \(share ? "on" : "off")")
    }

    /// At launch, before anything can be noted: did the last run end in good
    /// order? A run that didn't (a crash, a hang ended by force, the Mac
    /// losing power) is one unexpected quit. Then this run is marked open.
    static func noteLaunch() {
        let defaults = UserDefaults.standard
        if defaults.object(forKey: UsageCounts.closedCleanlyKey) != nil, !defaults.bool(forKey: UsageCounts.closedCleanlyKey) {
            UsageCounts.note(.unexpectedQuit)
            AVMLog.write("Guest House: the last run didn't end in good order")
        }
        defaults.set(false, forKey: UsageCounts.closedCleanlyKey)
        if defaults.string(forKey: UsageCounts.firstDayKey) == nil {
            defaults.set(UsageCounts.day(Date()), forKey: UsageCounts.firstDayKey)
        }
    }

    /// From applicationWillTerminate.
    static func noteQuit() {
        UserDefaults.standard.set(true, forKey: UsageCounts.closedCleanlyKey)
    }

    /// A machine reached running: that, and what it was set up with.
    static func noteStart(_ configuration: VMConfiguration) {
        UsageCounts.note(.machineStarted)
        if configuration.sharedFolderURL != nil { UsageCounts.note(.sharedFolder) }
        if configuration.windowsKeyboardID != nil { UsageCounts.note(.windowsKeyboard) }
        if configuration.remoteDesktopOn { UsageCounts.note(.remoteDesktop) }
        if configuration.sharesPrinters { UsageCounts.note(.printers) }
        if configuration.sharesCamera { UsageCounts.note(.camera) }
    }

    /// From launch, not in a test run: today's message if it is owed, then a
    /// look every six hours for a copy that stays open for days; and the
    /// one-time question, once the person is at Guest House.
    static func start() {
        sendIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in sendIfDue() }
        }
        if choice == nil || (choice == true && detail == nil) { askWhenOnTheMac() }
    }

    static func todaysMessage(ignoringLast: Bool = false, withDetail: Bool? = nil) -> UsageCounts.Message? {
        let machines = VMStore.shared?.configurations ?? []
        let system = ProcessInfo.processInfo.operatingSystemVersion
        var message = UsageCounts.message(
            lastSent: ignoringLast ? nil : UserDefaults.standard.string(forKey: UsageCounts.lastSentKey), now: Date(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            macOS: "\(system.majorVersion).\(system.minorVersion)",
            language: Locale.preferredLanguages.first ?? "en",
            windows: machines.filter { $0.guestOS == .windows }.count,
            linux: machines.filter { $0.guestOS.isLinux }.count,
            macOSMachines: machines.filter { $0.guestOS == .macOS }.count)
        if withDetail ?? (detail == true) {
            // The screen readers chosen when each Windows machine was made, and Orca for Linux.
            let readers = machines.flatMap { $0.guestOS == .windows ? $0.windowsScreenReaders.map(\.rawValue) : $0.guestOS.isLinux ? ["orca"] : [] }
            message?.detail = UsageCounts.detail(notes: UsageCounts.notes(), readers: readers,
                                                 age: UsageCounts.age(firstDay: UserDefaults.standard.string(forKey: UsageCounts.firstDayKey), now: Date()))
        }
        return message
    }

    /// True when the website took it.
    private static func send(_ message: UsageCounts.Message, to url: URL) async -> Bool {
        var request = URLRequest(url: url, timeoutInterval: 20)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.setValue("Guest House", forHTTPHeaderField: "User-Agent")
        request.httpBody = UsageCounts.body(message)
        // No cookies, no cache, nothing kept between messages.
        let session = URLSession(configuration: .ephemeral)
        defer { session.invalidateAndCancel() }
        guard let (_, response) = try? await session.data(for: request) else { return false }
        return (200..<300).contains((response as? HTTPURLResponse)?.statusCode ?? 0)
    }

    /// `Guest House --test-usage-counts <address>`: one made-up message to a
    /// test address (a copy of the website on this Mac), so the real counts
    /// never hold a test's. Prints what it sent and whether it arrived.
    static func runTestIfAsked(arguments: [String] = CommandLine.arguments) {
        guard let at = arguments.firstIndex(of: "--test-usage-counts"), arguments.indices.contains(at + 1),
              let url = URL(string: arguments[at + 1]) else { return }
        var message = UsageCounts.message(lastSent: nil, now: Date(), version: "0.0.1", macOS: "27.3", language: "en-US",
                                          windows: 2, linux: 1, macOSMachines: 0)!
        // --with-detail: the fuller message too, made up the same way.
        if arguments.contains("--with-detail") {
            message.detail = UsageCounts.detail(notes: ["machine_started": 3, "shared_folder": 1, "install_apps": 1, "install_started_windows": 2,
                                                        "install_finished_windows": 1, "install_media_failed_linux": 1, "unexpected_quit": 1],
                                                readers: ["nvda", "orca"], age: "month")
        }
        print("   sending: \(String(decoding: UsageCounts.body(message), as: UTF8.self))")
        Task {
            let arrived = await send(message, to: url)
            print(arrived ? "   yes  it arrived\nPASSED" : "   NO   it arrived\nFAILED")
            exit(arrived ? 0 : 1)
        }
        RunLoop.main.run(until: Date().addingTimeInterval(30))
        print("   NO   it answered within 30 seconds\nFAILED")
        exit(1)
    }

    static func sendIfDue() {
        guard choice == true, !sending, let message = todaysMessage(), let url = URL(string: UsageCounts.address) else { return }
        sending = true
        let sent = UsageCounts.day(Date())
        // What this message carries of the notes; what is noted meanwhile stays.
        let carried = message.detail == nil ? [:] : UsageCounts.notes()
        Task {
            let arrived = await send(message, to: url)
            sending = false
            if arrived { UsageCounts.forget(carried) }
            // Only a message that arrived counts as sent: the next look tries again.
            if arrived {
                UserDefaults.standard.set(sent, forKey: UsageCounts.lastSentKey)
                AVMLog.write("Guest House: usage counts — sent: \(UsageCounts.words(message))")
            } else {
                AVMLog.write("Guest House: usage counts — today's didn't arrive; it will be tried again")
            }
        }
    }

    // MARK: The one-time question

    private static func askWhenOnTheMac() {
        guard choice == nil || (choice == true && detail == nil), !asking else { return }
        // Not at a quiet login, with the keyboard in a machine, under another
        // question or sheet, or while Guest House is behind another app.
        let busy = BackgroundMode.shared.quietUntilOpened || FocusLockManager.shared?.isLocked == true
            || NSApp.modalWindow != nil || NSApp.windows.contains { $0.attachedSheet != nil } || !NSApp.isActive
            || !(NSApp.windows.contains { $0.isVisible && $0.isKeyWindow })
        guard !busy else {
            DispatchQueue.main.asyncAfter(deadline: .now() + 5) { askWhenOnTheMac() }
            return
        }
        asking = true
        defer { asking = false }
        let never = "It never sends your name, an install number, your machines' names, anything you type, or any files, and the website doesn't keep your internet address. Every message is written to the diagnostic log, and you can change this any time in Guest House's Settings, under General."
        let fuller = "which features were used since the last message (for example a shared folder, Save, or Install Apps, by name only), whether installs of Windows or Linux started, finished or failed, which screen readers your machines were set up with, whether Guest House closed unexpectedly, and roughly how long you have used it"
        let alert = NSAlert()
        if choice == nil {
            // Never asked: one question for everything.
            alert.messageText = "Share anonymous usage counts with Full Circle AT?"
            alert.informativeText = "This helps me know how many people use Guest House, what they use it for and where installs go wrong, so I know what to work on. Once a day, Guest House would send only this: its version, your macOS version, your language, how many Windows, Linux and macOS machines you have, whether it is the first message this week and this month, \(fuller). \(never)"
            alert.addButton(withTitle: "Share Anonymous Counts")
            alert.addButton(withTitle: "Don't Share")
            let yes = alert.runModal() == .alertFirstButtonReturn
            setDetail(yes)
            set(yes)
            Announcer.shared.announce(yes ? "Thank you. Anonymous counts are shared. You can change this in Settings, under General."
                                          : "Nothing is shared. You can change this in Settings, under General.", tone: .info)
        } else {
            // Said yes to the short message (0.4.50): the fuller one is asked for, not assumed.
            alert.messageText = "Also share which features you use and whether installs succeed?"
            alert.informativeText = "You agreed to share anonymous usage counts. Guest House can now add a little more to that daily message, to show me what people use and where installs go wrong: \(fuller). \(never) If you choose Keep It As It Is, Guest House goes on sending only what you agreed to before."
            alert.addButton(withTitle: "Share These Too")
            alert.addButton(withTitle: "Keep It As It Is")
            let yes = alert.runModal() == .alertFirstButtonReturn
            setDetail(yes)
            Announcer.shared.announce(yes ? "Thank you. Features and install results are shared too. You can change this in Settings, under General."
                                          : "Nothing more is shared. You can change this in Settings, under General.", tone: .info)
        }
    }
}
