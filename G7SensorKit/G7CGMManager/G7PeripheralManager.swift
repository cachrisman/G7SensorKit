//
//  G7PeripheralManager.swift
//  CGMBLEKit
//
//  Created by Pete Schwamb on 11/11/22.
//  Copyright © 2022 LoopKit Authors. All rights reserved.
//

import CoreBluetooth
import Foundation
import os.log


enum PeripheralManagerError: Error {
    case cbPeripheralError(Error)
    case notReady
    case invalidConfiguration
    case timeout
    case unknownCharacteristic
}

class G7PeripheralManager: NSObject {

    private let log = OSLog(category: "G7PeripheralManager")

    ///
    /// This is mutable, because CBPeripheral instances can seemingly become invalid, and need to be periodically re-fetched from CBCentralManager
    var peripheral: CBPeripheral {
        didSet {
            guard oldValue !== peripheral else {
                return
            }

            log.error("Replacing peripheral reference %{public}@ -> %{public}@", oldValue, peripheral)

            oldValue.delegate = nil
            peripheral.delegate = self

            // C-208-12: async, never sync. This didSet runs on `managerQueue` (the `.makeActive`
            // re-assign site); a `queue.sync` here can wedge against `runCommand`, which blocks
            // THIS queue while waiting for a CBPeripheralDelegate callback that only
            // `managerQueue` can deliver — a lock-order inversion resolved only by the command
            // timeout, freezing the BLE delegate queue inside the connect window.
            // Stale-window coverage: a block already queued at re-assign time can run before this
            // async lands, seeing `needsConfiguration == false` against the NEW peripheral.
            // Protection there is `configureAndRun`'s read-site check (`peripheral.services == nil`
            // forces reconfiguration for a fresh instance) plus characteristic lookups throwing
            // `.unknownCharacteristic` for the cached-services residual — C3's retry covers the
            // skip-on-config-failure case only.
            queue.async {
                self.needsConfiguration = true
                self.cancelConfigurationRetry() // C3: stale peripheral — drop the pending retry block
            }
        }
    }

    /// Makes this manager the peripheral's delegate again, in case another
    /// manager for the same peripheral took the role in the meantime.
    func reclaimPeripheral() {
        if peripheral.delegate !== self {
            log.error("Reclaiming peripheral %{public}@ from %{public}@", peripheral, String(describing: peripheral.delegate))
            peripheral.delegate = self
        }
    }

    /// The dispatch queue used to serialize operations on the peripheral
    let queue = DispatchQueue(label: "com.loopkit.PeripheralManager.queue", qos: .unspecified)

    /// The condition used to signal command completion
    private let commandLock = NSCondition()

    /// The required conditions for the operation to complete
    private var commandConditions = [CommandCondition]()

    /// Any error surfaced during the active operation
    private var commandError: Error?

    /// Persistent per-characteristic update handlers. The pairing handshake
    /// installs these to collect streamed chunks, which the one-shot command
    /// conditions cannot do: the sensor starts streaming on the certificate
    /// characteristic before its acknowledgement lands on the authentication
    /// characteristic, and acknowledgements themselves can arrive while our
    /// own write is still pending. Guarded by `commandLock`.
    private var valueUpdateHandlers: [CBUUID: (Data) -> Void] = [:]

    /// TRIO-094: label of the command currently inside `runCommand`; guarded by `commandLock`.
    private var currentCommandOp: String?

    private let lockedUnmatchedWhilePendingCount = Locked(0)
    /// TRIO-094: notifications delivered to the delegate while a command was pending on this connection
    /// (the old gate would have dropped them). Thread-safe.
    var unmatchedWhilePendingCount: Int {
        lockedUnmatchedWhilePendingCount.value
    }

    func resetUnmatchedWhilePendingCount() {
        lockedUnmatchedWhilePendingCount.value = 0
    }

    private(set) weak var central: CBCentralManager?

    let configuration: Configuration

    // Confined to `queue`
    private var needsConfiguration = true

    // C3 (build 205): bounded, fail-closed retry of a configuration block that was skipped because
    // configuration failed. All confined to `queue`. First-wins — never replace a pending retry, so
    // the dominant skipped op (the initial auth subscription) survives; reset on configuration success.
    private var configurationRetryWorkItem: DispatchWorkItem?
    private var configurationRetryAttempts = 0
    private let maxConfigurationRetryAttempts = 5

