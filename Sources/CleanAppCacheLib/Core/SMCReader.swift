import Foundation
import IOKit

// MARK: - SMC reader (best-effort temperatures)
//
// Reads temperature sensors from the Apple System Management Controller (SMC).
// SMC keys are undocumented and vary by model — especially Apple Silicon, where
// many sensors are inaccessible to unprivileged apps. This reader returns nil
// for anything it can't read, and the UI shows "—" rather than fake values.

private struct SMCKeyDataVers {
    var major: UInt8 = 0
    var minor: UInt8 = 0
    var build: UInt8 = 0
    var reserved: UInt8 = 0
    var release: UInt16 = 0
}

private struct SMCKeyDataPLimitData {
    var version: UInt16 = 0
    var length: UInt16 = 0
    var cpuPLimit: UInt32 = 0
    var gpuPLimit: UInt32 = 0
    var memPLimit: UInt32 = 0
}

private struct SMCKeyDataKeyInfo {
    var dataSize: UInt32 = 0
    var dataType: UInt32 = 0
    var dataAttributes: UInt8 = 0
    // C rounds a struct's size up to its alignment, so this is 12 bytes to the
    // kernel. Swift packs the next field of the enclosing struct right after
    // this one's 9th byte instead, which shifts `result`, `status`, `data8`
    // (the *selector*) and the payload 3 bytes down and makes SMCKeyData 76
    // bytes where AppleSMC expects 80. The driver then either rejects every
    // call outright or reads a zero selector and returns shifted bytes —
    // either way, no temperature comes back without the explicit padding.
    private var trailingPadding: (UInt8, UInt8, UInt8) = (0, 0, 0)
}

private struct SMCBytes {
    // 32-byte buffer
    var b: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
            UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) =
        (0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0, 0,0,0,0,0,0,0,0)
}

private struct SMCKeyData {
    var key: UInt32 = 0
    var vers = SMCKeyDataVers()
    var pLimitData = SMCKeyDataPLimitData()
    var keyInfo = SMCKeyDataKeyInfo()
    var result: UInt8 = 0
    var status: UInt8 = 0
    var data8: UInt8 = 0
    var data32: UInt32 = 0
    var bytes = SMCBytes()
}

/// Not thread-safe. The IOKit connection and the enumerated key caches are
/// unsynchronised mutable state, so `@unchecked Sendable` holds only while each
/// instance is driven from a single serial queue. Each `SystemMonitor` owns a
/// private instance and calls it only from the queue that samples that monitor.
/// Do not share an instance across queues; prefer a private instance per owner
/// over `shared`.
public final class SMCReader: @unchecked Sendable {
    public static let shared = SMCReader()

    private var connection: io_connect_t = 0
    private var opened = false

    /// The key operations are injectable without an IOKit connection so failure
    /// recovery can be checked on machines that expose different sensor sets.
    struct KeyAccess {
        var info: (UInt32) -> (size: UInt32, type: UInt32)?
        var bytes: (UInt32, UInt32) -> [UInt8]?
        var name: (Int) -> UInt32?
    }
    private let keyAccess: KeyAccess?
    private let appleSilicon: Bool
    private let now: () -> TimeInterval

    init() {
        keyAccess = nil
        appleSilicon = Self.isAppleSilicon
        now = { TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000 }
        open()
    }
    init(keyAccess: KeyAccess, appleSilicon: Bool = true,
         now: @escaping () -> TimeInterval) {
        self.keyAccess = keyAccess
        self.appleSilicon = appleSilicon
        self.now = now
    }
    deinit { if opened { IOServiceClose(connection) } }

