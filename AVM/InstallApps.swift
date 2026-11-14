// InstallApps.swift
// Guest House — accessible virtual machines
//
// Install Apps (2026-11-03, the user's request): tick apps in a list, and they
// install in a running Windows machine one at a time with no questions, through
// the guest agent, so nobody has to work through each installer with a screen
// reader. What's offered and how each runs is in WindowsAppList.swift.
//
// Each installer comes from its maker to Windows. The Mac only reads winget's
// manifests. It goes on with the window closed, and says each app as it finishes.
//
// Linux machines too (2026-11-14): a list of their own (LinuxApp), installed
// by the system's package manager from its own software sources. Only the
// apps that machine's sources have are offered.

import Combine
import SwiftUI

@MainActor
final class InstallApps: ObservableObject {
    static let shared = InstallApps()
    /// One queue at a time: two installers at once make each other fail.
    @Published private(set) var current: String?
    @Published private(set) var remaining = 0
    private var stopAfterThis = false

    /// The apps from `WindowsApp.all` already in the machine, or nil if it
    /// didn't answer.
    func installed(in machine: VMManager) async -> Set<WindowsApp>? {
        guard let names = await listedNames(in: machine) else { return nil }
        return Set(WindowsApp.all.filter { $0.isListed(in: names) })
    }

    /// What this machine can be offered, and what it has already: every
    /// Windows app in Windows; in Linux, the ones its software sources have.
    /// `present` is nil when the machine didn't answer.
    func offered(in machine: VMManager) async -> (apps: [OfferedApp], present: Set<OfferedApp>?) {
        if machine.runningGuestOS == .windows {
            let apps = WindowsApp.all.map { OfferedApp(source: .windows($0)) }
            guard let has = await installed(in: machine) else { return (apps, nil) }
            return (apps, Set(has.map { OfferedApp(source: .windows($0)) }))
        }
        guard let output = try? await machine.agentRun("/bin/sh", ["-c", LinuxApp.stateScript], limit: .seconds(180)),
              let state = LinuxApp.state(from: output) else {
            return (LinuxApp.all.map { OfferedApp(source: .linux($0)) }, nil)
        }
        return (state.offered.map { OfferedApp(source: .linux($0)) }, Set(state.present.map { OfferedApp(source: .linux($0)) }))
    }

    func stop() { stopAfterThis = true }

    /// Says how each went, and returns the apps that are in Windows after.
    @discardableResult
    func install(_ apps: [WindowsApp], in machine: VMManager) async -> [WindowsApp] {
        let done = await install(apps.map { OfferedApp(source: .windows($0)) }, in: machine)
        return apps.filter { done.contains(OfferedApp(source: .windows($0))) }
    }

    /// The same, for a Windows or a Linux machine's apps.
    @discardableResult
    func install(_ apps: [OfferedApp], in machine: VMManager) async -> [OfferedApp] {
        guard current == nil else { return [] }
        let name = machine.machineName
        stopAfterThis = false
        remaining = apps.count
        defer { current = nil; remaining = 0 }
        Announcer.shared.announce("Installing \(apps.count) \(apps.count == 1 ? "app" : "apps") in \(name). You can keep working while they install.", tone: .info)
        var done: [OfferedApp] = []
        var failed: [String] = []
        var restart = false
        for app in apps {
            if stopAfterThis || machine.state != .running { break }
            current = app.name
            remaining = apps.count - done.count - failed.count
            AVMLog.write("Guest House: Install Apps — \(app.id) in \(name)")
            switch await install(app, in: machine) {
            case .installed(let restartNeeded):
                restart = restart || restartNeeded
                done.append(app)
                Announcer.shared.announce("\(app.name) is installed.", tone: .success, routine: true)
            case .failed, .checksum, .download, .noAnswer:
                failed.append(app.name)
            }
        }
        var words = done.isEmpty ? "No apps were installed in \(name)." : "Finished installing in \(name): \(done.map(\.name).joined(separator: ", "))."
        if !failed.isEmpty { words += " These didn't install: \(failed.joined(separator: ", ")). Next: try them again, or get them from their makers. Guest House's log says why." }
        if restart { words += " \(machine.runningGuestOS == .windows ? "Windows" : name) needs a restart to finish." }
        Announcer.shared.announce(words, tone: failed.isEmpty ? .success : .failure)
        return done
    }

