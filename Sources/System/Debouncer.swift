import Foundation

/// Collapses a burst of calls into the last one: each `call` cancels the previous pending block
/// and schedules its own after the quiet interval, on the main queue.
final class Debouncer {
    private let delay: TimeInterval
    private var pending: (() -> Void)?
    private var generation = 0

    init(delay: TimeInterval) { self.delay = delay }

    func call(_ block: @escaping () -> Void) {
        generation += 1
        let scheduled = generation
        pending = block
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, generation == scheduled else { return }
            runPending()
        }
    }

    /// Run the latest block now. Older scheduled callbacks are invalidated by the generation.
    func flush() {
        generation += 1
        runPending()
    }

    /// Drop the latest block, for terminal actions such as deleting the value it would save.
    func cancel() {
        generation += 1
        pending = nil
    }

    private func runPending() {
        let block = pending
        pending = nil
        block?()
    }
}