    private func open() {
        // On Apple Silicon, `AppleSMC` matches several nodes; only the
        // `AppleSMCKeysEndpoint` child actually services key reads (#KEY, Tp*,
        // Tg*). Opening the generic parent (as IOServiceGetMatchingService
        // returns) makes #KEY return 0 and every temperature key fail. macmon
        // iterates the matches and opens the keys endpoint explicitly — we do
        // the same, falling back to the first match for Intel/compat.
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleSMC"), &iter) == KERN_SUCCESS else { return }
        defer { IOObjectRelease(iter) }

        var endpoint: io_service_t = 0   // preferred: AppleSMCKeysEndpoint
        var fallback: io_service_t = 0   // first match, used if no endpoint node

        var service = IOIteratorNext(iter)
        while service != 0 {
            var nameBuf = [CChar](repeating: 0, count: 128)
            let isEndpoint = IORegistryEntryGetName(service, &nameBuf) == KERN_SUCCESS
                && String(cString: nameBuf) == "AppleSMCKeysEndpoint"
            if isEndpoint, endpoint == 0 {
                endpoint = service                 // keep (don't release)
            } else if fallback == 0 {
                fallback = service                 // keep first as fallback
            } else {
                IOObjectRelease(service)
            }
            service = IOIteratorNext(iter)
        }

        let target = endpoint != 0 ? endpoint : fallback
        defer {
            if endpoint != 0 { IOObjectRelease(endpoint) }
            if fallback != 0 { IOObjectRelease(fallback) }
        }
        guard target != 0 else { return }
        if IOServiceOpen(target, mach_task_self_, 0, &connection) == kIOReturnSuccess {
            opened = true
        }
    }

    /// Plausible range for a temperature reading, in °C.
    ///
    /// The upper bound must clear the real junction maximum: Apple Silicon P-core
    /// hot-spot keys pass 100 °C under sustained load, and a 125/130 °C cutoff
    /// would drop exactly the hottest sensors — pulling the reported average
    /// *down* as the machine gets hotter. 150 °C matches macmon.
    static func isPlausibleTemp(_ v: Double) -> Bool { v > 0 && v <= 150 }

    /// Temperature in °C for a 4-char SMC key, or nil if unreadable.
    public func temperature(_ key: String) -> Double? {
        guard opened || keyAccess != nil else { return nil }
        guard let val = readKey(key) else { return nil }
        return Self.isPlausibleTemp(val) ? val : nil
    }

    // MARK: Internals

    private func readKey(_ key: String) -> Double? {
        let code = fourCharCode(key)
        guard let info = readKeyInfo(code), info.size > 0,
              let bytes = readBytes(code, size: info.size) else { return nil }
        return decode(type: info.type, size: info.size, bytes: bytes)
    }

    private func call(_ input: inout SMCKeyData, _ output: inout SMCKeyData) -> Bool {
        // The layout must match the kernel's SMCParamStruct exactly; a silent
        // mismatch here is indistinguishable from "this Mac has no sensors".
        assert(MemoryLayout<SMCKeyData>.stride == 80, "SMCKeyData must be 80 bytes")
        guard MemoryLayout<SMCKeyData>.stride == 80 else { return false }

        var outSize = MemoryLayout<SMCKeyData>.stride
        let inSize = MemoryLayout<SMCKeyData>.stride
        let result = withUnsafePointer(to: &input) { inPtr in
            withUnsafeMutablePointer(to: &output) { outPtr in
                IOConnectCallStructMethod(connection, 2, inPtr, inSize, outPtr, &outSize)
            }
        }
        return result == kIOReturnSuccess && output.result == 0
    }

