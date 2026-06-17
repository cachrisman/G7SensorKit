//
//  G7BluetoothManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


enum PeripheralConnectionCommand {
    case connect
    case makeActive
    case ignore
}

protocol G7BluetoothManagerDelegate: AnyObject {

    /**
     Tells the delegate that the bluetooth manager has finished connecting to and discovering all required services of its peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed

     - returns: True if scanning should stop
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool

    /**
     Tells the delegate that the bluetooth manager encountered an error while connecting to and discovering required services of a peripheral

     - parameter manager: The bluetooth manager
     - parameter peripheralManager: The peripheral manager
     - parameter error:   An error describing why bluetooth setup failed
     */
    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error)

    /**
     Asks the delegate if the discovered or restored peripheral is active or should be connected to

     - parameter manager:    The bluetooth manager
     - parameter peripheral: The found peripheral

     - returns: PeripheralConnectionCommand indicating what should be done with this peripheral
     */
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral) -> PeripheralConnectionCommand

    /// Informs the delegate that the bluetooth manager received new data in the control characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the control characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the backfill characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - response: The data received on the backfill characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data)

    /// Informs the delegate that the bluetooth manager received new data in the authentication characteristic
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    ///   - peripheralManager: The peripheral manager
    ///   - response: The data received on the authentication characteristic
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data)

    /// Informs the delegate that the bluetooth manager started or stopped scanning
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager)

    /// Informs the delegate that a peripheral disconnected
    ///
    /// - Parameters:
    ///   - manager: The bluetooth manager
    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool)
}


class G7BluetoothManager: NSObject {

    weak var delegate: G7BluetoothManagerDelegate?

    private let log = OSLog(category: "G7BluetoothManager")

    /// Isolated to `managerQueue`
    private var centralManager: CBCentralManager! = nil

    /// Isolated to `managerQueue`
    private var activePeripheral: CBPeripheral? {
        get {
            return activePeripheralManager?.peripheral
        }
    }

    /// Isolated to `managerQueue`
    private var managedPeripherals: [UUID:G7PeripheralManager] = [:]

