// SPDX-License-Identifier: MIT

import Foundation

enum NetworkSettingsOperationError: Error {
    case operationPending
    case timedOut
}

final class NetworkSettingsOperation {
    private enum State {
        case idle
        case running
        case timedOut
    }

    private final class Completion {
        let condition = NSCondition()
        let deadline: Date
        var result: Result<Void, Error>?

        init(deadline: Date) {
            self.deadline = deadline
        }

        func complete(_ error: Error?) {
            condition.lock()
            defer { condition.unlock() }
            guard result == nil, Date() <= deadline else { return }
            result = error.map(Result.failure) ?? .success(())
            condition.signal()
        }
    }

    private let lock = NSLock()
    private var state: State = .idle

    var isFenced: Bool {
        lock.lock()
        defer { lock.unlock() }
        return state == .timedOut
    }

    func perform(timeout: TimeInterval, apply: (@escaping (Error?) -> Void) -> Void) throws {
        lock.lock()
        switch state {
        case .idle:
            state = .running
            lock.unlock()
        case .running:
            lock.unlock()
            throw NetworkSettingsOperationError.operationPending
        case .timedOut:
            lock.unlock()
            throw NetworkSettingsOperationError.timedOut
        }

        let deadline = Date().addingTimeInterval(timeout)
        let completion = Completion(deadline: deadline)
        apply { completion.complete($0) }

        completion.condition.lock()
        while completion.result == nil, completion.condition.wait(until: deadline) {}
        let result = completion.result
        completion.condition.unlock()

        lock.lock()
        // A late OS callback cannot undo a timeout or overlap another settings request
        state = result == nil ? .timedOut : .idle
        lock.unlock()

        guard let result else { throw NetworkSettingsOperationError.timedOut }
        try result.get()
    }
}
