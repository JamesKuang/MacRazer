// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class DeviceIOGateTests: XCTestCase {
    private func assertSleeping(_ operation: () throws -> Void,
                                file: StaticString = #filePath, line: UInt = #line) {
        XCTAssertThrowsError(try operation(), file: file, line: line) { error in
            guard case HIDDevice.HIDError.systemSleeping = error else {
                return XCTFail("Unexpected error: \(error)", file: file, line: line)
            }
        }
    }

    func testSleepRejectsWorkAndWakeAllowsANewSession() throws {
        let gate = DeviceIOGate()
        let beforeSleep = gate.session
        XCTAssertEqual(try gate.perform(session: beforeSleep) { 42 }, 42)
        gate.suspend()
        assertSleeping { try gate.perform { XCTFail("must not reach the device") } }
        gate.resume()
        assertSleeping { try gate.perform(session: beforeSleep) { XCTFail("stale request") } }
        XCTAssertEqual(try gate.perform(session: gate.session) { 7 }, 7)
    }

    func testSleepBetweenRequestAndResponseStopsTheResponseRead() throws {
        let gate = DeviceIOGate()
        let session = gate.session
        var transfers = 0
        try gate.perform(session: session) { transfers += 1 } // SetReport
        gate.suspend() // while waiting for the receiver
        assertSleeping { try gate.perform(session: session) { transfers += 1 } }
        XCTAssertEqual(transfers, 1)
    }

    func testSleepWaitsForOneInFlightTransferThenRejectsMore() {
        let gate = DeviceIOGate()
        let started = DispatchSemaphore(value: 0)
        let finishTransfer = DispatchSemaphore(value: 0)
        let transferDone = DispatchSemaphore(value: 0)
        let sleepStarted = DispatchSemaphore(value: 0)
        let sleepDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            do {
                try gate.perform {
                    started.signal()
                    _ = finishTransfer.wait(timeout: .now() + 2)
                }
            } catch { XCTFail("\(error)") }
            transferDone.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 1), .success)
        DispatchQueue.global().async {
            sleepStarted.signal()
            gate.suspend()
            sleepDone.signal()
        }
        XCTAssertEqual(sleepStarted.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(sleepDone.wait(timeout: .now() + 0.02), .timedOut,
                       "sleep must wait for the current IOKit call")
        finishTransfer.signal()
        XCTAssertEqual(transferDone.wait(timeout: .now() + 1), .success)
        XCTAssertEqual(sleepDone.wait(timeout: .now() + 1), .success)
        assertSleeping { try gate.perform { XCTFail("new transfer during sleep") } }
    }

    func testRetryDoesNotReplayARequestAfterSleepAndWake() {
        let gate = DeviceIOGate()
        var attempts = 0
        assertSleeping {
            try RazerRetry.run(attempts: 3, gate: gate) {
                attempts += 1
                gate.suspend()
                gate.resume()
                throw HIDDevice.HIDError.timeout
            }
        }
        XCTAssertEqual(attempts, 1)
    }

    func testSleepCancellationIsNotRetried() {
        let gate = DeviceIOGate()
        var attempts = 0
        assertSleeping {
            try RazerRetry.run(attempts: 3, gate: gate) {
                attempts += 1
                throw HIDDevice.HIDError.systemSleeping
            }
        }
        XCTAssertEqual(attempts, 1)
    }

    func testOrdinaryRetryStillSucceeds() throws {
        let gate = DeviceIOGate()
        var attempts = 0
        let value = try RazerRetry.run(attempts: 3, gate: gate) {
            attempts += 1
            if attempts < 3 { throw HIDDevice.HIDError.timeout }
            return 42
        }
        XCTAssertEqual(value, 42)
        XCTAssertEqual(attempts, 3)
    }
}