    var activePeripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Isolated to `managerQueue`
    private var activePeripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
        }
    }

    /// C-207-2: `true` once a real-time glucose message has been parsed on the current connection.
    /// Reset to `false` when a connect is issued (`connectIfNotInFlight`); set to `true` by
    /// `G7Sensor.handleGlucoseMessage`. A disconnect with this still `false` means the transmitter
    /// dropped *before* delivering an EGV (pre-auth / pre-EGV) — it is likely still advertising, so
    /// `scanAfterDelay()` rescans immediately instead of waiting the 2s post-EGV shutdown grace.
    /// Isolated to `managerQueue` (written/read only on that queue: connect issue, glucose parse,
    /// and the disconnect-path `scanAfterDelay`).
    var receivedGlucoseSinceConnect: Bool = false

    /// C-210-6: wall-clock of the last real-time EGV parsed on the active binding, set alongside
    /// `receivedGlucoseSinceConnect` in `G7Sensor.handleGlucoseMessage`. Unlike that per-connection
    /// flag this persists across reconnects, so a "bound but stalled" condition (no EGV for longer
    /// than a reading cycle) is detectable. managerQueue-isolated (written on glucose parse, read in
    /// `connectionEventDidOccur`).
    var lastGlucoseAt: Date?

    /// C-210-7: sliding window of issued-connect timestamps for the reconnect-storm throttle.
    /// managerQueue-isolated (only `connectIfNotInFlight` touches it).
    private var recentConnectIssueTimes: [Date] = []
    private static let connectGateWindow: TimeInterval = 300 // 5 min
    /// Normal cadence is ~1 connect / 5-min reading; allow a few recovery retries, gate true storms
    /// (the 208/209 soak saw up to 16 did_connect in a 5-min window).
    private static let connectGateMaxPerWindow = 8

    /// C-210-6: a bound peripheral with no EGV for longer than this is "stalled" — a connection event
    /// then signals a fresh sensor window worth re-attaching to. > 2 missed 5-min cycles.
    private static let rekickStallThreshold: TimeInterval = 12 * 60

    /// C-210-6 (review H1): wall-clock the active peripheral last became `.connected`; set in
    /// `didConnect`, cleared on disconnect / fail. Lets the re-kick require a genuine "connected but
    /// EGV-silent for a full cycle" zombie, so a fresh recovery attach is never cancelled.
    private var currentConnectionStartedAt: Date?
    /// C-210-6 (review H1): a CONNECTED peripheral silent this long is a zombie (> one 5-min cycle).
    private static let zombieConnectionThreshold: TimeInterval = 6 * 60
    /// C-210-6 (review H2): last re-kick time — debounce so the cancel path can't churn faster than
    /// the connect-gate caps the reconnects. >= connectGateWindow.
    private var lastRekickAt: Date?
    private static let rekickMinInterval: TimeInterval = 300
    /// C-210-7 (review/codex Blocker): true while a drain-time gated-connect retry is already queued,
    /// so repeated gating doesn't stack retries.
    private var gatedRetryScheduled = false

    // MARK: - Synchronization

    private let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    override init() {
        super.init()

        managerQueue.sync {
            self.centralManager = CBCentralManager(delegate: self, queue: managerQueue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
        }
    }

    // MARK: - Actions

    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            self.managerQueue_scanForPeripheral()
        }
    }

    func forgetPeripheral() {
        managerQueue.sync {
            self.activePeripheralManager = nil
            // C-210-6/7 (review B1/M2): binding reset (incl. scanForNewSensor) drops stall / throttle /
            // connection state so the next sensor is not re-kicked or gated by the prior binding.
            self.lastGlucoseAt = nil
            self.recentConnectIssueTimes.removeAll()
            self.receivedGlucoseSinceConnect = false
            self.currentConnectionStartedAt = nil
            self.lastRekickAt = nil
        }
    }

    func stopScanning() {
        managerQueue.sync {
            managerQueue_stopScanning()
        }
    }

    private func managerQueue_stopScanning() {
        if centralManager.isScanning {
            log.default("Stopping scan")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            if centralManager.isScanning {
                log.default("Stopping scan on disconnect")
                centralManager.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }

            if let peripheral = activePeripheral {
                centralManager.cancelPeripheralConnection(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, connectionEventDidOccur event: CBConnectionEvent, for peripheral: CBPeripheral) {
        managerQueue.async {
            // C-208-16b: handle `.peerConnected` for the BOUND peripheral too. This was
            // previously gated to discovery mode (`activePeripheralIdentifier == nil`), so the
            // system-level "the G7 just connected on this device" wake was dropped exactly when
            // following a sensor — the dominant state. For a bound sensor this routes through
            // `.makeActive` → `connectIfNotInFlight`, which is a no-op nudge when a pending
            // connect already exists; the value is the wake + observability.
            // Verification finding: preserve the pre-208 discovery-mode behavior — when
            // unbound, ANY connection event (incl. `.peerDisconnected`, i.e. another app just
            // released the sensor's system connection) triggered discovery handling. For the
            // bound case (new in 208), only `.peerConnected` attaches.
            guard event == .peerConnected || self.activePeripheralIdentifier == nil else { return }
            emitG7Telemetry(
                "connection_event",
                "event=\(event.rawValue) peripheral=\(peripheral.identifier.uuidString) bound=\(self.activePeripheralIdentifier != nil)"
            )
            self.log.default("Peripheral from connectionEventDidOccur %{public}@", peripheral.identifier.uuidString)
            // C-210-6: bound-but-stalled re-kick. If we are bound to THIS sensor but it has gone
            // stalled (no EGV past `rekickStallThreshold`), a connection event means the sensor just
            // opened a fresh window. The normal `handleDiscoveredPeripheral` -> `connectIfNotInFlight`
            // path no-ops when the CB connection still looks alive, so force a re-attach to ride the
            // window now instead of waiting on the host's own timer. HARD-GATED to the stalled case:
            // re-kicking while healthy would tear down a live connection on every event and feed the
            // reconnect storm the C-210-7 gate exists to suppress.
            if self.shouldRekickBoundStalled(for: peripheral) {
                self.rekickBoundStalledPeripheral(peripheral)
                return
            }
            self.handleDiscoveredPeripheral(peripheral)
        }
    }

    private func managerQueue_scanForPeripheral() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard centralManager.state == .poweredOn else {
            return
        }

        let currentState = activePeripheral?.state ?? .disconnected
        guard currentState != .connected else {
            return
        }

        if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.default("Retrieved peripheral %{public}@", peripheral.identifier.uuidString)
            emitG7Telemetry("attach_path", "path=stored_id peripheral=\(peripheral.identifier.uuidString)")
            handleDiscoveredPeripheral(peripheral)
        } else {
            emitG7Telemetry("attach_path", "path=miss has_identifier=\(activePeripheralIdentifier != nil)")
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]) {
                log.default("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
                emitG7Telemetry("attach_path", "path=connected_peripherals peripheral=\(peripheral.identifier.uuidString)")
                handleDiscoveredPeripheral(peripheral)
            }
        }

        if activePeripheral == nil {
            log.default("Scanning for peripherals and listening for connection events")

            centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]])

            emitG7Telemetry("attach_path", "path=scan")
            centralManager.scanForPeripherals(withServices: [
                    SensorServiceUUID.advertisement.cbUUID
                ],
                options: nil
            )
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    /**

     Persistent connections don't seem to work with the transmitter shutoff: The OS won't re-wake the
     app unless it's scanning.

     The sleep gives the transmitter time to shut down, but keeps the app running.

     */
    fileprivate func scanAfterDelay() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // C-207-2: the 2s grace lets the transmitter finish its normal between-reading shutdown AFTER
        // it has delivered an EGV. But when the connection dropped BEFORE any glucose arrived this
        // connection (pre-auth / pre-EGV remote disconnect — the dominant watch-background miss in
        // build 206), the transmitter is likely still in its advertise/connection window; waiting 2s
        // plus a full rescan can miss it and lose the reading. Rescan immediately in that case. Read
        // the flag here (on `managerQueue`) before hopping to the utility queue.
        let settleDelay: TimeInterval = receivedGlucoseSinceConnect ? 2 : 0
        // C-208-15: observability only — makes the self-initiated rescan visible in telemetry
        // (it was previously inferable only from its consequences). No control-flow change.
        emitG7Telemetry("rescan_scheduled", "delay_s=\(Int(settleDelay)) had_glucose=\(receivedGlucoseSinceConnect)")
        DispatchQueue.global(qos: .utility).async {
            if settleDelay > 0 {
                Thread.sleep(forTimeInterval: settleDelay)
            }
            self.scanForPeripheral()
        }
    }

    // MARK: - Accessors

    var isScanning: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isScanning = false
        managerQueue.sync {
            isScanning = centralManager.isScanning
        }
        return isScanning
    }

    var isConnected: Bool {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var isConnected = false
        managerQueue.sync {
            isConnected = activePeripheral?.state == .connected
        }
        return isConnected
    }

    /// Issue a CoreBluetooth connect only when the peripheral is not already connecting or
    /// connected. Discovery callbacks fan in from several paths (scan restart, connectionEvent,
    /// willRestoreState, didDiscover); without this guard each can stack a redundant
    /// `connect(peripheral)` on an already-in-flight connection. Skipped calls are recorded so the
    /// dedup is observable in telemetry.
    private func connectIfNotInFlight(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard peripheral.state != .connecting, peripheral.state != .connected else {
            emitG7Telemetry(
                "connect_skipped",
                "reason=in_flight peripheral=\(peripheral.identifier.uuidString) state=\(peripheral.state.rawValue)"
            )
            return
        }
        // C-210-7: connect-gate. Throttle reconnect STORMS (208/209 soak saw up to 16 did_connect in a
        // 5-min window) without blocking normal cadence (~1 connect/reading) or a few recovery retries.
        // Slide a 5-min window; beyond the cap, skip + log. Fail-safe: this can only REDUCE connects,
        // never add one — a later discovery / scan / disconnect re-invokes this once the window drains.
        let now = Date()
        recentConnectIssueTimes = recentConnectIssueTimes.filter { now.timeIntervalSince($0) < Self.connectGateWindow }
        guard recentConnectIssueTimes.count < Self.connectGateMaxPerWindow else {
            emitG7Telemetry(
                "connect_gated",
                "reason=rate_limit window_s=\(Int(Self.connectGateWindow)) recent_connects=\(recentConnectIssueTimes.count) peripheral=\(peripheral.identifier.uuidString)"
            )
            // review/codex Blocker: a gated connect must NOT leave a bound-but-disconnected peripheral
            // idle (the bound scan path won't scan, and nothing else re-attempts). Queue one drain-time
            // retry on managerQueue so recovery resumes when the window clears.
            scheduleGatedConnectRetry(peripheral)
            return
        }
        recentConnectIssueTimes.append(now)
        // C-207-2: a fresh connect attempt opens a new "did this connection deliver an EGV?" window.
        receivedGlucoseSinceConnect = false
        centralManager.connect(peripheral)
    }

    /// C-210-6: true ONLY for a genuine zombie — bound to this peripheral, globally stalled (no EGV
    /// past `rekickStallThreshold`), AND this specific connection has been `.connected` longer than a
    /// reading cycle without delivering an EGV. Never true for a `.connecting` or freshly connected
    /// peripheral (a fresh post-gap recovery attach must not be cancelled — review H1), nor more than
    /// once per `rekickMinInterval` per binding (review H2).
    private func shouldRekickBoundStalled(for peripheral: CBPeripheral) -> Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard let activeID = activePeripheralIdentifier, activeID == peripheral.identifier else { return false }
        guard let last = lastGlucoseAt, Date().timeIntervalSince(last) > Self.rekickStallThreshold else { return false }
        guard peripheral.state == .connected, !receivedGlucoseSinceConnect,
              let connectedAt = currentConnectionStartedAt,
              Date().timeIntervalSince(connectedAt) > Self.zombieConnectionThreshold else { return false }
        if let lastRekick = lastRekickAt, Date().timeIntervalSince(lastRekick) < Self.rekickMinInterval { return false }
        return true
    }

    /// C-210-6: re-kick a proven zombie (guaranteed `.connected` by `shouldRekickBoundStalled`).
    /// Cancelling the EGV-silent connection drives the existing disconnect -> `scanAfterDelay` ->
    /// rescan path (immediate rescan, no glucose this connection), reconnecting onto the window the
    /// connection event signalled. The reconnect is still subject to the C-210-7 gate, and the
    /// `lastRekickAt` debounce bounds how often this can fire — so a persistent stall cannot storm.
    private func rekickBoundStalledPeripheral(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        lastRekickAt = Date()
        let stallAge = lastGlucoseAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let connAge = currentConnectionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        emitG7Telemetry(
            "connection_event_rekick",
            "peripheral=\(peripheral.identifier.uuidString) stall_age_s=\(stallAge) conn_age_s=\(connAge)"
        )
        receivedGlucoseSinceConnect = false
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// C-210-7 (review/codex Blocker): queue a single drain-time retry for a gated connect, so a
    /// bound-but-disconnected peripheral isn't left idle until an unrelated event happens to re-attempt.
    private func scheduleGatedConnectRetry(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !gatedRetryScheduled else { return }
        gatedRetryScheduled = true
        let oldest = recentConnectIssueTimes.min() ?? Date()
        let drainIn = max(1, Self.connectGateWindow - Date().timeIntervalSince(oldest) + 1)
        managerQueue.asyncAfter(deadline: .now() + drainIn) { [weak self] in
            guard let self else { return }
            self.gatedRetryScheduled = false
            guard self.activePeripheralIdentifier == peripheral.identifier,
                  peripheral.state != .connected, peripheral.state != .connecting else { return }
            self.emitG7Telemetry("connect_gate_retry", "peripheral=\(peripheral.identifier.uuidString)")
            self.connectIfNotInFlight(peripheral)
        }
    }

    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                if let peripheralManager = activePeripheralManager {
                    peripheralManager.peripheral = peripheral
                } else {
                    activePeripheralManager = G7PeripheralManager(
                        peripheral: peripheral,
                        configuration: .dexcomG7,
                        centralManager: centralManager
                    )
                    activePeripheralManager?.delegate = self
                }
                self.managedPeripherals[peripheral.identifier] = activePeripheralManager
                self.connectIfNotInFlight(peripheral)

            case .connect:
                log.default("Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                self.connectIfNotInFlight(peripheral)
                let peripheralManager = G7PeripheralManager(
                    peripheral: peripheral,
                    configuration: .dexcomG7,
                    centralManager: centralManager
                )
                peripheralManager.delegate = self
                self.managedPeripherals[peripheral.identifier] = peripheralManager
            case .ignore:
                break
            }
        }
    }

    override var debugDescription: String {
        return [
            "## BluetoothManager",
            activePeripheralManager.map(String.init(reflecting:)) ?? "No peripheral",
        ].joined(separator: "\n")
    }
}


