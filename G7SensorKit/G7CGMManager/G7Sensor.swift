//
//  G7Sensor.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 9/24/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import Foundation
import CoreBluetooth
import LoopKit
import os.log


/// Delegate for `G7Sensor` events.
///
/// **Queue contract (C-208-17):** every callback is invoked on `G7Sensor`'s private serial
/// `delegateQueue` — NOT the main thread, and NOT the internal Bluetooth `managerQueue`.
/// Implementations must hop to their own isolation context; do not block this queue.
public protocol G7SensorDelegate: AnyObject {
    /// Fired when a *followed* sensor's peripheral becomes ready (auth subscription armed).
    ///
    /// **Not guaranteed on first discovery (C-208-17):** when no sensor is being followed yet
    /// (`sensorID == nil` at readied time), the first-discovery cycle accepts the sensor inside
    /// the glucose-message handler and delivers `didRead` directly — this callback never fires
    /// for that session. Consumers keying session bookkeeping off this callback must also treat
    /// a `didRead` with no preceding connect as an implicit connect (see Trio's
    /// `G7WatchSensorAdapter` first-read bootstrap).
    func sensorDidConnect(_ sensor: G7Sensor, name: String)

    /// Fired when the followed sensor's connection ends.
    ///
    /// **`suspectedEndOfSession` is a heuristic, not a session-end signal (C-208-17):** it means
    /// "remote disconnect while authentication was still pending" (`pendingAuth &&
    /// wasRemoteDisconnect`). On a consumer with long-lived authenticated connections (iPhone)
    /// that pattern is rare and meaningful. On a passive observer with a per-window
    /// connect/auth/read/disconnect cadence (watch) it misfires on routine reconnects —
    /// measured 111/112 false-positive in build 205. Do NOT take destructive action (e.g.
    /// forgetting the sensor / rescanning for new) on this flag alone; corroborate with
    /// algorithm state or sensor age.
    func sensorDisconnected(_ sensor: G7Sensor, suspectedEndOfSession: Bool)

    func sensor(_ sensor: G7Sensor, didError error: Error)

    /// A received frame, as hex. Kept for the raw-receive lines.
    func sensor(_ sensor: G7Sensor, logComms comms: String)

    /// A device-log entry of the given type: sends as hex, connection events,
    /// handshake narration. Mirrors what the pump plugins record.
    func sensor(_ sensor: G7Sensor, log message: String, type: DeviceLogEntryType)

    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage)

    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage])

    /// If this returns true, then start following this sensor. The identifier is
    /// the peripheral the sensor was found under. It is passed explicitly because
    /// the sensor's own credentials are only updated after this returns.
    ///
    /// **Synchronous on `delegateQueue` (C-208-17):** the return value is consumed inline, so
    /// implementations cannot hop to an actor/main queue to answer — they must use
    /// synchronously-accessible state (e.g. `UserDefaults`). Keep it fast; the glucose message
    /// that triggered discovery is processed on the same queue right after this returns.
    func sensor(_ sensor: G7Sensor, didDiscoverNewSensor name: String, activatedAt: Date, peripheralIdentifier: UUID) -> Bool

    func sensor(_ sensor: G7Sensor, didReceive extendedVersion: ExtendedVersionMessage)

    func sensor(_ sensor: G7Sensor, didReceive transmitterVersion: TransmitterVersionMessage)

    /// The sensor's answer to a calibration we sent.
    func sensor(_ sensor: G7Sensor, didReceiveCalibrationResponse response: G7CalibrateRxMessage)

    /// A queued calibration grew too old to send before the sensor connected.
    func sensor(_ sensor: G7Sensor, didDiscardStaleCalibrationEnteredAt date: Date)

    /// The sensor's calibration state, after a calibration or on request.
    func sensor(_ sensor: G7Sensor, didReadCalibrationBounds bounds: G7CalibrationBoundsMessage)

    // This is triggered for connection/disconnection events, and enabling/disabling scan
    func sensorConnectionStatusDidUpdate(_ sensor: G7Sensor)

    /// Direct mode only: a handshake produced a new shared key, which the
    /// caller must persist so later reconnects can skip the key exchange.
    func sensor(_ sensor: G7Sensor, didAuthenticateWith sharedKey: Data, deviceName: String?, authenticity: G7SensorAuthenticity)

    /// Direct mode only: the stored shared key is no longer accepted by the
    /// sensor. It has been discarded; if a pairing code is still held, the
    /// next connection will run a full handshake.
    func sensorDidInvalidateSharedKey(_ sensor: G7Sensor)

    /// One line for the host's device log. Optional.
    func sensor(_ sensor: G7Sensor, logEvent line: String)

    /// A sensor passed in by another controller found its own peripheral (nil when it let go of
    /// one). Optional.
    func sensor(_ sensor: G7Sensor, didAdoptPeripheral identifier: UUID?)

    /// `needsCodeForSensor` or `isSearchingForSensor` changed. Optional.
    func sensorStatusDidChange(_ sensor: G7Sensor)

    /// The key from a pairing whose Bluetooth bond was never confirmed was refused: the pairing did not
    /// finish. The key has been discarded and the next connection pairs again. Optional.
    func sensorPairingDidNotFinish(_ sensor: G7Sensor)
}

public extension G7SensorDelegate {
    func sensor(_ sensor: G7Sensor, logEvent line: String) {}
    func sensor(_ sensor: G7Sensor, didAdoptPeripheral identifier: UUID?) {}
    func sensorStatusDidChange(_ sensor: G7Sensor) {}
    func sensorPairingDidNotFinish(_ sensor: G7Sensor) {}
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
    /// No sensor known and nothing to pair with: an eavesdropping session
    /// waiting for the Dexcom app to start one.
    case searching
    /// Direct mode with nothing to connect to yet: the CGM was added but no
    /// sensor has been paired.
    case unpaired
    /// Paired, but the sensor has not reported its first reading yet. It
    /// links only briefly around each 5-minute reading, so this can last a
    /// few minutes after pairing.
    case connecting
    case warmup
    case ok
    case failed
    case gracePeriod
    case expired
}

/// Everything needed to reach a particular sensor. Held behind a lock: the
/// handshake completes on the peripheral manager's queue, while scanning and
/// the public setters run elsewhere.
struct G7SensorCredentials: Equatable {
    /// The sensor's advertised name, which is also how a session recognizes
    /// its own sensor across reconnects.
    var sensorID: String?

    /// The 4-digit code printed on the applicator. Direct mode only, and only
    /// valid for the sensor it came with.
    var pairingCode: String?

    /// The key derived at pairing. Direct mode only; its presence is what
    /// lets a reconnect skip the key exchange.
    var sharedKey: Data?

    /// The paired sensor's CoreBluetooth identifier, so a relaunch can go
    /// straight to it instead of waiting for an advertisement.
    var peripheralIdentifier: UUID?

    /// Passed in by another controller, whose peripheral handle means nothing here: this session
    /// keeps the one it finds itself.
    var configuredByAnotherController = false
}


public final class G7Sensor: G7BluetoothManagerDelegate {
    public static let defaultLifetime = TimeInterval(hours: 10 * 24)
    public static let defaultWarmupDuration = TimeInterval(minutes: 27)
    public static let gracePeriod = TimeInterval(hours: 12)

    /// How far back to ask the sensor to backfill after a direct-mode
    /// reconnect when nothing is known about the gap (a fresh pairing).
    static let backfillWindow = TimeInterval(hours: 3)

    /// The most a single backfill request will ask for when the gap since
    /// the last reading is known. Anything the sensor no longer holds it
    /// simply omits.
    static let maximumBackfillWindow = TimeInterval(hours: 24)

    public weak var delegate: G7SensorDelegate?

    /// How readings are obtained. Changed in place by `reconfigure`, so the
    /// Bluetooth central (and any connection it holds) survives a pairing.
    public private(set) var mode: G7SessionMode

