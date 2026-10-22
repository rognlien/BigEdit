import Foundation

/// A source of time and delayed calls, so the flush schedule can be driven
/// by a test without waiting.
protocol FlushClock: AnyObject {

    /// Seconds on a monotonic scale.
    var now: TimeInterval { get }

    /// Calls `action` at `time` unless the returned call is cancelled first.
    func schedule(at time: TimeInterval, _ action: @escaping () -> Void) -> ScheduledCall
}

/// A delayed call that has not happened yet.
protocol ScheduledCall {
    func cancel()
}

/// The clock the app runs on: uptime, with calls delivered on the main queue.
final class MainQueueFlushClock: FlushClock {

    static let shared = MainQueueFlushClock()

    var now: TimeInterval {
        TimeInterval(DispatchTime.now().uptimeNanoseconds) / 1e9
    }

    func schedule(at time: TimeInterval, _ action: @escaping () -> Void) -> ScheduledCall {
        let item = DispatchWorkItem(block: action)
        DispatchQueue.main.asyncAfter(deadline: .now() + max(0, time - now), execute: item)
        return item
    }
}

extension DispatchWorkItem: ScheduledCall {}

/// Decides when a journal's appends are made durable: once writes pause for
/// `quietInterval`, and while they do not, no later than `maximumInterval`
/// after the first write not yet flushed. Each write only moves a deadline;
/// the flush itself is the caller's, and runs off the main thread.
final class JournalFlushSchedule {

    static let quietInterval: TimeInterval = 1
    static let maximumInterval: TimeInterval = 3

    private let clock: FlushClock
    private let flush: () -> Void
    private var firstUnflushedWrite: TimeInterval?
    private var scheduledFlush: ScheduledCall?

    init(clock: FlushClock, flush: @escaping () -> Void) {
        self.clock = clock
        self.flush = flush
    }

    /// Whether a write is waiting to be flushed.
    var hasUnflushedWrites: Bool {
        firstUnflushedWrite != nil
    }

    /// Records a write, pushing the flush back unless that would leave the
    /// first unflushed write waiting longer than `maximumInterval`.
    func noteWrite() {
        let now = clock.now
        let first = firstUnflushedWrite ?? now
        firstUnflushedWrite = first
        let deadline = min(now + JournalFlushSchedule.quietInterval,
                           first + JournalFlushSchedule.maximumInterval)
        scheduledFlush?.cancel()
        scheduledFlush = clock.schedule(at: deadline) { [weak self] in
            self?.flushNow()
        }
    }

    /// Flushes whatever is waiting at once.
    func flushNow() {
        cancel()
        flush()
    }

    /// Forgets waiting writes without flushing them.
    func cancel() {
        scheduledFlush?.cancel()
        scheduledFlush = nil
        firstUnflushedWrite = nil
    }
}