    private func install(_ app: OfferedApp, in machine: VMManager) async -> WindowsAppManifest.Outcome {
        switch app.source {
        case .windows(let windows): return await install(windows, in: machine)
        case .linux(let linux): return await install(linux, in: machine)
        }
    }

    /// Its own word is checked in the script: the package is installed after.
    private func install(_ app: LinuxApp, in machine: VMManager) async -> WindowsAppManifest.Outcome {
        guard let output = try? await machine.agentRun("/bin/sh", ["-c", app.installScript], limit: .seconds(30 * 60)) else {
            AVMLog.write("Guest House: Install Apps — \(app.name): the machine didn't answer")
            return .noAnswer
        }
        let outcome = WindowsAppManifest.outcome(of: output)
        AVMLog.write("Guest House: Install Apps — \(app.name) by the machine's package manager: \(outcome)\(outcome == .installed(restartNeeded: false) ? "" : " — " + output.suffix(300).replacingOccurrences(of: "\n", with: " | "))")
        return outcome
    }

    private func install(_ app: WindowsApp, in machine: VMManager) async -> WindowsAppManifest.Outcome {
        guard let installer = await Self.latestInstaller(app) else {
            AVMLog.write("Guest House: Install Apps — no installer for \(app.id) in its manifest")
            return .download
        }
        let outcome: WindowsAppManifest.Outcome
        do {
            // LibreOffice and the like are big, on a slow connection.
            let output = try await machine.agentRun("powershell.exe", ["-NoProfile", "-EncodedCommand", WindowsAppManifest.encoded(WindowsAppManifest.script(installer))], limit: .seconds(30 * 60))
            outcome = WindowsAppManifest.outcome(of: output)
        } catch {
            AVMLog.write("Guest House: Install Apps — \(app.id): \(error.localizedDescription)")
            return .noAnswer
        }
        AVMLog.write("Guest House: Install Apps — \(app.id) from \(installer.url.host ?? "?"), \(installer.type): \(outcome)")
        guard case .installed = outcome else { return outcome }
        // Its own word isn't enough: an installer can end at 0 having done nothing.
        if let names = await listedNames(in: machine), !app.isListed(in: names) {
            AVMLog.write("Guest House: Install Apps — \(app.id) ended well, but Windows doesn't list it")
            return .failed(code: nil)
        }
        return outcome
    }

    private func listedNames(in machine: VMManager) async -> [String]? {
        guard let output = try? await machine.agentRun("powershell.exe", ["-NoProfile", "-EncodedCommand", WindowsAppManifest.encoded(WindowsAppManifest.installedListScript)], limit: .seconds(60)) else { return nil }
        return output.components(separatedBy: .newlines).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    /// The newest release's installer, from winget's public manifests.
    nonisolated static func latestInstaller(_ app: WindowsApp) async -> WindowsAppInstaller? {
        guard let version = try? await ScreenReaderInstallers.newestFolder(app.manifestFolder),
              let yaml = try? await ScreenReaderInstallers.text(ScreenReaderInstallers.raw + "\(app.manifestFolder)/\(version)/\(app.id).installer.yaml") else { return nil }
        return WindowsAppManifest.installer(yaml: yaml)
    }
}

/// The menu's command and its window, on the machine list.
struct InstallAppsCommand: ViewModifier {
    @State private var window: MachineDevicesRequest?

