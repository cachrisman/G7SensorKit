//
//  G7Sensor.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
import HealthKit
import os.log


public protocol G7SensorDelegate: AnyObject {
    func sensorDidConnect(_ sensor: G7Sensor, name: String)

    func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool)

    func sensor(_ sensor: G7Sensor, didError error: Error)

    func sensor(_ sensor: G7Sensor, logComms comms: String)

    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage)

    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage])

    // If this returns true, then start following this sensor
    func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date) -> Bool

    func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage)

    // This is triggered for connection/disconnection events, and enabling/disabling scan
    func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor)
}

public enum G7SensorError: Error {
    case authenticationError(String)
    case controlError(String)
    case observationError(String)
}

extension G7SensorError: CustomStringConvertible {
    public var description: String {
        switch self {
        case .authenticationError(let description):
            return description
        case .controlError(let description):
            return description
        case .observationError(let description):
            return description
        }
    }
}

public enum G7SensorLifecycleState {
    case searching
    case warmup
    case ok
    case failed
    case gracePeriod
    case expired
}


public final class G7Sensor: G7BluetoothManagerDelegate {
    public static let defaultLifetime = TimeInterval(hours: 10 * 24)
    public static let defaultWarmupDuration = TimeInterval(minutes: 27)
    public static let gracePeriod = TimeInterval(hours: 12)

    public weak var delegate: G7SensorDelegate?

    // MARK: - Passive observation state, confined to `bluetoothManager.managerQueue`

    /// The initial activation date of the sensor
    var activationDate: Date?

    /// The initial activation date of the sensor
    var needsVersionInfo: Bool = false

    /// The date of last connection
    private var lastConnection: Date?

    /// Used to detect connections that do not authenticate, signalling possible sensor switchover
    private var pendingAuth: Bool = false

    /// The backfill data buffer
    private var backfillBuffer: [G7BackfillMessage] = []

    // MARK: -

    private let log = OSLog(category: "G7Sensor")

    private let bluetoothManager = G7BluetoothManager()

    private let delegateQueue = DispatchQueue(label: "com.loopkit.G7Sensor.delegateQueue", qos: .unspecified)

    private var sensorID: String?

    private func emitG7TelemetrySensorLocked(_ name: String) {
        emitG7Telemetry("sensor_name_locked", "locked_name=\(name)")
    }

    public init(sensorID: String?) {
        self.sensorID = sensorID
        bluetoothManager.delegate = self
    }

    public func scanForNewSensor() {
        self.sensorID = nil
        bluetoothManager.disconnect()
        bluetoothManager.forgetPeripheral()
        bluetoothManager.scanForPeripheral()
    }

    public func resumeScanning() {
        bluetoothManager.scanForPeripheral()
    }

    public func stopScanning() {
        bluetoothManager.disconnect()
    }

    public var isScanning: Bool {
        return bluetoothManager.isScanning
    }

    public var isConnected: Bool {
        return bluetoothManager.isConnected
    }

    private func handleGlucoseMessage(message: G7GlucoseMessage, peripheralManager: G7PeripheralManager) {
        let trendStr = message.trend.map { String(format: "%.1f", $0) } ?? "nil"
        let glucoseStr = message.glucose.map { String($0) } ?? "nil"
        emitG7Telemetry(
            "egv_received",
            "glucose=\(glucoseStr) sequence=\(message.sequence) algorithm_state=\(message.algorithmState.rawValue) age_s=\(message.age) message_timestamp=\(message.messageTimestamp) trend_rate=\(trendStr) display_only=\(message.glucoseIsDisplayOnly)"
        )
        // C-207-2: this connection delivered a real-time EGV, so a subsequent disconnect is the
        // transmitter's normal post-reading shutdown — `scanAfterDelay` should keep its 2s grace.
        // (A disconnect with this flag still false ⇒ pre-EGV drop ⇒ immediate rescan.) Runs on
        // `managerQueue`, the same queue `scanAfterDelay` reads the flag on.
        bluetoothManager.receivedGlucoseSinceConnect = true
        activationDate = Date().addingTimeInterval(-TimeInterval(message.messageTimestamp))
        peripheralManager.perform { (peripheral) in
            self.log.debug("Listening for backfill responses")
            // Subscribe to backfill updates
            do {
                try peripheral.listenToCharacteristic(.backfill)
            } catch let error {
                emitG7Telemetry("backfill_notify_failed", "error=\(error.localizedDescription)")
                self.log.error("Error trying to enable notifications on backfill characteristic: %{public}@", String(describing: error))
                self.delegateQueue.async {
                    self.delegate?.sensor(self, didError: error)
                }
            }
        }

        if needsVersionInfo, let name = peripheralManager.peripheral.name, name == sensorID {
            peripheralManager.perform { (peripheral) in
                do {
                    try peripheral.requestExtendedVersion()
                } catch let error {
                    self.log.error("Error trying to request extended version: %{public}@", String(describing: error))
                }
            }
        }

        if sensorID == nil, let name = peripheralManager.peripheral.name, let activationDate = activationDate  {
            delegateQueue.async {
                guard let delegate = self.delegate else {
                    return
                }

                if delegate.sensor(self, didDiscoverNewSensor: name, activatedAt: activationDate) {
                    self.sensorID = name
                    self.emitG7TelemetrySensorLocked(name)
                    self.activationDate = activationDate
                    self.needsVersionInfo = true
                    self.delegate?.sensor(self, didRead: message)
                    self.bluetoothManager.stopScanning()
                    if self.needsVersionInfo, let name = peripheralManager.peripheral.name, name == self.sensorID {
                        peripheralManager.perform { (peripheral) in
                            do {
                                try peripheral.requestExtendedVersion()
                            } catch let error {
                                self.log.error("Error trying to request extended version on initial detection: %{public}@", String(describing: error))
                            }
                        }
                    }
                }
            }
        } else if sensorID != nil {
            delegateQueue.async {
                self.delegate?.sensor(self, didRead: message)
            }
        } else {
            self.log.error("Dropping unhandled glucose message: %{public}@", String(describing: message))
        }
    }

