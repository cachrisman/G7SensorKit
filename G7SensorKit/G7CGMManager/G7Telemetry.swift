//
//  G7Telemetry.swift
//  G7SensorKit
//
//  Optional structured-telemetry sink for Build 192/193 comparison work.
//  Default: no-op. Trio sets `G7Telemetry.emit` at startup to forward
//  events to its logger / BetterStack. Other consumers (e.g. Loop) get
//  zero overhead.
//
//  All emissions are dispatched async through a dedicated serial queue so
//  BLE callbacks on managerQueue are never stalled by logger I/O or lock
//  contention. Serial ordering preserves event sequence in logs.
//

import Foundation

/// One telemetry emission: short `event` token plus optional `key=value` fields (no `module=` / `sensor_name=` — host adds those).
public struct G7TelemetryPayload: Sendable {
    public let event: String
    public let fields: String

    public init(event: String, fields: String = "") {
        self.event = event
        self.fields = fields
    }
}

public enum G7Telemetry {
    /// Set by the host app at startup. When nil, all emissions are no-ops.
    /// Receives structured payload; host formats `module=g7_core sensor_name=… event=… … g7_session=…`.
    public static var emit: ((G7TelemetryPayload) -> Void)?

    /// Serial queue for async telemetry dispatch.
    fileprivate static let queue = DispatchQueue(
        label: "com.g7sensorkit.telemetry",
        qos: .utility
    )
}

/// Dispatches `event` + optional `fields` to `G7Telemetry.emit`. No `name=` — host supplies `sensor_name`.
@inline(__always)
internal func emitG7Telemetry(_ event: String, _ fields: String = "") {
    guard let emit = G7Telemetry.emit else { return }
    let payload = G7TelemetryPayload(event: event, fields: fields)
    G7Telemetry.queue.async {
        emit(payload)
    }
}