    weak var delegate: G7PeripheralManagerDelegate? {
        didSet {
            // C-208-12: async for the same lock-order-inversion reason as the `peripheral`
            // didSet above (this setter is also reached from `managerQueue`).
            queue.async {
                self.needsConfiguration = true
                self.cancelConfigurationRetry() // C3
            }
        }
    }

    init(peripheral: CBPeripheral, configuration: Configuration, centralManager: CBCentralManager) {
        self.peripheral = peripheral
        self.central = centralManager
        self.configuration = configuration

        super.init()

        peripheral.delegate = self

        assertConfiguration()
    }

    /// Installs (or with a nil handler, removes) a persistent handler that
    /// receives every value update for `characteristic`, ahead of the
    /// unsolicited-notification path to the delegate.
    func setValueUpdateHandler(for characteristic: CGMServiceCharacteristicUUID, handler: ((Data) -> Void)?) {
        commandLock.lock()
        valueUpdateHandlers[characteristic.cbUUID] = handler
        commandLock.unlock()
    }

    func requestExtendedVersion() throws {
        self.log.default("Requesting sensor extended version");
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            self.log.error("Peripheral missing cgm service. Services = %{public}@", String(describing: peripheral.services));
            throw PeripheralManagerError.invalidConfiguration
        }

        guard let characteristic = service.characteristics?.itemWithUUID(CGMServiceCharacteristicUUID.control.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try writeValue(Data([G7Opcode.extendedVersionTx.rawValue]), for: characteristic, type: .withResponse, timeout: 1, op: "write_control_extended_version")
    }

    /// TRIO-094: actively request backfill for [start, end] (sensor seconds since activation).
    /// 0x59 is both the request and its acknowledgement opcode (`G7Opcode.backfillFinished`); see upstream
    /// LoopKit requestBackfillIfNeeded, Juggluco askfilldata, xDrip+ BackFillTxMessage2.
    func requestBackfill(start: UInt32, end: UInt32) throws {
        self.log.default("Requesting sensor backfill %{public}d-%{public}d", start, end);
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            self.log.error("Peripheral missing cgm service. Services = %{public}@", String(describing: peripheral.services));
            throw PeripheralManagerError.invalidConfiguration
        }

        guard let characteristic = service.characteristics?.itemWithUUID(CGMServiceCharacteristicUUID.control.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        var request = Data([G7Opcode.backfillFinished.rawValue])
        withUnsafeBytes(of: start.littleEndian) { request.append(contentsOf: $0) }
        withUnsafeBytes(of: end.littleEndian) { request.append(contentsOf: $0) }

        try writeValue(request, for: characteristic, type: .withResponse, timeout: 1, op: "write_control_backfill_request")
    }
}


// MARK: - Nested types
extension G7PeripheralManager {
    struct Configuration {
        var serviceCharacteristics: [CBUUID: [CBUUID]] = [:]
        var notifyingCharacteristics: [CBUUID: [CBUUID]] = [:]
        var valueUpdateMacros: [CBUUID: (_ manager: G7PeripheralManager) -> Void] = [:]
    }

    enum CommandCondition {
        case notificationStateUpdate(characteristicUUID: CBUUID, enabled: Bool)
        case valueUpdate(characteristic: CBCharacteristic, matching: ((Data?) -> Bool)?)
        case write(characteristic: CBCharacteristic)
        case discoverServices
        case discoverCharacteristicsForService(serviceUUID: CBUUID)
    }
}

protocol G7PeripheralManagerDelegate: AnyObject {
    func peripheralManager(_ manager: G7PeripheralManager, didUpdateValueFor characteristic: CBCharacteristic)

    func peripheralManager(_ manager: G7PeripheralManager, didReadRSSI RSSI: NSNumber, error: Error?)

    func peripheralManagerDidUpdateName(_ manager: G7PeripheralManager)

    func completeConfiguration(for manager: G7PeripheralManager) throws
}


