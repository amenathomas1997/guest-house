// UTMExport.swift
// Guest House — accessible virtual machines
//
// A copy of a Windows or Linux machine that UTM opens (2026-11-17, the
// user's request). No AppKit here, so the tests reach the settings; the
// panel and the spoken progress are in MachineArchivePanels.swift.
//
// THE PACKAGE: a folder named "<Name>.utm", as UTM 4 and 5 keep their own
// machines (configuration version 4, read from UTM's source at v5.0.0):
//   config.plist        the machine's settings, in UTM's words
//   Data/disk.qcow2     the disk, written by qemu-img convert: one whole
//                       file, with no restore points in it
//   Data/drive2.qcow2   the second drive, when there is one
//   Data/efi_vars.fd    the firmware's variable store, as qcow2, which is
//                       what UTM's own templates are
//   Data/tpmdata        the security chip's contents, for a machine UTM
//                       gives a TPM (see below)
//
// WHAT UTM IS TOLD, so the system inside meets the hardware it knows:
//   - the same disk connection (virtio or NVMe), network card (virtio),
//     sound card (Intel HDA, see soundArguments) and USB 3 controller;
//   - the same machine UUID and SMBIOS identity (the -smbios line goes in
//     UTM's additional arguments), which Windows activation looks at;
//   - a TPM for every Windows machine, and for any machine with Secure
//     Boot: UTM boots its Secure Boot firmware exactly when the machine has
//     a TPM, so that is also how Secure Boot is kept.
//
// THE TPM'S CONTENTS: Guest House's swtpm keeps them in a folder, UTM's in
// one file ("linear" storage). They are moved the way a migration moves
// them: one swtpm reads the folder and hands over its permanent state
// through the control channel, a second takes it and writes UTM's file.
// Only a copy of the folder is read. If that fails, the machine still goes,
// with a new, empty TPM, and the words at the end say what that means.
//
// WHAT IS LEFT BEHIND: restore points, a saved session, the install media,
// and every setting that is Guest House's own (the shared folder's path,
// Remote Desktop, the keyboard for Windows, sound choices). The original
// is not changed.
//
// PRIVACY: no password or key is read or written. The TPM's contents go as
// they are, to a folder the user chose.

import Foundation

enum UTMExport {
    nonisolated static let packageExtension = "utm"

    /// "Windows 11.utm", with characters a folder name can't have replaced.
    static func packageName(for configuration: VMConfiguration) -> String {
        let avm = MachineArchive.packageName(for: configuration)
        return String(avm.dropLast(MachineArchive.packageExtension.count)) + packageExtension
    }

    /// Why this machine can't go to UTM, in words to speak; nil when it can.
    /// Export's own refusals (running, saved, still installing) come first.
    static func problem(for configuration: VMConfiguration) -> String? {
        if configuration.guestOS == .macOS {
            return "Guest House can't export a macOS machine for UTM yet, only Windows and Linux machines."
        }
        return nil
    }

    /// UTM boots its Secure Boot firmware exactly when the machine has a TPM.
    static func usesTPM(_ configuration: VMConfiguration) -> Bool {
        configuration.guestOS == .windows || configuration.usesSecureBoot
    }

    /// One of UTM's own icon names.
    static func iconName(for guest: GuestOS) -> String {
        switch guest {
        case .windows: return "windows-11"
        case .ubuntu: return "ubuntu"
        case .debian, .kali: return "debian"
        case .fedora: return "fedora"
        case .almalinux: return "almalinux"
        case .rocky: return "rocky-linux"
        case .opensuse: return "opensuse"
        case .macOS: return "macos"
        }
    }

    /// A network address of the machine's own, from its id. Guest House runs
    /// every machine on QEMU's default address, each on a private network;
    /// UTM's shared network holds them all, so two exported machines with
    /// the same address would knock each other off it. Locally administered,
    /// one device.
    nonisolated static func macAddress(for id: UUID) -> String {
        let u = id.uuid
        let bytes: [UInt8] = [(u.0 & 0xFC) | 0x02, u.1, u.2, u.13, u.14, u.15]
        return bytes.map { String(format: "%02X", $0) }.joined(separator: ":")
    }

    /// The disk files, in the order UTM starts from them.
    struct Drive: Equatable, Sendable {
        let identifier: String
        let imageName: String
    }

