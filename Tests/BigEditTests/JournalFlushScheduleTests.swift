import XCTest
@testable import BigEdit

/// A clock that only moves when told to, firing whatever falls due.
final class ManualFlushClock: FlushClock {

    private final class Call: ScheduledCall {
        let time: TimeInterval
        let action: () -> Void
        var isCancelled = false

        init(time: TimeInterval, action: @escaping () -> Void) {
            self.time = time
            self.action = action
        }

        func cancel() {
            isCancelled = true
        }
    }

    private(set) var now: TimeInterval = 0
    private var calls: [Call] = []

    func schedule(at time: TimeInterval, _ action: @escaping () -> Void) -> ScheduledCall {
        let call = Call(time: time, action: action)
        calls.append(call)
        return call
    }

    func advance(by interval: TimeInterval) {
        now += interval
        let due = calls.filter { $0.time <= now && !$0.isCancelled }
        calls.removeAll { $0.time <= now || $0.isCancelled }
        due.sorted { $0.time < $1.time }.forEach { call in
            if !call.isCancelled {
                call.action()
            }
        }
    }
}

/// The journal is flushed once typing pauses, and at least every few seconds
/// while it does not; never per keystroke.
final class JournalFlushScheduleTests: XCTestCase {

    private var clock: ManualFlushClock!
    private var flushes = 0
    private var schedule: JournalFlushSchedule!

    override func setUp() {
        super.setUp()
        clock = ManualFlushClock()
        flushes = 0
        schedule = JournalFlushSchedule(clock: clock) { [unowned self] in
            self.flushes += 1
        }
    }

    func testAPauseFlushesOnce() {
        schedule.noteWrite()
        clock.advance(by: 0.9)
        XCTAssertEqual(flushes, 0)
        clock.advance(by: 0.1)
        XCTAssertEqual(flushes, 1)
        XCTAssertFalse(schedule.hasUnflushedWrites)
        clock.advance(by: 10)
        XCTAssertEqual(flushes, 1)
    }

    func testEachWritePushesTheFlushBack() {
        schedule.noteWrite()
        clock.advance(by: 0.5)
        schedule.noteWrite()
        clock.advance(by: 0.9)
        XCTAssertEqual(flushes, 0)
        clock.advance(by: 0.1)
        XCTAssertEqual(flushes, 1)
    }

    func testContinuousTypingStillFlushesEveryFewSeconds() {
        for _ in 0..<100 {
            schedule.noteWrite()
            clock.advance(by: 0.1)
        }
        XCTAssertEqual(flushes, Int(10 / JournalFlushSchedule.maximumInterval))
        XCTAssertTrue(schedule.hasUnflushedWrites)
    }

    func testFlushingNowCancelsTheWait() {
        schedule.noteWrite()
        schedule.flushNow()
        XCTAssertEqual(flushes, 1)
        clock.advance(by: 5)
        XCTAssertEqual(flushes, 1)
    }

    func testCancellingForgetsTheWrites() {
        schedule.noteWrite()
        schedule.cancel()
        clock.advance(by: 5)
        XCTAssertEqual(flushes, 0)
        XCTAssertFalse(schedule.hasUnflushedWrites)
    }
}