// MARK: - Operation sequence management
extension G7PeripheralManager {
    func configureAndRun(_ block: @escaping (_ manager: G7PeripheralManager) -> Void, retryOnConfigFailure: Bool = true) -> (() -> Void) {
        return {
            if !self.needsConfiguration && self.peripheral.services == nil {
                self.log.error("Configured peripheral has no services. Reconfiguring…")
            }

            if self.needsConfiguration || self.peripheral.services == nil {
                do {
                    // Foreground is 5s on every host (iPhone and foreground watch) since TRIO-093: 2026-10-28 phone telemetry showed 86-92% of command_timeouts firing on a still-connected peripheral and 29-39% of auth-timeout replies arriving 1-2s after the 2s timeout, within a 7-10s connection window. A backgrounded watch keeps 6s (C-217 W-1).
                    try self.applyConfiguration(discoveryTimeout: Self.currentDiscoveryTimeout)
                    self.log.default("Peripheral configuration completed")
                    if let delegate = self.delegate {
                        try delegate.completeConfiguration(for: self)
                        self.log.default("Delegate configuration completed")
                        self.needsConfiguration = false
                        self.configurationRetryAttempts = 0 // C3: success resets the retry budget
                    } else {
                        self.log.error("No delegate set configured")
                    }
                } catch let error {
                    // C3: FAIL CLOSED. Running `block` against a peripheral whose characteristics were
                    // never discovered yields no EGV (config churn). Skip the block, keep
                    // needsConfiguration, and schedule a bounded retry that re-runs THIS block once
                    // configuration recovers.
                    emitG7Telemetry("configure_block_skipped", "error=\(String(describing: error))")
                    self.log.error("Peripheral configuration failed; skipping operation block: %{public}@", String(describing: error))
                    self.needsConfiguration = true
                    // Only real operation blocks arm the bounded retry. The no-op assertConfiguration
                    // probe passes retryOnConfigFailure=false: otherwise its (empty) retry could first-win
                    // the single retry slot and a real auth/control block's retry would be dropped
                    // (configure_retry_already_pending) — silently losing the EGV subscription.
                    if retryOnConfigFailure {
                        self.scheduleConfigurationRetry(rerunning: block)
                    }
                    return
                }

            }

            block(self)
        }
    }

    func perform(_ block: @escaping (_ manager: G7PeripheralManager) -> Void, retryOnConfigFailure: Bool = true) {
        queue.async(execute: configureAndRun(block, retryOnConfigFailure: retryOnConfigFailure))
    }

    /// C3: schedule a bounded, fail-closed retry that re-runs the skipped `block` once configuration
    /// recovers. First-wins (never replaces a pending retry, so the dominant skipped op — the auth
    /// subscription — survives); clears the slot before re-entering `perform` so a re-failure can
    /// schedule the next attempt; abandons if the peripheral disconnected; capped attempt count.
    private func scheduleConfigurationRetry(rerunning block: @escaping (_ manager: G7PeripheralManager) -> Void) {
        queue.async {
            guard self.configurationRetryWorkItem == nil else {
                emitG7Telemetry("configure_retry_already_pending")
                return
            }
            guard self.configurationRetryAttempts < self.maxConfigurationRetryAttempts else {
                // C-208-11: escalate at exhaustion instead of dead-ending. A connection whose
                // configuration can never complete delivers no EGVs; holding it open blocks
                // re-attach until the transmitter gives up (observed as ~600s zombie
                // connections on builds 204/205). Drop it and let the normal disconnect path
                // re-attach.
                emitG7Telemetry(
                    "configure_retry_exhausted",
                    "attempts=\(self.configurationRetryAttempts) action=disconnect"
                )
                // C-208-11 (verification finding): reset the budget when escalating. The
                // stored_id re-attach returns the SAME CBPeripheral instance, so the
                // `peripheral` didSet (identity-guarded) never resets it — without this line,
                // every post-exhaustion reconnection's first config failure would instantly
                // re-disconnect with no retry ladder.
                self.configurationRetryAttempts = 0
                self.central?.cancelPeripheralConnection(self.peripheral)
                return
            }
            self.needsConfiguration = true
            let attempt = self.configurationRetryAttempts
            let backoff = min(60.0, Double(2 << attempt)) // 2,4,8,16,32s, capped at 60
            let work = DispatchWorkItem { [weak self] in
                guard let self else { return }
                self.queue.async {
                    self.configurationRetryWorkItem = nil // clear BEFORE re-entering perform
                    guard self.peripheral.state == .connected else {
                        // C-215: reset the retry budget on abandon. The same stored-id CBPeripheral reconnects
                        // (identity-guarded peripheral didSet never fires), so without this the backoff ladder
                        // climbs ACROSS reconnects — each successive retry less likely to fit the connection
                        // window. The connection is already gone, so the exhaustion zombie-hold concern is moot.
                        emitG7Telemetry("configure_retry_abandoned", "reason=disconnected attempt=\(attempt) backoff_s=\(Int(backoff))")
                        self.configurationRetryAttempts = 0
                        return
                    }
                    self.perform(block) // a re-failure re-enters this path and schedules the next attempt
                }
            }
            self.configurationRetryWorkItem = work
            self.configurationRetryAttempts += 1
            emitG7Telemetry("configure_retry_scheduled", "attempt=\(attempt) backoff_s=\(Int(backoff))")
            self.queue.asyncAfter(deadline: .now() + backoff, execute: work)
        }
    }

