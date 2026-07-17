import Foundation

/// Collapses a burst of calls into the last one: each `call` cancels the previous pending block
/// and schedules its own after the quiet interval, on the main queue.
final class Debouncer {
    private let delay: TimeInterval
    private var pending: DispatchWorkItem?

    init(delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        pending?.cancel()
        let work = DispatchWorkItem(block: block)
        pending = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }
}