extension G7BluetoothManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        activePeripheralManager?.centralManagerDidUpdateState(central)
        log.default("%{public}@: %{public}@", #function, String(describing: central.state.rawValue))

        switch central.state {
        case .poweredOn:
            // C-208-16a: register for connection events at every poweredOn, not only inside the
            // scan branch of `managerQueue_scanForPeripheral`. The bound steady-state attaches
            // via stored_id (pending connect, no scan — 95–97% of attaches in telemetry), so
            // scan-branch-only registration left connection events unregistered for most of the
            // process lifetime. Registration dies with the process (build-190 lesson) — this is
            // the per-process re-arm site. Re-registering later in the scan branch is harmless
            // (the OS replaces the prior registration).
            central.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]])
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            if central.isScanning {
                log.default("Stopping scan on central not powered on")
                central.stopScan()
                delegate?.bluetoothManagerScanningStatusDidChange(self)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        // M2: make CB state restoration observable in telemetry. `willRestoreState` previously logged
        // only via OSLog (invisible to BetterStack), so whether watchOS ever relaunches us for BLE was
        // unmeasurable. Emit a structured event so the entitlement question (P1) can be answered from data.
        emitG7Telemetry("will_restore_state", "restored_peripherals=\(restoredPeripherals?.count ?? 0)")

        if let peripherals = restoredPeripherals {
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral, advertisementData: [String : Any], rssi RSSI: NSNumber) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        log.default("%{public}@: %{public}@, data = %{public}@", #function, peripheral, String(describing: advertisementData))

        managerQueue.async {
            self.handleDiscoveredPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        emitG7Telemetry("did_connect", "peripheral=\(peripheral.identifier.uuidString)")
        currentConnectionStartedAt = Date() // C-210-6: zombie-age baseline (review H1)

        log.default("%{public}@: %{public}@", #function, peripheral)

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            peripheralManager.centralManager(central, didConnect: peripheral)

            if let delegate = delegate, case .poweredOn = centralManager.state, case .connected = peripheral.state {
                if delegate.bluetoothManager(self, readied: peripheralManager) {
                    managerQueue_stopScanning()
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        currentConnectionStartedAt = nil // C-210-6: connection ended (review H1)
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = activePeripheralManager {
                self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
            }
        }

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            let remoteDisconnect: Bool
            if let error = error as NSError?, CBError(_nsError: error).code == .peripheralDisconnected {
                remoteDisconnect = true
            } else {
                remoteDisconnect = false
            }
            self.delegate?.peripheralDidDisconnect(self, peripheralManager: peripheralManager, wasRemoteDisconnect: remoteDisconnect)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        scanAfterDelay()
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        currentConnectionStartedAt = nil // C-210-6: no live connection (review H1)
        emitG7Telemetry(
            "did_fail_to_connect",
            "peripheral=\(peripheral.identifier.uuidString) error=\(error?.localizedDescription ?? "nil")"
        )

        log.error("%{public}@: %{public}@", #function, String(describing: error))
        if let error = error, let peripheralManager = activePeripheralManager {
            self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        scanAfterDelay()
    }
}


extension G7BluetoothManager: G7PeripheralManagerDelegate {
    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {

    }

    func peripheralManagerDidUpdateName(_ manager: G7PeripheralManager) {
    }

    func peripheralManagerDidConnect(_ manager: G7PeripheralManager) {
    }

    func completeConfiguration(for manager: G7PeripheralManager) throws {
    }

    func peripheralManager(_ manager: G7PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic) {
        guard let value = characteristic.value else {
            return
        }

        switch CGMServiceCharacteristicUUID(rawValue: characteristic.uuid.uuidString.uppercased()) {
        case .none, .communication?:
            return
        case .control?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveControlResponse: value)
        case .backfill?:
            self.delegate?.bluetoothManager(self, didReceiveBackfillResponse: value)
        case .authentication?:
            self.delegate?.bluetoothManager(self, peripheralManager: manager, didReceiveAuthenticationResponse: value)
        }
    }
}
