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


/// C-216-B / W-7a: point-in-time BLE diagnostics snapshot for build-216 heartbeat consumers.
///
/// **Diagnostic significance:** `activePeripheralStateRaw == 1` (`CBPeripheralState.connecting`)
/// together with `connectPendingAgeS == nil` is the "unwatched pending connect" fingerprint — a
/// `.connecting` peripheral that did NOT arise from a `connectIfNotInFlight` we issued (no
/// `bindingState.connectIssuedAt`), e.g. a CB-restored or discovery-mode connect the C-212-1
/// connect-attempt watchdog (`scheduleConnectTimeout`) is not watching, and so cannot time out on
/// its own. Build-216 heartbeat consumers key on this combination.
public struct G7BLEDiagnosticsSnapshot {
    public let centralStateRaw: Int           // CBManagerState.rawValue
    public let isScanning: Bool
    public let activePeripheralStateRaw: Int? // CBPeripheralState.rawValue; nil when no active peripheral
    public let connectPendingAgeS: Int?       // seconds since bindingState.connectIssuedAt; nil when none pending
    public let secondsSinceLastDiscover: Int? // nil if no didDiscover yet this process
    public let lastDiscoverRSSI: Int?         // nil if none yet
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

    /// C-216-A: wall-clock of the most recent `didDiscover` (any peripheral, bound or not), for the
    /// `rssi_age_s=` staleness stamp on `attach_path`/`connect_timeout` telemetry. Isolated to
    /// `managerQueue` (written only from `centralManager(_:didDiscover:...)`, which already
    /// dispatch-preconditions onto it).
    private var lastDiscoverAt: Date?
    /// C-216-A: RSSI from that same most recent `didDiscover`. Isolated to `managerQueue` alongside
    /// `lastDiscoverAt` — always written/read together.
    private var lastDiscoverRSSI: Int?

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

    /// C-210-6/7: the binding-scoped BLE recovery state, reset atomically on every binding change
    /// (`forgetPeripheral`, and a `.makeActive` re-bind to a new peripheral). Consolidated into one
    /// object — rather than separate fields cleared at each transition site — so "no stale
    /// stall/throttle/connection state across a sensor swap or restore" is structural, not a
    /// per-transition checklist (review round 2: A/B/C/D/H were all missed transitions). NOTE:
    /// `receivedGlucoseSinceConnect` is intentionally NOT in here — it is connection-scoped (reset on
    /// every connect issue), not binding-scoped; it is reset alongside this struct in
    /// `forgetPeripheral` for completeness. managerQueue-isolated.
    private struct BindingBLEState {
        /// Wall-clock of the last real-time EGV on this binding (persists across reconnects).
        var lastGlucoseAt: Date?
        /// Wall-clock the ACTIVE peripheral last became `.connected`. Set/cleared ONLY for the active
        /// binding (review A/H) and seeded once on adopt-if-already-connected (review D). Drives the
        /// "connected zombie" age check.
        var currentConnectionStartedAt: Date?
        /// C-212-1: wall-clock the active binding's current connect attempt was issued while it is
        /// still `.connecting`. Set on connect issue (or on C-216-W7 watchdog adoption of a
        /// restored/externally-created in-flight attempt); thereafter owned by the connect watchdog
        /// (`scheduleConnectTimeout`), which clears it once the attempt resolves on a `.connected` tick.
        /// Also cleared by an explicit `disconnect()` and by binding resets. Deliberately NOT cleared by
        /// didConnect/didDisconnect/didFailToConnect — a belated callback from a cancelled attempt would
        /// otherwise disarm a newer attempt's watchdog (review). Drives the connect-attempt timeout that
        /// breaks a wedged `.connecting` peripheral (`connect()` has no timeout). Active binding only.
        var connectIssuedAt: Date?
        /// Last re-kick time — debounce so the cancel path can't churn faster than the gate caps
        /// reconnects (review H2).
        var lastRekickAt: Date?
        /// Sliding window of issued-connect timestamps for the reconnect-storm throttle (C-210-7).
        var recentConnectIssueTimes: [Date] = []
        /// True while a drain-time gated-connect retry is queued, so repeated gating doesn't stack.
        var gatedRetryScheduled = false
        /// C-217 Task 2: consecutive `.connecting` watchdog ticks for the current connect attempt.
        /// Reset to 0 on every fresh connect issue (`connectIssuedAt` assignment). Tick 1 runs the
        /// legacy cancel-and-reschedule path; tick ≥2 with escalation enabled triggers central re-init.
        var connectWedgeTicks: Int = 0
        /// True once `connect_wedge_persistent` has been emitted for the current wedge episode.
        var wedgePersistentEmitted = false
    }
    private var bindingState = BindingBLEState()
    /// Monotonic id bumped on every binding reset, captured by the delayed-retry closure so a stale
    /// closure from a prior binding no-ops instead of clearing the NEW binding's retry flag (review B).
    private var bindingGeneration = 0

