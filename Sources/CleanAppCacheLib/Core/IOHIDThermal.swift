import Foundation
import IOKit

// MARK: - IOHID thermal sensor reader (Apple Silicon, best-effort)
//
// On Apple Silicon, temperature sensors are exposed through IOHIDEventSystem
// rather than classic SMC keys. The relevant functions are private (not in
// public headers), so we resolve them dynamically with dlsym. Everything is
// guarded — if a symbol is missing or returns nothing, we yield nil and the UI
// shows "—" rather than crashing.

/// Not thread-safe. The resolved function pointers and the event-system client
/// are unsynchronised mutable state, so `@unchecked Sendable` holds only while
/// each instance is driven from a single serial queue. Each `SystemMonitor`
/// owns a private instance and calls it only from the queue that samples that
/// monitor. Do not share an instance across queues.
public final class IOHIDThermal: @unchecked Sendable {

    // Private IOKit symbol signatures, resolved at runtime.
    private typealias CreateClientFn = @convention(c) (CFAllocator?, Int32) -> Unmanaged<AnyObject>?
    private typealias SetMatchingFn = @convention(c) (AnyObject, CFDictionary) -> Void
    private typealias CopyServicesFn = @convention(c) (AnyObject) -> Unmanaged<CFArray>?
    private typealias CopyEventFn = @convention(c) (AnyObject, Int64, Int32, Int64) -> Unmanaged<AnyObject>?
    private typealias EventGetValueFn = @convention(c) (AnyObject, Int64) -> Double
    private typealias CopyPropertyFn = @convention(c) (AnyObject, CFString) -> Unmanaged<AnyObject>?

    private var createClient: CreateClientFn?
    private var setMatching: SetMatchingFn?
    private var copyServices: CopyServicesFn?
    private var copyEvent: CopyEventFn?
    private var eventGetValue: EventGetValueFn?
    /// Resolved with the others rather than per sensor: a walk names every one
    /// of the forty-odd services, and a `dlsym` each time is a symbol-table
    /// search repeated for an answer that cannot change.
    private var copyProperty: CopyPropertyFn?

    private var client: AnyObject?
    private var available = false

    // IOHID temperature event constants.
    private let kIOHIDEventTypeTemperature: Int64 = 15
    private let kTemperatureField: Int64 = 15 << 16   // field = (type << 16)

    init() { resolve() }

    private func resolve() {
        // Symbols live in the IOKit framework image (already loaded).
        guard let create = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientCreate"),
              let match = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientSetMatching"),
              let services = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventSystemClientCopyServices"),
              let event = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDServiceClientCopyEvent"),
              let getValue = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDEventGetFloatValue")
        else { return }

        createClient = unsafeBitCast(create, to: CreateClientFn.self)
        setMatching = unsafeBitCast(match, to: SetMatchingFn.self)
        copyServices = unsafeBitCast(services, to: CopyServicesFn.self)
        copyEvent = unsafeBitCast(event, to: CopyEventFn.self)
        eventGetValue = unsafeBitCast(getValue, to: EventGetValueFn.self)
        // Optional: without it a sensor is still read, only named "sensor".
        if let copyProp = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "IOHIDServiceClientCopyProperty") {
            copyProperty = unsafeBitCast(copyProp, to: CopyPropertyFn.self)
        }

        guard let c = createClient?(kCFAllocatorDefault, 0)?.takeRetainedValue() else { return }
        client = c
        // Match temperature sensors.
        let matching: [String: Any] = ["PrimaryUsagePage": 0xff00, "PrimaryUsage": 5]
        setMatching?(c, matching as CFDictionary)
        available = true
    }

    /// Returns all readable temperature sensors as (name, °C). Empty if the
    /// private API is unavailable or matched nothing.
    public func readSensors() -> [(name: String, value: Double)] {
        guard available, let client,
              let services = copyServices?(client)?.takeRetainedValue() as? [AnyObject]
        else { return [] }

        var result: [(String, Double)] = []
        for service in services {
            guard let evt = copyEvent?(service, kIOHIDEventTypeTemperature, 0, 0)?.takeRetainedValue() else { continue }
            let value = eventGetValue?(evt, kTemperatureField) ?? 0
            guard SMCReader.isPlausibleTemp(value) else { continue }
            let name = serviceName(service)
            result.append((name, value))
        }
        return result
    }

    private func serviceName(_ service: AnyObject) -> String {
        // IOHIDServiceClientCopyProperty("Product") — also private.
        if let name = copyProperty?(service, "Product" as CFString)?.takeRetainedValue() as? String {
            return name
        }
        return "sensor"
    }
}
