// KeyboardTestJob.swift
// Guest House — accessible virtual machines
//
// The keyboard, tested into a real Windows (2026-10-26), for
// Tools/test-windows-install.sh --keyboard:
//
//   Guest House.app/Contents/MacOS/Guest House --test-keyboard --spice <spice.sock> [--qmp <qmp.sock>]
//
// It connects to a running Windows machine's SPICE socket the way the
// machine's window does (CocoaSpice), and types a fixed sequence through
// the same send calls and the same translation Guest House uses: Mac keys through
// SPICECoordinator.scancode(forVirtualKey:), modifiers through
// ModifierSides, the keyboard for Windows' keys through
// WindowsKeyTranslator, and the way back to the Mac through the same
// Control tap and release as the unlock flush. The test script has a key
// watcher running in Windows' signed-in session and compares what Windows
// saw with what should have arrived. Prints each step; exits 0 when every
// key was sent, 1 if the machine's input couldn't be reached.

import Foundation
import Carbon.HIToolbox
import CocoaSpiceNoUsb

@MainActor
enum KeyboardTestJob {

    static let flag = "--test-keyboard"
    /// QEMU's control socket: Pause goes that way, as in the app
    /// (VMView's WindowsKeyboard.sendPause).
    private static var qmpPath: String?

    /// One QMP command on a fresh connection: greeting, capabilities, the
    /// command. Enough for a test; the app uses VMManager's connection.
    private static func qmp(_ command: String) {
        guard let qmpPath else { print("   (no --qmp; Pause not sent)"); return }
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return }
        defer { close(fd) }
        var addr = sockaddr_un()
        addr.sun_family = sa_family_t(AF_UNIX)
        _ = withUnsafeMutableBytes(of: &addr.sun_path) { raw in
            qmpPath.utf8CString.withUnsafeBytes { raw.copyMemory(from: UnsafeRawBufferPointer(rebasing: $0.prefix(raw.count - 1))) }
        }
        let connected = withUnsafePointer(to: &addr) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard connected == 0 else { print("   (QMP connect failed)"); return }
        var buffer = [UInt8](repeating: 0, count: 4096)
        _ = read(fd, &buffer, buffer.count)                                  // greeting
        for line in [#"{"execute":"qmp_capabilities"}"#, command] {
            let bytes = Array((line + "\n").utf8)
            _ = write(fd, bytes, bytes.count)
            _ = read(fd, &buffer, buffer.count)
        }
    }

    private static func pause(down: Bool) {
        qmp(#"{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":\#(down),"key":{"type":"qcode","data":"pause"}}}]}}"#)
    }

    /// `--play-spice-audio --spice <sock> [--low-latency]`: plays a
    /// machine's sound the way its window does (CocoaSpice, Guest House's audio
    /// pipeline), with nothing else, until stopped; for
    /// Tools/measure-audio-latency.sh to listen to (2026-10-26).
    static func playAudioIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--play-spice-audio"),
              let i = arguments.firstIndex(of: "--spice"), arguments.indices.contains(i + 1) else { return }
        AVMLog.useTestLogFolder()
        SpiceAudioPipeline.apply(lowLatency: arguments.contains("--low-latency"))
        let client = Client()
        client.wantsAudio = true
        guard client.connect(URL(fileURLWithPath: arguments[i + 1])) else {
            print("FAILED: couldn't connect")
            exit(1)
        }
        print("PLAYING")
        fflush(stdout)
        while true { RunLoop.main.run(until: Date().addingTimeInterval(1)) }
    }

    /// `Guest House --test-control-keys` (2026-11-16, a report that Control-Tab,
    /// Control-Space and Control-F4 didn't reach Windows): do Control keys
    /// that arrive at Guest House reach the code that sends keys to the
    /// machine? A small window with the machine's own key view and a button
    /// beside it (somewhere for Control-Tab to go), the keyboard marked as
    /// in the machine, and key events sent through NSApp. No machine runs.
    /// A check that the path works, and no more: events sent from code
    /// reach the handler even under the old rule, which lost a real
    /// Control-Tab (measured with a key-logging window, ~/Developer/
    /// avm-probe/keyprobe). Keys the Mac itself takes, such as Control-F4,
    /// never arrive at all (MacShortcutsInMachine).
    static func controlKeysIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains("--test-control-keys") else { return }
        AVMLog.useTestLogFolder()
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) {
            MainActor.assumeIsolated {
                print("   keyboard navigation of all controls, as VoiceOver turns on: \(NSApp.isFullKeyboardAccessEnabled ? "on" : "off")")
                let focus = FocusLockManager()
                let coordinator = SPICECoordinator(focusLock: focus)
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 160), styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "Guest House key test"
                let view = SPICEKeyCaptureView(frame: NSRect(x: 0, y: 40, width: 360, height: 120), device: nil)
                view.coordinator = coordinator
                let button = NSButton(title: "Another control", target: nil, action: nil)
                button.frame = NSRect(x: 10, y: 5, width: 160, height: 30)
                window.contentView?.addSubview(view)
                window.contentView?.addSubview(button)
                window.center()
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                window.makeFirstResponder(view)
                focus.isLocked = true
                var failed = false
                func press(_ name: String, _ keyCode: UInt16, _ flags: NSEvent.ModifierFlags, _ characters: String, expected: Bool = true) {
                    guard let event = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime,
                                                       windowNumber: window.windowNumber, context: nil, characters: characters,
                                                       charactersIgnoringModifiers: characters, isARepeat: false, keyCode: keyCode) else { return }
                    window.makeFirstResponder(view)
                    let before = SPICECoordinator.pressesSeenForTest
                    NSApp.sendEvent(event)
                    let reached = SPICECoordinator.pressesSeenForTest > before
                    let kept = window.firstResponder === view
                    if reached != expected || !kept { failed = true }
                    print("   \(reached && kept ? "yes" : "NO ")  \(name): \(reached ? "reached the machine's keys" : "did not reach the machine's keys")\(kept ? "" : ", and the keyboard left the machine's view")")
                }
                let functionKey = String(UnicodeScalar(NSF4FunctionKey)!)
                press("a plain letter", 0, [], "a")
                press("Control-Tab", 48, [.control], "\t")
                press("Control-Shift-Tab", 48, [.control, .shift], "\u{19}")
                press("Control-Space", 49, [.control], " ")
                press("Control-F4", 118, [.control, .function], functionKey)
                press("Control-F6", 97, [.control, .function], String(UnicodeScalar(NSF6FunctionKey)!))
                press("Control-A", 0, [.control], "\u{01}")
                press("Control-Escape", 53, [.control], "\u{1b}")
                press("Control-Right Arrow", 124, [.control, .function, .numericPad], String(UnicodeScalar(NSRightArrowFunctionKey)!))
                focus.isLocked = false
                window.orderOut(nil)
                print(failed ? "FAILED" : "PASSED")
                fflush(stdout)
                exit(failed ? 1 : 0)
            }
        }
    }

    /// `Guest House --serve-folder <folder> --spice <spice.sock>` (2026-10-27): a
    /// SPICE client that only serves a folder, as a machine's window does,
    /// for the shared folder test; runs until it's ended.
    static func serveFolderIfAsked(arguments: [String] = CommandLine.arguments) {
        guard let f = arguments.firstIndex(of: "--serve-folder"), arguments.indices.contains(f + 1),
              let i = arguments.firstIndex(of: "--spice"), arguments.indices.contains(i + 1) else { return }
        AVMLog.useTestLogFolder()
        let client = Client()
        client.sharedFolder = arguments[f + 1]
        guard client.connect(URL(fileURLWithPath: arguments[i + 1])) else {
            print("FAILED: couldn't connect")
            exit(1)
        }
        print("SERVING")
        fflush(stdout)
        // --then-folder <folder> --after <seconds> (2026-11-14): the folder
        // changed while the machine runs, as saving Settings changes it.
        if let t = arguments.firstIndex(of: "--then-folder"), arguments.indices.contains(t + 1),
           let a = arguments.firstIndex(of: "--after"), arguments.indices.contains(a + 1), let seconds = TimeInterval(arguments[a + 1]) {
            let next = arguments[t + 1]
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
                client.changeSharedFolder(next)
                print("CHANGED")
                fflush(stdout)
            }
        }
        while true { RunLoop.main.run(until: Date().addingTimeInterval(1)) }
    }

    static func runIfAsked(arguments: [String] = CommandLine.arguments) {
        guard arguments.contains(flag) else { return }
        AVMLog.useTestLogFolder()
        guard let i = arguments.firstIndex(of: "--spice"), arguments.indices.contains(i + 1) else {
            print("Usage: Guest House \(flag) --spice <spice.sock>")
            exit(64)
        }
        let socket = URL(fileURLWithPath: arguments[i + 1])
        if let q = arguments.firstIndex(of: "--qmp"), arguments.indices.contains(q + 1) {
            qmpPath = arguments[q + 1]
        }
        let client = Client()
        guard client.connect(socket) else {
            print("FAILED: couldn't connect to \(socket.path)")
            exit(1)
        }
        let deadline = Date().addingTimeInterval(30)
        while client.input == nil && Date() < deadline {
            RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        }
        guard let input = client.input else {
            print("FAILED: the machine's keyboard channel didn't open in 30 seconds.")
            exit(1)
        }
        // CocoaSpice says the channel is available just BEFORE it connects
        // it (CSConnection.m: spiceInputAvailable, then
        // spice_channel_connect); keys sent at once were all dropped
        // (2026-10-26). A person never types that fast after a start.
        RunLoop.main.run(until: Date().addingTimeInterval(5))
        type(into: input)
        print("SENT")
        exit(0)
    }

    /// Sends one key, waits a little, as typing does.
    private static func send(_ input: CSInput, _ code: Int, down: Bool) {
        input.send(down ? .press : .release, code: Int32(code))
        RunLoop.main.run(until: Date().addingTimeInterval(0.15))
    }

    private static func say(_ step: String) {
        print("== \(step)")
        fflush(stdout)
        RunLoop.main.run(until: Date().addingTimeInterval(0.5))
    }

    private static func type(into input: CSInput) {
        // The order and the steps' names are the test script's
        // expectations (test-windows-install.sh, KEYBOARD CHECK).
        say("mark-start")
        let a = SPICECoordinator.scancode(forVirtualKey: kVK_ANSI_A) ?? 0x1E
        send(input, a, down: true); send(input, a, down: false)

        say("both-shifts")
        // Left Shift down, Right Shift down, Right Shift up, Left Shift up,
        // as flagsChanged reports them, decided by ModifierSides.
        let left = SPICECoordinator.scancode(forVirtualKey: kVK_Shift) ?? 0x2A
        let right = SPICECoordinator.scancode(forVirtualKey: kVK_RightShift) ?? 0x36
        let lBit: UInt = 0x2, rBit: UInt = 0x4
        for (vk, code, flags) in [(kVK_Shift, left, lBit), (kVK_RightShift, right, lBit | rBit),
                                  (kVK_RightShift, right, lBit), (kVK_Shift, left, UInt(0))] {
            let down = ModifierSides.isDown(virtualKey: vk, flags: flags) ?? false
            send(input, code, down: down)
        }

        say("fn-delete-and-pause")
        // The keyboard for Windows: Fn-Backspace is Delete; Pause.
        var translator = WindowsKeyTranslator()
        for (usage, down) in [(HIDKeyMap.fnUsage, true), (0x2A, true), (0x2A, false), (HIDKeyMap.fnUsage, false),
                              (HIDKeyMap.pauseUsage, true), (HIDKeyMap.pauseUsage, false)] {
            switch translator.translate(usage: usage, pressed: down) {
            case .key(let code, let isDown):
                // The app sends these through QMP (WindowsKeyboard.swift).
                qmp(#"{"execute":"input-send-event","arguments":{"events":[{"type":"key","data":{"down":\#(isDown),"key":{"type":"number","data":\#(HIDKeyMap.qemuNumber(forScancode: Int(code)))}}}]}}"#)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            case .pause(let isDown):
                pause(down: isDown)
                RunLoop.main.run(until: Date().addingTimeInterval(0.15))
            case nil: break
            }
        }

        say("windows-key-alone")
        // The control: a bare Windows-key tap opens Start, so the test can
        // tell its watcher sees Start at all. Then Escape closes it.
        let win = SPICECoordinator.scancode(forVirtualKey: kVK_Command) ?? 0x15B
        send(input, win, down: true); send(input, win, down: false)
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        say("escape")
        send(input, 0x01, down: true); send(input, 0x01, down: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1.5))

        say("way-back-to-the-mac")
        // Control-Command-Escape: Control and the Windows key reach the
        // guest, the Escape is the hotkey's. Then the unlock flush: a
        // Control tap while the Windows key is down, and releaseKeys.
        let control = SPICECoordinator.scancode(forVirtualKey: kVK_Control) ?? 0x1D
        send(input, control, down: true)
        send(input, win, down: true)
        input.send(.press, code: 0x1D)
        input.send(.release, code: 0x1D)
        input.releaseKeys()
        RunLoop.main.run(until: Date().addingTimeInterval(2.5))
        say("mark-end")
        send(input, a, down: true); send(input, a, down: false)
        RunLoop.main.run(until: Date().addingTimeInterval(1))
    }

    /// The SPICE connection, for the keyboard channel only.
    private final class Client: NSObject, CSConnectionDelegate {
        var connection: CSConnection?
        var input: CSInput?
        var wantsAudio = false
        var sharedFolder: String?

        func connect(_ socket: URL) -> Bool {
            if !CSMain.shared.running { guard CSMain.shared.spiceStart() else { return false } }
            let c = CSConnection(unixSocketFile: socket)
            c.delegate = self
            c.audioEnabled = wantsAudio
            connection = c
            return c.connect()
        }

        func spiceConnected(_ connection: CSConnection) {
            if let sharedFolder {
                connection.session.setSharedDirectory(sharedFolder, readOnly: false)
            }
        }
        /// As SPICECoordinator.sharedFolderChanged does it: on SPICE's thread.
        func changeSharedFolder(_ folder: String) {
            sharedFolder = folder
            guard let connection else { return }
            CSMain.shared.async { connection.session.setSharedDirectory(folder, readOnly: false) }
        }
        func spiceDisconnected(_ connection: CSConnection) {}
        func spiceInputAvailable(_ connection: CSConnection, input: CSInput) {
            DispatchQueue.main.async { self.input = input }
        }
        func spiceInputUnavailable(_ connection: CSConnection, input: CSInput) {}
        func spiceError(_ connection: CSConnection, code: CSConnectionError, message: String?) {
            print("SPICE error: \(message ?? "\(code.rawValue)")")
        }
        func spiceDisplayCreated(_ connection: CSConnection, display: CSDisplay) {}
        func spiceDisplayUpdated(_ connection: CSConnection, display: CSDisplay) {}
        func spiceDisplayDestroyed(_ connection: CSConnection, display: CSDisplay) {}
        func spiceAgentConnected(_ connection: CSConnection, supportingFeatures features: CSConnectionAgentFeature) {}
        func spiceAgentDisconnected(_ connection: CSConnection) {}
        func spiceForwardedPortOpened(_ connection: CSConnection, port: CSPort) {}
        func spiceForwardedPortClosed(_ connection: CSConnection, port: CSPort) {}
    }
}