    /// C3: cancel any pending configuration retry. Must be called on `queue`.
    private func cancelConfigurationRetry() {
        configurationRetryWorkItem?.cancel()
        configurationRetryWorkItem = nil
        configurationRetryAttempts = 0 // a replaced peripheral/delegate starts with a fresh retry budget
    }

    private func assertConfiguration() {
        log.debug("assertConfiguration")
        // This empty probe only triggers configuration; it must NOT arm the fail-closed retry (see
        // configureAndRun) — a no-op retry could otherwise block a real operation's retry.
        perform(retryOnConfigFailure: false) { (_) in
            // Intentionally empty to trigger configuration if necessary
        }
    }

    private static let foregroundDiscoveryTimeout: TimeInterval = 5
    private static let backgroundedDiscoveryTimeout: TimeInterval = 6
    private static var currentDiscoveryTimeout: TimeInterval { G7BackgroundHints.isHostBackgrounded ? backgroundedDiscoveryTimeout : foregroundDiscoveryTimeout }
    /// The pre-TRIO-093 foreground timeout; ops slower than this would have timed out before and count what the longer timeout rescues.
    private static let slowCommandThreshold: TimeInterval = 2

    private func applyConfiguration(discoveryTimeout: TimeInterval = G7PeripheralManager.currentDiscoveryTimeout) throws {
        try discoverServices(configuration.serviceCharacteristics.keys.map { $0 }, timeout: discoveryTimeout)

        for service in peripheral.services ?? [] {
            guard let characteristics = configuration.serviceCharacteristics[service.uuid] else {
                // Not all services may have characteristics
                continue
            }

            try discoverCharacteristics(characteristics, for: service, timeout: discoveryTimeout)
        }

        for (serviceUUID, characteristicUUIDs) in configuration.notifyingCharacteristics {
            guard let service = peripheral.services?.itemWithUUID(serviceUUID) else {
                // Log what discovery returned: an empty or partial inventory means the link dropped
                // mid-discovery, a full but different one means unexpected GATT.
                log.error("unknownCharacteristic: service %{public}@ MISSING on %{public}@ — discovered: %{public}@", String(serviceUUID.uuidString.prefix(8)), peripheral.name ?? "unnamed", Self.gattInventory(peripheral))
                throw PeripheralManagerError.unknownCharacteristic
            }

            for characteristicUUID in characteristicUUIDs {
                guard let characteristic = service.characteristics?.itemWithUUID(characteristicUUID) else {
                    log.error("unknownCharacteristic: char %{public}@ MISSING in service %{public}@ on %{public}@ — discovered: %{public}@", String(characteristicUUID.uuidString.prefix(8)), String(serviceUUID.uuidString.prefix(8)), peripheral.name ?? "unnamed", Self.gattInventory(peripheral))
                    throw PeripheralManagerError.unknownCharacteristic
                }

                guard !characteristic.isNotifying else {
                    continue
                }

                try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
            }
        }
    }

    /// One-line GATT inventory — "svc(8chars):[char8,char8] | svc:[...]".
    /// nil services = discovery never completed at all.
    static func gattInventory(_ peripheral: CBPeripheral) -> String {
        guard let services = peripheral.services else { return "NO SERVICES (discovery incomplete)" }
        if services.isEmpty { return "0 services" }
        return services.map { svc in
            let chars = svc.characteristics?.map { String($0.uuid.uuidString.prefix(8)) }.joined(separator: ",") ?? "none-discovered"
            return "\(svc.uuid.uuidString.prefix(8)):[\(chars)]"
        }.joined(separator: " | ")
    }
}

