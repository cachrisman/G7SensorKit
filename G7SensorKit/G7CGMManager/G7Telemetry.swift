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
    /// C-208-14: lock-backed storage. The host assigns `emit` at startup on the main thread
    /// while BLE queues may already be emitting (the central can exist before the assignment
    /// lands) — an unsynchronized static var here is a data race.
    private static let lockedEmit: Locked<((G7TelemetryPayload) -> Void)?> = Locked(nil)

    /// Set by the host app at startup. When nil, all emissions are no-ops.
    /// Receives structured payload; host formats `module=g7_core sensor_name=… event=… … g7_session=…`.
    /// Thread-safe; intended as set-once-at-launch.
    public static var emit: ((G7TelemetryPayload) -> Void)? {
        get { lockedEmit.value }
        set { lockedEmit.value = newValue }
    }

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

/// C-209-11: host-set background hint. When the host app (e.g. Trio watch) is backgrounded, the
/// library skips non-essential GATT round-trips (backfill subscription, extended-version request)
/// that add radio time inside a constrained background runtime slice without helping the current
/// reading. Scene phase isn't visible to the library, so the host sets this. Thread-safe (read on
/// BLE queues, written from the host's main thread). Default `false` — hosts that never set it
/// (Loop, the iOS phone path) see no behavior change.
public enum G7BackgroundHints {
    private static let lockedBackgrounded = Locked<Bool>(false)
    public static var isHostBackgrounded: Bool {
        get { lockedBackgrounded.value }
        set { lockedBackgrounded.value = newValue }
    }
}
