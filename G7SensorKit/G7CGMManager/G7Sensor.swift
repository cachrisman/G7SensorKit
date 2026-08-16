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

    func sensor(_ sensor: G7Sensor, logComms comms: String)

    func sensor(_ sensor: G7Sensor, didRead glucose: G7GlucoseMessage)

    func sensor(_ sensor: G7Sensor, didReadBackfill backfill: [G7BackfillMessage])

    /// If this returns true, then start following this sensor.
    ///
    /// **Synchronous on `delegateQueue` (C-208-17):** the return value is consumed inline, so
    /// implementations cannot hop to an actor/main queue to answer — they must use
    /// synchronously-accessible state (e.g. `UserDefaults`). Keep it fast; the glucose message
    /// that triggered discovery is processed on the same queue right after this returns.
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

    // MARK: - Passive observation state
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

    /// The date of last connection
    private var lastConnection: Date?

    private let lockedPendingAuth = Locked(false)
    /// Used to detect connections that do not authenticate, signalling possible sensor switchover.
    /// Thread-safe (set on the peripheral queue inside `readied`'s perform block; cleared on
    /// managerQueue in the auth-pass and disconnect paths).
    private var pendingAuth: Bool {
        get { lockedPendingAuth.value }
        set { lockedPendingAuth.value = newValue }
    }

    /// The backfill data buffer
    private var backfillBuffer: [G7BackfillMessage] = []

    // MARK: - Multi-packet backfill stream state

    /// Maximum accumulated size (in bytes) for the multi-packet backfill stream buffer.
    /// Mirrors the reference implementation's 2800-byte bound; also prevents the 1-byte
    /// sequence counter from wrapping after 255 packets.
    private static let backfillStreamMaxAccumulatedSize = 2800

    /// Accumulated payload bytes from the sequenced multi-packet backfill stream.
    private var backfillStreamPayload: Data = Data()
    /// Last accepted 1-based sequence number in the current stream (0 means no packet yet).
    private var backfillStreamLastSequence: UInt8 = 0
    /// Whether the current stream has been locked out due to invalid first-packet content.
    private var backfillStreamLockedOut: Bool = false
    /// Count of packets suppressed after the stream was locked out.
    private var backfillStreamSuppressedCount: Int = 0
    /// Whether the current stream has seen a sequence break (a gap in the 1-based sequence numbers).
    private var backfillStreamSawSequenceBreak: Bool = false

    // C-217 Task 3: gap-conditional background backfill. `lastSequence` is the most recent EGV
    // sequence on the CURRENT binding. A background reconnect after a missed window can then detect
    // a real gap (sequence jump > 1) and, ONLY then, arm the passive backfill subscription that
    // C-209-11 otherwise skips while backgrounded. Thread-safe (Locked, C-208-13 pattern): written
    // on managerQueue in handleGlucoseMessage, reset from scanForNewSensor (caller's thread). Resets
    // to nil on sensor forget so a fresh binding never false-fires. Persists across same-sensor
    // reconnects/.makeActive (a gap there is a real gap).
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

    // MARK: -

    private let log = OSLog(category: "G7Sensor")

    private let bluetoothManager = G7BluetoothManager()

    private let delegateQueue = DispatchQueue(label: "com.loopkit.G7Sensor.delegateQueue", qos: .unspecified)

    private let lockedSensorID: Locked<String?>
    /// Followed sensor name. Thread-safe (C-208-13): written from `scanForNewSensor()` (caller's
    /// thread) and the discovery-accept path (`delegateQueue`); read on managerQueue in
    /// `readied` / `shouldConnectPeripheral` / `peripheralDidDisconnect` / `handleGlucoseMessage`.
    /// The historical race here meant managerQueue could issue broad `.connect`s after the
    /// accept path had already bound a sensor — a day-1 discovery-path hazard.
    private var sensorID: String? {
        get { lockedSensorID.value }
        set { lockedSensorID.value = newValue }
    }

    private func emitG7TelemetrySensorLocked(_ name: String) {
        emitG7Telemetry("sensor_name_locked", "locked_name=\(name)")
    }

    public init(sensorID: String?) {
        lockedSensorID = Locked(sensorID)
        bluetoothManager.delegate = self
    }

    public func scanForNewSensor() {
        self.sensorID = nil
        self.lastSequence = nil // C-217 Task 3: fresh binding — drop gap baseline so it cannot false-fire
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

    /// C-216-B / W-7a: public diagnostics snapshot, forwarded from `bluetoothManager` — see
    /// `G7BLEDiagnosticsSnapshot`'s doc comment for the "unwatched pending connect" fingerprint
    /// build-216 heartbeat consumers key on.
    public func diagnosticsSnapshot() -> G7BLEDiagnosticsSnapshot {
        bluetoothManager.diagnosticsSnapshot()
    }

    // C-217 Task 4: passthrough for the watch adapter's episode-level central re-init.
    public func requestCentralReinit(reason: String) { bluetoothManager.requestCentralReinit(reason: reason) }

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
        bluetoothManager.noteGlucoseReceived() // C-210-6: receivedGlucoseSinceConnect + binding lastGlucoseAt
        activationDate = Date().addingTimeInterval(-TimeInterval(message.messageTimestamp))
        // C-209-11: skip the non-essential GATT round-trips while the host is backgrounded. The
        // current EGV already arrived; the backfill subscription and extended-version request only
        // add radio time inside a constrained background runtime slice. Foreground / iOS behavior
        // is unchanged (the hint defaults to false). needsVersionInfo stays true if skipped, so the
        // one-time version fetch simply happens on the next foreground connection.
        // C-217 Task 3: compute the sequence gap on the current binding, then update the baseline.
        // A nil prior baseline (fresh binding) yields gap 0 -> never fires.
        let priorSequence = lastSequence
        lastSequence = message.sequence
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

            // Keep the extended-version request background-skipped (C-209-11): only issue it in the
            // foreground path, never on a gap-triggered background backfill.
            if !skipBackgroundGATT, needsVersionInfo, let name = peripheralManager.peripheral.name, name == sensorID {
                peripheralManager.perform { (peripheral) in
                    do {
                        try peripheral.requestExtendedVersion()
                    } catch let error {
                        self.log.error("Error trying to request extended version: %{public}@", String(describing: error))
                    }
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
            let hexCap = 192
            let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
            emitG7Telemetry("backfill_finished", "bytes=\(response.count) hex=\(hexData)")
            flushBackfillBuffer()
        default:
            let opcode = response[0]
            emitG7Telemetry("unknown_control_opcode", "opcode=0x\(String(format: "%02X", opcode)) bytes=\(response.count)")
        }
    }

    func flushBackfillBuffer() {
        drainBackfillStream()
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

        // 9-byte single-record path — behaviour unchanged
        if response.count == 9 {
            if let msg = G7BackfillMessage(data: response) {
                backfillBuffer.append(msg)
            }
            return
        }

        // Multiple whole 9-byte records concatenated (18, 27, 36, …).
        // Observation only: record the shape without parsing, so we can confirm
        // whether the sensor ever batches records this way without risking
        // fabricated glucose values from an unconfirmed layout.
        //
        // NOTE: A stream continuation packet is 2 header bytes + 8×N record bytes, so it
        // is an exact multiple of 9 whenever N ≡ 2 (mod 9) — e.g. 2 records → 18 B, 11 → 90 B.
        // (A first packet carries 4 extra length bytes and collides at N = 6 → 54 B.)
        // At the default ATT MTU of 23 the max notification payload is 20 B, so an 18-byte
        // two-record continuation is the ordinary full-size packet. The two shapes overlap at
        // these lengths and cannot be distinguished by size alone; an in-progress stream takes
        // precedence, so we only drop isolated packets (no active stream) here.
        if response.count > 9 && response.count % 9 == 0 {
            let recordCount = response.count / 9
            let hexCap = 192
            let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
            let streamInProgress = backfillStreamLastSequence != 0 || !backfillStreamPayload.isEmpty
            emitG7Telemetry("backfill_stream_multirecord_9byte", "bytes=\(response.count) records=\(recordCount) payload=\(hexData) stream_in_progress=\(streamInProgress)")
            // Only drop when no stream is active; otherwise fall through so the packet is
            // processed as the continuation it almost certainly is.
            if !streamInProgress {
                return
            }
        }

        // ── Multi-packet backfill stream path ──

        // If the stream has been locked out, suppress further packets silently.
        if backfillStreamLockedOut {
            backfillStreamSuppressedCount += 1
            return
        }

        guard response.count >= 2 else { return }

        let seqByte: UInt8 = response[0]

        // First-packet validation: distinguish genuinely-unrelated traffic on the same
        // characteristic from real backfill.  Fires only once per stream (when no packet
        // has been accepted yet, i.e. lastSequence == 0) and only when the packet is
        // long enough to contain the sentinel positions at indices 5, 9, and 17.
        if backfillStreamLastSequence == 0 && response.count > 17 {
            let b5  = response[5]
            let b9  = response[9]
            let b17 = response[17]
            if b5 != 0 || b9 != 0 || b17 != 0 {
                backfillStreamLockedOut = true
                let hexCap = 192
                let hexData = response.prefix(hexCap).map { String(format: "%02X", $0) }.joined()
                emitG7Telemetry("backfill_stream_locked_out", "seq=\(seqByte) bytes=\(response.count) payload=\(hexData)")
                return
            }
        }

        // Sequence check: byte 0 must be exactly one greater than the last accepted.
        let expectedSeq = backfillStreamLastSequence &+ 1
        if seqByte != expectedSeq {
            backfillStreamSawSequenceBreak = true
            emitG7Telemetry("backfill_stream_seq_mismatch", "expected=\(expectedSeq) got=\(seqByte) bytes=\(response.count)")
            return
        }

        // Accept: record the new sequence number and append payload (bytes 2 onward).
        let packetPayloadSize = response.count - 2
        if backfillStreamPayload.count + packetPayloadSize > Self.backfillStreamMaxAccumulatedSize {
            backfillStreamLockedOut = true
            emitG7Telemetry("backfill_stream_size_cap_reached", "accumulated=\(backfillStreamPayload.count) packet_payload=\(packetPayloadSize) max=\(Self.backfillStreamMaxAccumulatedSize)")
            return
        }
        backfillStreamLastSequence = seqByte
        backfillStreamPayload.append(response.subdata(in: 2..<response.count))
    }

    /// Resets all five pieces of multi-packet backfill stream state.
    /// Emits a telemetry event reporting the suppressed count when it is greater than zero.
    private func resetBackfillStream() {
        if backfillStreamSuppressedCount > 0 {
            emitG7Telemetry("backfill_stream_reset", "suppressed=\(backfillStreamSuppressedCount)")
        }
        backfillStreamPayload = Data()
        backfillStreamLastSequence = 0
        backfillStreamLockedOut = false
        backfillStreamSuppressedCount = 0
        backfillStreamSawSequenceBreak = false
    }

    /// Drains the accumulated multi-packet backfill stream into `backfillBuffer`, then resets
    /// the stream state.  Each 8-byte stream record is expanded to the 9-byte form expected by
    /// `G7BackfillMessage` by inserting a zero byte for the display-only flag, which the stream
    /// form does not carry.
    private func drainBackfillStream() {
        guard !backfillStreamPayload.isEmpty else {
            if backfillStreamLockedOut || backfillStreamSuppressedCount > 0 || backfillStreamLastSequence != 0 || backfillStreamSawSequenceBreak {
                resetBackfillStream()
            }
            return
        }

        let payload = backfillStreamPayload

        // 4-byte little-endian declared length
        let declaredLen: UInt32
        if payload.count >= 4 {
            declaredLen = UInt32(payload[0])
                | (UInt32(payload[1]) << 8)
                | (UInt32(payload[2]) << 16)
                | (UInt32(payload[3]) << 24)
        } else {
            declaredLen = 0
        }

        let trailingBytes = payload.count > 4 ? payload.count - 4 : 0
        let declaredLenInt = Int(declaredLen)

        // Abort the stream when it is incomplete or corrupt: prefer discarding over partial delivery.
        let hasSeqBreak = backfillStreamSawSequenceBreak
        let declaredExceedsTrailing = declaredLenInt > trailingBytes
        let notMultipleOf8 = (declaredLen % 8) != 0

        if hasSeqBreak || declaredExceedsTrailing || notMultipleOf8 {
            var reasons: [String] = []
            if hasSeqBreak { reasons.append("sequence_break") }
            if declaredExceedsTrailing { reasons.append("declared_len_exceeds_trailing") }
            if notMultipleOf8 { reasons.append("declared_len_not_multiple_of_8") }
            emitG7Telemetry("backfill_stream_drain_aborted", "reason=\(reasons.joined(separator: ",")) declared_len=\(declaredLen) trailing_bytes=\(trailingBytes) saw_seq_break=\(hasSeqBreak) declared_eq_trailing=\(declaredLenInt == trailingBytes) declared_eq_trailing_plus_4=\(declaredLenInt == trailingBytes + 4) declared_times_8_eq_trailing=\(declaredLenInt * 8 == trailingBytes)")
            resetBackfillStream()
            return
        }

        let recordCount = declaredLenInt / 8
        let surplus = trailingBytes - declaredLenInt

        emitG7Telemetry("backfill_stream_drain", "declared_len=\(declaredLen) actual_bytes=\(payload.count) records=\(recordCount) surplus_bytes=\(surplus)")

        // Walk the declared-length region in 8-byte steps.
        // Stream record layout: timestamp(4 LE) + glucose(2 LE) + algo_state(1) + trend(1) = 8 bytes.
        // The 9-byte G7BackfillMessage layout inserts a display-only flag byte between
        // algo_state and trend; the stream form does not carry that flag, so we insert 0x00
        // to keep it clear.
        let endOffset = 4 + declaredLenInt
        var offset = 4
        while offset + 8 <= endOffset {
            let record = payload.subdata(in: offset..<offset + 8)
            var nineByte = Data()
            nineByte.append(record.subdata(in: 0..<7))       // timestamp(4) + glucose(2) + algo_state(1)
            nineByte.append(0x00)                             // display-only flag unavailable in stream form
            nineByte.append(record[7])                        // trend
            if let msg = G7BackfillMessage(data: nineByte) {
                backfillBuffer.append(msg)
            }
            offset += 8
        }

        resetBackfillStream()
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