    // MARK: - Session state
    // C-208-13: this state was historically documented as "confined to managerQueue" but was in
    // fact written from three different queues (managerQueue, delegateQueue, the peripheral
    // queue) and read cross-queue by consumers — unsynchronized data races. Now `Locked<>`-backed:
    // every read sees the latest committed value at a defined point. Call sites are unchanged.

    private let lockedActivationDate: Locked<Date?> = Locked(nil)
    /// The initial activation date of the sensor. Thread-safe (written on managerQueue and the
    /// discovery-accept path; read by consumers on `delegateQueue`, e.g. `G7CGMManager.didRead`).
    var activationDate: Date? {
        get { lockedActivationDate.value }
        set { lockedActivationDate.value = newValue }
    }

    private let lockedNeedsVersionInfo = Locked(false)
    /// Whether an ExtendedVersion request should be issued after the next EGV. Thread-safe
    /// (set by consumers at init, cleared on `delegateQueue`, read on managerQueue).
    var needsVersionInfo: Bool {
        get { lockedNeedsVersionInfo.value }
        set { lockedNeedsVersionInfo.value = newValue }
    }

    private let lockedPendingAuth = Locked(false)
    /// Used to detect connections that do not authenticate, signalling possible sensor switchover.
    /// Thread-safe (set on the peripheral queue inside `readied`'s perform block and on the
    /// handshake's completion; cleared on managerQueue in the auth-pass and disconnect paths).
    private var pendingAuth: Bool {
        get { lockedPendingAuth.value }
        set { lockedPendingAuth.value = newValue }
    }
    /// The last fresh pairing ended without the sensor confirming its Bluetooth bond.
    private var lastPairingBondUnconfirmed = false

    /// The backfill data buffer
    private var backfillBuffer: [G7BackfillMessage] = []

    /// Cumulative rejection-signature counts for the backfill length guard.
    /// Key: "byteLength-mod9"; value: total occurrences seen for that shape.
    /// Not reset across connections — the running total is cumulative by design.
    private var backfillRejectSignatures: [String: Int] = [:]

    // C-217 Task 3: gap-conditional background backfill. `lastSequence` is the most recent EGV
    // sequence on the CURRENT binding. A background reconnect after a missed window can then detect
    // a real gap (sequence jump > 1) and, ONLY then, arm the passive backfill subscription that
    // C-209-11 otherwise skips while backgrounded. Thread-safe (Locked, C-208-13 pattern): written
    // on managerQueue in handleGlucoseMessage, reset from scanForNewSensor / reconfigure (caller's
    // thread). Resets to nil on sensor forget so a fresh binding never false-fires. Persists across
    // same-sensor reconnects/.makeActive (a gap there is a real gap).
    private let lockedLastSequence: Locked<UInt16?> = Locked(nil)
    private var lastSequence: UInt16? {
        get { lockedLastSequence.value }
        set { lockedLastSequence.value = newValue }
    }
    /// Last time a gap-triggered background backfill subscribe was armed. Caps attempts to <= 1 per
    /// 10 min so a throttled background subscribe cannot spin (Task 3 attempt cap).
    private let lockedLastBgBackfillAttemptAt: Locked<Date?> = Locked(nil)
    private var lastBackgroundBackfillAttemptAt: Date? {
        get { lockedLastBgBackfillAttemptAt.value }
        set { lockedLastBgBackfillAttemptAt.value = newValue }
    }
    private static let backgroundBackfillMinInterval: TimeInterval = 600

    // TRIO-094: opt-in active backfill request (0x59) on a sequence gap.
    private let lockedRequestMissedReadings = Locked(false)
    /// Whether to actively request backfill on a sequence gap. Default off; set by `G7CGMManager` from its
    /// persisted state, so hosts that use `G7Sensor` alone (watch) never enable it. Thread-safe.
    var requestMissedReadings: Bool {
        get { lockedRequestMissedReadings.value }
        set { lockedRequestMissedReadings.value = newValue }
    }

    /// TRIO-099: set once the toggle state was logged this launch (see `backfill_toggle_state`).
    private let lockedLoggedToggleStateThisLaunch = Locked(false)
    private var loggedToggleStateThisLaunch: Bool {
        get { lockedLoggedToggleStateThisLaunch.value }
        set { lockedLoggedToggleStateThisLaunch.value = newValue }
    }

    /// TRIO-094: `glucoseTimestamp` (glucose time, not message time) of the most recent EGV on the current binding,
    /// kept next to `lastSequence` to anchor the start of a backfill request range.
    private let lockedLastGlucoseTimestamp: Locked<UInt32?> = Locked(nil)
    private var lastGlucoseTimestamp: UInt32? {
        get { lockedLastGlucoseTimestamp.value }
        set { lockedLastGlucoseTimestamp.value = newValue }
    }

    /// TRIO-094: set once a backfill request was attempted on this connection; reset on ready and disconnect.
    private let lockedBackfillRequestedThisConnection = Locked(false)
    private var backfillRequestedThisConnection: Bool {
        get { lockedBackfillRequestedThisConnection.value }
        set { lockedBackfillRequestedThisConnection.value = newValue }
    }

    /// TRIO-094: the range of the outstanding backfill request (sensor seconds), until its result is reported.
    private let lockedOutstandingBackfillRange: Locked<(start: UInt32, end: UInt32)?> = Locked(nil)
    private var outstandingBackfillRange: (start: UInt32, end: UInt32)? {
        get { lockedOutstandingBackfillRange.value }
        set { lockedOutstandingBackfillRange.value = newValue }
    }
    private static let maxBackfillRequestSpan: UInt32 = 3 * 60 * 60

    /// TRIO-094: records received while a request is outstanding that fall inside its range.
    private let lockedOutstandingBackfillRecords: Locked<[G7BackfillMessage]> = Locked([])
    /// TRIO-094: 0x59 acknowledgements seen while a request is outstanding that were not attributed to it.
    private let lockedOtherBackfillAcks = Locked(0)

    /// TRIO-094: bumped on every ready and disconnect so a queued request block can tell it is stale.
    private let lockedConnectionGeneration = Locked(0)

    /// When the newest reading we hold was taken. Sizes the backfill request
    /// after a direct-mode reconnect. Seeded by the manager from its saved
    /// state, so a relaunch asks for the gap rather than a default window.
    var latestReadingDate: Date?

    /// Set when a session opens; the backfill request goes out once the
    /// reading reply has arrived, so the sensor never has two of our
    /// commands outstanding. Confined to `bluetoothManager.managerQueue`.
    private var backfillRequestPending = false

    /// A calibration waiting for the sensor's next connection: the link is
    /// only up for a few seconds around each reading, so one entered between
    /// readings has to wait. Newest wins. Settable from any queue.
    private let lockedPendingCalibration = Locked<(glucose: UInt16, date: Date)?>(nil)

    /// A meter reading older than this no longer describes the glucose the
    /// sensor is measuring, so it is dropped rather than sent.
    public static let calibrationMaxAge = TimeInterval(minutes: 5)

    /// Whether to ask for the calibration state on the next connection.
    private let lockedCalibrationBoundsRequestPending = Locked(false)

    // MARK: -

    private let log = OSLog(category: "G7Sensor")

    /// Shared with a pairing run, which borrows it as its central; see
    /// `G7BluetoothManager.init`.
    let bluetoothManager: G7BluetoothManager

    private let delegateQueue = DispatchQueue(label: "com.loopkit.G7Sensor.delegateQueue", qos: .unspecified)

    private let lockedCredentials: Locked<G7SensorCredentials>

    var credentials: G7SensorCredentials {
        lockedCredentials.value
    }

    public var sensorID: String? {
        lockedCredentials.value.sensorID
    }

    private func emitG7TelemetrySensorLocked(_ name: String) {
        emitG7Telemetry("sensor_name_locked", "locked_name=\(name)")
    }

    /// Which of the sensor's display slots this session takes: a phone by
    /// default; a watch app would take its own, alongside the phone's.
    let displayType: G7DisplayType

    convenience init(mode: G7SessionMode, credentials: G7SensorCredentials, displayType: G7DisplayType = .phone) {
        self.init(mode: mode, credentials: credentials, bluetoothManager: G7BluetoothManager(), displayType: displayType)
    }

