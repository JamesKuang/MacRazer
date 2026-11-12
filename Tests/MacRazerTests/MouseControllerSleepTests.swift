// SPDX-License-Identifier: GPL-2.0-or-later
// Part of MacRazer, a control app for Razer mice on macOS. See LICENSE and NOTICE.md.

import XCTest
@testable import MacRazer

final class MouseControllerSleepTests: XCTestCase {
    /// Only touched on the controller's serial queue, read after the queue has drained.
    private final class Transport: RazerTransport {
        let productID = 0x00EB
        let productName = "Sleep test mouse"
        let locationID = 0
        let isBluetooth = false
        var sends = 0
        var closes = 0
        func sendWithRetry(_ report: RazerReport) throws -> RazerReport {
            sends += 1
            throw HIDDevice.HIDError.timeout
        }
        func close() { closes += 1 }
    }

    func testQueuedReadsStandDownAndTheOpenHandleCloses() {
        DeviceIOGate.shared.resume()
        defer { DeviceIOGate.shared.resume() }
        let controller = MouseController()
        let transport = Transport()
        controller.installTransportForTesting(transport)
        let queued = DispatchSemaphore(value: 0)
        let proceed = DispatchSemaphore(value: 0)
        controller.runUserCommandForTesting {
            queued.signal()
            _ = proceed.wait(timeout: .now() + 2)
        }
        XCTAssertEqual(queued.wait(timeout: .now() + 1), .success)
        controller.beginDeviceTest()
        controller.endDeviceTest() // resumes the real poll timer without starting the app
        controller.setPopoverVisible(true)
        XCTAssertTrue(controller.pollScheduledForTesting)
        XCTAssertTrue(controller.settingsPollScheduledForTesting)
        controller.refreshAll()
        controller.refreshSettings()
        controller.systemWillSleep()
        proceed.signal()
        controller.waitForIOForTesting()
        XCTAssertEqual(transport.sends, 0, "queued battery/settings reads must not reach hardware")
        XCTAssertEqual(transport.closes, 1)
        XCTAssertFalse(controller.pollScheduledForTesting)
        XCTAssertFalse(controller.settingsPollScheduledForTesting)

        // Plug callbacks, UI refreshes and a device-test completion must not restart polling.
        controller.forceCheck(immediateOffline: false)
        controller.checkIfOffline()
        controller.refreshAll()
        controller.beginDeviceTest()
        controller.endDeviceTest()
        controller.waitForIOForTesting()
        XCTAssertFalse(controller.pollScheduledForTesting)
        XCTAssertEqual(transport.sends, 0)
    }

    func testWakeReopensTheGateWithoutInterferingWithADeviceTest() throws {
        DeviceIOGate.shared.resume()
        defer { DeviceIOGate.shared.resume() }
        let controller = MouseController()
        controller.beginDeviceTest() // recovery must not touch real hardware mid-test
        controller.systemWillSleep()
        XCTAssertTrue(DeviceIOGate.shared.isSuspended)
        controller.systemDidWake()
        XCTAssertFalse(DeviceIOGate.shared.isSuspended)
        XCTAssertEqual(try DeviceIOGate.shared.perform { 42 }, 42)
        controller.waitForIOForTesting()
        XCTAssertFalse(controller.pollScheduledForTesting)
    }
}
