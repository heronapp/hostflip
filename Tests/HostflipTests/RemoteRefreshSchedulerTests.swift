import Foundation
import HostflipCore
import XCTest
@testable import Hostflip

/// The pure schedule arithmetic (#71): due/next-wake decisions across the boundary cases —
/// clock rollback, failure spacing via attempt times, and manual exclusion.
final class RemoteRefreshScheduleTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_755_000_000)

    private func entry(
        _ id: String,
        interval: RemoteHeader.RefreshInterval = .oneHour,
        lastSuccessAt: Date? = nil,
        lastAttemptAt: Date? = nil
    ) -> RemoteRefreshSchedule.Entry {
        .init(
            profileID: .init(id),
            interval: interval,
            lastSuccessAt: lastSuccessAt,
            lastAttemptAt: lastAttemptAt
        )
    }

    func testAProfileWithoutARecordedSuccessIsDueAtOnce() {
        let verdict = RemoteRefreshSchedule.evaluate(entries: [entry("a")], now: now)

        XCTAssertEqual(verdict, .init(due: [.init("a")], nextWake: nil))
    }

    func testAProfileWhoseIntervalElapsedIsDue() {
        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry("a", lastSuccessAt: now.addingTimeInterval(-3600))],
            now: now
        )

        XCTAssertEqual(verdict.due, [.init("a")])
    }

    func testAFreshProfileWakesOneIntervalAfterItsLastSuccess() {
        let succeededAt = now.addingTimeInterval(-600)

        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry("a", lastSuccessAt: succeededAt)], now: now
        )

        XCTAssertEqual(verdict, .init(due: [], nextWake: succeededAt.addingTimeInterval(3600)))
    }

    func testManualProfilesAreNeverScheduled() {
        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry("a", interval: .manual)], now: now
        )

        XCTAssertEqual(verdict, .init(due: [], nextWake: nil))
    }

    func testASuccessTimeInTheFutureIsDiscardedAndTheProfileIsDueAtOnce() {
        // A rolled-back clock leaves lastSuccessAt ahead of now. Clamping it against a moving
        // now would slide the due date forward on every evaluation; discarding it makes the
        // profile due at once, and the resulting refresh writes a sane timestamp.
        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry("a", lastSuccessAt: now.addingTimeInterval(7 * 24 * 3600))],
            now: now
        )

        XCTAssertEqual(verdict, .init(due: [.init("a")], nextWake: nil))
    }

    func testAnAttemptTimeInTheFutureIsDiscarded() {
        // The stale future attempt must not mask the profile's real overdue state.
        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry(
                "a",
                lastSuccessAt: now.addingTimeInterval(-2 * 3600),
                lastAttemptAt: now.addingTimeInterval(7 * 24 * 3600)
            )],
            now: now
        )

        XCTAssertEqual(verdict, .init(due: [.init("a")], nextWake: nil))
    }

    func testAFailedAttemptSpacesTheRetryByOneInterval() {
        // The attempt time outranks an older success: an always-failing source retries once
        // per interval instead of on every evaluation.
        let attemptedAt = now.addingTimeInterval(-600)

        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry(
                "a",
                lastSuccessAt: now.addingTimeInterval(-2 * 3600),
                lastAttemptAt: attemptedAt
            )],
            now: now
        )

        XCTAssertEqual(verdict, .init(due: [], nextWake: attemptedAt.addingTimeInterval(3600)))
    }

    func testASuccessAfterTheLastAttemptOutranksIt() {
        // A refresh succeeding after a failed attempt advances the schedule from the
        // success, not the stale attempt.
        let succeededAt = now.addingTimeInterval(-300)

        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [entry(
                "a",
                lastSuccessAt: succeededAt,
                lastAttemptAt: now.addingTimeInterval(-600)
            )],
            now: now
        )

        XCTAssertEqual(verdict, .init(due: [], nextWake: succeededAt.addingTimeInterval(3600)))
    }

    func testTheNextWakeIsTheEarliestUpcomingDueDate() {
        let verdict = RemoteRefreshSchedule.evaluate(
            entries: [
                entry("slow", interval: .twentyFourHours, lastSuccessAt: now.addingTimeInterval(-3600)),
                entry("fast", interval: .oneHour, lastSuccessAt: now.addingTimeInterval(-600)),
                entry("hands-off", interval: .manual),
            ],
            now: now
        )

        XCTAssertEqual(verdict, .init(due: [], nextWake: now.addingTimeInterval(3000)))
    }

    func testWithoutEntriesNothingIsDueAndNoWakeIsNeeded() {
        XCTAssertEqual(
            RemoteRefreshSchedule.evaluate(entries: [], now: now),
            .init(due: [], nextWake: nil)
        )
    }
}

/// Records the delays the scheduler asks for and suspends each sleep until the test wakes it
/// or the scheduler cancels it; @unchecked because access is locked.
private final class SleeperStub: @unchecked Sendable {
    private let lock = NSLock()
    private var delays: [TimeInterval] = []
    private var wakeSignals = 0

