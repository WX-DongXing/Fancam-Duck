import Foundation

/// Run one decoder seek at a time, replacing intermediate drag positions with the latest.
/// An exact release request supersedes any queued approximate position.
@MainActor
final class VideoSeekCoalescer {
    struct Request {
        let perform: (@escaping @MainActor () -> Void) -> Void
        let cancel: () -> Void
    }
    private var active: Request?
    private var pending: Request?
    private var generation = UUID()
    var isSeeking:Bool {active != nil}

    func submit(_ request: Request) {
        if active != nil { pending = request }
        else { start(request) }
    }

    func cancel() {
        let previous = active
        generation = UUID()
        active = nil; pending = nil
        previous?.cancel()
    }

    private func start(_ request: Request) {
        active = request
        let id = UUID(); generation = id
        request.perform { [weak self] in
            guard let self, self.generation == id else { return }
            self.active = nil
            if let next = self.pending {
                self.pending = nil
                self.start(next)
            }
        }
    }
}