extension CBManagerState {
    var description: String {
        switch self {
        case .poweredOff:
            return "poweredOff"
        case .poweredOn:
            return "poweredOn"
        case .resetting:
            return "resetting"
        case .unauthorized:
            return "unauthorized"
        case .unknown:
            return "unknown"
        case .unsupported:
            return "unsupported"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}

extension CBPeripheralState {
    var description: String {
        switch self {
        case .connected:
            return "connected"
        case .disconnected:
            return "disconnected"
        case .connecting:
            return "connecting"
        case .disconnecting:
            return "disconnecting"
        @unknown default:
            return "unknown(\(rawValue))"
        }
    }
}


// MARK: - Synchronous Commands
extension G7PeripheralManager {
    /// - Throws: PeripheralManagerError
    func runCommand(timeout: TimeInterval, op: String, command: () -> Void) throws {
        // Prelude
        dispatchPrecondition(condition: .onQueue(queue))
        guard central?.state == .poweredOn && peripheral.state == .connected else {
            log.debug("Unable to run command: central state = %{public}@, peripheral state = %{public}@", String(describing: central?.state.description), String(describing: peripheral.state))
            throw PeripheralManagerError.notReady
        }

        commandLock.lock()

        defer {
            commandLock.unlock()
        }

        guard commandConditions.isEmpty else {
            throw PeripheralManagerError.invalidConfiguration
        }

        currentCommandOp = op // TRIO-094
        defer { currentCommandOp = nil }

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let start = Date()
        let deadline = Date(timeIntervalSinceNow: timeout)
        // NSCondition may wake spuriously; loop until the callbacks have drained commandConditions or the deadline passes (TRIO-093 review)
        while !commandConditions.isEmpty && commandLock.wait(until: deadline) {}
        let signaled = commandConditions.isEmpty

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            // C-216-W1a: stamp the CB states at the moment of timeout so a dead-link timeout
            // (peripheral no longer `.connected`) can be told apart from a starved-CPU timeout
            // (still `.connected`, callback just never ran).
            emitG7Telemetry("command_timeout", "op=\(op) timeout_s=\(Int(timeout)) peripheral_state=\(peripheral.state.rawValue) central_state=\(central?.state.rawValue ?? -1)")
            throw PeripheralManagerError.timeout
        }

        let elapsed = Date().timeIntervalSince(start)
        if elapsed > Self.slowCommandThreshold {
            emitG7Telemetry("command_slow", "op=\(op) elapsed_ms=\(Int(elapsed * 1000)) timeout_s=\(Int(timeout)) peripheral_state=\(peripheral.state.rawValue)")
        }

        if let error = commandError {
            throw PeripheralManagerError.cbPeripheralError(error)
        }
    }

    /// It's illegal to call this without first acquiring the commandLock
    ///
    /// - Parameter condition: The condition to add
    func addCondition(_ condition: CommandCondition) {
        dispatchPrecondition(condition: .onQueue(queue))
        commandConditions.append(condition)
    }

    func discoverServices(_ serviceUUIDs: [CBUUID], timeout: TimeInterval) throws {
        let servicesToDiscover = peripheral.servicesToDiscover(from: serviceUUIDs)

        log.debug("Discovering servicesToDiscover %@", String(describing: servicesToDiscover))

        guard servicesToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout, op: "discover_services") {
            addCondition(.discoverServices)

            log.debug("discoverServices %@", String(describing: serviceUUIDs))

            peripheral.discoverServices(serviceUUIDs)
        }
    }

