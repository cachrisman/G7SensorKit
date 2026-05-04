//
//  G7Telemetry.swift
//  G7SensorKit
//
//  Optional structured-telemetry sink for Build 192/193 comparison work.
//  Default: no-op. Trio iOS sets `G7Telemetry.emit` at startup to forward
//  events to its logger / BetterStack. Other consumers (e.g. Loop) get
//  zero overhead.
//
//  All emissions are dispatched async through a dedicated serial queue so
//  BLE callbacks on managerQueue are never stalled by logger I/O or lock
//  contention. Serial ordering preserves event sequence in logs.
//

import Foundation

public enum G7Telemetry {
    /// Set by the host app at startup. When nil, all emissions are no-ops.
    /// Closure receives the fully formatted line, e.g.:
    ///   "event=g7_ble_ios connect_called peripheral=ABCD-... name=DXCMQU"
    public static var emit: ((String) -> Void)?

    /// Serial queue for async telemetry dispatch.
    /// Serial (not concurrent) to preserve emission ordering —
    /// rapid-fire events like connect_called/did_connect must arrive in order.
    fileprivate static let queue = DispatchQueue(
        label: "com.g7sensorkit.telemetry",
        qos: .utility
    )
}

/// Internal helper. Formats `<subevent> <kv pairs>` with the `event=g7_ble_ios` prefix
/// and dispatches async through the telemetry serial queue.
/// No-op (single nil check) if G7Telemetry.emit is unset.
@inline(__always)
internal func emitG7Telemetry(_ event: String) {
    guard let emit = G7Telemetry.emit else { return }
    let formatted = "event=g7_ble_ios \(event)"
    G7Telemetry.queue.async {
        emit(formatted)
    }
}