    // MARK: - BluetoothManagerDelegate

    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        var shouldStopScanning = false;
        let peripheralName = peripheralManager.peripheral.name ?? "nil"
        let peripheralID = peripheralManager.peripheral.identifier.uuidString
        let isFollowing = (sensorID != nil && sensorID == peripheralName)
        emitG7Telemetry("gatt_ready", "peripheral=\(peripheralID) following_known=\(isFollowing)")

        if let sensorID = sensorID, sensorID == peripheralManager.peripheral.name {
            shouldStopScanning = true
            delegateQueue.async {
                self.delegate?.sensorDidConnect(self, name: sensorID)
            }
        }

        peripheralManager.perform { (peripheral) in
            self.log.info("Listening for authentication responses for %{public}@", String(describing: peripheralManager.peripheral.name))
            do {
                try peripheral.listenToCharacteristic(.authentication)
                self.pendingAuth = true
                emitG7Telemetry("auth_notify_subscribed", "peripheral=\(peripheralID)")
                emitG7Telemetry("auth_notify_requested", "peripheral=\(peripheralID)")
            } catch let error {
                emitG7Telemetry("auth_notify_failed", "peripheral=\(peripheralID) error=\(error.localizedDescription)")
                self.delegateQueue.async {
                    self.delegate?.sensor(self, didError: error)
                }
            }
        }
        return shouldStopScanning
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error) {
        delegateQueue.async {
            self.delegate?.sensor(self, didError: error)
        }
    }

    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool) {
        let peripheralName = peripheralManager.peripheral.name ?? "nil"
        let peripheralID = peripheralManager.peripheral.identifier.uuidString
        let isFollowed = (sensorID != nil && sensorID == peripheralName)
        emitG7Telemetry(
            "disconnect",
            "peripheral=\(peripheralID) was_remote=\(wasRemoteDisconnect) pending_auth=\(pendingAuth) followed=\(isFollowed)"
        )
        if let sensorID = sensorID, sensorID == peripheralManager.peripheral.name {

            // Sometimes we do not receive the backfillFinished message before disconnect
            flushBackfillBuffer()

            let suspectedEndOfSession: Bool

            self.log.info("Sensor disconnected: wasRemoteDisconnect:%{public}@", String(describing: wasRemoteDisconnect))
            if pendingAuth, wasRemoteDisconnect {
                suspectedEndOfSession = true // Normal disconnect without auth is likely that G7 app stopped this session
                emitG7Telemetry("suspected_end_of_session", "prior_name=\(sensorID)")
            } else {
                suspectedEndOfSession = false
            }
            pendingAuth = false

            delegateQueue.async {
                self.delegate?.sensorDisconnected(self, suspectedEndOfSession: suspectedEndOfSession)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> PeripheralConnectionCommand {

        guard let name = peripheral.name else {
            log.debug("Not connecting to unnamed peripheral: %{public}@", String(describing: peripheral))
            return .ignore
        }

        /// The Dexcom G7 advertises a peripheral name of "DXCMxx", and later reports a full name of "Dexcomxx"
        /// Dexcom One+ peripheral name start with "DX02"
        if name.hasPrefix("DXCM") || name.hasPrefix("DX02"){
            // If we're following this name or if we're scanning, connect
            if let sensorName = sensorID, name.suffix(2) == sensorName.suffix(2) {
                emitG7Telemetry("connect_called", "intent=makeActive peripheral=\(peripheral.identifier.uuidString)")
                return .makeActive
            } else if sensorID == nil {
                emitG7Telemetry("connect_called", "intent=connect peripheral=\(peripheral.identifier.uuidString)")
                return .connect
            }
        }

        log.info("Not connecting to peripheral: %{public}@", name)
        return .ignore
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data) {

        guard response.count > 0 else { return }

        log.default("Received control response: %{public}@", response.hexadecimalString)

        switch G7Opcode(rawValue: response[0]) {
        case .glucoseTx?:
            if let glucoseMessage = G7GlucoseMessage(data: response) {
                handleGlucoseMessage(message: glucoseMessage, peripheralManager: peripheralManager)
            } else {
                emitG7Telemetry("egv_parse_failed", "bytes=\(response.count)")
                delegateQueue.async {
                    self.delegate?.sensor(self, didError: G7SensorError.observationError("Unable to handle glucose control response"))
                }
            }
        case .extendedVersionTx:
            if let extendedVersionMessage = ExtendedVersionMessage(data: response) {
                log.default("Received %{public}@", String(describing: extendedVersionMessage))
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceive: extendedVersionMessage)
                    self.needsVersionInfo = false
                    self.delegate?.sensor(self, logComms: response.hexadecimalString)
                }
            }
        case .backfillFinished:
            emitG7Telemetry("backfill_finished", "bytes=\(response.count)")
            flushBackfillBuffer()
        default:
            break
        }
    }

    func flushBackfillBuffer() {
        if backfillBuffer.count > 0 {
            let backfill = backfillBuffer
            emitG7Telemetry("backfill_flush", "count=\(backfill.count)")
            for entry in backfill {
                let bgStr = entry.glucose.map { String($0) } ?? "nil"
                let trStr = entry.trend.map { String(format: "%.1f", $0) } ?? "nil"
                emitG7Telemetry(
                    "backfill_entry",
                    "timestamp=\(entry.timestamp) glucose=\(bgStr) algorithm_state=\(entry.algorithmState.rawValue) display_only=\(entry.glucoseIsDisplayOnly) trend=\(trStr)"
                )
            }
            self.backfillBuffer = []
            delegateQueue.async {
                self.delegate?.sensor(self, didReadBackfill: backfill)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {

        log.debug("Received backfill response: %{public}@", response.hexadecimalString)

        guard response.count == 9 else {
            return
        }

        if let msg = G7BackfillMessage(data: response) {
            backfillBuffer.append(msg)
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data) {

        let opcode = response.first ?? 0xFF
        let authByte = response.count > 1 ? response[1] : 0xFF
        let bondByte = response.count > 2 ? response[2] : 0xFF
        let payloadHex = response.count <= 8
            ? response.map { String(format: "%02X", $0) }.joined()
            : "omitted"

        guard let message = AuthChallengeRxMessage(data: response) else {
            emitG7Telemetry(
                "auth_value_received",
                "opcode=0x\(String(format: "%02X", opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=false"
            )
            emitG7Telemetry("auth_payload_ignored", "bytes=\(response.count)")
            log.debug("Ignoring authentication response: %{public}@", response.hexadecimalString)
            return
        }
        let gatePass = message.isAuthenticated && message.isBonded
        emitG7Telemetry(
            "auth_value_received",
            "opcode=0x\(String(format: "%02X", opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=\(gatePass)"
        )
        if gatePass {
            log.debug("Observed authenticated session. enabling notifications for control characteristic.")
            pendingAuth = false
            emitG7Telemetry("auth_authenticated_bonded", "peripheral=\(peripheralManager.peripheral.identifier.uuidString)")
            peripheralManager.perform { (peripheral) in
                do {
                    try peripheral.listenToCharacteristic(.control)
                    emitG7Telemetry("control_notify_subscribed", "peripheral=\(peripheralManager.peripheral.identifier.uuidString)")
                } catch let error {
                    emitG7Telemetry("control_notify_failed", "error=\(error.localizedDescription)")
                    self.log.error("Error trying to enable notifications on control characteristic: %{public}@", String(describing: error))
                    self.delegateQueue.async {
                        self.delegate?.sensor(self, didError: error)
                    }
                }
            }
        } else {
            emitG7Telemetry("auth_payload_ignored", "bytes=\(response.count)")
            log.debug("Ignoring authentication response: %{public}@", response.hexadecimalString)
        }
    }

    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager) {
        // Read isScanning on a background thread to avoid potential queue deadlock.
        // If this still deadlocks in practice, drop the boolean and log just the event.
        DispatchQueue.global(qos: .utility).async {
            let scanning = manager.isScanning
            emitG7Telemetry("scanning_status_changed", "scanning=\(scanning)")
        }
        self.delegateQueue.async {
            self.delegate?.sensorConnectionStatusDidUpdate(self)
        }
    }
}


// MARK: - Helpers
fileprivate extension G7PeripheralManager {

    func listenToCharacteristic(_ characteristic: CGMServiceCharacteristicUUID) throws {
        do {
            try setNotifyValue(true, for: characteristic)
        } catch let error {
            throw G7SensorError.controlError("Error enabling notification for \(characteristic): \(error)")
        }
    }
}
