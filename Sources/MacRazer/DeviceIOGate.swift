// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import Foundation

/// Stops USB control transfers at system sleep, including work already queued or retrying.
/// The lock covers one synchronous IOKit call, never a receiver wait or retry delay. Sleep
/// waits for that call to finish; no later call can start until the Mac has woken.
final class DeviceIOGate: @unchecked Sendable {
    static let shared = DeviceIOGate()

    private let lock = NSLock()
    private var suspended = false
    private var generation: UInt64 = 0

    var isSuspended: Bool { lock.withLock { suspended } }
    var session: UInt64 { lock.withLock { generation } }

    func isCurrent(session: UInt64) -> Bool {
        lock.withLock { !suspended && generation == session }
    }

    func suspend() {
        lock.withLock {
            suspended = true
            generation &+= 1
        }
    }

    func resume() {
        lock.withLock { suspended = false }
    }

    /// A session also rejects retries from before sleep after a quick sleep/wake cycle.
    func check(session: UInt64) throws {
        try lock.withLock { try checkLocked(session: session) }
    }

    func perform<T>(session: UInt64? = nil, _ operation: () throws -> T) throws -> T {
        try lock.withLock {
            try checkLocked(session: session)
            return try operation()
        }
    }

    private func checkLocked(session: UInt64?) throws {
        guard !suspended, session == nil || session == generation else {
            throw HIDDevice.HIDError.systemSleeping
        }
    }
}