    /// config.plist's contents.
    static func settings(for configuration: VMConfiguration, drives: [Drive], appVersion: String?) -> [String: Any] {
        let id = configuration.id.uuidString
        let interface = configuration.usesVirtioDisk ? "VirtIO" : "NVMe"
        let from = appVersion.map { "Guest House \($0)" } ?? "Guest House"
        return [
            "Backend": "QEMU",
            "ConfigurationVersion": 4,
            "Information": [
                "Name": MachineArchive.cleanName(configuration.name),
                "UUID": id,
                "IconCustom": false,
                "Icon": iconName(for: configuration.guestOS),
                "Notes": "Exported from \(from)."
            ] as [String: Any],
            "System": [
                "Architecture": "aarch64",
                "Target": "virt",
                "CPU": "default",
                "CPUFlagsAdd": [String](),
                "CPUFlagsRemove": [String](),
                "CPUCount": max(1, configuration.cpuCount),
                "ForceMulticore": false,
                "MemorySize": max(1, configuration.ramSizeGB) * 1024,
                "JITCacheSize": 0
            ] as [String: Any],
            "QEMU": [
                "DebugLog": false,
                "UEFIBoot": true,
                // Not in the machine Guest House ran, so not added here.
                "RNGDevice": false,
                "BalloonDevice": false,
                "TPMDevice": usesTPM(configuration),
                "Hypervisor": true,
                "TSO": false,
                // As VMManager's -rtc: Windows keeps the clock in local time.
                "RTCLocalTime": !configuration.guestOS.isLinux,
                "PS2Controller": false,
                // In quotes: UTM splits each of these at spaces unless it is
                // (measured 2026-11-17: "Could not open 'Virtual'"), and takes
                // the quotes off.
                "AdditionalArguments": ["-smbios", "\"type=1,manufacturer=AVM,product=AVM Virtual Machine,serial=\(id)\""] + soundArguments
            ] as [String: Any],
            "Input": [
                "UsbBusSupport": "3.0",
                "UsbSharing": true,
                "MaximumUsbShare": 3
            ] as [String: Any],
            "Sharing": [
                // spice-webdavd and the SPICE agent are already in the guest.
                "DirectoryShareMode": "WebDAV",
                "DirectoryShareReadOnly": false,
                "ClipboardSharing": true
            ] as [String: Any],
            "Display": [[
                "Hardware": "virtio-ramfb",
                "DynamicResolution": true,
                "UpscalingFilter": "Nearest",
                "DownscalingFilter": "Linear",
                "NativeResolution": false
            ] as [String: Any]],
            "Drive": drives.map { drive in
                [
                    "Identifier": drive.identifier,
                    "ImageName": drive.imageName,
                    "ImageType": "Disk",
                    "Interface": interface,
                    "InterfaceVersion": 1,
                    "ReadOnly": false
                ] as [String: Any]
            },
            "Network": [[
                "Mode": "Shared",
                "Hardware": "virtio-net-pci",
                "MacAddress": macAddress(for: configuration.id),
                "IsolateFromHost": false,
                "PortForward": [[String: Any]]()
            ] as [String: Any]],
            "Serial": [[String: Any]](),
            // None of UTM's own: see soundArguments.
            "Sound": [[String: Any]]()
        ]
    }

    /// The sound card, in UTM's additional arguments and not in its Sound
    /// list (2026-11-18: in UTM "JAWS sounds like Alvin and the Chipmunks").
    /// On a Mac UTM has QEMU play to the Mac itself, with QEMU's stock
    /// CoreAudio code, which asks the output device for 44,100 samples a
    /// second and takes it that it got them. A device that only runs at
    /// 48,000 (the user's USB headset: read from Core Audio, it can do
    /// nothing else) then plays everything about 9 percent fast and high.
    /// UTM's Sound list has no place for a rate, so the same card, an Intel
    /// HDA with an output codec as UTM makes it, is given here with 48,000,
    /// the rate Mac speakers, AirPods and USB headsets run at. UTM's engine
    /// recorded at the right speed to a file either way (measured in UTM
    /// 5.0.8), so the fault is only in that last step. Not heard by me: a
    /// test can't hear pitch. No spaces in these, so UTM leaves them whole.
    static let soundArguments = ["-audiodev", "coreaudio,id=ghaudio,out.frequency=48000",
                                 "-device", "intel-hda", "-device", "hda-output,audiodev=ghaudio"]

