//
//  G7CGMManagerTests.swift
//  G7SensorKitTests
//
//  Copyright © 2026 LoopKit Authors. All rights reserved.
//

import XCTest
import CoreBluetooth
@testable import G7SensorKit

/// CBCentralManager with the state restoration option raises an exception in a
/// test bundle, which lacks the bluetooth-central background mode.
private class TestBluetoothManager: G7BluetoothManager {
    override func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue)
    }
}

final class G7CGMManagerTests: XCTestCase {

    private static let sensorID = "DXCM99"

    private func makeManager(gracePeriod: TimeInterval) -> G7CGMManager {
        var state = G7CGMManagerState()
        state.sensorID = Self.sensorID
        state.activatedAt = Date(timeIntervalSinceNow: -54000) // ~15h old session
        let sensor = G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        manager.suspectedSessionEndGracePeriod = gracePeriod
        return manager
    }

    private var okGlucoseMessage: G7GlucoseMessage {
        // Same sample as G7GlucoseMessageTests: glucose 138, algorithm state ok
        return G7GlucoseMessage(data: Data(hexadecimalString: "4e00c35501002601000106008a00060187000f")!)!
    }

    /// A grace period in flight when the app is terminated must be re-established
    /// on restore: the deferred scan is an in-memory work item and does not survive.
    /// Restore runs during init, so this goes through the internal init to pick up
    /// the bluetooth seam, and uses the production default grace period.
    private func makeRestoredManager(suspectedSessionEndAt: Date?,
                                     latestReadingTimestamp: Date?) -> G7CGMManager {
        var state = G7CGMManagerState()
        state.sensorID = Self.sensorID
        state.activatedAt = Date(timeIntervalSinceNow: -54000)
        state.suspectedSessionEndAt = suspectedSessionEndAt
        state.latestReadingTimestamp = latestReadingTimestamp

        let sensor = G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        return G7CGMManager(state: state, sensor: sensor)
    }

    func testRestoreForgetsSensorWhenGraceExpiredWhileNotRunning() {
        // Grace started an hour ago, nothing heard since: the session really ended.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -3600),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -7200)
        )