    init(mode: G7SessionMode, credentials: G7SensorCredentials, bluetoothManager: G7BluetoothManager, displayType: G7DisplayType = .phone) {
        self.mode = mode
        self.displayType = displayType
        self.lockedCredentials = Locked(credentials)
        self.bluetoothManager = bluetoothManager
        bluetoothManager.delegate = self
        bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
    }

    private func mutateCredentials(_ changes: (inout G7SensorCredentials) -> Void) {
        _ = lockedCredentials.mutate(changes)
    }

    /// Whether a peripheral is the sensor these credentials describe.
    ///
    /// By identifier once one is known. Otherwise by the last two characters
    /// of the name, so a match does not depend on which prefix the
    /// peripheral reports.
    static func isSensor(identifier: UUID, name: String?, describedBy credentials: G7SensorCredentials) -> Bool {
        if let known = credentials.peripheralIdentifier {
            return identifier == known
        }
        guard let sensorID = credentials.sensorID, let name = name else {
            return false
        }
        return name.suffix(2) == sensorID.suffix(2)
    }

    /// Names a G7-family sensor uses: the model prefixes ("DXCMxx",
    /// "DX02xx", "DX01xx"), or "Dexcomxx".
    static func isSensorName(_ name: String) -> Bool {
        G7SensorModel.isFamilyName(name)
    }

    private func isOurSensor(_ peripheralManager: G7PeripheralManager) -> Bool {
        G7Sensor.isSensor(
            identifier: peripheralManager.peripheral.identifier,
            name: peripheralManager.peripheral.name,
            describedBy: lockedCredentials.value
        )
    }

    /// ", advertised -78 dBm", or nothing when CoreBluetooth had no reading
    /// (127) — a reconnect to a known peripheral has no advertisement.
    static func describeRSSI(_ rssi: NSNumber, label: String) -> String {
        let value = rssi.intValue
        return value < 0 ? ", \(label) \(value) dBm" : ""
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReadRSSI rssi: NSNumber, error: Error?) {
        guard isOurSensor(peripheralManager) else { return }
        if let error = error {
            logToDevice("Signal strength unavailable: \(error.localizedDescription)", type: .connection)
        } else {
            logToDevice("Signal strength \(rssi.intValue) dBm", type: .connection)
        }
    }

    private func logToDevice(_ message: String, type: DeviceLogEntryType) {
        delegateQueue.async {
            self.delegate?.sensor(self, log: message, type: type)
        }
    }

    private func logSend(_ data: Data, on characteristic: CGMServiceCharacteristicUUID) {
        logToDevice("\(characteristic) \(data.hexadecimalString)", type: .send)
    }

    /// Points this session at a different sensor (or a different way of
    /// reaching the same one) without rebuilding it. Everything learned about
    /// the previous sensor is forgotten; the first reading re-establishes it.
    func reconfigure(mode: G7SessionMode, credentials: G7SensorCredentials) {
        self.mode = mode
        lockedCredentials.value = credentials
        activationDate = nil
        latestReadingDate = nil
        needsVersionInfo = true
        pendingAuth = false
        backfillBuffer = []
        lastSequence = nil // C-217 Task 3: fresh binding — drop gap baseline so it cannot false-fire
        lastGlucoseTimestamp = nil // TRIO-094
        clearOutstandingBackfill()
        bluetoothManager.delegate = self
        bluetoothManager.setActivePeripheralIdentifier(credentials.peripheralIdentifier)
    }

    /// Takes over a connection on which a pairing run has just authenticated,
    /// and opens the session on it straight away. Without this the sensor
    /// would be dropped and reconnected on its next 5-minute advertisement,
    /// leaving a gap right after "paired".
    func adoptAuthenticatedConnection(_ peripheralManager: G7PeripheralManager) {
        bluetoothManager.delegate = self
        bluetoothManager.adoptAsActive(peripheralManager)
        if let name = peripheralManager.peripheral.name {
            delegateQueue.async {
                self.delegate?.sensorDidConnect(self, name: name)
            }
        }
        beginSession(peripheralManager)
    }

    public func scanForNewSensor() {
        // The pairing code and key belong to the sensor being replaced, not to
        // whatever comes next. Keeping them would make every candidate fail
        // its handshake, so a replacement can only be adopted after pairing.
        mutateCredentials { credentials in
            credentials.sensorID = nil
            credentials.pairingCode = nil
            credentials.sharedKey = nil
            credentials.peripheralIdentifier = nil
        }
        bluetoothManager.setActivePeripheralIdentifier(nil)
        lastSequence = nil // C-217 Task 3: fresh binding — drop gap baseline so it cannot false-fire
        lastGlucoseTimestamp = nil // TRIO-094
        bluetoothManager.disconnect()
        bluetoothManager.forgetPeripheral()
        bluetoothManager.scanForPeripheral()
    }

    /// Lets go of the sensor's link without forgetting it, so another
    /// display (the Dexcom app) can take the slot.
    public func dropConnection() {
        bluetoothManager.disconnect()
    }

    /// Seeds the acquisition arm's reading clock after a relaunch; nothing without an arm.
    func noteLatestReading(at date: Date) {
        bluetoothManager.noteReading(at: date)
    }

    public func resumeScanning() {
        // Deliberately leaves the active peripheral identifier alone. Every
        // write to the credentials already reaches the bluetooth manager, and
        // a session relaunched by state restoration knows its peripheral only
        // through the manager: overwriting that with a nil persisted
        // identifier left the rescan after the next disconnect with nothing
        // to retrieve and, with the peripheral still active, nothing to scan for.
        bluetoothManager.scanForPeripheral()
    }