    func discoverCharacteristics(_ characteristicUUIDs: [CBUUID], for service: CBService, timeout: TimeInterval) throws {

        log.debug("all uuids: %@", String(describing: characteristicUUIDs))

        let knownCharacteristicUUIDs = service.characteristics?.compactMap({ $0.uuid }) ?? []
        log.debug("knownCharacteristicUUIDs: %@", String(describing: knownCharacteristicUUIDs))

        let characteristicsToDiscover = peripheral.characteristicsToDiscover(from: characteristicUUIDs, for: service)

        log.debug("characteristicsToDiscover: %@", String(describing: characteristicsToDiscover))

        guard characteristicsToDiscover.count > 0 else {
            return
        }

        try runCommand(timeout: timeout, op: "discover_characteristics") {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            log.debug("Discovering characteristics %@ for %@", String(describing: characteristicsToDiscover), String(describing: peripheral))
            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval, op: String? = nil) throws {
        let opLabel = op ?? "set_notify_\(Self.characteristicOpName(for: characteristic))"
        try runCommand(timeout: timeout, op: opLabel) {
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))
            log.debug("Set notify %@ for %@", String(describing: enabled), String(describing: peripheral))
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout, op: "read_value_\(Self.characteristicOpName(for: characteristic))") {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }

    /// - Throws: PeripheralManagerError
    func wait(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data {
        try runCommand(timeout: timeout, op: "wait_\(Self.characteristicOpName(for: characteristic))") {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
        }

        guard let value = characteristic.value else {
            throw PeripheralManagerError.timeout
        }

        return value
    }

    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval, op: String? = nil) throws {
        let opLabel = op ?? "write_\(Self.characteristicOpName(for: characteristic))"
        try runCommand(timeout: timeout, op: opLabel) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
        }
    }

    private static func characteristicOpName(for characteristic: CBCharacteristic) -> String {
        if let uuid = CGMServiceCharacteristicUUID(rawValue: characteristic.uuid.uuidString.uppercased()) {
            return characteristicOpName(uuid)
        }
        return "unknown"
    }

    private static func characteristicOpName(_ uuid: CGMServiceCharacteristicUUID) -> String {
        switch uuid {
        case .authentication:
            return "authentication"
        case .control:
            return "control"
        case .backfill:
            return "backfill"
        case .communication:
            return "communication"
        case .certificate:
            return "certificate"
        }
    }
}


// MARK: - Delegate methods executed on the central's queue
extension G7PeripheralManager: CBPeripheralDelegate {

    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverServices = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .discoverCharacteristicsForService(serviceUUID: service.uuid) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    /// Logs an update's error, which the command machinery otherwise drops. watchOS reports its
    /// background-runtime budget here (WWDC22 10135): CBError 18 = near the limit, 17 = exceeded.
    private func reportGattError(_ error: Error?, during what: String, on characteristic: CBCharacteristic) {
        guard let error = error else { return }
        let ns = error as NSError
        var tag = ""
        if ns.domain == CBErrorDomain {
            switch ns.code {
            case 18: tag = " — NEAR the watchOS background-notification limit (CBError 18); the next background wake may be the last before the reset"
            case 17: tag = " — EXCEEDED the watchOS background-notification limit (CBError 17); no background BLE runtime until the user interacts with the app or 24 h pass"
            default: break
            }
        }
        log.error("[gatt] %{public}@ error on %{public}@ — %{public}@ (%{public}@#%d)%{public}@", what, characteristic.uuid.uuidString, error.localizedDescription, ns.domain, ns.code, tag)
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        reportGattError(error, during: "notification-state update", on: characteristic)
        commandLock.lock()

        // On an error the state does not change, so match the characteristic
        // alone; otherwise the error is lost and the command only times out.
        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: let enabled) = condition {
                return error != nil || enabled == characteristic.isNotifying
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didWriteValueFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .write(characteristic: characteristic) = condition {
                return true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        }

        commandLock.unlock()
    }