        XCTAssertNil(manager.state.sensorID)
    }

    func testRestoreKeepsSensorWhenReadingArrivedAfterGraceStart() {
        // A reading after the grace period began proves the session survived.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -3600),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -60)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testRestoreKeepsSensorWhileGraceStillRunning() {
        // Terminated one minute into a 15-minute grace period: still within the
        // window, so keep the sensor and let the re-armed deferral decide.
        let manager = makeRestoredManager(
            suspectedSessionEndAt: Date(timeIntervalSinceNow: -60),
            latestReadingTimestamp: Date(timeIntervalSinceNow: -120)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
        XCTAssertNotNil(manager.state.suspectedSessionEndAt)
    }

    func testRestoreWithNoPendingGraceLeavesSensorAlone() {
        let manager = makeRestoredManager(
            suspectedSessionEndAt: nil,
            latestReadingTimestamp: Date(timeIntervalSinceNow: -7200)
        )

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testSuspectedSessionEndPersistsGraceStart() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        XCTAssertNotNil(manager.state.suspectedSessionEndAt)
    }

    func testReadingClearsPersistedGraceStart() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        XCTAssertNotNil(manager.state.suspectedSessionEndAt)

        manager.sensor(manager.sensor, didRead: okGlucoseMessage)

        XCTAssertNil(manager.state.suspectedSessionEndAt)
    }

    func testSuspectedSessionEndKeepsSensorDuringGracePeriod() {
        let manager = makeManager(gracePeriod: 10)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testSuspectedSessionEndForgetsSensorAfterGracePeriodWithoutReadings() {
        let manager = makeManager(gracePeriod: 0.1)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        let forgotten = XCTNSPredicateExpectation(
            predicate: NSPredicate { _, _ in manager.state.sensorID == nil },
            object: nil
        )
        wait(for: [forgotten], timeout: 5)
    }

    func testReadingDuringGracePeriodPreventsForgettingSensor() {
        let manager = makeManager(gracePeriod: 0.5)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        manager.sensor(manager.sensor, didRead: okGlucoseMessage)

        let graceElapsed = expectation(description: "grace period elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 1.5) {
            graceElapsed.fulfill()
        }
        wait(for: [graceElapsed], timeout: 5)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testGraceExpiryAfterCommsSinceGraceStartKeepsSensor() throws {
        // A reading races the expiry: it is already dispatched when the reading
        // arrives and clears the marker. Expiry must notice it no longer owns
        // the window and leave the sensor alone.
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        let graceStart = try XCTUnwrap(manager.state.suspectedSessionEndAt)

        manager.sensor(manager.sensor, didRead: okGlucoseMessage)
        manager.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testGraceExpiryWithoutCommsForgetsSensor() throws {
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)
        let graceStart = try XCTUnwrap(manager.state.suspectedSessionEndAt)

        manager.handleSuspectedSessionEndGraceExpiry(graceStart: graceStart)

        XCTAssertNil(manager.state.sensorID)
    }

    /// An expiry from a superseded grace period must not forget the sensor.
    func testStaleGraceExpiryDoesNotForgetSensor() {
        let manager = makeManager(gracePeriod: 100)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: true)

        manager.handleSuspectedSessionEndGraceExpiry(graceStart: Date(timeIntervalSinceNow: -3600))

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    func testNonSuspectedDisconnectDoesNotForgetSensor() {
        let manager = makeManager(gracePeriod: 0.1)

        manager.sensorDisconnected(manager.sensor, suspectedEndOfSession: false)

        let graceElapsed = expectation(description: "grace period elapsed")
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            graceElapsed.fulfill()
        }
        wait(for: [graceElapsed], timeout: 5)

        XCTAssertEqual(Self.sensorID, manager.state.sensorID)
    }

    /// Only the watchOS target compiles an acquisition arm; here the stock steps run.
    func testThisPlatformUsesTheStockAcquisition() {
        XCTAssertNil(TestBluetoothManager().acquisitionArm)
    }

    // MARK: - Discovery

    /// The identifier a new sensor was found under must reach the persisted
    /// state, so a relaunch can retrieve the peripheral instead of waiting to
    /// hear from it. The manager used to read it back from the sensor's
    /// credentials, which the sensor only updates after this callback returns,
    /// so every sensor adopted while eavesdropping was persisted with nil.
    func testDiscoveringSensorPersistsItsPeripheralIdentifier() {
        let state = G7CGMManagerState()
        let sensor = G7Sensor(mode: state.sessionMode, credentials: state.sensorCredentials, bluetoothManager: TestBluetoothManager())
        let manager = G7CGMManager(state: state, sensor: sensor)
        let identifier = UUID()

        XCTAssertTrue(manager.sensor(sensor, didDiscoverNewSensor: Self.sensorID, activatedAt: Date(), peripheralIdentifier: identifier))

        XCTAssertEqual(identifier, manager.state.peripheralIdentifier)
    }

    // MARK: - Resuming

    /// A session relaunched by Bluetooth state restoration knows its peripheral
    /// only through the bluetooth manager, which records it when the restored
    /// peripheral is made active. Credentials saved before the identifier was
    /// persisted have nil there; resuming must keep the live one, or the rescan
    /// after the next disconnect has nothing to retrieve and, with the
    /// peripheral still active, nothing to scan for.
    func testResumeScanningKeepsLiveIdentifierWhenNonePersisted() {
        let bluetoothManager = TestBluetoothManager()
        let credentials = G7SensorCredentials(sensorID: Self.sensorID, pairingCode: nil, sharedKey: nil, peripheralIdentifier: nil)
        let sensor = G7Sensor(mode: .eavesdropping, credentials: credentials, bluetoothManager: bluetoothManager)
        let restored = UUID()
        bluetoothManager.setActivePeripheralIdentifier(restored)

        sensor.resumeScanning()

        XCTAssertEqual(restored, bluetoothManager.activePeripheralIdentifier)
    }

    /// With `resumeScanning` no longer touching the identifier, a directly
    /// paired session relies on construction and `reconfigure` to target the
    /// peripheral its credentials name.
    func testSessionTargetsPersistedIdentifierFromCredentials() {
        let bluetoothManager = TestBluetoothManager()
        let persisted = UUID()
        let credentials = G7SensorCredentials(sensorID: Self.sensorID, pairingCode: "0420", sharedKey: nil, peripheralIdentifier: persisted)
        let sensor = G7Sensor(mode: .direct, credentials: credentials, bluetoothManager: bluetoothManager)

        XCTAssertEqual(persisted, bluetoothManager.activePeripheralIdentifier)

        let repaired = UUID()
        sensor.reconfigure(mode: .direct, credentials: G7SensorCredentials(sensorID: Self.sensorID, pairingCode: "0420", sharedKey: nil, peripheralIdentifier: repaired))

        XCTAssertEqual(repaired, bluetoothManager.activePeripheralIdentifier)
    }
}