    func body(content: Content) -> some View {
        content
            .onReceive(NotificationCenter.default.publisher(for: .avmInstallApps)) { _ in
                guard let manager = VMManager.shared, manager.state == .running else {
                    Announcer.shared.announce("Install Apps works in a running Windows or Linux machine. Next: start it, then try again.", tone: .info)
                    return
                }
                guard manager.runningGuestOS == .windows || manager.runningGuestOS?.isLinux == true else {
                    Announcer.shared.announce("Install Apps works in Windows and Linux machines. \(manager.machineName) isn't one.", tone: .info)
                    return
                }
                window = MachineDevicesRequest(machine: manager)
            }
            .sheet(item: $window) { request in
                InstallAppsView(machine: request.machine)
            }
    }
}

struct InstallAppsView: View {
    let machine: VMManager

    @Environment(\.dismiss) private var dismiss
    @ObservedObject private var installer = InstallApps.shared
    @State private var chosen = Set<OfferedApp>()
    @State private var offered: [OfferedApp] = []
    @State private var present: Set<OfferedApp>?
    @State private var looked = false
    private var windows: Bool { machine.runningGuestOS == .windows }
    private var system: String { machine.runningGuestOS?.displayName ?? machine.machineName }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Install Apps in \(machine.machineName)")
                .font(.title2)
                .accessibilityAddTraits(.isHeader)
                .accessibilityHeading(.h1)
            Text(windows
                 ? "Choose apps, and Guest House installs them in Windows one at a time, with no questions. Each comes from its maker, using the links and checksums in Microsoft's public package list. Windows needs to be connected to the internet."
                 : "Choose apps, and Guest House installs them in \(system) one at a time, with no questions. Each comes from \(system)'s own software sources, through its own package manager. Only the apps those sources have are listed. \(system) needs to be connected to the internet.")
                .fixedSize(horizontal: false, vertical: true)
            if let current = installer.current {
                Text("Installing \(current). \(installer.remaining) left, this one included.")
            } else if !looked {
                Text("Looking at what's already in \(windows ? "Windows" : system).")
            } else if present == nil {
                Text("Guest House couldn't see what's in \(windows ? "Windows" : system), so it can't tell which of these are already there.")
                    .fixedSize(horizontal: false, vertical: true)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 8) {
                    ForEach(OfferedApp.grouped(offered), id: \.group) { section in
                        Text(section.group)
                            .font(.headline)
                            .padding(.top, 6)
                            .accessibilityAddTraits(.isHeader)
                            .accessibilityHeading(.h2)
                        ForEach(section.apps) { app in
                            let already = present?.contains(app) == true
                            Toggle(already ? "\(app.name), \(app.what), already installed" : "\(app.name), \(app.what)", isOn: Binding(
                                get: { chosen.contains(app) },
                                set: { if $0 { chosen.insert(app) } else { chosen.remove(app) } }))
                                .disabled(already || installer.current != nil)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .frame(minHeight: 280)
            HStack {
                if installer.current != nil {
                    Button("Stop After This App") { installer.stop() }
                } else {
                    Button(chosen.isEmpty ? "Install" : "Install \(chosen.count) \(chosen.count == 1 ? "App" : "Apps")") {
                        let apps = offered.filter { chosen.contains($0) }
                        chosen = []
                        Task {
                            await installer.install(apps, in: machine)
                            present = await installer.offered(in: machine).present
                        }
                    }
                    .disabled(chosen.isEmpty)
                    .keyboardShortcut(.defaultAction)
                }
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityHint("Closes this window. Apps being installed carry on.")
            }
        }
        .padding(24)
        .frame(minWidth: 520)
        .task {
            // The whole list at once for Windows; Linux's once it has said
            // which of them its sources have.
            if windows { offered = WindowsApp.all.map { OfferedApp(source: .windows($0)) } }
            let state = await installer.offered(in: machine)
            offered = state.apps
            present = state.present
            looked = true
        }
    }
}
