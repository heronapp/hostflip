import Foundation
import HostflipCore

/// The schedule arithmetic behind automatic Remote Profile refreshes (#71, ADR-0012), kept
/// pure — entries and the current date in; due profiles and the next wake date out — so every
/// boundary (clock rollback, interval changes, failure spacing) is testable without timers.
enum RemoteRefreshSchedule {
    struct Entry: Equatable {
        var profileID: Profile.ID
        var interval: RemoteHeader.RefreshInterval
        /// The manifest's last successful refresh time; nil when the runtime state was never
        /// recorded or was stripped by an older app version — such a profile is due at once.
        var lastSuccessAt: Date?
        /// When a refresh for this profile last actually started — manual and scheduled
        /// alike, recorded in-memory by the store — so a failing source retries one interval
        /// after its newest attempt instead of on every evaluation, and a manual failure is
        /// not immediately followed by a scheduled retry.
        var lastAttemptAt: Date? = nil
    }

    struct Verdict: Equatable {
        var due: [Profile.ID]
        var nextWake: Date?
    }

    /// A profile is due one interval after the later of its last success and its last
    /// attempt; with no usable basis it is due at once. A timestamp ahead of `now` is a
    /// rolled-back clock's leftover and is discarded rather than clamped: clamping against a
    /// moving `now` would slide the due date forward on every evaluation (the profile would
    /// not fire until the wall clock caught up), while discarding makes the profile due at
    /// once and the resulting refresh writes a sane timestamp. Manual profiles are never
    /// scheduled.
    static func evaluate(entries: [Entry], now: Date) -> Verdict {
        var due: [Profile.ID] = []
        var nextWake: Date?
        for entry in entries {
            guard let period = entry.interval.period else { continue }
            let bases = [entry.lastSuccessAt, entry.lastAttemptAt]
                .compactMap { $0 }
                .filter { $0 <= now }
            guard let basis = bases.max() else {
                due.append(entry.profileID)
                continue
            }
            let dueAt = basis.addingTimeInterval(period)
            if dueAt <= now {
                due.append(entry.profileID)
            } else {
                nextWake = min(nextWake ?? dueAt, dueAt)
            }
        }
        return Verdict(due: due, nextWake: nextWake)
    }
}

extension RemoteHeader.RefreshInterval {
    /// The interval's length as a schedule period; nil for manual, which is never scheduled.
    var period: TimeInterval? {
        switch self {
        case .oneHour: 3600
        case .sixHours: 6 * 3600
        case .twentyFourHours: 24 * 3600
        case .manual: nil
        }
    }
}

/// Drives the schedule against real time (#71): one pending sleep until the earliest due
/// date, re-evaluated on every `resync()` — the app pokes it whenever the model changes, so
/// interval edits, new Remote Profiles, and refresh results all take effect immediately. The
/// first `resync()` after launch doubles as the startup catch-up: profiles whose interval
/// already elapsed are due right away and get one fetch each. Refreshes for due profiles run
/// concurrently; while they run, resyncs coalesce into the single re-evaluation that always
/// follows the firing. The scheduler itself is stateless between evaluations: attempt times
/// live in the store, which records one for every refresh it actually starts — the invariant
/// evaluation relies on to move past a due profile whose refresh failed.
@MainActor
final class RemoteRefreshScheduler {
    private let entries: @MainActor () -> [RemoteRefreshSchedule.Entry]
    private let refresh: @Sendable (Profile.ID) async -> Void
    private let now: @Sendable () -> Date
    private let sleep: @Sendable (TimeInterval) async throws -> Void

    /// The pending wait for the next due date; cancelled and rebuilt by every resync.
    private(set) var sleepTask: Task<Void, Never>?
    /// The in-flight refreshes of due profiles; tests await its completion before asserting.
    private(set) var fireTask: Task<Void, Never>?
    private var isFiring = false

    init(
        entries: @escaping @MainActor () -> [RemoteRefreshSchedule.Entry],
        refresh: @escaping @Sendable (Profile.ID) async -> Void,
        now: @escaping @Sendable () -> Date = Date.init,
        sleep: @escaping @Sendable (TimeInterval) async throws -> Void = {
            try await Task.sleep(for: .seconds($0))
        }
    ) {
        self.entries = entries
        self.refresh = refresh
        self.now = now
        self.sleep = sleep
    }

    /// Re-evaluates the schedule now: fires every due profile, or arms one sleep until the
    /// earliest upcoming due date. Safe to call at any rate — a resync while refreshes are
    /// in flight defers to the re-evaluation that follows them. Tasks capture the scheduler
    /// weakly, so a pending sleep never keeps a released scheduler alive.
    func resync() {
        guard !isFiring else { return }
        sleepTask?.cancel()
        sleepTask = nil
        let verdict = RemoteRefreshSchedule.evaluate(entries: entries(), now: now())
        if !verdict.due.isEmpty {
            isFiring = true
            fireTask = Task { [refresh, weak self] in
                await withTaskGroup(of: Void.self) { group in
                    for profileID in verdict.due {
                        group.addTask { await refresh(profileID) }
                    }
                }
                guard let self else { return }
                self.isFiring = false
                self.resync()
            }
        } else if let wake = verdict.nextWake {
            let delay = max(0, wake.timeIntervalSince(now()))
            sleepTask = Task { [sleep, weak self] in
                guard (try? await sleep(delay)) != nil, !Task.isCancelled else { return }
                self?.resync()
            }
        }
    }
}
