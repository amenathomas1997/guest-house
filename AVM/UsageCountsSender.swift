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

    /// From launch, not in a test run: today's message if it is owed, then a
    /// look every six hours for a copy that stays open for days; and the
    /// one-time question, once the person is at Guest House.
    static func start() {
        sendIfDue()
        timer = Timer.scheduledTimer(withTimeInterval: 6 * 3600, repeats: true) { _ in
            Task { @MainActor in sendIfDue() }
        }
        if choice == nil { askWhenOnTheMac() }
    }

    static func todaysMessage(ignoringLast: Bool = false) -> UsageCounts.Message? {
        let machines = VMStore.shared?.configurations ?? []
        let system = ProcessInfo.processInfo.operatingSystemVersion
        return UsageCounts.message(
            lastSent: ignoringLast ? nil : UserDefaults.standard.string(forKey: UsageCounts.lastSentKey), now: Date(),
            version: Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0",
            macOS: "\(system.majorVersion).\(system.minorVersion)",
            language: Locale.preferredLanguages.first ?? "en",
            windows: machines.filter { $0.guestOS == .windows }.count,
            linux: machines.filter { $0.guestOS.isLinux }.count,
            macOSMachines: machines.filter { $0.guestOS == .macOS }.count)
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
        let message = UsageCounts.message(lastSent: nil, now: Date(), version: "0.0.1", macOS: "27.3", language: "en-US",
                                          windows: 2, linux: 1, macOSMachines: 0)!
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
        Task {
            let arrived = await send(message, to: url)
            sending = false
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
        guard choice == nil, !asking else { return }
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
        let alert = NSAlert()
        alert.messageText = "Share anonymous usage counts with Full Circle AT?"
        alert.informativeText = "This helps me know how many people use Guest House and which systems they run, so I know what to work on. Once a day, Guest House would send only this: its version, your macOS version, your language, how many Windows, Linux and macOS machines you have, and whether it is the first message this week and this month. It never sends your name, an install number, your machines' names, anything you type, or any files, and the website doesn't keep your internet address. Every message is written to the diagnostic log, and you can change this any time in Guest House's Settings, under General."
        alert.addButton(withTitle: "Share Anonymous Counts")
        alert.addButton(withTitle: "Don't Share")
        set(alert.runModal() == .alertFirstButtonReturn)
        Announcer.shared.announce(choice == true ? "Thank you. Anonymous counts are shared. You can change this in Settings, under General."
                                                 : "Nothing is shared. You can change this in Settings, under General.", tone: .info)
    }
}