    static func settingsData(for configuration: VMConfiguration, drives: [Drive], appVersion: String?) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: settings(for: configuration, drives: drives, appVersion: appVersion),
                                           format: .xml, options: 0)
    }

    // MARK: - Writing the package

    /// Everything the copy needs, as plain values, so it runs off the main
    /// thread.
    struct Job: Sendable {
        struct Disk: Sendable {
            let source: URL
            let imageName: String
        }
        var disks: [Disk]
        /// nvram.fd: the firmware's variable store, raw, 64 MiB.
        var variableStore: URL
        /// tpm-state, when the machine gets a TPM in UTM and has one here.
        var tpmState: URL?
        var settings: Data
        var qemuImg: URL
        var swtpm: URL?
    }

    struct Outcome: Sendable {
        /// nil: no TPM asked for. false: asked for, and UTM will make a new one.
        var tpmCarried: Bool?
    }

    /// The space the copy can take: what the disks hold now, and the small files.
    nonisolated static func bytesNeeded(_ job: Job) -> UInt64 {
        job.disks.reduce(UInt64(4 * 1_048_576)) { $0 + allocated($1.source) }
    }

    nonisolated static func allocated(_ url: URL) -> UInt64 {
        let values = try? url.resourceValues(forKeys: [.totalFileAllocatedSizeKey, .fileSizeKey])
        return UInt64(values?.totalFileAllocatedSize ?? values?.fileSize ?? 0)
    }

    /// Writes the package at `packageURL`, under a hidden name until it is
    /// whole. One already there (the save panel asked) goes to the Trash
    /// only then. `progress` gets 0 to 1.
    nonisolated static func writePackage(_ job: Job, to packageURL: URL, progress: @escaping @Sendable (Double) -> Void) throws -> Outcome {
        let fm = FileManager.default
        let parent = packageURL.deletingLastPathComponent()
        let partialPrefix = ".\(packageURL.lastPathComponent)-partial-"
        for leftover in (try? fm.contentsOfDirectory(atPath: parent.path)) ?? [] where leftover.hasPrefix(partialPrefix) {
            try? fm.removeItem(at: parent.appendingPathComponent(leftover))
        }
        let partial = parent.appendingPathComponent(partialPrefix + UUID().uuidString, isDirectory: true)
        let data = partial.appendingPathComponent("Data", isDirectory: true)
        try fm.createDirectory(at: data, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        do {
            var outcome = Outcome()
            let total = max(1, job.disks.reduce(UInt64(0)) { $0 + allocated($1.source) })
            var before: UInt64 = 0
            for disk in job.disks {
                let size = allocated(disk.source)
                let start = Double(before) / Double(total), share = Double(size) / Double(total)
                try convert(job.qemuImg, from: disk.source, format: "qcow2", to: data.appendingPathComponent(disk.imageName)) {
                    progress(start + share * $0)
                }
                before += size
            }
            try convert(job.qemuImg, from: job.variableStore, format: "raw", to: data.appendingPathComponent("efi_vars.fd")) { _ in }
            if let state = job.tpmState {
                if let swtpm = job.swtpm, fm.fileExists(atPath: state.appendingPathComponent(tpmPermanentFile).path) {
                    do {
                        try carryTPM(swtpm, from: state, to: data.appendingPathComponent("tpmdata"))
                        outcome.tpmCarried = true
                    } catch {
                        AVMLog.write("Guest House: UTM export — the TPM's contents didn't go: \(error.localizedDescription)")
                        try? fm.removeItem(at: data.appendingPathComponent("tpmdata"))
                        outcome.tpmCarried = false
                    }
                } else {
                    outcome.tpmCarried = false
                }
            }
            try job.settings.write(to: partial.appendingPathComponent("config.plist"), options: .atomic)
            // UTM runs as the same user, from its own sandbox, once the user
            // has opened the package: readable folders, as UTM makes its own.
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: data.path)
            try fm.setAttributes([.posixPermissions: 0o755], ofItemAtPath: partial.path)
            if fm.fileExists(atPath: packageURL.path) {
                do {
                    try fm.trashItem(at: packageURL, resultingItemURL: nil)
                } catch {
                    throw MachineArchiveError("The earlier \(packageURL.lastPathComponent) couldn't be moved to the Trash, so it was left as it is. Reason: \(error.localizedDescription)")
                }
            }
            try fm.moveItem(at: partial, to: packageURL)
            return outcome
        } catch {
            try? fm.removeItem(at: partial)
            throw error
        }
    }

    /// qemu-img convert, to one whole qcow2. -p prints "(12.34/100%)".
    nonisolated private static func convert(_ tool: URL, from source: URL, format: String, to destination: URL,
                                            progress: @escaping @Sendable (Double) -> Void) throws {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["convert", "-p", "-f", format, "-O", "qcow2", source.path, destination.path]
        let output = Pipe(), errors = Pipe()
        process.standardOutput = output
        process.standardError = errors
        output.fileHandleForReading.readabilityHandler = { handle in
            let text = String(decoding: handle.availableData, as: UTF8.self)
            guard let open = text.range(of: "(", options: .backwards),
                  let slash = text.range(of: "/100%", range: open.upperBound..<text.endIndex),
                  let percent = Double(text[open.upperBound..<slash.lowerBound].trimmingCharacters(in: .whitespaces)) else { return }
            progress(min(1, max(0, percent / 100)))
        }
        try process.run()
        let said = errors.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        output.fileHandleForReading.readabilityHandler = nil
        guard process.terminationStatus == 0 else {
            let detail = String(decoding: said, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
            throw MachineArchiveError("\(source.lastPathComponent) couldn't be copied. qemu-img said: \(detail.isEmpty ? "exit \(process.terminationStatus)" : detail)")
        }
    }

    // MARK: - The TPM's contents

    nonisolated static let tpmPermanentFile = "tpm2-00.permall"

    /// swtpm's control channel (swtpm's tpm_ioctl.h): commands and the
    /// permanent state's number.
    private enum Control {
        nonisolated static let initialize: UInt32 = 2
        nonisolated static let getStateBlob: UInt32 = 12
        nonisolated static let setStateBlob: UInt32 = 13
        nonisolated static let permanent: UInt32 = 1
    }

    /// From Guest House's folder of TPM state to UTM's one file. Works on a
    /// copy of the folder, in a short temporary path (a socket's path has a
    /// 104-character limit, and swtpm's options split on commas).
    nonisolated static func carryTPM(_ swtpm: URL, from stateFolder: URL, to destination: URL) throws {
        let fm = FileManager.default
        let work = URL(fileURLWithPath: "/tmp", isDirectory: true).appendingPathComponent("gh-utm-\(UUID().uuidString.prefix(8))", isDirectory: true)
        let source = work.appendingPathComponent("in", isDirectory: true)
        try fm.createDirectory(at: source, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try fm.setAttributes([.posixPermissions: 0o700], ofItemAtPath: work.path)
        defer { try? fm.removeItem(at: work) }
        try fm.copyItem(at: stateFolder.appendingPathComponent(tpmPermanentFile), to: source.appendingPathComponent(tpmPermanentFile))

        // Out of the folder.
        let reader = try startSwtpm(swtpm, state: "dir=\(source.path)", socket: work.appendingPathComponent("in.sock"))
        defer { reader.process.terminate() }
        var blob = try stateBlob(reader.descriptor)
        if blob == nil {
            // swtpm 0.9 hands it over only once the TPM is initialized, which
            // loads the state and changes nothing in it.
            try command(reader.descriptor, Control.initialize, body: be(0), what: "starting the TPM")
            blob = try stateBlob(reader.descriptor)
        }
        close(reader.descriptor)
        guard let blob, !blob.isEmpty else { throw MachineArchiveError("swtpm gave no TPM state.") }

        // Into UTM's file, which swtpm wants to exist.
        let file = work.appendingPathComponent("tpmdata")
        fm.createFile(atPath: file.path, contents: nil)
        let writer = try startSwtpm(swtpm, state: "backend-uri=file://\(file.path)", socket: work.appendingPathComponent("out.sock"))
        defer { writer.process.terminate() }
        try command(writer.descriptor, Control.setStateBlob, body: be(0) + be(Control.permanent) + be(UInt32(blob.count)) + blob, what: "writing the TPM state")
        // Read back by the TPM itself: a state it can't load is refused here,
        // not at the machine's first start in UTM.
        try command(writer.descriptor, Control.initialize, body: be(0), what: "loading the TPM state back")
        close(writer.descriptor)
        writer.process.terminate()
        writer.process.waitUntilExit()
        guard allocated(file) > 0 || ((try? fm.attributesOfItem(atPath: file.path))?[.size] as? NSNumber)?.intValue ?? 0 > 0 else {
            throw MachineArchiveError("swtpm wrote an empty TPM file.")
        }
        try? fm.removeItem(at: destination)
        try fm.copyItem(at: file, to: destination)
        try fm.setAttributes([.posixPermissions: 0o644], ofItemAtPath: destination.path)
    }

    nonisolated private static func be(_ value: UInt32) -> Data {
        withUnsafeBytes(of: value.bigEndian) { Data($0) }
    }

    nonisolated private static func startSwtpm(_ tool: URL, state: String, socket: URL) throws -> (process: Process, descriptor: Int32) {
        let process = Process()
        process.executableURL = tool
        process.arguments = ["socket", "--tpmstate", state, "--ctrl", "type=unixio,path=\(socket.path)", "--tpm2", "--log", "level=0"]
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        for _ in 0..<100 {
            if FileManager.default.fileExists(atPath: socket.path), let descriptor = connect(to: socket.path) {
                return (process, descriptor)
            }
            guard process.isRunning else { break }
            usleep(50_000)
        }
        process.terminate()
        throw MachineArchiveError("swtpm didn't start.")
    }

    nonisolated private static func connect(to path: String) -> Int32? {
        let descriptor = socket(AF_UNIX, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return nil }
        var address = sockaddr_un()
        address.sun_family = sa_family_t(AF_UNIX)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard path.utf8.count < capacity else { close(descriptor); return nil }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: Array(path.utf8))
        }
        var timeout = timeval(tv_sec: 20, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        let result = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { Darwin.connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) }
        }
        guard result == 0 else { close(descriptor); return nil }
        return descriptor
    }

    nonisolated private static func send(_ descriptor: Int32, _ data: Data) throws {
        var sent = 0
        while sent < data.count {
            let n = data.withUnsafeBytes { write(descriptor, $0.baseAddress! + sent, data.count - sent) }
            guard n > 0 else { throw MachineArchiveError("swtpm stopped answering.") }
            sent += n
        }
    }

    nonisolated private static func receive(_ descriptor: Int32, _ count: Int) throws -> Data {
        var data = Data(count: count)
        var got = 0
        while got < count {
            let n = data.withUnsafeMutableBytes { read(descriptor, $0.baseAddress! + got, count - got) }
            guard n > 0 else { throw MachineArchiveError("swtpm stopped answering.") }
            got += n
        }
        return data
    }

    nonisolated private static func number(_ data: Data, at offset: Int) -> UInt32 {
        data.subdata(in: offset..<offset + 4).reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
    }

    /// A command whose answer is one result code.
    nonisolated private static func command(_ descriptor: Int32, _ code: UInt32, body: Data, what: String) throws {
        try send(descriptor, be(code) + body)
        let result = number(try receive(descriptor, 4), at: 0)
        guard result == 0 else { throw MachineArchiveError("swtpm refused \(what) (code \(result)).") }
    }

    /// The permanent state, whole; nil when swtpm refuses for now.
    nonisolated private static func stateBlob(_ descriptor: Int32) throws -> Data? {
        // state flags, which state, offset
        try send(descriptor, be(Control.getStateBlob) + be(0) + be(Control.permanent) + be(0))
        // The result alone when it's a refusal (measured 2026-11-17: code 10
        // before the TPM is initialized); then state flags, total length and
        // this part's length, and the state itself.
        guard number(try receive(descriptor, 4), at: 0) == 0 else { return nil }
        let total = Int(number(try receive(descriptor, 12), at: 4))
        guard total > 0, total < 16 * 1_048_576 else { throw MachineArchiveError("swtpm gave a TPM state of \(total) bytes.") }
        return try receive(descriptor, total)
    }
}
