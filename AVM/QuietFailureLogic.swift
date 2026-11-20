// QuietFailureLogic.swift
// Guest House — accessible virtual machines
//
// Something that keeps failing is said, once (2026-11-19, the user's
// request after 2026-11-18). Windows apps had been missing from Command-Tab
// for days: the helper's install failed at every start, and later its list
// could not be updated, and each time Guest House wrote a line in its log,
// tried again and said nothing. Nobody reads the log until something is
// already known to be wrong.
//
// This counts such failures by machine and by kind. The first one or two
// are let pass, as a Windows that is still starting fails that way too; one
// that goes on is spoken of once in a run of Guest House, with what it
// means for the person and where the details can be sent from (Help >
// Report a Problem). When it clears, that is said too, so the person isn't
// left wondering. Counting only; who speaks is the caller's business, which
// keeps this testable.

import Foundation

struct QuietFailureTally {

    enum Kind: String, CaseIterable {
        /// The Windows apps helper could not be installed or updated.
        case helperInstall
        /// The helper runs but cannot replace its list of open apps.
        case listStuck
    }

    struct Key: Hashable {
        let machine: UUID
        let kind: Kind
    }

    private struct Run {
        var count: Int
        var since: Date
    }

    private var runs: [Key: Run] = [:]
    private var said: Set<Key> = []

    /// How long a failure goes on before it is worth a person's attention.
    /// An install is tried every ten minutes, so the second failure is
    /// already ten minutes of nothing in Command-Tab. A list that stands
    /// still is looked at once a minute, and one bad minute is common while
    /// Windows is busy.
    static func isWorthSaying(_ kind: Kind, count: Int, lasting seconds: TimeInterval) -> Bool {
        switch kind {
        case .helperInstall: return count >= 2
        case .listStuck: return count >= 3 && seconds >= 150
        }
    }

    /// One more failure. True when this is the one to speak of: it has gone
    /// on long enough, and hasn't been spoken of since it last worked.
    mutating func failed(_ kind: Kind, machine: UUID, at now: Date = Date()) -> Bool {
        let key = Key(machine: machine, kind: kind)
        var run = runs[key] ?? Run(count: 0, since: now)
        run.count += 1
        runs[key] = run
        guard !said.contains(key),
              Self.isWorthSaying(kind, count: run.count, lasting: now.timeIntervalSince(run.since)) else { return false }
        said.insert(key)
        return true
    }

    /// It worked. True when a failure had been spoken of, so that its end
    /// is worth saying as well.
    mutating func worked(_ kind: Kind, machine: UUID) -> Bool {
        let key = Key(machine: machine, kind: kind)
        runs[key] = nil
        return said.remove(key) != nil
    }

    /// A machine that stopped: its counts start again at its next start.
    /// What was said stays said only while it runs.
    mutating func forget(machine: UUID) {
        for kind in Kind.allCases {
            let key = Key(machine: machine, kind: kind)
            runs[key] = nil
            said.remove(key)
        }
    }

    static func message(_ kind: Kind, machineName: String) -> String {
        switch kind {
        case .helperInstall:
            return "\(machineName): its Windows apps can't be shown in Command-Tab or the Dock. Guest House couldn't set up its helper in Windows, and keeps trying. If this goes on, choose Help, then Report a Problem, to send the details."
        case .listStuck:
            return "\(machineName): its Windows apps are showing late in Command-Tab and the Dock. The helper in Windows can't update its list of open apps. Restarting Windows may clear it. If not, choose Help, then Report a Problem, to send the details."
        }
    }

    static func recoveredMessage(_ kind: Kind, machineName: String) -> String {
        switch kind {
        case .helperInstall: return "\(machineName): its Windows apps can be shown in Command-Tab and the Dock again."
        case .listStuck: return "\(machineName): its Windows apps are keeping up in Command-Tab and the Dock again."
        }
    }
}