    var requestedDelays: [TimeInterval] {
        lock.withLock { delays }
    }

    /// Lets the earliest pending sleep return normally, as if its delay elapsed.
    func wake() {
        lock.withLock { wakeSignals += 1 }
    }

    func sleep(for delay: TimeInterval) async throws {
        lock.withLock { delays.append(delay) }
        while true {
            try Task.checkCancellation()
            let woken = lock.withLock {
                if wakeSignals > 0 {
                    wakeSignals -= 1
                    return true
                }
                return false
            }
            if woken { return }
            await Task.yield()
        }
    }
}

/// Mutable clock for the scheduler's injected now; @unchecked because access is locked.
private final class ClockStub: @unchecked Sendable {
    private let lock = NSLock()
    private var date: Date

    init(_ date: Date) {
        self.date = date
    }

    var now: Date {
        lock.withLock { date }
    }

    func advance(by interval: TimeInterval) {
        lock.withLock { date = date.addingTimeInterval(interval) }
    }
}

/// The store's side of the contract, minimally: mutable schedule entries plus the attempt
/// times the store records for every refresh it starts; @unchecked because access is locked.
private final class ScheduleStateStub: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [RemoteRefreshSchedule.Entry]

    init(_ entries: [RemoteRefreshSchedule.Entry]) {
        storage = entries
    }

    var entries: [RemoteRefreshSchedule.Entry] {
        lock.withLock { storage }
    }

    func replace(_ entries: [RemoteRefreshSchedule.Entry]) {
        lock.withLock { storage = entries }
    }

    func recordAttempt(_ profileID: Profile.ID, at date: Date) {
        lock.withLock {
            for index in storage.indices where storage[index].profileID == profileID {
                storage[index].lastAttemptAt = date
            }
        }
    }
}

/// Records the profile IDs the scheduler fires; @unchecked because access is locked.
private final class RefreshRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var fired: [Profile.ID] = []
    /// Runs inside each fired refresh before it returns, simulating slow fetches.
    var beforeReturn: (@Sendable () async -> Void)?

    var refreshed: [Profile.ID] {
        lock.withLock { fired }
    }

    func refresh(_ profileID: Profile.ID) async {
        lock.withLock { fired.append(profileID) }
        await beforeReturn?()
    }
}

/// The timer driver (#71): due profiles fire (the first resync is the startup catch-up), a
/// single sleep waits for the earliest upcoming due date, and every resync re-evaluates —
/// interval changes replace the pending sleep immediately. The injected refresh records an
/// attempt time before running, mirroring the store's contract.
@MainActor
final class RemoteRefreshSchedulerTests: XCTestCase {
    private let launchDate = Date(timeIntervalSince1970: 1_755_000_000)

    private func makeScheduler(
        state: ScheduleStateStub,
        clock: ClockStub,
        recorder: RefreshRecorder,
        sleeper: SleeperStub
    ) -> RemoteRefreshScheduler {
        RemoteRefreshScheduler(
            entries: { state.entries },
            refresh: { profileID in
                state.recordAttempt(profileID, at: clock.now)
                await recorder.refresh(profileID)
            },
            now: { clock.now },
            sleep: { try await sleeper.sleep(for: $0) }
        )
    }

    /// Sleep and fire tasks are created synchronously by resync, but their bodies (which
    /// record delays and refreshes) run asynchronously; yield until the expectation holds.
    private func waitUntil(
        _ condition: @MainActor () -> Bool,
        file: StaticString = #filePath,
        line: UInt = #line
    ) async {
        for _ in 0..<100_000 {
            if condition() { return }
            await Task.yield()
        }
        XCTFail("the awaited condition never held", file: file, line: line)
    }

    func testTheFirstResyncRefreshesOnlyOverdueProfilesOnce() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("overdue"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(-2 * 3600)),
            .init(profileID: .init("fresh"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(-60)),
            .init(profileID: .init("manual"), interval: .manual, lastSuccessAt: nil),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)

        scheduler.resync()
        await scheduler.fireTask?.value