    /// C-216-W7: pending discovery-mode connects (unbound, or restored while unbound), keyed by
    /// peripheral id — the population C-212-1 deliberately left unwatched (accepted limitation E).
    /// Build-215 forensics (06-30 gap entry) measured that hole at a ≥2 h silent wedge: an unbound
    /// connect that never completes suppresses didDiscover re-delivery (allowDuplicates=false scan)
    /// and every telemetry-emitting path, recoverable only by process relaunch. Markers are set at
    /// connect-issue/adopt and cleared ONLY by the discovery watchdog when it observes a settled
    /// state — mirroring `connectIssuedAt`'s no-callback-clears invariant so a belated callback
    /// cannot disarm a newer attempt's chain. Deliberately NOT binding-scoped (not in
    /// `BindingBLEState`): discovery attempts are binding-independent and their cleanup must survive
    /// binding resets. managerQueue-isolated.
    private var pendingDiscoveryConnects: [UUID: Date] = [:]

    /// C-217 Task 4: wall-clock of the most recent `reinitCentral` call — 120 s anti-loop guard so a
    /// persistent wedge cannot churn central managers. managerQueue-isolated.
    private var lastCentralReinitAt: Date?

    private static let connectGateWindow: TimeInterval = 300 // 5 min
    /// Normal cadence is ~1 connect / 5-min reading; allow a few recovery retries, gate true storms
    /// (the 208/209 soak saw up to 16 did_connect in a 5-min window).
    private static let connectGateMaxPerWindow = 8
    /// C-210-6: a bound peripheral with no EGV for longer than this is "stalled" — a connection event
    /// then signals a fresh sensor window worth re-attaching to. > 2 missed 5-min cycles.
    private static let rekickStallThreshold: TimeInterval = 12 * 60
    /// C-210-6 (review H1): a CONNECTED peripheral silent this long is a zombie (> one 5-min cycle).
    private static let zombieConnectionThreshold: TimeInterval = 6 * 60
    /// C-210-6 (review H2): re-kick debounce; >= connectGateWindow.
    private static let rekickMinInterval: TimeInterval = 300
    /// C-212-1: a connect attempt that never reaches `.connected` (and never fails) wedges the
    /// peripheral in `.connecting` forever — `connect()` has no timeout — and every later
    /// connectIfNotInFlight is skipped as in_flight (the build-211 multi-hour stall). Generous vs a
    /// healthy connect (< a few seconds), under the 5-min cadence so a slow-but-progressing connect
    /// is not killed and a hang costs at most one cycle.
    private static let connectAttemptTimeout: TimeInterval = 60
    /// C-217 Task 4: minimum interval between `reinitCentral` calls — prevents a re-init loop when
    /// the wedge persists across central swaps.
    private static let centralReinitMinInterval: TimeInterval = 120

