//
//  G7BluetoothManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//
//  Active-peripheral tracking, the powered-on recheck and central recreation
//  are derived from DexKit by Erik Tolboom
//  (https://github.com/nightscout/DexKit).
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
    /// A signal-strength reading for a connected peripheral, requested with `readRSSI()`.
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReadRSSI rssi: NSNumber, error: Error?)


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
    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) -> PeripheralConnectionCommand

    /**
     Asks the delegate whether peripherals restored by CoreBluetooth's state
     restoration should be adopted.

     A session says yes: that is how it resumes its own sensor after a relaunch.
     A pairing run says no, because a stale restored peripheral would be treated
     as a candidate and crowd out the sensor actually being paired.
     */
    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool

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

    /// One line for the host's device log (OmnipodKit's omnipodLogDeviceEvent shape).
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String)

    /// Whether a connection could be authenticated (direct: a pairing code or stored key;
    /// eavesdropping: always).
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool

    /// A peripheral was adopted as the sensor (nil when one was let go of).
    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?)

    /// `needsCodeForSensor` or `isSearchingForSensor` changed.
    func bluetoothManagerStatusDidChange(_ manager: G7BluetoothManager)
}

extension G7BluetoothManagerDelegate {
    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReadRSSI rssi: NSNumber, error: Error?) {}
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String) {}
    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool { true }
    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?) {}
    func bluetoothManagerStatusDidChange(_ manager: G7BluetoothManager) {}
}

/// Takes over acquisition where a platform cannot use the stock steps (watchOS: the app sleeps
/// between readings and its scanning is rationed). Called on the manager's queue.
protocol G7AcquisitionArm: AnyObject {
    /// In place of the stock retrieve-or-scan.
    func scan()
    /// In place of the stock connect to an adopted sensor.
    func found(_ peripheral: CBPeripheral)
    func connected(_ peripheral: CBPeripheral)
    /// True when the arm owns what happens next; false runs the stock rescan.
    func disconnected(_ peripheral: CBPeripheral, error: Error?) -> Bool
    func failedToConnect(_ peripheral: CBPeripheral, error: Error?) -> Bool
    func radioDown()
    /// A peripheral handed back by state restoration, after the stock adoption.
    func restored(_ peripheral: CBPeripheral)
    /// A reading's own sensor timestamp.
    func noteReading(at timestamp: Date)
    /// Any wake: put acquisition right if a lost callback left nothing standing.
    func recheck()
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
    var centralManager: CBCentralManager! = nil

    /// Whether the radio is usable: off, unauthorized, or on. Readable from
    /// any queue; changes are announced through
    /// `bluetoothManagerScanningStatusDidChange`.
    var centralState: CBManagerState {
        centralManager?.state ?? .unknown
    }

    /// Isolated to `managerQueue`
    var activePeripheral: CBPeripheral? {
        get {
            return activePeripheralManager?.peripheral
        }
    }

    /// Isolated to `managerQueue`
    var managedPeripherals: [UUID:G7PeripheralManager] = [:]

    /// The platform's acquisition arm, or nil for the stock steps. Set once in init, before the
    /// central can call back.
    private(set) var acquisitionArm: G7AcquisitionArm?

    private let lockedNeedsCodeForSensor = Locked<String?>(nil)
    private let lockedIsSearchingForSensor = Locked(false)

    /// The sensor a direct connection would reach without a pairing code or key; nil once one exists.
    var needsCodeForSensor: String? { lockedNeedsCodeForSensor.value }

    /// Scanning for a sensor this controller has never connected to.
    var isSearchingForSensor: Bool { lockedIsSearchingForSensor.value }

    func setNeedsCodeForSensor(_ name: String?) {
        guard lockedNeedsCodeForSensor.value != name else { return }
        lockedNeedsCodeForSensor.value = name
        delegate?.bluetoothManagerStatusDidChange(self)
    }

    func setIsSearchingForSensor(_ searching: Bool) {
        guard lockedIsSearchingForSensor.value != searching else { return }
        lockedIsSearchingForSensor.value = searching
        delegate?.bluetoothManagerStatusDidChange(self)
    }

    var activePeripheralIdentifier: UUID? {
        get {
            return lockedPeripheralIdentifier.value
        }
    }
    private let lockedPeripheralIdentifier: Locked<UUID?> = Locked(nil)

    /// Targets a known peripheral directly, so a relaunch can retrieve it by
    /// identifier instead of waiting for its next advertisement. Passing nil
    /// reopens the search to any sensor in range.
    func setActivePeripheralIdentifier(_ identifier: UUID?) {
        lockedPeripheralIdentifier.value = identifier
    }

    /// Isolated to `managerQueue`
    var activePeripheralManager: G7PeripheralManager? {
        didSet {
            oldValue?.delegate = nil
            lockedPeripheralIdentifier.value = activePeripheralManager?.peripheral.identifier
            let identifier = activePeripheralManager?.peripheral.identifier
            if identifier != oldValue?.peripheral.identifier, !suppressAdoptNotification {
                delegate?.bluetoothManager(self, didAdoptPeripheral: identifier)
            }
        }
    }

    /// C-216-A: wall-clock of the most recent `didDiscover` (any peripheral, bound or not), for the
    /// `rssi_age_s=` staleness stamp on `attach_path`/`connect_timeout` telemetry. Isolated to
    /// `managerQueue` (written only from `centralManager(_:didDiscover:...)`, which already
    /// dispatch-preconditions onto it).
    private var lastDiscoverAt: Date?
    /// C-216-A: RSSI from that same most recent `didDiscover`. Isolated to `managerQueue` alongside
    /// `lastDiscoverAt` — always written/read together.
    private var lastDiscoverRSSI: Int?