/// TRIO-101: connect-watchdog decision (late-tick deferral) and timing constants.
final class G7ConnectWatchdogActionTests: XCTestCase {
    private func action(
        _ state: CBPeripheralState,
        lateness: TimeInterval = 0,
        deferred: Bool = false,
        ticks: Int = 1,
        escalation: Bool = false
    ) -> G7BluetoothManager.ConnectWatchdogAction {
        G7BluetoothManager.connectWatchdogAction(
            state: state,
            lateness: lateness,
            alreadyDeferred: deferred,
            wedgeTicksAfterThisTick: ticks,
            escalationEnabled: escalation
        )
    }

    func testConnectingOnTimeFirstTickCancels() {
        XCTAssertEqual(action(.connecting), .cancelAndRewatch)
    }

    func testConnectingLateDefers() {
        XCTAssertEqual(action(.connecting, lateness: 11), .deferRecheck)
    }

    func testConnectingLateAlreadyDeferredCancels() {
        XCTAssertEqual(action(.connecting, lateness: 11, deferred: true), .cancelAndRewatch)
    }

    func testConnectingSecondTickEscalatesWhenEnabled() {
        XCTAssertEqual(action(.connecting, ticks: 2, escalation: true), .escalate)
    }

    func testConnectingSecondTickWithoutEscalationCancels() {
        XCTAssertEqual(action(.connecting, ticks: 2, escalation: false), .cancelAndRewatch)
    }

    func testLateWithTicksTwoDefersFirst() {
        XCTAssertEqual(action(.connecting, lateness: 11, ticks: 2, escalation: true), .deferRecheck)
    }

    func testLateRecheckWithTicksTwoEscalates() {
        XCTAssertEqual(action(.connecting, lateness: 11, deferred: true, ticks: 2, escalation: true), .escalate)
    }

    func testDisconnectingRewatches() {
        XCTAssertEqual(action(.disconnecting), .rewatch)
    }

    func testDisconnectedReissues() {
        XCTAssertEqual(action(.disconnected), .reissue)
    }

    func testConnectedSettles() {
        XCTAssertEqual(action(.connected), .settled)
    }

    func testLatenessAtThresholdIsNotDeferred() {
        XCTAssertEqual(action(.connecting, lateness: 10), .cancelAndRewatch)
    }

    func testLateNonConnectingStatesAreNotDeferred() {
        XCTAssertEqual(action(.disconnected, lateness: 60), .reissue)
        XCTAssertEqual(action(.connected, lateness: 60), .settled)
    }

    func testConstants() {
        XCTAssertEqual(G7BluetoothManager.connectAttemptTimeout, 330)
        XCTAssertEqual(G7BluetoothManager.connectWatchdogLateTickThreshold, 10)
        XCTAssertEqual(G7BluetoothManager.connectWatchdogRecheckDelay, 3)
    }
}

final class G7ReconnectPlanTests: XCTestCase {
    private func plan(
        _ cause: G7BluetoothManager.LinkEndCause,
        active: Bool = true,
        poweredOn: Bool = true,
        watchOS: Bool = false,
        glucose: Bool = false
    ) -> G7BluetoothManager.ReconnectPlan {
        return G7BluetoothManager.reconnectPlan(cause: cause, isActivePeripheral: active, centralPoweredOn: poweredOn, isWatchOS: watchOS, hadGlucose: glucose)
    }

    func testIOSRemoteCloseUsesStartDelay() {
        XCTAssertEqual(plan(.remoteClose), .startDelay(seconds: 30))
        XCTAssertEqual(plan(.remoteClose, glucose: true), .startDelay(seconds: 30))
    }

    func testIOSLocalCancelRescans() {
        XCTAssertEqual(plan(.localCancel, glucose: true), .rescan(afterSeconds: 2))
        XCTAssertEqual(plan(.localCancel, glucose: false), .rescan(afterSeconds: 0))
    }

    func testIOSFailedToConnectRescansAtOnce() {
        XCTAssertEqual(plan(.failedToConnect), .rescan(afterSeconds: 0))
    }

    func testWatchOSRemoteCloseRescans() {
        XCTAssertEqual(plan(.remoteClose, watchOS: true, glucose: true), .rescan(afterSeconds: 2))
        XCTAssertEqual(plan(.remoteClose, watchOS: true), .rescan(afterSeconds: 0))
    }

    func testWatchOSFailedToConnectRescans() {
        XCTAssertEqual(plan(.failedToConnect, watchOS: true), .rescan(afterSeconds: 0))
    }

