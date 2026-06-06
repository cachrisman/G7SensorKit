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

            queue.sync {
                self.needsConfiguration = true
                self.cancelConfigurationRetry() // C3: stale peripheral — drop the pending retry block
            }
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
            queue.sync {
                needsConfiguration = true
                cancelConfigurationRetry() // C3
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

    func requestExtendedVersion() throws {
        self.log.default("Requesting sensor extended version");
        guard let service = peripheral.services?.itemWithUUID(SensorServiceUUID.cgmService.cbUUID) else {
            self.log.error("Peripheral missing cgm service. Services = %{public}@", String(describing: peripheral.services));
            throw PeripheralManagerError.invalidConfiguration
        }

        guard let characteristic = service.characteristics?.itemWithUUID(CGMServiceCharacteristicUUID.control.cbUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try writeValue(Data([G7Opcode.extendedVersionTx.rawValue]), for: characteristic, type: .withResponse, timeout: 1)
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
                    try self.applyConfiguration()
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
                emitG7Telemetry("configure_retry_exhausted", "attempts=\(self.configurationRetryAttempts)")
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
                        emitG7Telemetry("configure_retry_abandoned", "reason=disconnected")
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

    private func applyConfiguration(discoveryTimeout: TimeInterval = 2) throws {
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
                throw PeripheralManagerError.unknownCharacteristic
            }

            for characteristicUUID in characteristicUUIDs {
                guard let characteristic = service.characteristics?.itemWithUUID(characteristicUUID) else {
                    throw PeripheralManagerError.unknownCharacteristic
                }

                guard !characteristic.isNotifying else {
                    continue
                }

                try setNotifyValue(true, for: characteristic, timeout: discoveryTimeout)
            }
        }
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
    func runCommand(timeout: TimeInterval, command: () -> Void) throws {
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

        // Run
        command()

        guard !commandConditions.isEmpty else {
            // If the command didn't add any conditions, then finish immediately
            return
        }

        // Postlude
        let signaled = commandLock.wait(until: Date(timeIntervalSinceNow: timeout))

        defer {
            commandError = nil
            commandConditions = []
        }

        guard signaled else {
            emitG7Telemetry("command_timeout", "timeout_s=\(Int(timeout))")
            throw PeripheralManagerError.timeout
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

        try runCommand(timeout: timeout) {
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

        try runCommand(timeout: timeout) {
            addCondition(.discoverCharacteristicsForService(serviceUUID: service.uuid))

            log.debug("Discovering characteristics %@ for %@", String(describing: characteristicsToDiscover), String(describing: peripheral))
            peripheral.discoverCharacteristics(characteristicsToDiscover, for: service)
        }
    }

    /// - Throws: PeripheralManagerError
    func setNotifyValue(_ enabled: Bool, for characteristic: CBCharacteristic, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            addCondition(.notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: enabled))
            log.debug("Set notify %@ for %@", String(describing: enabled), String(describing: peripheral))
            peripheral.setNotifyValue(enabled, for: characteristic)
        }
    }

    /// - Throws: PeripheralManagerError
    func readValue(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data? {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))

            peripheral.readValue(for: characteristic)
        }

        return characteristic.value
    }

    /// - Throws: PeripheralManagerError
    func wait(for characteristic: CBCharacteristic, timeout: TimeInterval) throws -> Data {
        try runCommand(timeout: timeout) {
            addCondition(.valueUpdate(characteristic: characteristic, matching: nil))
        }

        guard let value = characteristic.value else {
            throw PeripheralManagerError.timeout
        }

        return value
    }

    /// - Throws: PeripheralManagerError
    func writeValue(_ value: Data, for characteristic: CBCharacteristic, type: CBCharacteristicWriteType, timeout: TimeInterval) throws {
        try runCommand(timeout: timeout) {
            if case .withResponse = type {
                addCondition(.write(characteristic: characteristic))
            }

            peripheral.writeValue(value, for: characteristic, type: type)
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

    func peripheral(_ peripheral: CBPeripheral, didUpdateNotificationStateFor characteristic: CBCharacteristic, error: Error?) {
        commandLock.lock()

        if let index = commandConditions.firstIndex(where: { (condition) -> Bool in
            if case .notificationStateUpdate(characteristicUUID: characteristic.uuid, enabled: characteristic.isNotifying) = condition {
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
        commandLock.lock()

        var notifyDelegate = false

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
        } else if let macro = configuration.valueUpdateMacros[characteristic.uuid] {
            macro(self)
        } else if commandConditions.isEmpty {
            notifyDelegate = true // execute after the unlock
        }

        commandLock.unlock()

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
        timeout: TimeInterval = 2) throws
    {
        guard let characteristic = getCharacteristicWithUUID(characteristicUUID) else {
            throw PeripheralManagerError.unknownCharacteristic
        }

        try setNotifyValue(enabled, for: characteristic, timeout: timeout)
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