    private func decode(type: UInt32, size: UInt32, bytes p: [UInt8]) -> Double? {
        guard Self.canDecode(type: type, size: size), p.count >= Int(size) else { return nil }
        switch Self.fourCharString(type) {
        case "flt ":
            guard size >= 4 else { return nil }
            // Apple Silicon SMC returns flt values in little-endian (native ARM byte order).
            return Double(Float(bitPattern: Self.littleEndian(p, count: 4)))
        case "sp78":
            guard size >= 2 else { return nil }
            let intPart = Int8(bitPattern: p[0])
            let frac = Double(p[1]) / 256.0
            return Double(intPart) + frac
        case "ui8 ":
            return Double(p[0])
        case "ui16":
            // SMC integers are big-endian (see `keyCount`, which decodes #KEY
            // the same way). Reading only p[0] truncated every value ≥ 256
            // to its high byte.
            guard size >= 2 else { return nil }
            return Double(Self.bigEndian(p, count: 2))
        case "ui32":
            guard size >= 4 else { return nil }
            return Double(Self.bigEndian(p, count: 4))
        case "si32":
            guard size >= 4 else { return nil }
            return Double(Int32(bitPattern: Self.bigEndian(p, count: 4)))
        case "ioft":
            // IOFloat: 64-bit fixed point, 48.16. Used by this Mac's TG0*/TR*d
            // keys, which decoded as sp78 give values like -51.7 °C
            // and 102.9 °C.
            guard size >= 8 else { return nil }
            var raw: UInt64 = 0
            for i in 0..<8 { raw |= UInt64(p[i]) << (8 * UInt64(i)) }
            return Double(raw) / 65_536.0
        default:
            // Unknown encoding. Returning a decoded-as-sp78 guess produces
            // numbers that *look* like temperatures but are not, which is
            // worse than the "—" this reader promises for unreadable sensors.
            return nil
        }
    }

    /// Encoding support depends on the descriptor, not on whether a powered
    /// down sensor can return value bytes during the initial enumeration.
    private static func canDecode(type: UInt32, size: UInt32) -> Bool {
        guard let minimum = minimumByteCount(type: type) else { return false }
        return size >= minimum && size <= 32
    }

    private static func minimumByteCount(type: UInt32) -> UInt32? {
        switch fourCharString(type) {
        case "flt ", "ui32", "si32": return 4
        case "sp78", "ui16": return 2
        case "ui8 ": return 1
        case "ioft": return 8
        default: return nil
        }
    }

    // The byte arithmetic lives in these small typed helpers rather than in
    // one expression inside a buffer closure: the Swift 6.0 type checker
    // (Xcode 16, the CI toolchain) gives up on chained shifts and ORs of
    // mixed-width integers there and fails the build.

    private static func byteArray(_ bytes: SMCBytes) -> [UInt8] {
        withUnsafeBytes(of: bytes) { Array($0) }
    }

    /// The first `count` bytes, most significant first.
    private static func bigEndian(_ p: [UInt8], count: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<count { value = (value << 8) | UInt32(p[i]) }
        return value
    }

    /// The first `count` bytes, least significant first.
    private static func littleEndian(_ p: [UInt8], count: Int) -> UInt32 {
        var value: UInt32 = 0
        for i in 0..<count { value |= UInt32(p[i]) << UInt32(8 * i) }
        return value
    }

    // MARK: - Key enumeration (matches macmon's approach)
    //
    // On macOS 14+/Apple Silicon the real CPU/GPU temperatures live in SMC keys
    // named "Tp.." (P-core clusters), "Te.." (E-core clusters), "Ts.." (SoC die
    // sensors around the compute blocks) and "Tg.." (GPU). Their exact names vary
    // by chip, so we enumerate ALL keys once, cache the temperature ones, then
    // read them each sample and average — this is what macmon shows as CPU/GPU
    // temp, and it was verified sample-for-sample against `macmon pipe` on an
    // M4 (Mac16,12): CPU agrees to <0.02 °C, GPU to <0.01 °C.
    //
    // `Ts*` is NOT optional. Omitting it (39 Tp + 16 Te keys instead of the full
    // 83 on this chip) leaves out 28 cooler die sensors and biases the reported
    // CPU temperature ~3 °C high across the whole range.

    /// SMC key prefixes that make up the reported CPU temperature.
    private static let cpuKeyPrefixes = ["Tp", "Te", "Ts"]
    /// SMC key prefixes that make up the reported GPU temperature.
    private static let gpuKeyPrefixes = ["Tg"]