    func testNonActivePeripheralRescans() {
        XCTAssertEqual(plan(.remoteClose, active: false, glucose: true), .rescan(afterSeconds: 2))
        XCTAssertEqual(plan(.remoteClose, active: false), .rescan(afterSeconds: 0))
    }

    func testNotPoweredOnRescans() {
        XCTAssertEqual(plan(.remoteClose, poweredOn: false, glucose: true), .rescan(afterSeconds: 2))
        XCTAssertEqual(plan(.remoteClose, poweredOn: false), .rescan(afterSeconds: 0))
    }
}

/// TRIO-101: a restored, already-connected active peripheral is resumed by hand only on watchOS
/// (CoreBluetooth does not re-deliver didConnect on restore); under the arm only before poweredOn.
final class G7RestoredConnectedResumeTests: XCTestCase {
    private let allStates: [CBPeripheralState] = [.disconnected, .connecting, .connected, .disconnecting]

    private func decide(
        watchOS: Bool = true, arm: Bool = false, active: Bool = true,
        state: CBPeripheralState = .connected, poweredOn: Bool = true
    ) -> G7BluetoothManager.RestoredConnectedResume {
        G7BluetoothManager.restoredConnectedResume(isWatchOS: watchOS, armActive: arm, isActivePeripheral: active, state: state, centralPoweredOn: poweredOn)
    }

    func testFullTruthTable() {
        for watchOS in [true, false] {
            for arm in [true, false] {
                for active in [true, false] {
                    for state in allStates {
                        for poweredOn in [true, false] {
                            var expected = G7BluetoothManager.RestoredConnectedResume.none
                            if watchOS && active && state == .connected {
                                expected = poweredOn ? (arm ? .none : .resumeNow) : .deferToPoweredOn
                            }
                            XCTAssertEqual(
                                decide(watchOS: watchOS, arm: arm, active: active, state: state, poweredOn: poweredOn),
                                expected,
                                "watchOS=\(watchOS) arm=\(arm) active=\(active) state=\(state.rawValue) poweredOn=\(poweredOn)"
                            )
                        }
                    }
                }
            }
        }
    }

    func testStockPoweredOnResumesNow() {
        XCTAssertEqual(decide(arm: false, poweredOn: true), .resumeNow)
    }

    func testStockNotPoweredOnDefers() {
        XCTAssertEqual(decide(arm: false, poweredOn: false), .deferToPoweredOn)
    }

    func testArmNotPoweredOnDefers() {
        XCTAssertEqual(decide(arm: true, poweredOn: false), .deferToPoweredOn)
    }

    func testArmPoweredOnDoesNotDoubleTheSynthesizedDidConnect() {
        XCTAssertEqual(decide(arm: true, poweredOn: true), .none)
    }

    func testNonWatchOSIsNone() {
        XCTAssertEqual(decide(watchOS: false, poweredOn: true), .none)
        XCTAssertEqual(decide(watchOS: false, poweredOn: false), .none)
    }

    func testNotActivePeripheralIsNone() {
        XCTAssertEqual(decide(active: false, poweredOn: false), .none)
    }

    func testNotConnectedIsNone() {
        XCTAssertEqual(decide(state: .connecting, poweredOn: false), .none)
    }
}

/// TRIO-101: stale restored `.connecting` connects are cancelled only when the delegate declined them.
final class G7StaleRestoredConnectTests: XCTestCase {
    private func decide(
        binding: Bool = true, active: Bool = false, state: CBPeripheralState = .connecting,
        managed: Bool = false, pending: Bool = false
    ) -> Bool {
        G7BluetoothManager.shouldCancelStaleRestoredConnect(
            hasActiveBinding: binding, isActivePeripheral: active, state: state, isManaged: managed, isPendingDiscovery: pending
        )
    }

    func testCancelsDeclinedConnecting() {
        XCTAssertTrue(decide())
    }

    func testNoActiveBindingKeeps() {
        XCTAssertFalse(decide(binding: false))
    }

    func testActivePeripheralKeeps() {
        XCTAssertFalse(decide(active: true))
    }

    func testNonConnectingStatesKeep() {
        for state: CBPeripheralState in [.disconnected, .connected, .disconnecting] {
            XCTAssertFalse(decide(state: state), "state=\(state.rawValue)")
        }
    }

    func testManagedKeeps() {
        XCTAssertFalse(decide(managed: true))
    }

    func testPendingDiscoveryKeeps() {
        XCTAssertFalse(decide(pending: true))
    }
}