    /// Called on `managerQueue` from `G7Sensor.handleGlucoseMessage` when a real-time EGV is parsed:
    /// marks this connection as having delivered glucose and stamps the binding-scoped last-EGV time.
    func noteGlucoseReceived() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        receivedGlucoseSinceConnect = true
        bindingState.lastGlucoseAt = Date()
    }

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
            // C-210-6/7 (review A/B/C/D): binding reset. Reset binding-scoped recovery state in one
            // shot and bump the generation so any in-flight delayed retry from the prior binding no-ops;
            // drop stale managed peripherals so their late disconnect callbacks can't touch the new
            // binding's connection state. Reached ONLY via scanForNewSensor (sensor swap / EOS /
            // session-end), NOT from a normal disconnect(), so clearing managedPeripherals here does not
            // skip a live-connection disconnect callback (review round 3, M-c).
            self.bindingState = BindingBLEState()
            self.bindingGeneration += 1
            self.managedPeripherals.removeAll()
            self.receivedGlucoseSinceConnect = false
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

    /// C-217 Task 4 (C-210-8): public entry for host-driven central re-init (e.g. watch adapter
    /// episode classifier). Async onto `managerQueue`; safe from any queue except `managerQueue`.
    public func requestCentralReinit(reason: String) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.async {
            self.reinitCentral(reason: reason)
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
            // C-212-1 (review): an explicit disconnect is a stop — disarm the connect watchdog so it
            // can't reissue a connect the caller intended to stop.
            bindingState.connectIssuedAt = nil
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
            emitG7Telemetry("attach_path", "path=stored_id peripheral=\(peripheral.identifier.uuidString) \(rssiTelemetrySuffix())")
            handleDiscoveredPeripheral(peripheral)
        } else {
            emitG7Telemetry("attach_path", "path=miss has_identifier=\(activePeripheralIdentifier != nil) \(rssiTelemetrySuffix())")
            for peripheral in centralManager.retrieveConnectedPeripherals(withServices: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]) {
                log.default("Found system-connected peripheral: %{public}@", peripheral.identifier.uuidString)
                emitG7Telemetry("attach_path", "path=connected_peripherals peripheral=\(peripheral.identifier.uuidString) \(rssiTelemetrySuffix())")
                handleDiscoveredPeripheral(peripheral)
            }
        }

        if activePeripheral == nil {
            log.default("Scanning for peripherals and listening for connection events")

            centralManager.registerForConnectionEvents(options: [CBConnectionEventMatchingOption.serviceUUIDs: [
                SensorServiceUUID.advertisement.cbUUID,
                SensorServiceUUID.cgmService.cbUUID
            ]])

            emitG7Telemetry("attach_path", "path=scan \(rssiTelemetrySuffix())")
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

    /// C-216-B / W-7a: public diagnostics snapshot, contracted with a parallel adapter change — see
    /// `G7BLEDiagnosticsSnapshot`'s doc comment for the "unwatched pending connect" fingerprint this
    /// exists to surface. Same `notOnQueue` + `managerQueue.sync` pattern as `isScanning`/`isConnected`.
    func diagnosticsSnapshot() -> G7BLEDiagnosticsSnapshot {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        var snapshot: G7BLEDiagnosticsSnapshot!
        managerQueue.sync {
            let connectPendingAgeS = bindingState.connectIssuedAt.map { Int(Date().timeIntervalSince($0)) }
            let secondsSinceLastDiscover = lastDiscoverAt.map { Int(Date().timeIntervalSince($0)) }
            snapshot = G7BLEDiagnosticsSnapshot(
                centralStateRaw: centralManager.state.rawValue,
                isScanning: centralManager.isScanning,
                activePeripheralStateRaw: activePeripheral?.state.rawValue,
                connectPendingAgeS: connectPendingAgeS,
                secondsSinceLastDiscover: secondsSinceLastDiscover,
                lastDiscoverRSSI: lastDiscoverRSSI
            )
        }
        return snapshot
    }

    /// C-216-A: shared `last_rssi=`/`rssi_age_s=` suffix for the `attach_path` and `connect_timeout`
    /// emits, so the sentinel values (127 = BT-spec "RSSI not available", -1 = "no discover yet")
    /// are defined in exactly one place rather than repeated at each of the 5 call sites.
    /// managerQueue-isolated (reads `lastDiscoverAt`/`lastDiscoverRSSI`).
    private func rssiTelemetrySuffix() -> String {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let rssi = lastDiscoverRSSI ?? 127
        let ageS = lastDiscoverAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        return "last_rssi=\(rssi) rssi_age_s=\(ageS)"
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
            // C-210-6 (review D): adopt an already-`.connected` ACTIVE binding (CB restore / retrieve)
            // that skipped `didConnect`, so the zombie clock isn't permanently nil and re-kick can
            // eventually qualify. Seed once, active binding only.
            if peripheral.identifier == activePeripheralIdentifier, peripheral.state == .connected,
               bindingState.currentConnectionStartedAt == nil {
                bindingState.currentConnectionStartedAt = Date()
            }
            // C-216-W7 (arm-on-adopt): a `.connecting` peripheral this process never issued a connect
            // for — CoreBluetooth restores pending connects across relaunch, and willRestoreState →
            // handleDiscoveredPeripheral lands here — was previously invisible to the C-212-1
            // watchdog (`connectIssuedAt` nil), so the wedge could persist for hours with zero
            // connect_timeout telemetry while also suppressing scans (bound path scans only when
            // activePeripheral == nil). Build-215 06-30 forensics: three consecutive relaunches each
            // skipped the restored attempt as in_flight, followed by a 2 h silent gap. Adopt the
            // attempt into the matching watchdog so it can time out and recover like a native one.
            if peripheral.state == .connecting {
                if peripheral.identifier == activePeripheralIdentifier {
                    if bindingState.connectIssuedAt == nil {
                        bindingState.connectIssuedAt = Date()
                        bindingState.connectWedgeTicks = 0
                        bindingState.wedgePersistentEmitted = false
                        emitG7Telemetry("connect_watchdog_adopted", "scope=bound peripheral=\(peripheral.identifier.uuidString)")
                        scheduleConnectTimeout(peripheral)
                    }
                } else if pendingDiscoveryConnects[peripheral.identifier] == nil {
                    pendingDiscoveryConnects[peripheral.identifier] = Date()
                    emitG7Telemetry("connect_watchdog_adopted", "scope=discovery peripheral=\(peripheral.identifier.uuidString)")
                    scheduleDiscoveryConnectTimeout(peripheral)
                }
            }
            return
        }
        // C-210-7: connect-gate. Throttle reconnect STORMS (208/209 soak saw up to 16 did_connect in a
        // 5-min window) without blocking normal cadence (~1 connect/reading) or a few recovery retries.
        // Slide a 5-min window; beyond the cap, skip + log. Fail-safe: this can only REDUCE connects,
        // never add one — a later discovery / scan / disconnect re-invokes this once the window drains.
        let now = Date()
        bindingState.recentConnectIssueTimes = bindingState.recentConnectIssueTimes.filter { now.timeIntervalSince($0) < Self.connectGateWindow }
        guard bindingState.recentConnectIssueTimes.count < Self.connectGateMaxPerWindow else {
            emitG7Telemetry(
                "connect_gated",
                "reason=rate_limit window_s=\(Int(Self.connectGateWindow)) recent_connects=\(bindingState.recentConnectIssueTimes.count) peripheral=\(peripheral.identifier.uuidString)"
            )
            // review/codex Blocker: a gated connect must NOT leave a bound-but-disconnected peripheral
            // idle (the bound scan path won't scan, and nothing else re-attempts). Queue one drain-time
            // retry on managerQueue so recovery resumes when the window clears.
            scheduleGatedConnectRetry(peripheral)
            return
        }
        bindingState.recentConnectIssueTimes.append(now)
        // C-207-2: a fresh connect attempt opens a new "did this connection deliver an EGV?" window.
        receivedGlucoseSinceConnect = false
        centralManager.connect(peripheral)
        // C-212-1: arm a timeout for the active binding's connect so a wedged `.connecting` attempt
        // (no didConnect / didFailToConnect) can't stall recovery indefinitely. Active binding only.
        if peripheral.identifier == activePeripheralIdentifier {
            bindingState.connectIssuedAt = now
            bindingState.connectWedgeTicks = 0
            bindingState.wedgePersistentEmitted = false
            scheduleConnectTimeout(peripheral)
        } else {
            // C-216-W7: close C-212-1's accepted limitation E — an unbound discovery-mode connect
            // (`.connect` intent, sensorID nil) previously had no watchdog. If it wedged in
            // `.connecting`, nothing could time it out, and the duplicate-filtered scan cannot
            // re-deliver didDiscover for the same peripheral within the scan session — so recovery
            // required a process relaunch (build-215 06-30, second phase of the silent gap).
            pendingDiscoveryConnects[peripheral.identifier] = now
            scheduleDiscoveryConnectTimeout(peripheral)
        }
    }

    /// C-210-6: true ONLY for a genuine zombie — bound to this peripheral, globally stalled (no EGV
    /// past `rekickStallThreshold`), AND this specific connection has been `.connected` longer than a
    /// reading cycle without delivering an EGV. Never true for a `.connecting` or freshly connected
    /// peripheral (a fresh post-gap recovery attach must not be cancelled — review H1), nor more than
    /// once per `rekickMinInterval` per binding (review H2).
    private func shouldRekickBoundStalled(for peripheral: CBPeripheral) -> Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard let activeID = activePeripheralIdentifier, activeID == peripheral.identifier else { return false }
        // M-b (review round 3, accepted limitation): re-kick requires an in-process EGV baseline
        // (lastGlucoseAt non-nil). A nil clock after a cold launch / CB restore deliberately does NOT
        // qualify — treating nil as "stalled" would re-kick during the ~27-min warmup (no EGVs,
        // connection up past the zombie threshold). The fork has no warmup signal; cold-restore-into-
        // stalled recovers via the watch adapter watchdog or the first EGV.
        guard let last = bindingState.lastGlucoseAt, Date().timeIntervalSince(last) > Self.rekickStallThreshold else { return false }
        // review round 3 (High): do NOT also require a never-delivered-EGV flag — that would narrow the
        // zombie to "this connection never delivered ANY EGV" and miss a connection that delivered one
        // EGV then went silent. The connection-age guard already excludes a fresh attach, and the
        // global-stall guard above already excludes a connection that is actually delivering.
        guard peripheral.state == .connected,
              let connectedAt = bindingState.currentConnectionStartedAt,
              Date().timeIntervalSince(connectedAt) > Self.zombieConnectionThreshold else { return false }
        if let lastRekick = bindingState.lastRekickAt, Date().timeIntervalSince(lastRekick) < Self.rekickMinInterval { return false }
        return true
    }

    /// C-210-6: re-kick a proven zombie (guaranteed `.connected` by `shouldRekickBoundStalled`).
    /// Cancelling the EGV-silent connection drives the existing disconnect -> `scanAfterDelay` ->
    /// rescan path (immediate rescan, no glucose this connection), reconnecting onto the window the
    /// connection event signalled. The reconnect is still subject to the C-210-7 gate, and the
    /// `lastRekickAt` debounce bounds how often this can fire — so a persistent stall cannot storm.
    private func rekickBoundStalledPeripheral(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // review round 4 (codex Medium): the connection-event peripheral can be a FRESH CBPeripheral
        // object for the active UUID while the manager still holds a stale one. Cancelling the event
        // object directly would then trip `peripheral != activePeripheral` in didDisconnect and drop
        // the active map entry, blunting recovery. Adopt the event object as the active peripheral
        // first, so we cancel the object the manager and CoreBluetooth agree on and didDisconnect
        // keeps the binding's map entry. (Same UUID, so no binding change / no generation bump.)
        if activePeripheralManager?.peripheral !== peripheral {
            activePeripheralManager?.peripheral = peripheral
            lockedPeripheralIdentifier.value = peripheral.identifier
        }
        bindingState.lastRekickAt = Date()
        let stallAge = bindingState.lastGlucoseAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        let connAge = bindingState.currentConnectionStartedAt.map { Int(Date().timeIntervalSince($0)) } ?? -1
        emitG7Telemetry(
            "connection_event_rekick",
            "peripheral=\(peripheral.identifier.uuidString) stall_age_s=\(stallAge) conn_age_s=\(connAge)"
        )
        receivedGlucoseSinceConnect = false
        centralManager.cancelPeripheralConnection(peripheral)
    }

    /// C-210-7 (review/codex Blocker): queue a single drain-time retry for a gated connect, so a
    /// bound-but-disconnected peripheral isn't left idle until an unrelated event happens to re-attempt.
    /// ACCEPTED LIMITATION (review finding E): the retry resolves the *active* binding, so a connect
    /// gated during UNBOUND new-sensor discovery (activePeripheralIdentifier == nil) is not re-fired
    /// here — rediscovery / the next scan covers it once the window drains. Discovery-scoped pairing
    /// latency only, not a bound-steady-state gap; tracked as a soak follow-up.
    private func scheduleGatedConnectRetry(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard !bindingState.gatedRetryScheduled else { return }
        bindingState.gatedRetryScheduled = true
        let gen = bindingGeneration
        let pid = peripheral.identifier
        let oldest = bindingState.recentConnectIssueTimes.min() ?? Date()
        let drainIn = max(1, Self.connectGateWindow - Date().timeIntervalSince(oldest) + 1)
        managerQueue.asyncAfter(deadline: .now() + drainIn) { [weak self] in
            guard let self else { return }
            // review B: a stale closure from a prior binding must NOT clear the new binding's flag.
            guard self.bindingGeneration == gen else { return }
            self.bindingState.gatedRetryScheduled = false
            // review F: resolve the current peripheral by identifier (the object can be replaced by a
            // later retrieve/restore for the same UUID); only retry the still-active, disconnected binding.
            guard self.activePeripheralIdentifier == pid, let peripheral = self.activePeripheral,
                  peripheral.identifier == pid,
                  peripheral.state != .connected, peripheral.state != .connecting else { return }
            emitG7Telemetry("connect_gate_retry", "peripheral=\(pid.uuidString)")
            self.connectIfNotInFlight(peripheral)
        }
    }

    /// C-212-1: connect watchdog. `connect()` has no timeout, so a peripheral wedged in `.connecting`
    /// (no didConnect/didFailToConnect) would otherwise be skipped as in_flight by every later
    /// connectIfNotInFlight forever — the build-211 multi-hour in-flight stall. While the active
    /// binding has a pending connect (connectIssuedAt set), re-check every `connectAttemptTimeout`:
    ///   - `.connecting` past the timeout → wedged: cancel and keep watching. Cancelling a pending
    ///     connect may fire NO delegate callback and CB clears state asynchronously, so we must not
    ///     rescan now (an immediate connectIfNotInFlight would skip as in_flight and re-wedge) — keep
    ///     watching until state actually leaves `.connecting`.
    ///   - `.disconnecting` → a cancel is settling: keep watching, don't re-issue yet.
    ///   - `.disconnected` with the attempt still pending → the cancel settled without a callback
    ///     clearing the marker: re-issue via the standard retrieve+connect path, which re-arms a fresh
    ///     watchdog (so this chain ends here; no double-arm).
    /// The watchdog clears connectIssuedAt on a `.connected` tick; an explicit `disconnect()` and
    /// binding resets also clear it. Callbacks (didConnect/didDisconnect/didFailToConnect) do NOT, so a
    /// belated callback from a cancelled attempt can't disarm a newer attempt's watchdog.
    /// C-217 Task 2: on the second+ `.connecting` tick (`connectWedgeTicks >= 2`) with escalation
    /// enabled, emit `connect_wedge_persistent` and escalate to central re-init instead of repeating
    /// the cancel-and-reschedule loop (cancel-with-no-callback wedges survive identical retries).
    /// Generation-guarded and pinned to the exact attempt; re-issue is C-210-7-gated.
    private func scheduleConnectTimeout(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let gen = bindingGeneration
        let pid = peripheral.identifier
        let issuedAt = bindingState.connectIssuedAt
        managerQueue.asyncAfter(deadline: .now() + Self.connectAttemptTimeout) { [weak self] in
            guard let self else { return }
            guard self.bindingGeneration == gen,
                  self.activePeripheralIdentifier == pid,
                  self.bindingState.connectIssuedAt == issuedAt,
                  let peripheral = self.activePeripheral, peripheral.identifier == pid else { return }
            switch peripheral.state {
            case .connecting:
                self.bindingState.connectWedgeTicks += 1
                let ticks = self.bindingState.connectWedgeTicks
                let ageS = Int(Date().timeIntervalSince(issuedAt ?? Date()))
                if ticks >= 2, G7BackgroundHints.isConnectWedgeEscalationEnabled {
                    // Debounce emit to once-per-wedge; escalation is still attempted every tick.
                    if !self.bindingState.wedgePersistentEmitted {
                        emitG7Telemetry(
                            "connect_wedge_persistent",
                            "peripheral=\(pid.uuidString) age_s=\(ageS) ticks=\(ticks) \(self.rssiTelemetrySuffix())"
                        )
                        self.bindingState.wedgePersistentEmitted = true
                    }
                    if self.escalateWedgedConnect(peripheral) {
                        return
                    }
                    // reinit suppressed (Task-4 off or 120s guard) -> keep C-212-1 recovery alive
                }
                emitG7Telemetry("connect_timeout", "peripheral=\(pid.uuidString) age_s=\(ageS) \(self.rssiTelemetrySuffix())")
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.scheduleConnectTimeout(peripheral)
            case .disconnecting:
                self.scheduleConnectTimeout(peripheral)
            case .disconnected:
                emitG7Telemetry("connect_timeout_reissue", "peripheral=\(pid.uuidString)")
                self.managerQueue_scanForPeripheral()
                // review #2: if the reissue didn't start a new connect (gated / retrieve-miss /
                // delegate .ignore), connectIssuedAt is unchanged and no fresh watchdog was armed —
                // keep watching so a gated tick can't strand recovery.
                if self.bindingState.connectIssuedAt == issuedAt {
                    self.scheduleConnectTimeout(peripheral)
                }
            case .connected:
                // review #4: normally didConnect already cleared the marker (we never reach here);
                // clear defensively in case that callback was missed, then stop.
                self.bindingState.connectIssuedAt = nil
            @unknown default:
                break
            }
        }
    }

    /// C-217 Task 2+4: a `.connecting` peripheral whose `cancelPeripheralConnection` yields no
    /// delegate callback cannot be cleared at the peripheral level — retrieve/rescan return the same
    /// cached in-flight object and `connectIfNotInFlight` skips it as in_flight. Escalate to central
    /// re-init, which drops the wedged peripheral reference entirely.
    private func escalateWedgedConnect(_ peripheral: CBPeripheral) -> Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        return reinitCentral(reason: "wedge_escalation")
    }

    /// C-217 Task 4: replace the `CBCentralManager` to clear a peripheral wedged in `.connecting`
    /// that survives repeated cancel-with-no-callback cycles. Does NOT rescan or re-register here —
    /// the fresh central's `centralManagerDidUpdateState(.poweredOn)` handles both.
    ///
    /// ⚠️ REVIEW RISK: holding a NEW `CBCentralManager` with the SAME restore identifier
    /// (`com.loudnate.CGMBLEKit`) while the outgoing one deallocates. Verify: old central's
    /// `delegate=nil` + dropped reference → clean dealloc; no duplicate-restore-id warning; no
    /// double-delivery of callbacks during the swap window.
    ///
    /// Fallback if central-swap proves unsafe: do NOT recreate the central; instead
    /// `activePeripheralManager = nil` + full binding reset + `managerQueue_scanForPeripheral()`
    /// (weaker — may not clear a truly stuck `.connecting`, but no central-swap risk).
    @discardableResult
    private func reinitCentral(reason: String) -> Bool {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        guard G7BackgroundHints.isCentralReinitEnabled else { return false }
        if let last = lastCentralReinitAt, Date().timeIntervalSince(last) < Self.centralReinitMinInterval {
            return false
        }
        let activeState = activePeripheral?.state.rawValue
        emitG7Telemetry(
            "central_reinit",
            "reason=\(reason) active_state=\(activeState.map(String.init) ?? "nil") \(rssiTelemetrySuffix())"
        )
        if let peripheral = activePeripheral {
            centralManager.cancelPeripheralConnection(peripheral)
        }
        managerQueue_stopScanning()
        centralManager.delegate = nil
        // Nil-ing `activePeripheralManager` clears `activePeripheralIdentifier` via didSet — intended;
        // the fresh central rediscovers the sensor via name filter on the next poweredOn scan path.
        bindingState = BindingBLEState()
        bindingGeneration += 1
        pendingDiscoveryConnects.removeAll()
        managedPeripherals.removeAll()
        activePeripheralManager = nil
        receivedGlucoseSinceConnect = false
        lastCentralReinitAt = Date()
        centralManager = CBCentralManager(
            delegate: self,
            queue: managerQueue,
            options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"]
        )
        return true
    }

    /// C-216-W7: discovery-scoped sibling of `scheduleConnectTimeout`, for connects issued (or
    /// adopted) while the peripheral is NOT the active binding. Same recurring shape as C-212-1:
    ///   - `.connecting` past the timeout → cancel and keep watching (a cancelled pending connect may
    ///     fire no callback and CB clears state asynchronously).
    ///   - `.disconnecting` → a cancel is settling: keep watching.
    ///   - `.disconnected` → clear the marker and re-enter `managerQueue_scanForPeripheral()`;
    ///     re-issuing `scanForPeripherals` restarts the scan session, which resets the scanner's
    ///     duplicate filter (allowDuplicates=false otherwise suppresses a repeat didDiscover for this
    ///     peripheral), so the sensor can be rediscovered and re-connected via the normal gated path.
    ///   - `.connected` → clear and stop (the readied/auth path owns it now).
    /// If the peripheral has become the ACTIVE binding meanwhile, ownership passes to the C-212-1
    /// watchdog and this chain retires. Markers are cleared ONLY here (no delegate callback clears
    /// them) — the `connectIssuedAt` invariant — so a belated callback from a cancelled attempt
    /// cannot disarm a newer attempt's chain. No bindingGeneration guard on purpose: discovery
    /// attempts are binding-independent and stale-attempt cleanup must survive binding resets.
    /// All reissue paths remain C-210-7-gated via connectIfNotInFlight.
    private func scheduleDiscoveryConnectTimeout(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let pid = peripheral.identifier
        let issuedAt = pendingDiscoveryConnects[pid]
        managerQueue.asyncAfter(deadline: .now() + Self.connectAttemptTimeout) { [weak self] in
            guard let self else { return }
            // Superseded (a newer issue/adopt re-stamped the marker) or already retired.
            guard let issuedAt, self.pendingDiscoveryConnects[pid] == issuedAt else { return }
            // Became the active binding since — the C-212-1 watchdog owns it now.
            guard pid != self.activePeripheralIdentifier else {
                self.pendingDiscoveryConnects.removeValue(forKey: pid)
                return
            }
            guard let peripheral = self.managedPeripherals[pid]?.peripheral
                ?? self.centralManager.retrievePeripherals(withIdentifiers: [pid]).first else {
                self.pendingDiscoveryConnects.removeValue(forKey: pid)
                return
            }
            switch peripheral.state {
            case .connecting:
                let ageS = Int(Date().timeIntervalSince(issuedAt))
                emitG7Telemetry("discovery_connect_timeout", "peripheral=\(pid.uuidString) age_s=\(ageS)")
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.scheduleDiscoveryConnectTimeout(peripheral)
            case .disconnecting:
                self.scheduleDiscoveryConnectTimeout(peripheral)
            case .disconnected:
                self.pendingDiscoveryConnects.removeValue(forKey: pid)
                emitG7Telemetry("discovery_connect_timeout_rescan", "peripheral=\(pid.uuidString)")
                self.managerQueue_scanForPeripheral()
            case .connected:
                self.pendingDiscoveryConnects.removeValue(forKey: pid)
            @unknown default:
                break
            }
        }
    }

    private func handleDiscoveredPeripheral(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                // C-210-6 (review round 3, M-a / High#2): a re-bind to a DIFFERENT peripheral changes
                // the binding WITHOUT going through forgetPeripheral. Reset binding-scoped recovery
                // state + bump the generation so prior-binding stall/throttle/retry state can't leak in
                // and a pending gated-retry closure no-ops. Steady-state reconnects (same id) skip this.
                if activePeripheral?.identifier != peripheral.identifier {
                    bindingState = BindingBLEState()
                    bindingGeneration += 1
                }

                if let peripheralManager = activePeripheralManager {
                    peripheralManager.peripheral = peripheral
                    // Swapping `.peripheral` on the existing manager does NOT fire the
                    // activePeripheralManager didSet that maintains activePeripheralIdentifier, so set it
                    // explicitly — otherwise the re-kick/retry guards compare against a stale UUID (M-a).
                    lockedPeripheralIdentifier.value = peripheral.identifier
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
            // C-217 Task 4: observe restore-identifier reuse — a small since_reinit_s here traces
            // reinit → central_powered_on → scan after a central swap.
            emitG7Telemetry(
                "central_powered_on",
                "since_reinit_s=\(lastCentralReinitAt.map { Int(Date().timeIntervalSince($0)) } ?? -1)"
            )
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
        // C-217 Task 4: since_reinit_s + restored_ids observe restore-identifier reuse — a small
        // since_reinit_s is the undocumented in-process replay; restored_ids shows wedged re-inheritance.
        let restoredIdsStr: String
        if let peripherals = restoredPeripherals, !peripherals.isEmpty {
            restoredIdsStr = peripherals.map { $0.identifier.uuidString }.joined(separator: ",")
        } else {
            restoredIdsStr = "none"
        }
        emitG7Telemetry(
            "will_restore_state",
            "restored_peripherals=\(restoredPeripherals?.count ?? 0) since_reinit_s=\(lastCentralReinitAt.map { Int(Date().timeIntervalSince($0)) } ?? -1) restored_ids=\(restoredIdsStr)"
        )

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

        // C-216-A: last-discover RSSI baseline, stamped onto later attach_path/connect_timeout
        // telemetry. Bounded rate — the scan is `allowDuplicates=false`, so this is at most once
        // per peripheral per discovery cycle, not per-advertisement.
        lastDiscoverAt = Date()
        lastDiscoverRSSI = RSSI.intValue
        emitG7Telemetry("did_discover", "peripheral=\(peripheral.identifier.uuidString) rssi=\(RSSI.intValue) bound=\(activePeripheralIdentifier != nil)")

        managerQueue.async {
            self.handleDiscoveredPeripheral(peripheral)
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        emitG7Telemetry("did_connect", "peripheral=\(peripheral.identifier.uuidString)")
        // C-210-6 (review H): zombie-age baseline — ACTIVE binding only, so a did_connect for a
        // non-active managed peripheral can't refresh the active zombie's connection clock.
        if peripheral.identifier == activePeripheralIdentifier {
            // C-212-2 (review): refresh the zombie clock for the CURRENT attempt only — when a connect
            // WE issued is still pending (connectIssuedAt set, before the watchdog clears it on its
            // .connected tick). This both (a) always gives a genuinely new session a fresh baseline even
            // if the prior disconnect/fail callback was missed (the new connect set connectIssuedAt), and
            // (b) ignores a belated/duplicate didConnect on a long-lived zombie (whose connectIssuedAt was
            // already cleared by the watchdog), so it can't reset the clock and suppress
            // shouldRekickBoundStalled. (The C-210-6 review-D adopt path seeds the clock separately.)
            if bindingState.connectIssuedAt != nil {
                bindingState.currentConnectionStartedAt = Date()
            }
            // C-212-1 (review): do NOT clear connectIssuedAt here — the watchdog clears it on a
            // `.connected` tick. A belated didConnect from a cancelled attempt must not disarm a newer
            // attempt's watchdog. (currentConnectionStartedAt stays the C-210-6 zombie clock.)
        }

        log.default("%{public}@: %{public}@", #function, peripheral)

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            peripheralManager.centralManager(central, didConnect: peripheral)
            // C-216-A: opportunistic RSSI sample on connect; result arrives async via
            // `peripheralManager(_:didReadRSSI:error:)`. Read-only — CoreBluetooth serializes this
            // against the connection's other GATT operations on its own delegate queue.
            peripheral.readRSSI()

            if let delegate = delegate, case .poweredOn = centralManager.state, case .connected = peripheral.state {
                if delegate.bluetoothManager(self, readied: peripheralManager) {
                    managerQueue_stopScanning()
                }
            }
        }
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral, error: Error?) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        // C-210-6 (review A): clear the connection clock only when the ACTIVE binding disconnects, so
        // a stray non-active peripheral's disconnect can't suppress re-kick for the active zombie.
        if peripheral.identifier == activePeripheralIdentifier {
            bindingState.currentConnectionStartedAt = nil
        }
        // C-212-1 (review #1): do NOT clear connectIssuedAt here. A belated callback from a CANCELLED
        // connect can arrive after the watchdog already re-issued a new connect; clearing the marker
        // then would kill the NEW attempt's watchdog and re-wedge. connectIssuedAt is owned by connect
        // issue (set) and the watchdog (which clears it on a `.connected` tick); the scanAfterDelay()
        // below reissues and overwrites it.
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
        // C-210-6 (review A): active binding only (see didDisconnect).
        if peripheral.identifier == activePeripheralIdentifier {
            bindingState.currentConnectionStartedAt = nil
        }
        // C-212-1 (review #1): do NOT clear connectIssuedAt here (see didDisconnect) — a belated
        // callback from a cancelled attempt must not kill a newer attempt's watchdog.
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
        // C-216-A: result of the opportunistic `readRSSI()` issued in `didConnect`. Telemetry-only —
        // no state to update here (the discover-time sample in `lastDiscoverRSSI` is what
        // `attach_path`/`connect_timeout` stamp).
        emitG7Telemetry("rssi_read", "value=\(RSSI.intValue) error=\(error?.localizedDescription ?? "nil")")
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