        XCTAssertEqual(recorder.refreshed, [.init("overdue")])
        // The catch-up attempt spaces the overdue profile's next fire by one interval; the
        // fresh profile's earlier due date wins the wake.
        await waitUntil { sleeper.requestedDelays == [3600 - 60] }
    }

    func testTheSleepFiresTheProfileWhenItsDueDateArrives() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(-600)),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)

        scheduler.resync()
        await waitUntil { sleeper.requestedDelays == [3000] }
        XCTAssertEqual(recorder.refreshed, [])

        clock.advance(by: 3000)
        sleeper.wake()
        await scheduler.sleepTask?.value
        await scheduler.fireTask?.value

        XCTAssertEqual(recorder.refreshed, [.init("a")])
    }

    func testAnIntervalChangeReplacesThePendingSleepImmediately() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let lastSuccessAt = launchDate.addingTimeInterval(-600)
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .twentyFourHours, lastSuccessAt: lastSuccessAt),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)
        scheduler.resync()
        let initialSleep = scheduler.sleepTask
        await waitUntil { sleeper.requestedDelays == [24 * 3600 - 600] }

        state.replace([
            .init(profileID: .init("a"), interval: .oneHour, lastSuccessAt: lastSuccessAt),
        ])
        scheduler.resync()

        XCTAssertEqual(initialSleep?.isCancelled, true)
        await waitUntil { sleeper.requestedDelays == [24 * 3600 - 600, 3600 - 600] }
        XCTAssertEqual(recorder.refreshed, [])
    }

    func testAnIntervalChangeMakingTheProfileOverdueFiresAtOnce() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let lastSuccessAt = launchDate.addingTimeInterval(-2 * 3600)
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .twentyFourHours, lastSuccessAt: lastSuccessAt),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)
        scheduler.resync()
        XCTAssertEqual(recorder.refreshed, [])

        state.replace([
            .init(profileID: .init("a"), interval: .oneHour, lastSuccessAt: lastSuccessAt),
        ])
        scheduler.resync()
        await scheduler.fireTask?.value

        XCTAssertEqual(recorder.refreshed, [.init("a")])
    }

    func testManualOnlyEntriesArmNothing() {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .manual, lastSuccessAt: nil),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)

        scheduler.resync()

        XCTAssertNil(scheduler.sleepTask)
        XCTAssertNil(scheduler.fireTask)
        XCTAssertEqual(recorder.refreshed, [])
    }

    func testAFailedFireIsNotRetriedByTheNextResync() async {
        // The refresh leaves lastSuccessAt untouched (a failure); the recorded attempt
        // spaces the retry by one interval instead of firing on every resync.
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour, lastSuccessAt: nil),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)
        scheduler.resync()
        await scheduler.fireTask?.value

        scheduler.resync()

        XCTAssertEqual(recorder.refreshed, [.init("a")])
        await waitUntil { sleeper.requestedDelays == [3600, 3600] }
    }

    func testAManualAttemptSpacesTheScheduledRetryToo() async {
        // A manual refresh that failed just before the timer would have fired: the store
        // recorded its attempt, so the scheduler does not immediately fire a second fetch.
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(-2 * 3600),
                  lastAttemptAt: launchDate.addingTimeInterval(-30)),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)

        scheduler.resync()

        XCTAssertNil(scheduler.fireTask)
        XCTAssertEqual(recorder.refreshed, [])
        await waitUntil { sleeper.requestedDelays == [3600 - 30] }
    }

    func testARolledBackClockFiresOnceAndThenHoldsASteadySchedule() async {
        // The anti-slide guarantee: a success time the clock rollback left in the future is
        // discarded (due at once), and the attempt recorded by that fire anchors the next
        // evaluation — the due date must not keep moving out from under a ticking clock.
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(7 * 24 * 3600)),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)

        scheduler.resync()
        await scheduler.fireTask?.value

        XCTAssertEqual(recorder.refreshed, [.init("a")])
        await waitUntil { sleeper.requestedDelays == [3600] }
    }

    func testAResyncWhileFiringDefersToThePostFireEvaluation() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let gate = Gate()
        recorder.beforeReturn = { await gate.wait() }
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour, lastSuccessAt: nil),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)
        scheduler.resync()
        let fireTask = scheduler.fireTask

        // A model change mid-fire must neither start a second fire nor arm a sleep yet.
        scheduler.resync()
        XCTAssertNil(scheduler.sleepTask)

        gate.open()
        await fireTask?.value

        // One fire only, and the deferred evaluation armed the follow-up sleep.
        XCTAssertEqual(recorder.refreshed, [.init("a")])
        await waitUntil { sleeper.requestedDelays == [3600] }
    }

    func testARemovedProfileDropsItsPendingWake() async {
        let clock = ClockStub(launchDate)
        let recorder = RefreshRecorder()
        let sleeper = SleeperStub()
        let state = ScheduleStateStub([
            .init(profileID: .init("a"), interval: .oneHour,
                  lastSuccessAt: launchDate.addingTimeInterval(-60)),
        ])
        let scheduler = makeScheduler(state: state, clock: clock, recorder: recorder, sleeper: sleeper)
        scheduler.resync()
        XCTAssertNotNil(scheduler.sleepTask)

        state.replace([])
        scheduler.resync()

        XCTAssertNil(scheduler.sleepTask)
        XCTAssertEqual(recorder.refreshed, [])
    }
}

/// Suspends fired refreshes until the test opens it; @unchecked because access is locked.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var isOpen = false

    func open() {
        lock.withLock { isOpen = true }
    }

    func wait() async {
        while !(lock.withLock { isOpen }) {
            await Task.yield()
        }
    }
}
