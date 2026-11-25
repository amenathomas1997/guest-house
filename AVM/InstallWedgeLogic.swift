// InstallWedgeLogic.swift
// Guest House — accessible virtual machines
//
// The install watchdog's judgement, on its own (2026-11-24): the firmware
// hang at a Windows Setup restart shows as a screen that doesn't change, a
// busy processor and a disk nobody writes, for minutes on end. A guest
// that is busy with its disk is repairing or updating and must be left
// alone: a reset then is how a Windows gets broken into recovery.
//
// It was inline in VMManager's watchdog, which stood down when Setup's
// marker appeared. Allison found (her repository, 2026-11-15) that on the
// secure firmware the same hang struck at a Setup restart after the marker,
// and nothing spoke for half an hour. Guest House's watch after the marker
// (watchForFirstSignIn) only waited for the first sign-in and warned after
// an hour, with advice that can't work on a hung machine. So the same
// judgement now runs in both, from here.

import Foundation

nonisolated struct InstallWedgeSignature {
    /// Samples 20 seconds apart: 9 is about 3 minutes.
    static let requiredSamples = 9
    static let busyPercent = 90.0

    enum Reading: Equatable {
        /// Frozen, busy and quiet disk: this many samples in a row.
        case wedgeLike(Int)
        /// Frozen and busy, but the disk moved: repair or update; wait.
        case busyWithDisk
        /// Nothing like a wedge; true when it ended a run of wedge samples.
        case normal(brokeStreak: Bool)
        /// A sample was missing, so nothing can be judged.
        case unjudged
    }

    private var previousFrame: Data?
    private var previousDiskTime: Date?
    private var previousDiskSize: UInt64?
    private(set) var streak = 0

    var isWedged: Bool { streak >= Self.requiredSamples }

    /// A paused machine's still screen and quiet disk are not a wedge.
    mutating func reset() {
        streak = 0
        previousFrame = nil
    }

    mutating func sample(frame: Data?, cpuPercent: Double?, diskTime: Date?, diskSize: UInt64?) -> Reading {
        guard let frame, let cpuPercent, let diskTime, let diskSize else {
            // Fail toward silence: an unjudgeable sample never counts.
            streak = 0
            previousFrame = frame ?? previousFrame
            if let diskTime, let diskSize {
                previousDiskTime = diskTime
                previousDiskSize = diskSize
            }
            return .unjudged
        }
        let frozen = previousFrame != nil && frame == previousFrame
        previousFrame = frame
        // The first sample can never judge the disk flat.
        let diskFlat = previousDiskTime != nil && diskTime == previousDiskTime && diskSize == previousDiskSize
        let diskMoved = previousDiskTime != nil && !diskFlat
        previousDiskTime = diskTime
        previousDiskSize = diskSize
        let busy = cpuPercent >= Self.busyPercent
        if frozen && busy && diskFlat {
            streak += 1
            return .wedgeLike(streak)
        }
        let broke = streak > 0
        streak = 0
        return frozen && busy && diskMoved ? .busyWithDisk : .normal(brokeStreak: broke)
    }

    /// What to say, before or after Setup's marker. Force Stop, because a
    /// hung firmware can't answer the ordinary request to shut down
    /// (Allison's finding, 2026-11-15).
    static func guidance(afterMarker: Bool, machine: String) -> String {
        afterMarker
            ? "Windows Setup in \(machine) seems to be stuck while it restarts: the screen hasn't changed for about 3 minutes and the machine is busy without using its disk. Next: choose Force Stop, then start \(machine) again. Setup carries on from where it was."
            : "The Windows installation in \(machine) seems to be stuck: the screen hasn't changed for about 3 minutes and the machine is busy without using its disk. Next: choose Force Stop, then start \(machine) again. Setup will start over from the beginning."
    }
}