    /// True on Apple Silicon, decided at runtime rather than `#if arch`: an
    /// x86_64 build running under Rosetta must still answer for the physical
    /// hardware, and `hw.optional.arm64` does (the sysctl is absent entirely
    /// on Intel, so the call fails there and this stays false).
    private static let isAppleSilicon: Bool = {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }()

    public private(set) var diag = ""

    /// Key descriptors are properties of the hardware. Only a complete
    /// enumeration is cached; transient driver failures must remain retryable.
    private struct SensorKey { let code: UInt32; let size: UInt32; let type: UInt32 }
    private var cachedCPUKeys: [SensorKey]?
    private var cachedGPUKeys: [SensorKey]?

    /// A failed enumeration cannot establish absence. A known descriptor stays
    /// available even when its sensor is power-gated or temporarily unreadable.
    var gpuSensorAvailability: Bool? {
        // Intel uses named fallback keys, so skipping the Apple Silicon
        // enumeration cannot establish whether an Intel GPU sensor exists.
        guard appleSilicon else { return nil }
        return cachedGPUKeys.map { !$0.isEmpty }
    }

    private var nextKeyEnumerationAt: TimeInterval?
    private static let keyEnumerationRetryInterval: TimeInterval = 30

    /// Averages of the CPU and GPU key sets. Each is one SMC call per key, so
    /// a caller that shows only one of the two passes `false` for the other and
    /// gets nil there without the reads.
    public func temperatureSummary(cpu includeCPU: Bool = true,
                                   gpu includeGPU: Bool = true) -> (cpu: Double?, gpu: Double?) {
        guard opened || keyAccess != nil else { diag = "smc:closed"; return (nil, nil) }

        if cachedCPUKeys == nil,
           nextKeyEnumerationAt.map({ now() >= $0 }) ?? true { buildKeyCache() }
        let cpuKeys = cachedCPUKeys ?? []
        let gpuKeys = cachedGPUKeys ?? []

        func avgOf(_ keys: [SensorKey]) -> Double? {
            var sum = 0.0
            var count = 0
            for k in keys {
                guard let bytes = readBytes(k.code, size: k.size),
                      let v = decode(type: k.type, size: k.size, bytes: bytes),
                      Self.isPlausibleTemp(v) else { continue }
                sum += v
                count += 1
            }
            return count == 0 ? nil : sum / Double(count)
        }
        let cpu = includeCPU ? avgOf(cpuKeys) : nil
        let gpu = includeGPU ? avgOf(gpuKeys) : nil
        diag = "\(enumDiag) cpu:\(cpu.map { String(Int($0)) } ?? "-") gpu:\(gpu.map { String(Int($0)) } ?? "-")"
        return (cpu, gpu)
    }

    private var enumDiag = ""