    func peripheral(_ peripheral: CBPeripheral, didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        reportGattError(error, during: "value update", on: characteristic)
        commandLock.lock()

        var notifyDelegate = false
        var streamedValue: (handler: (Data) -> Void, value: Data)?
        var unmatchedWhilePending: (op: String, n: Int)?

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .valueUpdate(characteristic: characteristic, matching: let matching) = condition {
                return matching?(characteristic.value) ?? true
            } else {
                return false
            }
        }) {
            commandConditions.remove(at: index)
            commandError = error

            if commandConditions.isEmpty {
                commandLock.broadcast()
            }
        } else if let handler = valueUpdateHandlers[characteristic.uuid], let value = characteristic.value {
            // Deliberately ahead of the `commandConditions.isEmpty` gate below:
            // handshake traffic arrives while our own writes are still pending,
            // and dropping it there is what an installed handler exists to avoid.
            streamedValue = (handler, value) // execute after the unlock
        } else if let macro = configuration.valueUpdateMacros[characteristic.uuid] {
            macro(self)
        } else {
            // Unconditionally, pending command or not. The sensor answers a
            // control write with a notification a moment after the write
            // response, and if the next write (a backfill request) is already
            // in flight by then, gating on "no command pending" threw the
            // glucose reply away. Seen in the field as signal loss while the
            // sensor connected on schedule every five minutes.
            notifyDelegate = true // execute after the unlock
            if !commandConditions.isEmpty {
                let n = lockedUnmatchedWhilePendingCount.mutate { $0 += 1 }
                unmatchedWhilePending = (op: currentCommandOp ?? "nil", n: n)
            }
        }

        commandLock.unlock()

        if let streamedValue = streamedValue {
            streamedValue.handler(streamedValue.value)
        }

        if let (pendingOp, n) = unmatchedWhilePending {
            // TRIO-094: control and authentication always emit; the 20-byte burst stream (~600 packets) is capped at 3 per connection.
            let name = Self.characteristicOpName(for: characteristic)
            let isKeyCharacteristic = name == "control" || name == "authentication"
            if isKeyCharacteristic || n <= 3 {
                let value = characteristic.value
                let opcode = value?.first.map { String(format: "0x%02X", $0) } ?? "nil"
                emitG7Telemetry(
                    "unmatched_notification_while_pending",
                    "char=\(name == "backfill" || isKeyCharacteristic ? name : "other") opcode=\(opcode) bytes=\(value?.count ?? 0) pending_op=\(pendingOp) n=\(n)"
                )
            }
        }

        if notifyDelegate {
            // If we weren't expecting this notification, pass it along to the delegate
            delegate?.peripheralManager(self, didUpdateValueFor: characteristic)
        }
    }

    func peripheral(_ peripheral: CBPeripheral, didReadRSSI RSSI: NSNumber, error: Error?) {
        delegate?.peripheralManager(self, didReadRSSI: RSSI, error: error)
    }

    func peripheralDidUpdateName(_ peripheral: CBPeripheral) {
        delegate?.peripheralManagerDidUpdateName(self)
    }
}


extension G7PeripheralManager: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            log.debug("centralManagerDidUpdateState to poweredOn")
            assertConfiguration()
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        log.debug("didConnect to %{public}@", peripheral.identifier.uuidString)
        switch peripheral.state {
        case .connected:
            assertConfiguration()
        default:
            break
        }
    }
}


extension G7PeripheralManager {
    public override var debugDescription: String {
        var items = [
            "## G7PeripheralManager",
            "peripheral: \(peripheral)",
        ]
        queue.sync {
            items.append("needsConfiguration: \(needsConfiguration)")
        }
        return items.joined(separator: "\n")
    }
}

extension G7PeripheralManager {
    private func getCharacteristicWithUUID(_ uuid: CGMServiceCharacteristicUUID) -> CBCharacteristic? {
        return peripheral.getCharacteristicWithUUID(uuid)
    }

    func setNotifyValue(_ enabled: Bool,
        for characteristicUUID: CGMServiceCharacteristicUUID,
        timeout: TimeInterval? = nil) throws
    {
        guard let characteristic = getCharacteristicWithUUID(characteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try setNotifyValue(
            enabled,
            for: characteristic,
            timeout: timeout ?? Self.currentDiscoveryTimeout,
            op: "set_notify_\(Self.characteristicOpName(characteristicUUID))"
        )
    }

}


fileprivate extension CBPeripheral {
    func getServiceWithUUID(_ uuid: SensorServiceUUID) -> CBService? {
        return services?.itemWithUUIDString(uuid.rawValue)
    }

    func getCharacteristicForServiceUUID(_ serviceUUID: SensorServiceUUID, withUUIDString UUIDString: String) -> CBCharacteristic? {
        guard let characteristics = getServiceWithUUID(serviceUUID)?.characteristics else {
            return nil
        }

        return characteristics.itemWithUUIDString(UUIDString)
    }

    func getCharacteristicWithUUID(_ uuid: CGMServiceCharacteristicUUID) -> CBCharacteristic? {
        return getCharacteristicForServiceUUID(.cgmService, withUUIDString: uuid.rawValue)
    }
}
