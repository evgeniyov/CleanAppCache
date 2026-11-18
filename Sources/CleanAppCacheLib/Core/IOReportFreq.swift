import Foundation
import IOKit

// MARK: - IOReport-based CPU/GPU frequency reader (Apple Silicon, best-effort)
//
// Reads DVFS (Dynamic Voltage & Frequency Scaling) residency from the private
// `IOReport` library and combines it with the DVFS frequency tables stored in
// the `AppleARMIODevice` registry entry to compute an average operating
// frequency per cluster (E / P) and for the GPU.
//
// Approach mirrors the documented reverse-engineering of macmon/powermetrics.
// Everything is resolved dynamically (dlsym) and guarded — on unsupported
// hardware (Intel) or if any symbol is missing, sample() returns all nil and
// the UI shows "—".

/// Not thread-safe. The resolved function pointers, the subscription and the
/// previous sample are unsynchronised mutable state, so `@unchecked Sendable`
/// holds only while each instance is driven from a single serial queue. Each
/// `SystemMonitor` owns a private instance and calls it only from the queue
/// that samples that monitor. Do not share an instance across queues; prefer a
/// private instance per owner over `shared`.
public final class IOReportFreq: @unchecked Sendable {
    public static let shared = IOReportFreq()

    // Private IOReport function signatures.
    private typealias CopyChannelsFn = @convention(c) (CFString?, CFString?, UInt64, UInt64, UInt64) -> Unmanaged<CFMutableDictionary>?
    private typealias MergeFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Void
    private typealias CreateSubFn = @convention(c) (UnsafeRawPointer?, CFMutableDictionary, UnsafeMutablePointer<Unmanaged<CFMutableDictionary>?>?, UInt64, CFTypeRef?) -> Unmanaged<AnyObject>?
    private typealias CreateSamplesFn = @convention(c) (AnyObject, CFMutableDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias CreateDeltaFn = @convention(c) (CFDictionary, CFDictionary, CFTypeRef?) -> Unmanaged<CFDictionary>?
    private typealias ChannelGetGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetSubGroupFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias ChannelGetChanNameFn = @convention(c) (CFDictionary) -> Unmanaged<CFString>?
    private typealias StateCountFn = @convention(c) (CFDictionary) -> Int32
    private typealias StateNameFn = @convention(c) (CFDictionary, Int32) -> Unmanaged<CFString>?
    private typealias StateResidencyFn = @convention(c) (CFDictionary, Int32) -> Int64

    private var copyChannels: CopyChannelsFn?
    private var merge: MergeFn?
    private var createSub: CreateSubFn?
    private var createSamples: CreateSamplesFn?
    private var createDelta: CreateDeltaFn?
    private var getGroup: ChannelGetGroupFn?
    private var getChanName: ChannelGetChanNameFn?
    private var stateCount: StateCountFn?
    private var stateName: StateNameFn?
    private var stateResidency: StateResidencyFn?

    private var subscription: AnyObject?
    private var channels: CFMutableDictionary?
    private var available = false

    // DVFS frequency tables (MHz), read once from the registry.
    private var eFreqs: [Double] = []
    private var pFreqs: [Double] = []
    private var gpuFreqs: [Double] = []

    private var prevSample: CFDictionary?

    init() { setup() }

    /// Handle for `libIOReport.dylib`, opened explicitly.
    ///
    /// The IOReport symbols do NOT live in IOKit.framework — they are exported by
    /// `/usr/lib/libIOReport.dylib`, which nothing in this app links. `RTLD_DEFAULT`
    /// only searches images already loaded into the process, so every `dlsym` here
    /// returned nil, `setup()` bailed at the first `guard`, and `available` stayed
    /// false for the lifetime of the app: P/E/GPU frequencies were permanently "—"
    /// and GPU load silently fell back to the coarser IOAccelerator figure.
    private var ioReportLib: UnsafeMutableRawPointer?

    private func sym(_ name: String) -> UnsafeMutableRawPointer? {
        if let lib = ioReportLib, let p = dlsym(lib, name) { return p }
        // Fall back to the global scope in case a host process already linked it.
        return dlsym(UnsafeMutableRawPointer(bitPattern: -2), name)
    }

    private func setup() {
        ioReportLib = dlopen("/usr/lib/libIOReport.dylib", RTLD_LAZY)

        guard let c1 = sym("IOReportCopyChannelsInGroup"),
              let c2 = sym("IOReportMergeChannels"),
              let c3 = sym("IOReportCreateSubscription"),
              let c4 = sym("IOReportCreateSamples"),
              let c5 = sym("IOReportCreateSamplesDelta"),
              let c6 = sym("IOReportChannelGetGroup"),
              let c7 = sym("IOReportStateGetCount"),
              let c8 = sym("IOReportStateGetNameForIndex"),
              let c9 = sym("IOReportStateGetResidency")
        else { return }

        copyChannels = unsafeBitCast(c1, to: CopyChannelsFn.self)
        merge = unsafeBitCast(c2, to: MergeFn.self)
        createSub = unsafeBitCast(c3, to: CreateSubFn.self)
        createSamples = unsafeBitCast(c4, to: CreateSamplesFn.self)
        createDelta = unsafeBitCast(c5, to: CreateDeltaFn.self)
        getGroup = unsafeBitCast(c6, to: ChannelGetGroupFn.self)
        if let cn = sym("IOReportChannelGetChannelName") {
            getChanName = unsafeBitCast(cn, to: ChannelGetChanNameFn.self)
        }
        stateCount = unsafeBitCast(c7, to: StateCountFn.self)
        stateName = unsafeBitCast(c8, to: StateNameFn.self)
        stateResidency = unsafeBitCast(c9, to: StateResidencyFn.self)

        readDVFSTables()
        guard !eFreqs.isEmpty || !pFreqs.isEmpty || !gpuFreqs.isEmpty else { return }

        // Subscribe to CPU + GPU performance-state channels.
        guard let cpuChan = copyChannels?("CPU Stats" as CFString, "CPU Core Performance States" as CFString, 0, 0, 0)?.takeRetainedValue(),
              let gpuChan = copyChannels?("GPU Stats" as CFString, "GPU Performance States" as CFString, 0, 0, 0)?.takeRetainedValue()
        else { return }
        merge?(cpuChan, gpuChan, nil)

        var subDictOut: Unmanaged<CFMutableDictionary>?
        defer {
            // The out-parameter comes back +1 retained. Dropping the `Unmanaged`
            // wrapper does nothing, so without this the dictionary leaks.
            subDictOut?.release()
        }
        guard let sub = createSub?(nil, cpuChan, &subDictOut, 0, nil)?.takeRetainedValue() else { return }
        subscription = sub
        channels = cpuChan
        available = true
    }

    /// Read predefined DVFS frequency tables. The `voltage-states*` properties
    /// live on a descendant of AppleARMIODevice (usually "pmgr"), so we search
    /// the registry subtree rather than the top-level match.
    private func readDVFSTables() {
        guard let root = findEntryWithDVFS() else { return }
        defer { IOObjectRelease(root) }

        // Each voltage-states entry is a flat array of (freq_u32, volt_u32) pairs
        // in little-endian order — macmon's documented format for all M-series chips.
        // M1–M3 store frequencies in Hz; M4+ store them in kHz.
        // We detect the unit by inspecting the maximum raw value:
        //   < 10_000_000  → kHz  (max ~4_100_000 kHz = 4.1 GHz)
        //   ≥ 100_000_000 → Hz   (max ~4_100_000_000 Hz = 4.1 GHz)
        func table(_ key: String) -> [Double] {
            guard let cf = IORegistryEntryCreateCFProperty(root, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                  let data = cf as? Data else { return [] }
            // Read only the frequency word of each 8-byte (freq + volt) pair.
            //
            // Zero entries are dropped so both table shapes normalize to
            // "active states only": the CPU tables list only active states
            // (8 for E, 20 for P against 9/21 residency buckets), while the GPU
            // table encodes its OFF state as a leading 0 MHz entry. `avgFreq`
            // drops the same leading idle buckets from the residency side, so
            // after this the two arrays line up index-for-index.
            var rawFreqs: [UInt32] = []
            data.withUnsafeBytes { raw in
                let u32 = raw.bindMemory(to: UInt32.self)
                var i = 0
                while i < u32.count {
                    let v = UInt32(littleEndian: u32[i])
                    if v != 0 && v != 0xFFFF_FFFF { rawFreqs.append(v) }
                    i += 2   // skip the voltage word
                }
            }
            guard let first = rawFreqs.first, let last = rawFreqs.last,
                  let maxRaw = rawFreqs.max(), maxRaw > 0 else { return [] }

            // Reject the non-`-sram` `voltage-states1` / `voltage-states5`
            // properties. Those hold the *reciprocal* of the frequency
            // (raw = 65_535_000_000 / freq_kHz), so they descend as the paired
            // voltage rises and would otherwise be read as a 22–72 MHz CPU.
            // Real frequency tables end higher than they start; the GPU table is
            // not strictly monotonic (voltage bins interleave), so compare only
            // the endpoints rather than requiring a sorted list.
            guard last > first else { return [] }

            // Determine scale: < 10M → kHz (M4+), otherwise Hz (M1–M3).
            let divisor: Double = maxRaw < 10_000_000 ? 1_000.0 : 1_000_000.0
            let mhz = rawFreqs.map { Double($0) / divisor }
            // A single implausible entry means the layout was misread. Reject the
            // whole table instead of dropping entries, which would shift every
            // later frequency onto the wrong residency bucket.
            guard mhz.allSatisfy({ $0 >= 1 && $0 <= 6_000 }) else { return [] }
            return mhz
        }
        func pick(_ keys: [String]) -> [Double] {
            for k in keys { let t = table(k); if !t.isEmpty { return t } }
            return []
        }

        // macmon uses -sram variants as primary on all M-series chips (M1–M4+).
        eFreqs = pick(["voltage-states1-sram", "voltage-states1"])
        pFreqs = pick(["voltage-states5-sram", "voltage-states5"])
        // GPU: macmon uses voltage-states9 as primary.
        gpuFreqs = pick(["voltage-states9", "voltage-states11", "voltage-states10",
                         "voltage-states2", "voltage-states12", "voltage-states13"])
    }

    /// Walk the AppleARMIODevice subtree to find the entry holding voltage-states.
    private func findEntryWithDVFS() -> io_registry_entry_t? {
        var iter = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("AppleARMIODevice"), &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            // Dump this entry's property keys; if any look like voltage-states,
            // this is our DVFS entry.
            var propsRef: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(service, &propsRef, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let props = propsRef?.takeRetainedValue() as? [String: Any] {
                let vsKeys = props.keys.filter { $0.hasPrefix("voltage-states") }
                if !vsKeys.isEmpty {
                    return service
                }
            }
            IOObjectRelease(service)
            service = IOIteratorNext(iter)
        }
        return nil
    }

    /// Sample once; returns average MHz per group plus GPU busy% (residency).
    public func sample() -> (e: Double?, p: Double?, gpu: Double?, gpuBusy: Double?) {
        guard available, let sub = subscription, let chan = channels,
              let s1 = createSamples?(sub, chan, nil)?.takeRetainedValue()
        else { return (nil, nil, nil, nil) }

        // We use the delta vs the previous sample (priming on the first call).
        defer { prevSample = s1 }
        guard let prev = prevSample,
              let delta = createDelta?(prev, s1, nil)?.takeRetainedValue()
        else { return (nil, nil, nil, nil) }

        var eRes: [Int64] = []
        var pRes: [Int64] = []
        var gpuRes: [Int64] = []

        let dict = delta as NSDictionary
        guard let items = dict["IOReportChannels"] as? [CFDictionary] else { return (nil, nil, nil, nil) }

        // Track how many leading states are non-active for the GPU channel.
        // macmon finds the first state whose name is NOT IDLE/DOWN/OFF.
        // We lock in the offset from the FIRST GPU channel we see — subsequent
        // GPU channels (e.g. GPUPH + GPU PM on M-series) would overwrite it and
        // corrupt the busy% / avgFreq calculation for the accumulated residencies.
        var gpuIdleOffset = 1
        var gpuOffsetLocked = false

        for chDict in items {
            // IOReportChannelGet* follow the Get rule (+0 retain) → takeUnretainedValue.
            let group = (getGroup?(chDict)?.takeUnretainedValue() as String?) ?? ""
            let chanName = (getChanName?(chDict)?.takeUnretainedValue() as String?) ?? ""
            // Clamped for the same reason as the SMC key count: this number
            // comes from a private API, and an unbounded value would append
            // billions of entries before anything noticed.
            let count = min(Int(stateCount?(chDict) ?? 0), 1024)
            guard count > 0 else { continue }
            var residencies: [Int64] = []
            for i in 0..<count { residencies.append(stateResidency?(chDict, Int32(i)) ?? 0) }

            // Classify by channel name: ECPU/PCPU/GPU (Apple Silicon naming).
            let key = chanName.uppercased()
            if group.contains("GPU") || key.contains("GPU") {
                // Count leading IDLE/DOWN/OFF states by name so busyPercent is
                // accurate even when there are multiple non-active buckets (e.g. GPUPH
                // on M-series has IDLE + DFLR before the first active frequency state).
                if !gpuOffsetLocked {
                    var offset = 0
                    for i in 0..<count {
                        let sn = (stateName?(chDict, Int32(i))?.takeUnretainedValue() as String?)?.uppercased() ?? ""
                        if sn == "IDLE" || sn == "DOWN" || sn == "OFF" { offset += 1 } else { break }
                    }
                    if offset > 0 {
                        gpuIdleOffset = offset
                        gpuOffsetLocked = true
                    }
                }
                accumulate(&gpuRes, residencies)
            } else if key.contains("ECPU") || key.hasPrefix("E") {
                accumulate(&eRes, residencies)
            } else if key.contains("PCPU") || key.hasPrefix("P") {
                accumulate(&pRes, residencies)
            }
        }

        return (avgFreq(residencies: eRes, freqs: eFreqs),
                avgFreq(residencies: pRes, freqs: pFreqs),
                avgFreq(residencies: gpuRes, freqs: gpuFreqs, idleStates: gpuIdleOffset),
                busyPercent(gpuRes, idleStates: gpuIdleOffset))
    }

    /// Busy% from residency: (total − idle_states) / total.
    private func busyPercent(_ res: [Int64], idleStates: Int = 1) -> Double? {
        guard res.count > idleStates else { return nil }
        let total = res.reduce(0, +)
        guard total > 0 else { return nil }
        let idle = res.prefix(idleStates).reduce(0, +)
        return Double(total - idle) / Double(total) * 100
    }

    private func accumulate(_ acc: inout [Int64], _ add: [Int64]) {
        if acc.isEmpty { acc = add; return }
        for i in 0..<min(acc.count, add.count) { acc[i] += add[i] }
    }

    /// Weighted-average frequency over active states only.
    ///
    /// Bug fix: the `usage` denominator must only include states that have a
    /// paired entry in `freqs`. When `active.count > freqs.count` (multiple
    /// clusters accumulated into one array on Pro/Max chips), a denominator built
    /// from all active states causes the sum of weights to be < 1, producing a
    /// frequency estimate lower than reality.
    private func avgFreq(residencies: [Int64], freqs: [Double], idleStates: Int = 1) -> Double? {
        guard residencies.count > idleStates, !freqs.isEmpty else { return nil }
        let active = Array(residencies.dropFirst(idleStates))
        // Only pair up as many states as both arrays share.
        let pairedCount = min(active.count, freqs.count)
        let usage = active.prefix(pairedCount).reduce(0, +)
        guard usage > 0 else { return nil }   // fully idle → show "—" in UI
        var freq = 0.0
        for i in 0..<pairedCount {
            freq += (Double(active[i]) / Double(usage)) * freqs[i]
        }
        return freq
    }
}