    func recheckAcquisition() {
        bluetoothManager.recheckAcquisition()
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

    /// C-216-B / W-7a: public diagnostics snapshot, forwarded from `bluetoothManager` — see
    /// `G7BLEDiagnosticsSnapshot`'s doc comment for the "unwatched pending connect" fingerprint
    /// build-216 heartbeat consumers key on.
    public func diagnosticsSnapshot() -> G7BLEDiagnosticsSnapshot {
        bluetoothManager.diagnosticsSnapshot()
    }

    // C-217 Task 4: passthrough for the watch adapter's episode-level central re-init.
    public func requestCentralReinit(reason: String) { bluetoothManager.requestCentralReinit(reason: reason) }

    // MARK: - Calibration

    /// Queues a meter glucose for the sensor. It goes out after the reading
    /// reply on the next connection, timestamped with `date` on the sensor's
    /// clock, so it does not matter that the link is down right now.
    public func calibrate(glucose: UInt16, at date: Date) {
        lockedPendingCalibration.value = (glucose, date)
    }

    public var queuedCalibration: (glucose: UInt16, date: Date)? {
        lockedPendingCalibration.value
    }

    /// Drops a calibration that has not gone out yet.
    public func cancelPendingCalibration() {
        lockedPendingCalibration.value = nil
    }

    /// Asks for the sensor's calibration state on the next connection.
    public func requestCalibrationBounds() {
        lockedCalibrationBoundsRequestPending.value = true
    }

    private func sendPendingCalibration(_ peripheral: G7PeripheralManager) {
        guard let activationDate = activationDate else {
            return
        }
        if let calibration = lockedPendingCalibration.value, Date().timeIntervalSince(calibration.date) > G7Sensor.calibrationMaxAge {
            lockedPendingCalibration.value = nil
            logToDevice("Dropping calibration \(calibration.glucose) mg/dL entered at \(calibration.date): older than \(Int(G7Sensor.calibrationMaxAge)) s", type: .connection)
            delegateQueue.async {
                self.delegate?.sensor(self, didDiscardStaleCalibrationEnteredAt: calibration.date)
            }
        } else if let calibration = lockedPendingCalibration.value {
            lockedPendingCalibration.value = nil
            let sensorAge = UInt32(max(0, calibration.date.timeIntervalSince(activationDate)))
            let request = G7CalibrateTxMessage(glucose: calibration.glucose, sensorAge: sensorAge).data
            logToDevice("Sending calibration \(calibration.glucose) mg/dL taken at sensor age \(sensorAge)s", type: .connection)
            logSend(request, on: .control)
            do {
                try peripheral.writeValue(request, for: .control, type: .withResponse)
            } catch let error {
                log.error("Error sending calibration: %{public}@", String(describing: error))
                logToDevice("Calibration send failed: \(error)", type: .error)
            }
        }
        if lockedCalibrationBoundsRequestPending.value {
            lockedCalibrationBoundsRequestPending.value = false
            sendCalibrationBoundsRequest(peripheral)
        }
    }

    private func sendCalibrationBoundsRequest(_ peripheral: G7PeripheralManager) {
        let request = Data([G7Opcode.calibrationBounds.rawValue])
        logSend(request, on: .control)
        do {
            try peripheral.writeValue(request, for: .control, type: .withResponse)
        } catch let error {
            log.error("Error requesting calibration bounds: %{public}@", String(describing: error))
        }
    }

    private func handleGlucoseMessage(message: G7GlucoseMessage, peripheralManager: G7PeripheralManager) {
        let trendStr = message.trend.map { String(format: "%.1f", $0) } ?? "nil"
        let glucoseStr = message.glucose.map { String($0) } ?? "nil"
        emitG7Telemetry(
            "egv_received",
            "glucose=\(glucoseStr) sequence=\(message.sequence) algorithm_state=\(message.algorithmState.rawValue) age_s=\(message.age) message_timestamp=\(message.messageTimestamp) trend_rate=\(trendStr) display_only=\(message.glucoseIsDisplayOnly)"
        )
        // TRIO-099: logged here, not at G7CGMManager.init — the host assigns G7Telemetry.emit after the manager is created, so an init-time emission would be dropped.
        // Marked logged only once a sink exists, so a reading that beats the host's setup doesn't suppress it.
        if !loggedToggleStateThisLaunch, G7Telemetry.emit != nil {
            emitG7Telemetry("backfill_toggle_state", "enabled=\(requestMissedReadings)")
            loggedToggleStateThisLaunch = true
        }
        // C-207-2: this connection delivered a real-time EGV, so a subsequent disconnect is the
        // transmitter's normal post-reading shutdown — `scanAfterDelay` should keep its 2s grace.
        // (A disconnect with this flag still false ⇒ pre-EGV drop ⇒ immediate rescan.) Runs on
        // `managerQueue`, the same queue `scanAfterDelay` reads the flag on.
        bluetoothManager.noteGlucoseReceived() // C-210-6: receivedGlucoseSinceConnect + binding lastGlucoseAt
        activationDate = Date().addingTimeInterval(-TimeInterval(message.messageTimestamp))
        // The reading's own timestamp, for the acquisition arm's miss clock.
        bluetoothManager.noteReading(at: Date().addingTimeInterval(-TimeInterval(message.age)))
        let credentials = lockedCredentials.value

        if mode == .direct, credentials.sensorID != nil, isOurSensor(peripheralManager) {
            peripheralManager.perform { peripheral in
                self.sendPendingCalibration(peripheral)
            }
        }

        if backfillRequestPending {
            backfillRequestPending = false
            let latest = latestReadingDate
            peripheralManager.perform { peripheral in
                self.requestBackfillIfNeeded(peripheral, latestReadingDate: latest)
            }
        }

        // C-209-11: skip the non-essential GATT round-trips while the host is backgrounded. The
        // current EGV already arrived; the backfill subscription and extended-version request only
        // add radio time inside a constrained background runtime slice. Foreground / iOS behavior
        // is unchanged (the hint defaults to false). needsVersionInfo stays true if skipped, so the
        // one-time version fetch simply happens on the next foreground connection.
        // C-217 Task 3: compute the sequence gap on the current binding, then update the baseline.
        // A nil prior baseline (fresh binding) yields gap 0 -> never fires.
        let priorSequence = lastSequence
        lastSequence = message.sequence
        let priorGlucoseTimestamp = lastGlucoseTimestamp // TRIO-094
        lastGlucoseTimestamp = message.glucoseTimestamp
        let sequenceGap: Int = priorSequence.map { Int(message.sequence) - Int($0) } ?? 0

        let skipBackgroundGATT = G7BackgroundHints.isHostBackgrounded
        // C-217 Task 3: when backgrounded, C-209-11 normally skips the backfill subscribe. Allow it
        // ONLY when a real gap exists (sequence jump > 1) so the sensor's push-based backfill can
        // recover the missed reading(s) -- passive-contract-clean (subscribe only, no writes). Capped
        // to <= 1 per 10 min. The extended-version request stays background-skipped either way.
        let now = Date()
        let backfillCapCleared = lastBackgroundBackfillAttemptAt.map { now.timeIntervalSince($0) >= Self.backgroundBackfillMinInterval } ?? true
        let gapTriggeredBackfill = skipBackgroundGATT && sequenceGap > 1 && backfillCapCleared

        if skipBackgroundGATT && !gapTriggeredBackfill {
            emitG7Telemetry("background_gatt_skipped", "backfill_subscribe=true extended_version_pending=\(needsVersionInfo) sequence_gap=\(sequenceGap)")
        } else {
            if gapTriggeredBackfill {
                lastBackgroundBackfillAttemptAt = now
                emitG7Telemetry("background_backfill_gap", "sequence_gap=\(sequenceGap) sequence=\(message.sequence) prior_sequence=\(priorSequence.map { String($0) } ?? "nil")")
            }
            peripheralManager.perform { (peripheral) in
                self.log.default("Listening for backfill responses")
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

            // Keep the extended-version request background-skipped (C-209-11): only issue it in the
            // foreground path, never on a gap-triggered background backfill.
            if !skipBackgroundGATT, needsVersionInfo, credentials.sensorID != nil, isOurSensor(peripheralManager) {
                peripheralManager.perform { (peripheral) in
                    do {
                        self.logSend(Data([G7Opcode.extendedVersionTx.rawValue]), on: .control)
                        try peripheral.requestExtendedVersion()
                    } catch let error {
                        self.log.error("Error trying to request extended version: %{public}@", String(describing: error))
                    }
                }
            }

            requestMissedReadingsIfNeeded(message: message, priorSequence: priorSequence, priorGlucoseTimestamp: priorGlucoseTimestamp, sequenceGap: sequenceGap, peripheralManager: peripheralManager)
        }

        if credentials.sensorID == nil, let name = peripheralManager.peripheral.name, let activationDate = activationDate  {
            delegateQueue.async {
                guard let delegate = self.delegate else {
                    return
                }

                if delegate.sensor(self, didDiscoverNewSensor: name, activatedAt: activationDate, peripheralIdentifier: peripheralManager.peripheral.identifier) {
                    self.mutateCredentials { credentials in
                        credentials.sensorID = name
                        credentials.peripheralIdentifier = peripheralManager.peripheral.identifier
                    }
                    self.emitG7TelemetrySensorLocked(name)
                    self.bluetoothManager.setActivePeripheralIdentifier(peripheralManager.peripheral.identifier)
                    self.activationDate = activationDate
                    self.needsVersionInfo = true
                    self.latestReadingDate = activationDate.addingTimeInterval(TimeInterval(message.messageTimestamp))
                    self.delegate?.sensor(self, didRead: message)
                    self.bluetoothManager.stopScanning()
                    if self.needsVersionInfo, self.isOurSensor(peripheralManager) {
                        peripheralManager.perform { (peripheral) in
                            do {
                                self.logSend(Data([G7Opcode.extendedVersionTx.rawValue]), on: .control)
                                try peripheral.requestExtendedVersion()
                            } catch let error {
                                self.log.error("Error trying to request extended version on initial detection: %{public}@", String(describing: error))
                            }
                        }
                    }
                }
            }
        } else if credentials.sensorID != nil {
            latestReadingDate = activationDate?.addingTimeInterval(TimeInterval(message.messageTimestamp))
            delegateQueue.async {
                self.delegate?.sensor(self, didRead: message)
            }
        } else {
            self.log.error("Dropping unhandled glucose message: %{public}@", String(describing: message))
        }
    }

    /// TRIO-094: wall-clock ISO 8601 for a sensor-seconds value via the activation date, or "nil" when unknown.
    private func backfillWallString(_ sensorSeconds: UInt32) -> String {
        guard let activationDate = activationDate else {
            return "nil"
        }
        return ISO8601DateFormatter().string(from: activationDate.addingTimeInterval(TimeInterval(sensorSeconds)))
    }

    /// TRIO-094: after a sequence gap, actively ask the sensor for the missed range (opt-in, once per connection).
    /// Eavesdropping only: a direct-mode session already requests the gap since its newest reading
    /// on every connection (`requestBackfillIfNeeded`), and the sensor handles one command at a time.
    private func requestMissedReadingsIfNeeded(message: G7GlucoseMessage, priorSequence: UInt16?, priorGlucoseTimestamp: UInt32?, sequenceGap: Int, peripheralManager: G7PeripheralManager) {
        // TRIO-099: skip reasons are logged only on a real gap.
        guard requestMissedReadings else {
            if priorSequence != nil, sequenceGap > 1 {
                emitG7Telemetry("backfill_request_skipped", "reason=disabled sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            }
            return
        }
        guard let priorSequence = priorSequence, sequenceGap > 1 else { return }
        guard mode == .eavesdropping else {
            emitG7Telemetry("backfill_request_skipped", "reason=direct_mode_reconnect_backfill sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            return
        }
        guard lockedCredentials.value.sensorID != nil, isOurSensor(peripheralManager) else {
            emitG7Telemetry("backfill_request_skipped", "reason=not_current_sensor sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            return
        }
        guard !G7BackgroundHints.isHostBackgrounded else {
            emitG7Telemetry("backfill_request_skipped", "reason=host_backgrounded sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            return
        }
        guard !backfillRequestedThisConnection else {
            emitG7Telemetry("backfill_request_skipped", "reason=already_requested_this_connection sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            return
        }

        // TRIO-094: the range is in glucose time (backfill record timestamps are glucose times). End excludes the current reading (already in hand), so the Dexcom app's own one-record backfill of it falls outside our range.
        let end = Int64(message.glucoseTimestamp) - 1
        var start = priorGlucoseTimestamp.map { Int64($0) + 1 } ?? (Int64(message.glucoseTimestamp) - Int64(sequenceGap) * 300)
        start = max(start, end - Int64(Self.maxBackfillRequestSpan), 0)
        guard start < end else {
            emitG7Telemetry("backfill_request_skipped", "reason=empty_range sequence_gap=\(sequenceGap) sequence=\(message.sequence)")
            return
        }

        backfillRequestedThisConnection = true
        let startSeconds = UInt32(start)
        let endSeconds = UInt32(end)
        let generation = lockedConnectionGeneration.value

        peripheralManager.perform { (peripheral) in
            // TRIO-094: the connection may have cycled between scheduling and running; never touch a newer connection's state.
            guard self.lockedConnectionGeneration.value == generation, peripheral.peripheral.state == .connected else {
                emitG7Telemetry("backfill_request_skipped", "reason=stale_connection")
                return
            }
            // A reconfigure may have switched to direct mode between scheduling and running; never send 0x59 then.
            guard self.mode == .eavesdropping else {
                emitG7Telemetry("backfill_request_skipped", "reason=mode_changed")
                return
            }
            self.lockedOutstandingBackfillRecords.value = []
            self.lockedOtherBackfillAcks.value = 0
            self.outstandingBackfillRange = (start: startSeconds, end: endSeconds)
            do {
                try peripheral.requestBackfill(start: startSeconds, end: endSeconds)
                emitG7Telemetry(
                    "backfill_request_sent",
                    "start_s=\(startSeconds) end_s=\(endSeconds) start_date=\(self.backfillWallString(startSeconds)) end_date=\(self.backfillWallString(endSeconds)) sequence_gap=\(sequenceGap) prior_sequence=\(priorSequence) sequence=\(message.sequence)"
                )
            } catch let error {
                self.clearOutstandingBackfill()
                emitG7Telemetry("backfill_request_failed", "error=\(error.localizedDescription)")
                self.log.error("Error trying to request backfill: %{public}@", String(describing: error))
            }
        }
    }

    private func clearOutstandingBackfill() {
        outstandingBackfillRange = nil
        lockedOutstandingBackfillRecords.value = []
        lockedOtherBackfillAcks.value = 0
    }

    /// TRIO-094: called from `flushBackfillBuffer` (the queue that fills `backfillBuffer`) with the flushed records; keeps those inside the outstanding request's range, and is a no-op when none is outstanding. Records the Dexcom app requested that fall inside our range are counted too; they are recovered readings either way.
    private func noteFlushedBackfillRecordsForRequest(_ records: [G7BackfillMessage]) {
        guard let range = outstandingBackfillRange else { return }
        let inRange = records.filter { $0.timestamp >= range.start && $0.timestamp <= range.end }
        guard !inRange.isEmpty else { return }
        _ = lockedOutstandingBackfillRecords.mutate { $0.append(contentsOf: inRange) }
    }

    /// TRIO-094: report the outstanding request's outcome, once, then clear it. `ack` is nil when the connection ended first.
    private func reportBackfillRequestResult(finished: Bool, ack: (status: UInt8, first: UInt32, last: UInt32)?) {
        guard outstandingBackfillRange != nil else { return }
        let records = lockedOutstandingBackfillRecords.value
        let otherAcks = lockedOtherBackfillAcks.value
        clearOutstandingBackfill()
        let firstDate = records.first.map { backfillWallString($0.timestamp) } ?? "nil"
        let lastDate = records.last.map { backfillWallString($0.timestamp) } ?? "nil"
        let ackStatus = ack.map { String($0.status) } ?? "nil"
        let ackFirst = ack.map { String($0.first) } ?? "nil"
        let ackLast = ack.map { String($0.last) } ?? "nil"
        emitG7Telemetry(
            "backfill_request_result",
            "records=\(records.count) first_date=\(firstDate) last_date=\(lastDate) in_range=\(records.count) finished=\(finished) ack_status=\(ackStatus) ack_first_s=\(ackFirst) ack_last_s=\(ackLast) other_acks=\(otherAcks)"
        )
    }

    /// TRIO-094: attribute a 0x59 acknowledgement to the outstanding request (layout per DiaBLE).
    private func handleBackfillAck(_ response: Data) {
        guard let range = outstandingBackfillRange else { return }
        if response.count >= 19 {
            func leUInt32(_ offset: Int) -> UInt32 {
                let base = response.startIndex + offset
                return (0..<4).reduce(UInt32(0)) { $0 | (UInt32(response[base + $1]) << UInt32(8 * $1)) }
            }
            let length = leUInt32(3)
            let first = leUInt32(11)
            let last = leUInt32(15)
            if length > 0, first >= range.start, last <= range.end {
                reportBackfillRequestResult(finished: true, ack: (status: response[response.startIndex + 1], first: first, last: last))
                return
            }
        }
        _ = lockedOtherBackfillAcks.mutate { $0 += 1 }
    }

    // MARK: - Direct mode

    /// Runs the handshake and, on success, opens the session.
    private func authenticate(_ peripheralManager: G7PeripheralManager) {
        let credentials = lockedCredentials.value

        guard credentials.sharedKey != nil || credentials.pairingCode != nil else {
            // Without either, a handshake would run the key exchange against
            // whatever Dexcom device is in range and fail every time. Wait for
            // the user to pair instead.
            log.error("Not authenticating: no shared key or pairing code")
            return
        }

        pendingAuth = true

        let authenticator = G7Authenticator(
            pairingCode: credentials.pairingCode,
            storedSharedKey: credentials.sharedKey,
            stepTimeout: credentials.sharedKey == nil
                ? G7Authenticator.pairingStepTimeout
                : G7Authenticator.reconnectStepTimeout,
            displayType: displayType
        )
        authenticator.logHandler = { [weak self] message in
            self?.logToDevice(message, type: .connection)
        }

        authenticator.authenticate(peripheralManager: peripheralManager) { [weak self] result in
            guard let self = self else { return }
            switch result {
            case .success(let authResult):
                self.pendingAuth = false
                if authResult.didExchangeKeys {
                    self.lastPairingBondUnconfirmed = authResult.bondUnconfirmed
                    self.mutateCredentials { $0.sharedKey = authResult.sharedKey }
                    self.delegateQueue.async {
                        self.delegate?.sensor(
                            self,
                            didAuthenticateWith: authResult.sharedKey,
                            deviceName: authResult.deviceName,
                            authenticity: authResult.authenticity
                        )
                    }
                }
                self.beginSession(peripheralManager)
            case .failure(G7AuthenticatorError.linkLost):
                // Nothing wrong with the sensor; the next connection retries.
                self.pendingAuth = false
            case .failure(let error):
                self.handleAuthenticationFailure(error)
            }
        }
    }

    /// Subscribes to the session characteristics and asks for a reading right
    /// away, mirroring what the official app does after authenticating. A
    /// sensor only links briefly around each 5-minute reading, so waiting for
    /// an unprompted broadcast can cost a whole cycle.
    private func beginSession(_ peripheralManager: G7PeripheralManager) {
        peripheralManager.perform { peripheral in
            // A handshake can succeed and the sensor still drop the link
            // before this runs (seen after the bond request). Nothing to open
            // then; the reconnect authenticates with the stored key.
            guard peripheral.peripheral.state == .connected else {
                self.logToDevice("Link dropped before the session could open; waiting for the sensor to reconnect", type: .connection)
                return
            }
            do {
                try peripheral.listenToCharacteristic(.control)
                try peripheral.listenToCharacteristic(.backfill)
                // Ask for the reading first and the backfill only once its
                // reply is in: the sensor handles one command at a time, and
                // a backfill request sent on top of a pending GetEgv cost us
                // the reading.
                self.backfillRequestPending = true
                let request = Data([G7Opcode.glucoseTx.rawValue])
                self.logSend(request, on: .control)
                try peripheral.writeValue(request, for: .control, type: .withResponse)
            } catch let error {
                self.log.error("Error opening session: %{public}@", String(describing: error))
                self.delegateQueue.async {
                    self.delegate?.sensor(self, didError: error)
                }
                return
            }
        }
    }

    /// Asks for the readings taken while we were not connected. Nothing else
    /// requests them in direct mode, so without this a gap never fills. The
    /// range starts at the last reading we have, so an outage longer than the
    /// default window is still asked for in full (up to the cap); the sensor
    /// returns what it holds and the manager drops duplicates by timestamp.
    private func requestBackfillIfNeeded(_ peripheral: G7PeripheralManager, latestReadingDate: Date?) {
        guard let activationDate = activationDate else {
            return
        }

        let now = Date()
        let gapStart: Date
        if let latestReadingDate = latestReadingDate {
            gapStart = latestReadingDate
        } else {
            gapStart = now.addingTimeInterval(-G7Sensor.backfillWindow)
        }
        let earliest = max(activationDate, gapStart, now.addingTimeInterval(-G7Sensor.maximumBackfillWindow))
        guard earliest < now else {
            return
        }

        let start = UInt32(earliest.timeIntervalSince(activationDate))
        let end = UInt32(now.timeIntervalSince(activationDate))
        guard start < end else {
            return
        }

        var request = Data([G7Opcode.backfillFinished.rawValue])
        request.append(start.littleEndian)
        request.append(end.littleEndian)

        do {
            log.default("Requesting backfill from %{public}d to %{public}d", start, end)
            logSend(request, on: .control)
            try peripheral.writeValue(request, for: .control, type: .withResponse)
        } catch let error {
            log.error("Error requesting backfill: %{public}@", String(describing: error))
            logToDevice("Backfill request failed: \(error)", type: .error)
        }
    }

    func handleAuthenticationFailure(_ error: Error) {
        pendingAuth = false
        log.error("Authentication failed: %{public}@", String(describing: error))

        // A stale key is recoverable without the user: drop it, and the next
        // connection runs a full handshake with the pairing code we still
        // hold. Three signals say the key is stale: the sensor's answer to our
        // challenge not matching (caught before we ever send a wrong reply,
        // so the sensor records no rejection), and the sensor saying outright
        // that it has no key for us, or not as bonded on a reconnect. Without
        // a code there is nothing to fall back to, so leave the key in place
        // rather than locking the sensor out of reconnecting.
        let keyIsStale: Bool
        switch error {
        case G7AuthenticatorError.challengeMismatch,
             G7AuthenticatorError.rejected(_, .noAppKey),
             G7AuthenticatorError.storedKeyNotBonded:
            keyIsStale = true
        default:
            keyIsStale = false
        }
        if keyIsStale,
           lockedCredentials.value.sharedKey != nil,
           lockedCredentials.value.pairingCode != nil
        {
            log.default("Discarding the stored shared key; the next connection will re-run the key exchange")
            let pairingUnfinished = lastPairingBondUnconfirmed
            lastPairingBondUnconfirmed = false
            mutateCredentials { $0.sharedKey = nil }
            delegateQueue.async {
                self.delegate?.sensorDidInvalidateSharedKey(self)
                if pairingUnfinished { self.delegate?.sensorPairingDidNotFinish(self) }
            }
            return
        }

        delegateQueue.async {
            self.delegate?.sensor(self, didError: error)
        }
    }

    // MARK: - BluetoothManagerDelegate

    func bluetoothManager(_ manager: G7BluetoothManager, readied peripheralManager: G7PeripheralManager) -> Bool {
        var shouldStopScanning = false;
        let credentials = lockedCredentials.value
        let peripheralID = peripheralManager.peripheral.identifier.uuidString
        emitG7Telemetry("gatt_ready", "peripheral=\(peripheralID) following_known=\(credentials.sensorID != nil && isOurSensor(peripheralManager))")

        // TRIO-094: a newly readied peripheral starts a fresh connection.
        _ = lockedConnectionGeneration.mutate { $0 += 1 }
        backfillRequestedThisConnection = false
        clearOutstandingBackfill()
        peripheralManager.resetUnmatchedWhilePendingCount()

        // Ours by identifier once paired, even before the first reading has
        // supplied a sensor ID; otherwise the hand-off connection's events
        // went unlogged and its disconnect left the pending flags set.
        if isOurSensor(peripheralManager) {
            shouldStopScanning = true
            peripheralManager.peripheral.readRSSI()
            let name = credentials.sensorID ?? peripheralManager.peripheral.name ?? "sensor"
            delegateQueue.async {
                self.delegate?.sensorDidConnect(self, name: name)
            }
        }

        switch mode {
        case .direct:
            authenticate(peripheralManager)

        case .eavesdropping:
            peripheralManager.perform { (peripheral) in
                // .default so this survives into a sysdiagnose: info and debug are
                // memory-only and are not written to the log archive, which makes the
                // auth handshake invisible in field diagnostics.
                self.log.default("Listening for authentication responses for %{public}@", String(describing: peripheralManager.peripheral.name))
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
        }
        return shouldStopScanning
    }

    func bluetoothManager(_ manager: G7BluetoothManager, readyingFailed peripheralManager: G7PeripheralManager, with error: Error) {
        delegateQueue.async {
            self.delegate?.sensor(self, didError: error)
        }
    }

    func peripheralDidDisconnect(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, wasRemoteDisconnect: Bool) {
        let peripheralID = peripheralManager.peripheral.identifier.uuidString
        let isFollowed = (sensorID != nil && isOurSensor(peripheralManager))
        emitG7Telemetry(
            "disconnect",
            "peripheral=\(peripheralID) was_remote=\(wasRemoteDisconnect) pending_auth=\(pendingAuth) followed=\(isFollowed)"
        )
        // TRIO-094
        let unmatchedWhilePending = peripheralManager.unmatchedWhilePendingCount
        if unmatchedWhilePending > 0 {
            emitG7Telemetry("unmatched_notification_while_pending_summary", "count=\(unmatchedWhilePending)")
        }
        peripheralManager.resetUnmatchedWhilePendingCount()
        _ = lockedConnectionGeneration.mutate { $0 += 1 }
        backfillRequestedThisConnection = false
        if isOurSensor(peripheralManager) {

            // Sometimes we do not receive the backfillFinished message before disconnect
            flushBackfillBuffer()

            // TRIO-094: a request still outstanding at disconnect never got its acknowledgement.
            reportBackfillRequestResult(finished: false, ack: nil)

            let suspectedEndOfSession: Bool

            self.log.info("Sensor disconnected: wasRemoteDisconnect:%{public}@", String(describing: wasRemoteDisconnect))
            logToDevice(wasRemoteDisconnect ? "Disconnected by sensor" : "Disconnected by phone", type: .connection)
            // Only meaningful while eavesdropping, where the only reason to see
            // an authenticated session appear is the Dexcom app creating one.
            // In direct mode we authenticate ourselves and the sensor drops the
            // link at the end of every reading cycle, so this would fire
            // constantly; session end is read from the algorithm state instead.
            if mode == .eavesdropping, pendingAuth, wasRemoteDisconnect {
                suspectedEndOfSession = true // Normal disconnect without auth is likely that G7 app stopped this session
                emitG7Telemetry("suspected_end_of_session", "prior_name=\(String(describing: sensorID))")
            } else {
                suspectedEndOfSession = false
            }
            pendingAuth = false
            backfillRequestPending = false

            delegateQueue.async {
                self.delegate?.sensorDisconnected(self, suspectedEndOfSession: suspectedEndOfSession)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, shouldConnectPeripheral peripheral: CBPeripheral, advertisementData: [String: Any], rssi: NSNumber) -> PeripheralConnectionCommand {

        let name = (advertisementData[CBAdvertisementDataLocalNameKey] as? String) ?? peripheral.name

        guard let name = name else {
            log.debug("Not connecting to unnamed peripheral: %{public}@", String(describing: peripheral))
            return .ignore
        }

        let credentials = lockedCredentials.value

        // Nothing to authenticate with: no code, no key. Connecting would only take a slot on
        // whatever sensor is nearby, or open a link to our own that closes unauthenticated.
        if !G7Sensor.canAuthenticate(mode: mode, credentials: credentials) {
            if let identifier = credentials.peripheralIdentifier, peripheral.identifier == identifier {
                manager.setNeedsCodeForSensor(peripheral.name ?? name)
            }
            return .ignore
        }

        // Once paired, only ever the sensor we paired with, and by identifier,
        // never by name. A sensor admits one display at a time, so connecting
        // to a stranger's sensor would take its slot, and our key would not
        // authenticate there anyway.
        if mode == .direct, let identifier = credentials.peripheralIdentifier {
            guard peripheral.identifier == identifier else {
                return .ignore
            }
            logToDevice("Connecting to \(name)" + G7Sensor.describeRSSI(rssi, label: "advertised"), type: .connection)
            emitG7Telemetry("connect_called", "intent=makeActive peripheral=\(peripheral.identifier.uuidString)")
            return .makeActive
        }

        guard G7Sensor.isSensorName(name) else {
            log.info("Not connecting to peripheral: %{public}@", name)
            return .ignore
        }

        // If we're following this name or if we're scanning, connect
        if let sensorName = credentials.sensorID, name.suffix(2) == sensorName.suffix(2) {
            logToDevice("Connecting to \(name)", type: .connection)
            emitG7Telemetry("connect_called", "intent=makeActive peripheral=\(peripheral.identifier.uuidString)")
            return .makeActive
        } else if credentials.sensorID == nil {
            logToDevice("Connecting to \(name) to identify it", type: .connection)
            emitG7Telemetry("connect_called", "intent=connect peripheral=\(peripheral.identifier.uuidString)")
            return .connect
        }

        log.info("Not connecting to peripheral: %{public}@", name)
        return .ignore
    }

    func bluetoothManagerShouldAcceptRestoredPeripherals(_ manager: G7BluetoothManager) -> Bool {
        // A session wants its sensor back after a relaunch.
        return true
    }

    /// A device-log line from the bluetooth manager, forwarded to the host on the delegate queue.
    func bluetoothManager(_ manager: G7BluetoothManager, logEvent line: String) {
        delegateQueue.async { self.delegate?.sensor(self, logEvent: line) }
    }

    /// A sensor passed in by another controller keeps the peripheral it finds; one set up here
    /// keeps the identifier it paired with.
    func bluetoothManager(_ manager: G7BluetoothManager, didAdoptPeripheral identifier: UUID?) {
        guard lockedCredentials.value.configuredByAnotherController else { return }
        manager.setActivePeripheralIdentifier(identifier)
        guard lockedCredentials.value.peripheralIdentifier != identifier else { return }
        mutateCredentials { $0.peripheralIdentifier = identifier }
        delegateQueue.async { self.delegate?.sensor(self, didAdoptPeripheral: identifier) }
    }

    func bluetoothManagerStatusDidChange(_ manager: G7BluetoothManager) {
        delegateQueue.async { self.delegate?.sensorStatusDidChange(self) }
    }

    /// The sensor a direct connection would reach without a pairing code or key; nil once one exists.
    var needsCodeForSensor: String? { bluetoothManager.needsCodeForSensor }

    /// Scanning for a sensor this session has never connected to.
    var isSearchingForSensor: Bool { bluetoothManager.isSearchingForSensor }

    func bluetoothManagerCanAuthenticate(_ manager: G7BluetoothManager) -> Bool {
        G7Sensor.canAuthenticate(mode: mode, credentials: lockedCredentials.value)
    }

    /// Reading directly needs a pairing code or a stored key; eavesdropping needs neither.
    static func canAuthenticate(mode: G7SessionMode, credentials: G7SensorCredentials) -> Bool {
        mode != .direct || credentials.sharedKey != nil || credentials.pairingCode != nil
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveControlResponse response: Data) {

        guard response.count > 0 else {
            emitG7Telemetry("empty_control_response", "bytes=0")
            return
        }

        log.default("Received control response: %{public}@", response.hexadecimalString)
        delegateQueue.async {
            self.delegate?.sensor(self, logComms: "control \(response.hexadecimalString)")
        }

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
                }
                // The serial and firmware come from a second query, asked
                // here so a session learns them alongside its lifetime. The
                // version info isn't done until that answer arrives.
                peripheralManager.perform { peripheral in
                    let request = Data([G7Opcode.transmitterVersion.rawValue])
                    self.logSend(request, on: .control)
                    do {
                        try peripheral.writeValue(request, for: .control, type: .withResponse)
                    } catch let error {
                        self.log.error("Error requesting transmitter version: %{public}@", String(describing: error))
                    }
                }
            }
        case .transmitterVersion:
            if let transmitterVersionMessage = TransmitterVersionMessage(data: response) {
                log.default("Received %{public}@", String(describing: transmitterVersionMessage))
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceive: transmitterVersionMessage)
                    self.needsVersionInfo = false
                }
            }
        case .calibrate:
            if let message = G7CalibrateRxMessage(data: response) {
                logToDevice("Calibration \(message.accepted ? "accepted" : "refused") by the sensor (result \(message.result), detail \(message.detail))", type: .connection)
                delegateQueue.async {
                    self.delegate?.sensor(self, didReceiveCalibrationResponse: message)
                }
                // Confirm what the sensor made of it while the link is up.
                peripheralManager.perform { peripheral in
                    self.sendCalibrationBoundsRequest(peripheral)
                }
            }
        case .calibrationBounds:
            if let bounds = G7CalibrationBoundsMessage(data: response) {
                logToDevice("Calibration state: \(bounds)", type: .connection)
                delegateQueue.async {
                    self.delegate?.sensor(self, didReadCalibrationBounds: bounds)
                }
            } else {
                logToDevice("Calibration state reply not understood: \(response.hexadecimalString)", type: .error)
            }
        case .backfillFinished:
            // The acknowledgement arrives after the records, so it doubles as
            // the end-of-stream marker.
            let hexCap = 192
            let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
            let truncated = response.count > hexCap
            emitG7Telemetry("backfill_finished", "bytes=\(response.count) payload=\(hexData) truncated=\(truncated)")
            flushBackfillBuffer()
            handleBackfillAck(response) // TRIO-094
        default:
            let opcode = response[0]
            let hexCap = 192
            let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
            let truncated = response.count > hexCap
            // `default` catches two different things: a byte matching no G7Opcode case at all,
            // and a case the enum names but this switch does not handle (authChallengeRx,
            // sessionStopTx, ...). Reporting the latter as "unknown" would send a
            // future investigation chasing an unrecognised format the enum already names.
            // The payload hex is what makes an unidentified message decodable offline — byte
            // count alone gives the shape but never the content (TRIO-028).
            if G7Opcode(rawValue: opcode) != nil {
                emitG7Telemetry("known_unhandled_control_opcode", "opcode=0x\(String(format: "%02X", opcode)) bytes=\(response.count) truncated=\(truncated) payload=\(hexData)")
            } else {
                emitG7Telemetry("unknown_control_opcode", "opcode=0x\(String(format: "%02X", opcode)) bytes=\(response.count) truncated=\(truncated) payload=\(hexData)")
            }
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
            noteFlushedBackfillRecordsForRequest(backfill) // TRIO-094
            // The next backfill request starts after the newest record we
            // have, whichever path delivered it.
            if let activationDate = activationDate, let newest = backfill.map({ $0.timestamp }).max() {
                let newestDate = activationDate.addingTimeInterval(TimeInterval(newest))
                if newestDate > (latestReadingDate ?? .distantPast) {
                    latestReadingDate = newestDate
                }
            }
            delegateQueue.async {
                self.delegate?.sensor(self, didReadBackfill: backfill)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, didReceiveBackfillResponse response: Data) {

        log.debug("Received backfill response: %{public}@", response.hexadecimalString)
        logToDevice("backfill \(response.hexadecimalString)", type: .receive)

        // Records are 9 bytes each. A G7 packs two to a notification; the
        // ONE+ (and the Dexcom app's own backfill, which eavesdropping
        // overhears) sends one. Anything else is not a record frame.
        // TRIO-028: confirmed 2026-08-16 against a deliberate 16-minute radio gap: two 18-byte
        // notifications decoded as four records at exact 300s spacing, matching the live readings
        // either side and recovering one that was never seen live. Anything that is NOT a whole
        // multiple of 9 is still an unknown shape — `mod9` distinguishes the two at a glance and
        // the hex lets the packet be reconstructed offline, since the log.debug above is OSLog
        // .debug and is not persisted.
        guard response.count >= 9, response.count % 9 == 0 else {
            logToDevice("Backfill frame of unexpected length \(response.count) ignored", type: .error)
            let byteLen = response.count
            let mod9 = byteLen % 9
            let sig = "\(byteLen)-\(mod9)"
            let count = (backfillRejectSignatures[sig] ?? 0) + 1
            backfillRejectSignatures[sig] = count

            // A shape never seen before always logs in full immediately — that is the guard's
            // actual purpose. Only a shape that has already been characterised goes quiet, and
            // even then the periodic total keeps its burst cadence measurable.
            if count <= 3 {
                let hexCap = 192
                let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
                let truncated = byteLen > hexCap
                emitG7Telemetry(
                    "backfill_len_rejected",
                    "bytes=\(byteLen) mod9=\(mod9) truncated=\(truncated) payload=\(hexData)"
                )
            } else if count % 200 == 0 {
                emitG7Telemetry(
                    "backfill_len_rejected_suppressed",
                    "bytes=\(byteLen) mod9=\(mod9) total=\(count)"
                )
            }
            return
        }

        let recordCount = response.count / 9
        if recordCount > 1 {
            emitG7Telemetry("backfill_batch", "bytes=\(response.count) records=\(recordCount)")
        }

        // `subdata(in:)` re-bases each record to index 0; a range subscript would keep the
        // parent's indices and `G7BackfillMessage.init` reads absolute offsets 0...8.
        for offset in stride(from: 0, to: response.count, by: 9) {
            if let msg = G7BackfillMessage(data: response.subdata(in: offset..<(offset + 9))) {
                backfillBuffer.append(msg)
            }
        }
    }

    func bluetoothManager(_ manager: G7BluetoothManager, peripheralManager: G7PeripheralManager, didReceiveAuthenticationResponse response: Data) {

        // Direct mode drives its own handshake and collects these through the
        // authenticator's handler; anything reaching here is stray.
        guard mode == .eavesdropping else {
            log.default("Ignoring unsolicited authentication response: %{public}@", response.hexadecimalString)
            return
        }

        delegateQueue.async {
            self.delegate?.sensor(self, logComms: "auth \(response.hexadecimalString)")
        }

        let opcode = response.first ?? 0xFF
        let authByte = response.count > 1 ? response[1] : 0xFF
        let bondByte = response.count > 2 ? response[2] : 0xFF
        let payloadHex = response.count <= 8
            ? response.map { String(format: "%02X", $0) }.joined()
            : "omitted"
        // Nearly free in exposure terms: the first byte is the opcode and the next two are already
        // emitted in decimal as the authenticated and bonded fields.
        let prefix4Hex = response.prefix(4).map { String(format: "%02X", $0) }.joined()
        // Non-cryptographic change-detector: a 32-bit FNV-1a digest over the entire response,
        // rendered as eight uppercase hex digits. Chosen so two connections can be compared without
        // the payload itself being recoverable from a 32-bit digest of 16 bytes.
        let fnv1a = Self.fnv1a32(response)

        guard let message = AuthChallengeRxMessage(data: response) else {
            emitG7Telemetry(
                "auth_value_received",
                "opcode=0x\(String(format: "%02X", opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=false prefix4=\(prefix4Hex) fnv1a=\(fnv1a)"
            )
            emitG7Telemetry("auth_payload_ignored", "bytes=\(response.count)")
            log.default("Ignoring authentication response: %{public}@", response.hexadecimalString)
            return
        }
        let gatePass = message.isAuthenticated && message.isBonded
        emitG7Telemetry(
            "auth_value_received",
            "opcode=0x\(String(format: "%02X", opcode)) authenticated=\(authByte) bonded=\(bondByte) payload_len=\(response.count) payload=\(payloadHex) gate_passed=\(gatePass) prefix4=\(prefix4Hex) fnv1a=\(fnv1a)"
        )
        if gatePass {
            log.default("Observed authenticated session. enabling notifications for control characteristic.")
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
            log.default("Ignoring authentication response: %{public}@", response.hexadecimalString)
        }
    }

    func bluetoothManagerScanningStatusDidChange(_ manager: G7BluetoothManager) {
        // Called on the manager's queue; `isScanning` syncs onto that queue,
        // so it has to be read from somewhere else.
        // Read isScanning on a background thread to avoid potential queue deadlock.
        DispatchQueue.global(qos: .utility).async {
            let scanning = manager.isScanning
            emitG7Telemetry("scanning_status_changed", "scanning=\(scanning)")
        }
        self.delegateQueue.async {
            self.delegate?.sensor(self, log: manager.isScanning ? "Scanning for sensor" : "Stopped scanning", type: .connection)
            self.delegate?.sensorConnectionStatusDidUpdate(self)
        }
    }

    // MARK: - Non-cryptographic digest helpers

    /// 32-bit FNV-1a over `data`, returned as eight uppercase hex digits.
    ///
    /// Offset basis 2166136261 (0x811C9DC5); per-byte fold: XOR then wrapping-multiply by the
    /// prime 16777619. This is a **non-cryptographic change-detector**, not a security primitive:
    /// it exists so two connections can be compared for equality without the payload itself being
    /// recoverable — a 32-bit digest of 16 bytes has ~2^32 preimages.
    private static func fnv1a32(_ data: Data) -> String {
        var hash: UInt32 = 0x811C9DC5
        for byte in data {
            hash ^= UInt32(byte)
            hash = hash &* 16_777_619
        }
        return String(format: "%08X", hash)
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