    private func buildKeyCache() {
        // The Tp/Te/Ts/Tg prefixes are Apple Silicon naming; Intel has no
        // Tp*/Te* keys at all. But Intel *laptops* expose Ts0P/Ts1P/Ts0S —
        // palm-rest/skin proximity sensors, sp78-encoded, typically 25–35 °C —
        // which `hasPrefix("Ts")` matched, so the summary reported a
        // confident, plausible-looking ~30 °C as "CPU" while the machine
        // throttled (and the 85 °C overheat alert could never fire). Skip the
        // enumeration entirely on Intel: with the summary nil, the sampler
        // falls through to the named single-key chain, whose TC0*/TG0P keys
        // are the correct Intel sensors.
        guard appleSilicon else {
            cachedCPUKeys = []
            cachedGPUKeys = []
            enumDiag = "intel:skip-enum"
            return
        }
        var cpu: [SensorKey] = []
        var gpu: [SensorKey] = []
        // Clamped: `#KEY` is a value from the driver, and a garbage read of
        // 0xFFFFFFFF would spin four billion iterations of IOKit round
        // trips each — a silent, permanent hang of the sampling queue. Real
        // Macs report a few thousand keys (2242 on an M4).
        guard let reportedCount = keyCount(), reportedCount > 0 else {
            enumDiag = "keys:0 retry"
            nextKeyEnumerationAt = now() + Self.keyEnumerationRetryInterval
            return
        }
        let count = min(reportedCount, 8192)
        var complete = reportedCount <= 8192
        var tNames: [String] = []   // sample of temperature-ish keys
        if count > 0 {
            for i in 0..<count {
                guard let code = keyName(at: i) else { complete = false; continue }
                let name = Self.fourCharString(code)
                let isCPU = Self.cpuKeyPrefixes.contains { name.hasPrefix($0) }
                let isGPU = Self.gpuKeyPrefixes.contains { name.hasPrefix($0) }
                guard isCPU || isGPU else {
                    if name.hasPrefix("T") && tNames.count < 12 { tNames.append(name) }
                    continue
                }
                // A failed descriptor read makes the enumeration incomplete.
                // Value bytes are sampled later: a power-gated or temporarily
                // unreadable sensor must not disappear from the cache forever.
                guard let info = readKeyInfo(code) else { complete = false; continue }
                guard let minimum = Self.minimumByteCount(type: info.type) else { continue }
                guard info.size >= minimum, info.size <= 32 else { complete = false; continue }
                let sensor = SensorKey(code: code, size: info.size, type: info.type)
                if isCPU { cpu.append(sensor) } else { gpu.append(sensor) }
                if tNames.count < 12 { tNames.append(name) }
            }
        }
        enumDiag = "keys:\(count) Tp/Te/Ts:\(cpu.count) Tg:\(gpu.count) T[\(tNames.joined(separator: ","))]"
        guard complete else {
            enumDiag += " retry"
            nextKeyEnumerationAt = now() + Self.keyEnumerationRetryInterval
            return
        }
        cachedCPUKeys = cpu
        cachedGPUKeys = gpu
        nextKeyEnumerationAt = nil
    }

    private func keyCount() -> Int? {
        let key = fourCharCode("#KEY")
        guard let info = readKeyInfo(key), info.size >= 4,
              let bytes = readBytes(key, size: info.size), bytes.count >= 4 else { return nil }
        // #KEY is a big-endian UInt32 count.
        return Int(Self.bigEndian(bytes, count: 4))
    }

    private func keyName(at index: Int) -> UInt32? {
        if let keyAccess { return keyAccess.name(index) }
        var input = SMCKeyData(); var output = SMCKeyData()
        input.data8 = 8                 // kSMCGetKeyFromIndex
        input.data32 = UInt32(index)
        guard call(&input, &output) else { return nil }
        return output.key
    }

    private func readKeyInfo(_ key: UInt32) -> (size: UInt32, type: UInt32)? {
        if let keyAccess { return keyAccess.info(key) }
        var input = SMCKeyData(); var output = SMCKeyData()
        input.key = key; input.data8 = 9   // kSMCGetKeyInfo
        guard call(&input, &output) else { return nil }
        return (output.keyInfo.dataSize, output.keyInfo.dataType)
    }

    private func readBytes(_ key: UInt32, size: UInt32) -> [UInt8]? {
        if let keyAccess { return keyAccess.bytes(key, size) }
        var input = SMCKeyData(); var output = SMCKeyData()
        input.key = key; input.keyInfo.dataSize = size; input.data8 = 5   // kSMCReadKey
        guard call(&input, &output) else { return nil }
        return Self.byteArray(output.bytes)
    }

    private func fourCharCode(_ s: String) -> UInt32 {
        var result: UInt32 = 0
        for ch in s.utf8.prefix(4) { result = (result << 8) | UInt32(ch) }
        return result
    }

    private static func fourCharString(_ code: UInt32) -> String {
        let chars = [UInt8((code >> 24) & 0xFF), UInt8((code >> 16) & 0xFF),
                     UInt8((code >> 8) & 0xFF), UInt8(code & 0xFF)]
        return String(bytes: chars, encoding: .ascii) ?? ""
    }
}