    /// C-207-2: `true` once a real-time glucose message has been parsed on the current connection.
    /// Reset to `false` when a connect is issued (`connectIfNotInFlight`); set to `true` by
    /// `noteGlucoseReceived()`. A disconnect with this still `false` means the transmitter dropped
    /// *before* delivering an EGV (pre-auth / pre-EGV), so the stock rescan after a link ended does
    /// not wait the 2s post-EGV shutdown grace. Isolated to `managerQueue`.
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
        /// Start delay (s) carried by the connect the watchdog is watching, so a deliberately delayed
        /// reconnect (see `reconnectStartDelay`) is not mistaken for a wedge before the delay ends.
        var connectStartDelay: TimeInterval = 0
    }
    private var bindingState = BindingBLEState()
    /// TRIO-101: identifier of a restored, already-connected active peripheral whose `didConnect`
    /// could not run at `willRestoreState` because the central was not yet `.poweredOn`. Consumed
    /// (and always cleared) at the next `.poweredOn`. managerQueue-isolated.
    private var pendingRestoredConnectedResume: UUID?
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
    /// connectIfNotInFlight is skipped as in_flight (the build-211 multi-hour stall).
    /// TRIO-101: the G7 sensor only wakes and advertises every 300 s, so a healthy pending connect
    /// legitimately sits in `.connecting` for up to one full sensor period. The timeout must therefore
    /// exceed that period: 300 s + a 30 s margin. The old 60 s value (justified as "under the 5-min
    /// cadence") fired on every healthy pending connect and, when it fired late at the instant the
    /// sensor's didConnect woke a suspended app, cancelled the live link (build 236 field data). A
    /// connect lodged with a start delay is given that delay on top.
    static let connectAttemptTimeout: TimeInterval = 330
    /// TRIO-101: a watchdog tick this much later than its intended deadline means the process was
    /// very likely suspended and has just been woken (often by this very connection completing).
    static let connectWatchdogLateTickThreshold: TimeInterval = 10
    /// TRIO-101: delay of the single re-check that follows a deferred late tick.
    static let connectWatchdogRecheckDelay: TimeInterval = 3

    /// TRIO-101: what a connect-watchdog tick should do.
    enum ConnectWatchdogAction: Equatable {
        case deferRecheck, cancelAndRewatch, escalate, rewatch, reissue, settled
    }

    /// TRIO-101: pure decision shared by the bound (C-212-1) and discovery (C-216-W7) watchdogs.
    /// A `.connecting` tick that is late (> threshold) and not already a re-check is deferred rather
    /// than cancelled; the re-check (`alreadyDeferred`) never defers again.
    static func connectWatchdogAction(
        state: CBPeripheralState,
        lateness: TimeInterval,
        alreadyDeferred: Bool,
        wedgeTicksAfterThisTick: Int,
        escalationEnabled: Bool
    ) -> ConnectWatchdogAction {
        switch state {
        case .connecting:
            if lateness > connectWatchdogLateTickThreshold, !alreadyDeferred { return .deferRecheck }
            if wedgeTicksAfterThisTick >= 2, escalationEnabled { return .escalate }
            return .cancelAndRewatch
        case .disconnecting:
            return .rewatch
        case .disconnected:
            return .reissue
        case .connected:
            return .settled
        @unknown default:
            return .settled
        }
    }
    /// C-217 Task 4: minimum interval between `reinitCentral` calls — prevents a re-init loop when
    /// the wedge persists across central swaps.
    private static let centralReinitMinInterval: TimeInterval = 120

    /// Called on `managerQueue` when a real-time EGV is parsed: marks this connection as having
    /// delivered glucose and stamps the binding-scoped last-EGV time.
    func noteGlucoseReceived() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        receivedGlucoseSinceConnect = true
        bindingState.lastGlucoseAt = Date()
    }

    /// Set while `reinitCentral` drops the peripheral manager, so the delegate is not told the sensor
    /// was let go of (a watch's stored binding would be erased by it). Isolated to `managerQueue`.
    private var suppressAdoptNotification = false

    // MARK: - Synchronization

    let managerQueue = DispatchQueue(label: "com.loudnate.CGMBLEKit.bluetoothManagerQueue", qos: .unspecified)

    /// Whether a `.poweredOn` recheck is already pending. Confined to `managerQueue`.
    private var poweredOnRecheckScheduled = false

    /// Consecutive rechecks that still saw a non-`.poweredOn` state, and how
    /// often we have rebuilt the central because of it. Confined to `managerQueue`.
    private var poweredOnRecheckCount = 0
    private var centralRecreationCount = 0

    /// How long to tolerate a stuck state before rebuilding the central.
    private static let poweredOnRecheckInterval: TimeInterval = 3
    private static let poweredOnRechecksBeforeRecreating = 10
    private static let maximumCentralRecreations = 5

    /// The sensor advertises for other displays for ~20–24 s after closing a link; a connect into
    /// that tail fails, and repeated failures make CoreBluetooth demand a very strong signal.
    /// Whole seconds: CoreBluetooth rejects a fractional start delay as an invalid parameter.
    static let reconnectStartDelay = 30

    /// There is exactly one of these per session, and a pairing run borrows
    /// it rather than building a second: only one central per app may claim
    /// the restore identifier, and sharing the central is what lets the
    /// session adopt the connection pairing just authenticated instead of
    /// dropping it and waiting for the sensor's next advertisement.
    override init() {
        super.init()

        managerQueue.sync {
            #if os(watchOS)
            let enabled = G7BackgroundHints.isWatchAcquisitionArmEnabled
            self.acquisitionArm = enabled ? G7WatchAcquisition(manager: self) : nil
            emitG7Telemetry("watch_acquisition_mode", "arm=\(enabled ? "upstream" : "stock")")
            #else
            self.acquisitionArm = nil
            #endif
            self.centralManager = self.makeCentralManager(queue: self.managerQueue)
        }
    }

    /// Factory seam so tests can substitute a central manager without the state
    /// restoration option, which raises an exception outside an app with the
    /// bluetooth-central background mode.
    func makeCentralManager(queue: DispatchQueue) -> CBCentralManager {
        return CBCentralManager(delegate: self, queue: queue, options: [CBCentralManagerOptionRestoreIdentifierKey: "com.loudnate.CGMBLEKit"])
    }

    // MARK: - Actions

    // Fire-and-forget onto the manager queue, which keeps callers' order: a synchronous hop from
    // the main thread can wait behind a multi-second handshake and trip the system watchdog.
    func scanForPeripheral() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.async {
            self.managerQueue_scanForPeripheral()
        }
    }

    /// Re-derives the watch's acquisition from the central's own state on a wake; nothing on the phone.
    func recheckAcquisition() {
        managerQueue.async {
            guard self.delegate != nil, self.centralManager.state == .poweredOn,
                  (self.activePeripheral?.state ?? .disconnected) != .connected else { return }
            self.acquisitionArm?.recheck()
        }
    }

    func forgetPeripheral() {
        managerQueue.async {
            self.activePeripheralManager = nil
            // C-210-6/7 (review A/B/C/D): binding reset. Reset binding-scoped recovery state in one
            // shot and bump the generation so any in-flight delayed retry from the prior binding no-ops;
            // drop stale managed peripherals so their late disconnect callbacks can't touch the new
            // binding's connection state. Reached via scanForNewSensor (sensor swap / EOS /
            // session-end) and pairing teardown, NOT from a normal disconnect().
            self.bindingState = BindingBLEState()
            self.bindingGeneration += 1
            self.managedPeripherals.removeAll()
            self.receivedGlucoseSinceConnect = false
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

    func stopScanning() {
        managerQueue.async {
            self.managerQueue_stopScanning()
        }
    }

    func managerQueue_stopScanning() {
        if centralManager.isScanning {
            log.default("Stopping scan")
            centralManager.stopScan()
            delegate?.bluetoothManagerScanningStatusDidChange(self)
        }
    }

    func disconnect() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))
        managerQueue.async { self.managerQueue_disconnect() }
    }

    private func managerQueue_disconnect() {
        dispatchPrecondition(condition: .onQueue(managerQueue))
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

    /// A reading's own sensor timestamp, for the acquisition arm: each glucose message, and the
    /// saved last reading at launch.
    func noteReading(at readingTimestamp: Date) {
        guard let arm = acquisitionArm else { return }
        managerQueue.async { arm.noteReading(at: readingTimestamp) }
    }

    /// Makes `peripheralManager` the active peripheral, keeping its connection,
    /// and drops every other managed peripheral. This is the hand-off at the
    /// end of pairing: the candidate that authenticated becomes the session's
    /// sensor without a disconnect in between.
    func adoptAsActive(_ peripheralManager: G7PeripheralManager) {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            managerQueue_stopScanning()

            for (identifier, other) in managedPeripherals where other !== peripheralManager {
                centralManager.cancelPeripheralConnection(other.peripheral)
                managedPeripherals.removeValue(forKey: identifier)
            }

            if activePeripheralManager !== peripheralManager {
                activePeripheralManager = peripheralManager
                // Pairing candidates' connect attempts must not rate-gate the first reconnect after adoption.
                bindingState.recentConnectIssueTimes = []
            }
            peripheralManager.delegate = self
            peripheralManager.reclaimPeripheral()
            managedPeripherals[peripheralManager.peripheral.identifier] = peripheralManager
        }
    }

    /// Cancels every managed peripheral's connection, not just the active one.
    /// The pairing run needs this: its candidates are never made active (there
    /// is no sensor ID yet), so `disconnect()` would leave them connected.
    func disconnectAll() {
        dispatchPrecondition(condition: .notOnQueue(managerQueue))

        managerQueue.sync {
            managerQueue_stopScanning()

            for peripheralManager in managedPeripherals.values {
                centralManager.cancelPeripheralConnection(peripheralManager.peripheral)
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
            // Preserve the pre-208 discovery-mode behavior — when unbound, ANY connection event
            // (incl. `.peerDisconnected`, i.e. another app just released the sensor's system
            // connection) triggered discovery handling. For the bound case, only `.peerConnected`
            // attaches.
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

        // `didDisconnectPeripheral` always rescans, which keeps us alive for a
        // couple of seconds past release. A pairing run that has finished must
        // not start scanning again in that window: the sensor it just paired
        // admits one display, and the session manager is claiming it.
        guard delegate != nil else {
            log.default("Not scanning: no delegate")
            return
        }

        guard centralManager.state == .poweredOn else {
            schedulePoweredOnRecheck()
            return
        }

        poweredOnRecheckCount = 0

        let currentState = activePeripheral?.state ?? .disconnected
        guard currentState != .connected else {
            log.default("Not scanning: active peripheral is connected")
            return
        }

        if let arm = acquisitionArm {
            arm.scan()
            return
        }

        // Leave a pending (delayed) reconnect alone; a plain connect now could land in the advertising tail.
        guard currentState != .connecting else {
            log.default("Not scanning: active peripheral has a connect pending")
            return
        }

        if let peripheralID = activePeripheralIdentifier, let peripheral = centralManager.retrievePeripherals(withIdentifiers: [peripheralID]).first {
            log.default("Retrieved peripheral %{public}@", peripheral.identifier.uuidString)
            emitG7Telemetry("attach_path", "path=stored_id peripheral=\(peripheral.identifier.uuidString) \(rssiTelemetrySuffix())")
            handleDiscoveredPeripheral(peripheral)
        } else {
            emitG7Telemetry("attach_path", "path=miss has_identifier=\(activePeripheralIdentifier != nil) \(rssiTelemetrySuffix())")
            if let peripheralID = activePeripheralIdentifier {
                log.default("Could not retrieve peripheral %{public}@; active peripheral %{public}@", peripheralID.uuidString, activePeripheral?.identifier.uuidString ?? "none")
            }
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
    /// CoreBluetooth lies about its state at creation: a central built while
    /// another is being torn down can report `.unknown` or even `.unsupported`
    /// and then never send a corrective `didUpdateState`, leaving the manager
    /// permanently convinced Bluetooth is unavailable. Poll our way out, and
    /// rebuild the central if the state stays stuck.
    private func schedulePoweredOnRecheck() {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard !poweredOnRecheckScheduled, delegate != nil else {
            return
        }
        poweredOnRecheckScheduled = true

        managerQueue.asyncAfter(deadline: .now() + G7BluetoothManager.poweredOnRecheckInterval) { [weak self] in
            guard let self = self else { return }
            self.poweredOnRecheckScheduled = false

            guard self.delegate != nil else {
                return
            }
            guard self.centralManager.state != .poweredOn else {
                self.poweredOnRecheckCount = 0
                self.managerQueue_scanForPeripheral()
                return
            }

            self.poweredOnRecheckCount += 1
            self.log.default(
                "Bluetooth still %{public}@ after %{public}d rechecks",
                String(describing: self.centralManager.state.rawValue),
                self.poweredOnRecheckCount
            )

            let isStuckState = self.centralManager.state == .unknown || self.centralManager.state == .unsupported
            if isStuckState,
               self.poweredOnRecheckCount >= G7BluetoothManager.poweredOnRechecksBeforeRecreating,
               self.centralRecreationCount < G7BluetoothManager.maximumCentralRecreations,
               self.managedPeripherals.isEmpty
            {
                self.log.error("Recreating central manager stuck at %{public}@", String(describing: self.centralManager.state.rawValue))
                self.centralRecreationCount += 1
                self.poweredOnRecheckCount = 0
                self.centralManager.delegate = nil
                self.centralManager = self.makeCentralManager(queue: self.managerQueue)
            }

            self.schedulePoweredOnRecheck()
        }
    }

    /// Lodges the active peripheral's reconnect at once, so it stands even if the app is suspended,
    /// with a start delay that lets the sensor's advertising tail pass first.
    private func reconnectAfterAdvertisingTail(_ peripheral: CBPeripheral) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        reconnectLog("Reconnecting with a \(G7BluetoothManager.reconnectStartDelay) s start delay")
        handleDiscoveredPeripheral(peripheral, connectOptions: [CBConnectPeripheralOptionStartDelayKey: NSNumber(value: G7BluetoothManager.reconnectStartDelay)])
    }

    /// To both the system log and the host's device log, so field reports show it.
    private func reconnectLog(_ line: String) {
        log.default("%{public}@", line)
        delegate?.bluetoothManager(self, logEvent: line)
    }

    /// Why a link ended, which decides how we reconnect (TRIO-101).
    enum LinkEndCause {
        /// The sensor closed the link (`CBError.peripheralDisconnected`).
        case remoteClose
        /// We cancelled it (watchdog, explicit cancel), or it ended with any other error.
        case localCancel
        /// `didFailToConnect`.
        case failedToConnect

        var telemetryName: String {
            switch self {
            case .remoteClose: return "remote_close"
            case .localCancel: return "local_cancel"
            case .failedToConnect: return "failed_to_connect"
            }
        }
    }

    enum ReconnectPlan: Equatable {
        case startDelay(seconds: Int)
        case rescan(afterSeconds: TimeInterval)
    }

    /// TRIO-101: whether a restored peripheral must be resumed by hand. CoreBluetooth does not
    /// re-deliver `didConnect` for a link that was already up when it restored the app, and on
    /// watchOS without the acquisition arm nothing else (the arm's `restored()` does it) starts
    /// auth and the session. True only for watchOS + no arm + active binding + `.connected`.
    static func shouldResumeRestoredConnected(isWatchOS: Bool, armActive: Bool, isActivePeripheral: Bool, state: CBPeripheralState) -> Bool {
        return isWatchOS && !armActive && isActivePeripheral && state == .connected
    }

    /// Chooses the reconnect mode by WHY the link ended (TRIO-101).
    /// - Not the active peripheral, or central not poweredOn: rescan. C-207-2: the 2 s grace lets the
    ///   transmitter finish its normal between-reading shutdown AFTER it has delivered an EGV; with no
    ///   glucose yet (pre-auth / pre-EGV) it is likely still advertising, so rescan at once.
    /// - watchOS (stock path only; the arm path returns before this): upstream never runs the start
    ///   delay there because the option doesn't seem to work. Build 236 applied it anyway and watch
    ///   EGV fell from ~4.3/h to 1.4/h, so rescan as 235 did.
    /// - iOS, sensor closed the link: it is about to sit in its ~20–24 s advertising tail, so use the
    ///   start delay to keep the reconnect out of it.
    /// - iOS, our own cancel or a failed connect: the sensor is usually still mid-window. 235 rescanned
    ///   at once and recaught the burst; 236's 30 s delay missed it. Rescan.
    static func reconnectPlan(cause: LinkEndCause, isActivePeripheral: Bool, centralPoweredOn: Bool, isWatchOS: Bool, hadGlucose: Bool) -> ReconnectPlan {
        let rescan = ReconnectPlan.rescan(afterSeconds: hadGlucose ? 2 : 0)
        guard isActivePeripheral, centralPoweredOn else { return rescan }
        if isWatchOS { return rescan }
        switch cause {
        case .remoteClose:
            return .startDelay(seconds: reconnectStartDelay)
        case .localCancel, .failedToConnect:
            return rescan
        }
    }

    /// Stock path only (no arm): picks start-delay reconnect or rescan per `reconnectPlan`.
    private func resumeAfterLinkEnded(_ peripheral: CBPeripheral, cause: LinkEndCause) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        #if os(watchOS)
        let isWatchOS = true
        #else
        let isWatchOS = false
        #endif
        let plan = G7BluetoothManager.reconnectPlan(
            cause: cause,
            isActivePeripheral: peripheral == activePeripheral,
            centralPoweredOn: centralManager.state == .poweredOn,
            isWatchOS: isWatchOS,
            hadGlucose: receivedGlucoseSinceConnect
        )
        switch plan {
        case .rescan(let settleDelay):
            // C-208-15: observability only — makes the self-initiated rescan visible in telemetry.
            emitG7Telemetry("rescan_scheduled", "delay_s=\(Int(settleDelay)) had_glucose=\(receivedGlucoseSinceConnect) mode=rescan cause=\(cause.telemetryName)")
            managerQueue.asyncAfter(deadline: .now() + settleDelay) { [weak self] in
                self?.managerQueue_scanForPeripheral()
            }
        case .startDelay(let seconds):
            emitG7Telemetry("rescan_scheduled", "delay_s=\(seconds) had_glucose=\(receivedGlucoseSinceConnect) mode=start_delay cause=\(cause.telemetryName)")
            reconnectAfterAdvertisingTail(peripheral)
        }
    }

    /// C-216-A: shared `last_rssi=`/`rssi_age_s=` suffix for the `attach_path` and `connect_timeout`
    /// emits, so the sentinel values (127 = BT-spec "RSSI not available", -1 = "no discover yet")
    /// are defined in exactly one place rather than repeated at each call site.
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
    /// dedup is observable in telemetry. `options` carries the delayed-reconnect start delay.
    private func connectIfNotInFlight(_ peripheral: CBPeripheral, options: [String: Any]? = nil) {
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
                        // An adopted attempt may be a start-delayed reconnect lodged before a relaunch.
                        bindingState.connectStartDelay = TimeInterval(G7BluetoothManager.reconnectStartDelay)
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
        centralManager.connect(peripheral, options: options)
        // C-212-1: arm a timeout for the active binding's connect so a wedged `.connecting` attempt
        // (no didConnect / didFailToConnect) can't stall recovery indefinitely. Active binding only.
        if peripheral.identifier == activePeripheralIdentifier {
            bindingState.connectIssuedAt = now
            bindingState.connectWedgeTicks = 0
            bindingState.wedgePersistentEmitted = false
            bindingState.connectStartDelay = (options?[CBConnectPeripheralOptionStartDelayKey] as? NSNumber)?.doubleValue ?? 0
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
    /// Cancelling the EGV-silent connection drives the existing disconnect → `resumeAfterLinkEnded`
    /// path, reconnecting onto the window the connection event signalled. The reconnect is still
    /// subject to the C-210-7 gate, and the `lastRekickAt` debounce bounds how often this can fire —
    /// so a persistent stall cannot storm.
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
    /// binding has a pending connect (connectIssuedAt set), re-check every `connectAttemptTimeout`
    /// (330 s, TRIO-101; the first check also waits out a start-delayed reconnect's `connectStartDelay`):
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
    /// TRIO-101: the timeout is 330 s (one 300 s sensor period + margin). Each tick records its
    /// intended deadline; if a `.connecting` tick runs more than `connectWatchdogLateTickThreshold`
    /// late, the process was suspended and likely just woken by this connection completing, so it is
    /// NOT cancelled: emit `connect_timeout_deferred` and re-check once `connectWatchdogRecheckDelay`
    /// later (same guards, no further deferral, no wedge tick counted). The deferral replaces the
    /// tick — still exactly one pending closure.
    private func scheduleConnectTimeout(_ peripheral: CBPeripheral, deferredRecheck: Bool = false) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let gen = bindingGeneration
        let pid = peripheral.identifier
        let issuedAt = bindingState.connectIssuedAt
        // Only the first tick after an issue carries the start delay; a re-armed tick follows a cancel
        // + re-issue (which sets a fresh delay of its own) or a plain cancel-and-wait.
        let startDelay = bindingState.connectWedgeTicks == 0 ? bindingState.connectStartDelay : 0
        let delay = deferredRecheck ? Self.connectWatchdogRecheckDelay : Self.connectAttemptTimeout + startDelay
        let intendedAt = Date().addingTimeInterval(delay)
        managerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self else { return }
            guard self.bindingGeneration == gen,
                  self.activePeripheralIdentifier == pid,
                  self.bindingState.connectIssuedAt == issuedAt,
                  let peripheral = self.activePeripheral, peripheral.identifier == pid else { return }
            let lateness = Date().timeIntervalSince(intendedAt)
            let action = Self.connectWatchdogAction(
                state: peripheral.state,
                lateness: lateness,
                alreadyDeferred: deferredRecheck,
                wedgeTicksAfterThisTick: self.bindingState.connectWedgeTicks + 1,
                escalationEnabled: G7BackgroundHints.isConnectWedgeEscalationEnabled
            )
            switch action {
            case .deferRecheck:
                emitG7Telemetry(
                    "connect_timeout_deferred",
                    "peripheral=\(pid.uuidString) lateness_s=\(Int(lateness)) scope=bound"
                )
                self.scheduleConnectTimeout(peripheral, deferredRecheck: true)
            case .escalate, .cancelAndRewatch:
                self.bindingState.connectWedgeTicks += 1
                let ticks = self.bindingState.connectWedgeTicks
                let ageS = Int(Date().timeIntervalSince(issuedAt ?? Date()))
                if action == .escalate {
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
                emitG7Telemetry(
                    "connect_timeout",
                    "peripheral=\(pid.uuidString) age_s=\(ageS) lateness_s=\(Int(lateness)) \(self.rssiTelemetrySuffix())"
                )
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.scheduleConnectTimeout(peripheral)
            case .rewatch:
                self.scheduleConnectTimeout(peripheral)
            case .reissue:
                emitG7Telemetry("connect_timeout_reissue", "peripheral=\(pid.uuidString)")
                self.managerQueue_scanForPeripheral()
                // review #2: if the reissue didn't start a new connect (gated / retrieve-miss /
                // delegate .ignore), connectIssuedAt is unchanged and no fresh watchdog was armed —
                // keep watching so a gated tick can't strand recovery.
                if self.bindingState.connectIssuedAt == issuedAt {
                    self.scheduleConnectTimeout(peripheral)
                }
            case .settled:
                // review #4: normally didConnect already cleared the marker (we never reach here);
                // clear defensively in case that callback was missed, then stop.
                if peripheral.state == .connected {
                    self.bindingState.connectIssuedAt = nil
                }
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
        // Drop the wedged peripheral reference, but keep the binding's identifier: the fresh central
        // retrieves the sensor by it on the next poweredOn scan path. The adoption callback is
        // suppressed because upstream's delegate persists a nil adoption as "sensor let go of"
        // (it would clear the stored peripheral identifier of a configured-by-another-controller sensor).
        let boundIdentifier = activePeripheralIdentifier
        bindingState = BindingBLEState()
        // Old central's daemon requests die with it; clear lodged state so relodge() on the new central isn't a no-op.
        acquisitionArm?.radioDown()
        bindingGeneration += 1
        pendingDiscoveryConnects.removeAll()
        managedPeripherals.removeAll()
        suppressAdoptNotification = true
        activePeripheralManager = nil
        suppressAdoptNotification = false
        lockedPeripheralIdentifier.value = boundIdentifier
        receivedGlucoseSinceConnect = false
        lastCentralReinitAt = Date()
        centralManager = makeCentralManager(queue: managerQueue)
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
    private func scheduleDiscoveryConnectTimeout(_ peripheral: CBPeripheral, deferredRecheck: Bool = false) {
        dispatchPrecondition(condition: .onQueue(managerQueue))
        let pid = peripheral.identifier
        let issuedAt = pendingDiscoveryConnects[pid]
        // TRIO-101: same 330 s timeout and late-tick deferral as the bound watchdog (scope=discovery).
        let delay = deferredRecheck ? Self.connectWatchdogRecheckDelay : Self.connectAttemptTimeout
        let intendedAt = Date().addingTimeInterval(delay)
        managerQueue.asyncAfter(deadline: .now() + delay) { [weak self] in
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
            let lateness = Date().timeIntervalSince(intendedAt)
            let action = Self.connectWatchdogAction(
                state: peripheral.state,
                lateness: lateness,
                alreadyDeferred: deferredRecheck,
                wedgeTicksAfterThisTick: 0,
                escalationEnabled: false
            )
            switch action {
            case .deferRecheck:
                emitG7Telemetry(
                    "connect_timeout_deferred",
                    "peripheral=\(pid.uuidString) lateness_s=\(Int(lateness)) scope=discovery"
                )
                self.scheduleDiscoveryConnectTimeout(peripheral, deferredRecheck: true)
            case .cancelAndRewatch, .escalate:
                let ageS = Int(Date().timeIntervalSince(issuedAt))
                emitG7Telemetry("discovery_connect_timeout", "peripheral=\(pid.uuidString) age_s=\(ageS)")
                self.centralManager.cancelPeripheralConnection(peripheral)
                self.scheduleDiscoveryConnectTimeout(peripheral)
            case .rewatch:
                self.scheduleDiscoveryConnectTimeout(peripheral)
            case .reissue:
                self.pendingDiscoveryConnects.removeValue(forKey: pid)
                emitG7Telemetry("discovery_connect_timeout_rescan", "peripheral=\(pid.uuidString)")
                self.managerQueue_scanForPeripheral()
            case .settled:
                if peripheral.state == .connected {
                    self.pendingDiscoveryConnects.removeValue(forKey: pid)
                }
            }
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

    /// The manager already attached to this peripheral, if there is one. A
    /// candidate dropped from `managedPeripherals` on disconnect is still the
    /// peripheral's delegate, and may still have a handshake running; a
    /// second manager would take the delegate role from it, and its commands
    /// would never hear back.
    private func makeOrReusePeripheralManager(_ peripheral: CBPeripheral) -> G7PeripheralManager {
        if let existing = peripheral.delegate as? G7PeripheralManager {
            return existing
        }
        return G7PeripheralManager(peripheral: peripheral, configuration: .dexcomG7, centralManager: centralManager)
    }

    func handleDiscoveredPeripheral(_ peripheral: CBPeripheral, advertisementData: [String: Any] = [:], rssi: NSNumber = 127, connectOptions: [String: Any]? = nil) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        if let delegate = delegate {
            switch delegate.bluetoothManager(self, shouldConnectPeripheral: peripheral, advertisementData: advertisementData, rssi: rssi) {
            case .makeActive:
                log.default("Making peripheral active: %{public}@", peripheral.identifier.uuidString)

                // C-210-6 (review round 3, M-a / High#2): a re-bind to a DIFFERENT peripheral changes
                // the binding WITHOUT going through forgetPeripheral. Reset binding-scoped recovery
                // state + bump the generation so prior-binding stall/throttle/retry state can't leak in
                // and a pending gated-retry closure no-ops. Steady-state reconnects (same id) skip this.
                if activePeripheralIdentifier != peripheral.identifier {
                    bindingState = BindingBLEState()
                    bindingGeneration += 1
                }

                if let peripheralManager = activePeripheralManager {
                    if peripheralManager.peripheral.identifier != peripheral.identifier {
                        delegate.bluetoothManager(self, didAdoptPeripheral: peripheral.identifier)
                    }
                    peripheralManager.peripheral = peripheral
                    // Swapping `.peripheral` on the existing manager does NOT fire the
                    // activePeripheralManager didSet that maintains activePeripheralIdentifier, so set it
                    // explicitly — otherwise the re-kick/retry guards compare against a stale UUID (M-a).
                    lockedPeripheralIdentifier.value = peripheral.identifier
                } else {
                    activePeripheralManager = makeOrReusePeripheralManager(peripheral)
                    activePeripheralManager?.delegate = self
                }
                self.managedPeripherals[peripheral.identifier] = activePeripheralManager
                if let arm = acquisitionArm {
                    arm.found(peripheral)
                } else {
                    self.connectIfNotInFlight(peripheral, options: connectOptions)
                }

            case .connect:
                // Pairing hears repeat advertisements from the same candidate;
                // building a second manager for one peripheral leaves the first
                // as an orphaned delegate and loses handshake traffic.
                if let existingManager = self.managedPeripherals[peripheral.identifier] {
                    existingManager.peripheral = peripheral
                    if peripheral.state != .connected, peripheral.state != .connecting {
                        log.default("Reconnecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                        self.connectIfNotInFlight(peripheral)
                    }
                } else {
                    log.default("Connecting to peripheral: %{public}@", peripheral.identifier.uuidString)
                    let peripheralManager = makeOrReusePeripheralManager(peripheral)
                    peripheralManager.delegate = self
                    self.managedPeripherals[peripheral.identifier] = peripheralManager
                    self.connectIfNotInFlight(peripheral)
                }
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
            // TRIO-101: willRestoreState precedes poweredOn, so a restored, already-connected active
            // peripheral could not be resumed there (didConnect's readied call is gated on
            // .poweredOn). Always clear the marker so a later poweredOn after a radio reset cannot
            // act on a stale one.
            let pendingResume = pendingRestoredConnectedResume
            pendingRestoredConnectedResume = nil
            if let pendingResume = pendingResume {
                if acquisitionArm != nil {
                    emitG7Telemetry("restored_connected_resume_skipped", "reason=arm_on peripheral=\(pendingResume.uuidString)")
                } else if let active = activePeripheral, active.identifier == pendingResume {
                    if active.state == .connected {
                        emitG7Telemetry("restored_connected_resumed", "timing=powered_on peripheral=\(pendingResume.uuidString)")
                        self.centralManager(central, didConnect: active)
                    } else {
                        emitG7Telemetry("restored_connected_resume_skipped", "reason=not_connected peripheral=\(pendingResume.uuidString)")
                    }
                } else {
                    emitG7Telemetry("restored_connected_resume_skipped", "reason=not_active peripheral=\(pendingResume.uuidString)")
                }
            }
            managerQueue_scanForPeripheral()
        case .resetting, .poweredOff, .unauthorized, .unknown, .unsupported:
            fallthrough
        @unknown default:
            acquisitionArm?.radioDown()
            if central.isScanning {
                log.default("Stopping scan on central not powered on")
                central.stopScan()
            }
        }
        delegate?.bluetoothManagerScanningStatusDidChange(self)
    }

    // A daemon-held connect relaunches the app for the link; this is where the relaunch hands it back.
    func centralManager(_ central: CBCentralManager, willRestoreState dict: [String : Any]) {
        dispatchPrecondition(condition: .onQueue(managerQueue))

        guard delegate?.bluetoothManagerShouldAcceptRestoredPeripherals(self) ?? true else {
            log.default("Ignoring restored peripherals: delegate is not accepting them")
            return
        }

        let restoredPeripherals = dict[CBCentralManagerRestoredStatePeripheralsKey] as? [CBPeripheral]
        // M2: make CB state restoration observable in telemetry. `willRestoreState` previously logged
        // only via OSLog (invisible to BetterStack), so whether watchOS ever relaunches us for BLE was
        // unmeasurable. C-217 Task 4: since_reinit_s + restored_ids observe restore-identifier reuse — a
        // small since_reinit_s is the undocumented in-process replay; restored_ids shows wedged re-inheritance.
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
            let line = "RESTORED by the system — relaunched for Bluetooth with \(peripherals.count) peripheral(s): "
                + peripherals.map { "\($0.name ?? "unnamed") state=\($0.state.rawValue)" }.joined(separator: ", ")
            log.default("%{public}@", line)
            delegate?.bluetoothManager(self, logEvent: line)
            for peripheral in peripherals {
                log.default("Restoring peripheral from state: %{public}@", peripheral.identifier.uuidString)
                handleDiscoveredPeripheral(peripheral)
                acquisitionArm?.restored(peripheral)
            }

            // TRIO-101: restore does not re-deliver didConnect for a link already up, and with the
            // arm off nothing else starts auth/session (52 of 236-export relaunches had the active
            // sensor connected; 50 never got didConnect). willRestoreState precedes poweredOn, so
            // resume now only if the radio is already on; otherwise defer to poweredOn.
            pendingRestoredConnectedResume = nil
            #if os(watchOS)
            let isWatchOS = true
            #else
            let isWatchOS = false
            #endif
            if let peripheral = peripherals.first(where: { $0.identifier == activePeripheralIdentifier }),
               Self.shouldResumeRestoredConnected(
                   isWatchOS: isWatchOS,
                   armActive: acquisitionArm != nil,
                   isActivePeripheral: true,
                   state: peripheral.state
               ) {
                if central.state == .poweredOn {
                    emitG7Telemetry("restored_connected_resumed", "timing=immediate peripheral=\(peripheral.identifier.uuidString)")
                    self.centralManager(central, didConnect: peripheral)
                } else {
                    pendingRestoredConnectedResume = peripheral.identifier
                }
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
            self.handleDiscoveredPeripheral(peripheral, advertisementData: advertisementData, rssi: RSSI)
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
        acquisitionArm?.connected(peripheral)

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
        // TRIO-101: why the link ended decides the reconnect mode (see `reconnectPlan`).
        let cause: LinkEndCause
        if let error = error as NSError?, CBError(_nsError: error).code == .peripheralDisconnected {
            cause = .remoteClose
        } else {
            cause = .localCancel
        }
        // C-210-6 (review A): clear the connection clock only when the ACTIVE binding disconnects, so
        // a stray non-active peripheral's disconnect can't suppress re-kick for the active zombie.
        if peripheral.identifier == activePeripheralIdentifier {
            bindingState.currentConnectionStartedAt = nil
        }
        // C-212-1 (review #1): do NOT clear connectIssuedAt here. A belated callback from a CANCELLED
        // connect can arrive after the watchdog already re-issued a new connect; clearing the marker
        // then would kill the NEW attempt's watchdog and re-wedge. connectIssuedAt is owned by connect
        // issue (set) and the watchdog (which clears it on a `.connected` tick); the reconnect below
        // reissues and overwrites it.
        log.default("%{public}@: %{public}@", #function, peripheral)
        // Ignore errors indicating the peripheral disconnected remotely, as that's expected behavior
        if let error = error as NSError?, CBError(_nsError: error).code != .peripheralDisconnected {
            log.error("%{public}@: %{public}@", #function, error)
            if let peripheralManager = activePeripheralManager {
                self.delegate?.bluetoothManager(self, readyingFailed: peripheralManager, with: error)
            }
        }

        if let peripheralManager = managedPeripherals[peripheral.identifier] {
            self.delegate?.peripheralDidDisconnect(self, peripheralManager: peripheralManager, wasRemoteDisconnect: cause == .remoteClose)
        }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        if acquisitionArm?.disconnected(peripheral, error: error) == true { return }
        resumeAfterLinkEnded(peripheral, cause: cause)
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

        if acquisitionArm?.failedToConnect(peripheral, error: error) == true { return }

        if peripheral != activePeripheral {
            managedPeripherals.removeValue(forKey: peripheral.identifier)
        }

        resumeAfterLinkEnded(peripheral, cause: .failedToConnect)
    }
}


extension G7BluetoothManager: G7PeripheralManagerDelegate {
    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?) {
        // C-216-A: result of the opportunistic `readRSSI()` issued in `didConnect`. Telemetry plus
        // the upstream forward — the discover-time sample in `lastDiscoverRSSI` is what
        // `attach_path`/`connect_timeout` stamp.
        emitG7Telemetry("rssi_read", "value=\(RSSI.intValue) error=\(error?.localizedDescription ?? "nil")")
        delegate?.bluetoothManager(self, peripheralManager: manager, didReadRSSI: RSSI, error: error)
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
        case .none, .communication?, .certificate?:
            // The certificate characteristic only carries handshake payloads,
            // which the authenticator collects through an installed handler.
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
