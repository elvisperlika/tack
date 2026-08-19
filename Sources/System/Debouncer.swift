import Foundation

/// Collapses a burst of calls into the last one: each `call` cancels the previous pending block
/// and schedules its own after the quiet interval, on the main queue.
final class Debouncer {
    private let delay: TimeInterval
    private var pending: (() -> Bool)?
    private var generation = 0

    init(delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Bool) {
        generation += 1
        let scheduled = generation
        pending = block
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == scheduled else { return }
            _ = runPending()
        }
    }

    /// Run the latest block now. Older scheduled callbacks are invalidated by the generation.
    @discardableResult func flush() -> Bool {
        generation += 1
        return runPending()
    }

    /// Drop the latest block, for terminal actions such as deleting the value it would save.
    func cancel() {
        generation += 1
        pending = nil
    }

    private func runPending() -> Bool {
        guard let block = pending else { return true }
        guard block() else { return false }  // retain failed work so a lifecycle flush can retry
        pending = nil
        return true
    }
}
