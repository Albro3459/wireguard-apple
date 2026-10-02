// SPDX-License-Identifier: MIT

import Foundation
import XCTest

private final class PendingSettings {
    private let lock = NSLock()
    private var callback: ((Error?) -> Void)?

    func save(_ callback: @escaping (Error?) -> Void) {
        lock.lock()
        self.callback = callback
        lock.unlock()
    }

    func complete() {
        lock.lock()
        let callback = self.callback
        lock.unlock()
        callback?(nil)
    }
}

@objcMembers final class NetworkSettingsTests: XCTestCase {
    func testConfirmedCompletionAllowsAnotherOperation() throws {
        let operation = NetworkSettingsOperation()
        for _ in 0..<2 {
            try operation.perform(timeout: 1) { $0(nil) }
        }
        XCTAssertFalse(operation.isFenced)
    }

    func testSystemFailureIsPreserved() {
        let operation = NetworkSettingsOperation()
        let expectedError = NSError(domain: "test", code: 17)
        XCTAssertThrowsError(try operation.perform(timeout: 1) { callback in
            callback(expectedError)
            callback(nil)
        }) { error in
            XCTAssertEqual(error as NSError, expectedError)
        }
        XCTAssertFalse(operation.isFenced)
        XCTAssertNoThrow(try operation.perform(timeout: 1) { $0(nil) })
    }

    func testMissingCompletionFencesReplacement() {
        let operation = NetworkSettingsOperation()
        XCTAssertThrowsError(try operation.perform(timeout: 0.01) { _ in })
        XCTAssertTrue(operation.isFenced)
        var replacementSubmitted = false
        XCTAssertThrowsError(try operation.perform(timeout: 1) { _ in replacementSubmitted = true })
        XCTAssertFalse(replacementSubmitted)
    }

    func testLateCompletionCannotReviveOrReplaceOperation() {
        let errors: [Error?] = [nil, NSError(domain: "late", code: 1)]
        for error in errors {
            let operation = NetworkSettingsOperation()
            var callback: ((Error?) -> Void)?
            XCTAssertThrowsError(try operation.perform(timeout: 0.01) { callback = $0 })
            callback?(error)
            XCTAssertTrue(operation.isFenced)
            var replacementSubmitted = false
            XCTAssertThrowsError(try operation.perform(timeout: 1) { _ in replacementSubmitted = true })
            XCTAssertFalse(replacementSubmitted)
        }
    }

    func testPendingOperationRejectsOverlap() {
        let operation = NetworkSettingsOperation()
        let submitted = DispatchSemaphore(value: 0)
        let finished = DispatchSemaphore(value: 0)
        let pendingSettings = PendingSettings()
        DispatchQueue.global().async {
            try? operation.perform(timeout: 2) {
                pendingSettings.save($0)
                submitted.signal()
            }
            finished.signal()
        }
        XCTAssertEqual(submitted.wait(timeout: .now() + 1), .success)
        var replacementSubmitted = false
        XCTAssertThrowsError(try operation.perform(timeout: 1) { _ in replacementSubmitted = true }) { error in
            guard case NetworkSettingsOperationError.operationPending = error else {
                return XCTFail("Expected pending operation error")
            }
        }
        XCTAssertFalse(replacementSubmitted)
        pendingSettings.complete()
        XCTAssertEqual(finished.wait(timeout: .now() + 1), .success)
        XCTAssertFalse(operation.isFenced)
    }

    func testCompletionAfterDeadlineFailsEvenBeforeWait() {
        let operation = NetworkSettingsOperation()
        XCTAssertThrowsError(try operation.perform(timeout: 0.01) { callback in
            Thread.sleep(forTimeInterval: 0.02)
            callback(nil)
        })
        XCTAssertTrue(operation.isFenced)
    }
}

let suite = NetworkSettingsTests.defaultTestSuite
suite.run()
guard let result = suite.testRun, result.executionCount == 6, result.totalFailureCount == 0 else {
    exit(1)
}
