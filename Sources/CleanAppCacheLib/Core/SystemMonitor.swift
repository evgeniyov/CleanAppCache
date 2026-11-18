import Foundation
import AppKit
import Darwin
import IOKit
import IOKit.ps

// MARK: - Snapshot model

/// A single point-in-time reading of system metrics.
public struct SystemSnapshot: Sendable {
    public var cpuPercent: Double          // 0…100 (overall)
    public var perCorePercent: [Double]    // 0…100 per logical core
    public var memUsedBytes: UInt64
    public var memTotalBytes: UInt64
    public var memPressure: MemoryPressure
    public var memPressurePercent: Double  // 0…100, drives the colored bar

    // Memory panel. These four are not a second opinion on
    // `memUsedBytes` — they are its parts: app + wired + compressed sums to it
    // exactly (verified to the byte on this Mac: 5.85 + 3.53 + 3.65 = 13.03 GB),
    // and file cache is the reclaimable remainder that `memUsedBytes` excludes.
    /// Anonymous memory owned by running apps — Activity Monitor's "App Memory".
    public var memAppBytes: UInt64
    /// File-backed pages the kernel is keeping around — "Cached Files".
    public var memFileCacheBytes: UInt64
    public var memWiredBytes: UInt64
    public var memCompressedBytes: UInt64

    /// Bytes of swap currently in use (vm.swapusage). 0 when swap is empty.
    public var swapUsedBytes: UInt64
    public var netDownBytesPerSec: Double
    public var netUpBytesPerSec: Double

    // Network panel.
    /// BSD name of the physical interface carrying the default route ("en0").
    public var netInterfaceBSDName: String?
    /// macOS's own name for it ("Wi-Fi"), nil when it has none (virtual links).
    public var netInterfaceName: String?
    /// Its routable IPv4 address, or a global IPv6 one when there is no IPv4.
    public var netLocalAddress: String?
    /// Traffic counted since this sampler started — the "this session" row.
    public var netSessionDownBytes: UInt64
    public var netSessionUpBytes: UInt64
    /// Seconds since the last tick that carried traffic; nil while traffic is
    /// flowing. The panel shows an "idle" row in place of "this session" when
    /// this is set.
    public var netIdleSeconds: TimeInterval?

    public var diskReadBytesPerSec: Double
    public var diskWriteBytesPerSec: Double
    /// The "operations/s" row — read+write I/O operations per second, derived from the
    /// same cumulative IOKit counters as the byte rates.
    public var diskOpsPerSec: Double
    /// The "device" row — the internal drive's product name.
    public var storageDeviceName: String?
    /// The "SSD endurance" / "SMART status" rows. nil on hardware with no readable
    /// NVMe SMART log; never derived from anything else.
    public var ssdEndurance: SSDEndurance?

    /// A larger set of processes; views sort/slice as needed.
    public var processes: [ProcessInfoItem]
    /// Changes only when `processes` was listed afresh. The list is cached for
    /// longer than one tick, and a tick that repeats it repeats this value, so a
    /// consumer can skip re-deriving anything from an unchanged list.
    public var processListID: Int

    public var uptimeSeconds: TimeInterval

    // CPU / GPU panels.
    /// Live threads across the whole system — the "threads" row.
    public var threadCount: Int?
    /// 1-minute load average — rendered as "2.1 of 12 cores".
    public var loadAverage1m: Double?
    /// Active displays — the "displays" row.
    public var displayCount: Int?

    // Best-effort / may be nil on some hardware
    public var batteryPercent: Double?
    public var batteryCharging: Bool?
    public var batteryCycleCount: Int?
    /// Battery health = current max capacity / design capacity (0…100), or nil.
    public var batteryHealthPercent: Double?
    /// The "full-charge capacity" row — present full-charge capacity, and the design
    /// capacity it is measured against. Both in mAh, both read from the battery.
    public var batteryCapacityMAh: Int?
    public var batteryDesignCapacityMAh: Int?
    /// The "power" row — adapter wattage, nil when running on battery.
    public var powerAdapterWatts: Int?
    public var gpuPercent: Double?

    // Temperatures (°C) — best-effort via SMC; nil when sensor unreadable.
    public var tempCPU: Double?
    public var tempGPU: Double?
    public var tempBattery: Double?
    /// Which subsystem actually produced `tempCPU` / `tempGPU`.
    ///
    /// SMC and IOHID measure different things, so "is 50 °C the real CPU
    /// temperature?" cannot be answered without knowing which one answered.
    /// Surfaced in the sensors panel instead of being guessed at.
    public var tempOrigin: TempOrigin

    // CPU/GPU frequencies (MHz) via IOReport DVFS — nil when unavailable.
    public var freqECluster: Double?
    public var freqPCluster: Double?
    public var freqGPU: Double?

    public var memPercent: Double {
        memTotalBytes > 0 ? Double(memUsedBytes) / Double(memTotalBytes) * 100 : 0
    }

    /// Convenience: top processes by CPU (used by the compact summary).
    public var topProcesses: [ProcessInfoItem] {
        Array(processes.sorted { $0.cpuPercent > $1.cpuPercent }.prefix(6))
    }
}

/// macOS-style memory pressure: green / yellow / red — reflects responsiveness,
/// not raw "used of total".
public enum MemoryPressure: String, Sendable {
    case normal, warning, critical
}

public struct TempSensor: Identifiable, Sendable {
    /// Unique per reading, not per name. IOHID hands back several distinct
    /// services sharing one `Product` string — this Mac reports six sensors all
    /// called "gas gauge battery" — so keying on `name` alone would break the
    /// `Identifiable` contract for any view that iterates the raw list.
    public let id: String
    public let name: String
    public let celsius: Double

    public init(index: Int, name: String, celsius: Double) {
        self.id = "\(index)-\(name)"
        self.name = name
        self.celsius = celsius
    }
}

/// Where a temperature reading came from. The two subsystems are not
/// interchangeable: SMC `Tp*`/`Te*`/`Tg*` are per-cluster junction sensors,
/// while IOHID exposes thermal-zone dies that read a few degrees lower.
public enum TempSource: String, Sendable {
    /// SMC per-cluster keys — the same figure macmon and Stats report.
    case smc
    /// A single named SMC key from the fallback list.
    case smcSingleKey
    /// IOHID pACC/eACC/GPU "MTR Temp Sensor" — per-cluster, close to SMC.
    case iohidCluster
    /// IOHID die/thermal-zone sensors — reads a few °C below junction temp.
    case iohidDie
    case unavailable
}

public struct TempOrigin: Sendable {
    public var cpu: TempSource
    public var gpu: TempSource
    /// Raw SMC enumeration diagnostics: key count and how many Tp/Te/Tg keys
    /// passed validation. `keys:0` means the SMC connection returns nothing.
    public var smcDiagnostics: String

    public init(cpu: TempSource = .unavailable,
                gpu: TempSource = .unavailable,
                smcDiagnostics: String = "") {
        self.cpu = cpu
        self.gpu = gpu
        self.smcDiagnostics = smcDiagnostics
    }
}

public struct ProcessInfoItem: Identifiable, Sendable {
    public let id: Int32         // pid
    public let ppid: Int32       // parent pid
    public let name: String
    public let cpuPercent: Double
    public let memBytes: UInt64

    public init(id: Int32, ppid: Int32 = 0, name: String, cpuPercent: Double, memBytes: UInt64) {
        self.id = id
        self.ppid = ppid
        self.name = name
        self.cpuPercent = cpuPercent
        self.memBytes = memBytes
    }
}

/// A process group: a "lead" process plus its children, with summed totals.
public struct ProcessGroup: Identifiable, Sendable {
    public let id: String        // group key (normalized name)
    public let name: String
    public let cpuPercent: Double
    public let memBytes: UInt64
    public let children: [ProcessInfoItem]   // sorted; >1 means expandable
}

/// Static machine facts, sampled once.
public struct MachineInfo: Sendable {
    public let model: String         // e.g. "MacBook Air (M2, 2022)" or raw id
    public let chip: String          // e.g. "Apple M2" / Intel brand
    public let totalCores: Int
    public let perfCores: Int        // performance cores (P)
    public let effCores: Int         // efficiency cores (E)
    /// Cluster type ("E"/"P"/…) per logical core index, read from the IORegistry
    /// device tree (`cluster-type` + `cpu-id`). nil → fall back to the
    /// "E-cores first" ordering heuristic. Robust against future chips that add
    /// a third cluster type.
    public let clusterMap: [String]?
}

// MARK: - System monitor (sampler)
//
// Computes rate-based metrics (CPU, network, disk) from the delta between two
// samples, so the first call only primes the counters. All APIs used here are
// public; battery and GPU are best-effort and return nil when unavailable.

/// Not thread-safe. The delta counters, TTL caches and owned sensor readers are
/// unsynchronised mutable state, so `@unchecked Sendable` holds only while each
/// instance is driven from a single serial queue. `MonitorViewModel` drives
/// `shared` on its sample queue (reading `machineInfo()` in its init, before
/// it queues anything, and probing the GPU sensor on that queue), and
/// `MenuBarController` owns a separate instance driven on its own queue. Do not
/// share an instance across queues; another consumer creates its own instance.
/// `terminate(pid:)` and `groupProcesses(_:)` read no instance state.
public final class SystemMonitor: @unchecked Sendable {
    public static let shared = SystemMonitor()

    // Previous counters for delta computation.
    private var prevCPUTicks: host_cpu_load_info?
    private var prevPerCore: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
    private var networkCounters = NetworkCounters()
    private var diskCounters = DiskCounters()
    private var prevMono: TimeInterval?

    /// Monotonic seconds for rate denominators and cache aging. `Date()` is the
    /// wrong clock for both: a backward step (manual change, NTP correction)
    /// made one tick's dt negative — clamped to 0.2 s, it inflated the rate up
    /// to 10× and the auto-scaled sparklines kept that spike as their ceiling —
    /// and left every TTL cache "fresh" until the wall clock re-crossed its
    /// stamp. CLOCK_MONOTONIC never steps and keeps counting across sleep, so
    /// a large gap also reliably identifies a sleep/suspend.
    static func monotonicNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC)) / 1_000_000_000
    }

    /// Awake-only monotonic seconds (pauses during sleep). The right
    /// denominator for per-process CPU%: task CPU time does not accrue while
    /// the machine sleeps either, so the first post-wake refresh divides
    /// awake-time deltas by awake-time elapsed instead of showing ~0% for
    /// everything.
    static func uptimeNow() -> TimeInterval {
        TimeInterval(clock_gettime_nsec_np(CLOCK_UPTIME_RAW)) / 1_000_000_000
    }

    /// Gap (s) beyond which a tick is treated as "the machine was away"
    /// (sleep, suspension): counter deltas then span the gap, and dividing by
    /// it would present an hours-long average as the current rate.
    private static let sleepGap: TimeInterval = 30

    // Session totals and the idle clock behind the network panel's "this
    // session" / "idle" rows.
    // Accumulated from the deltas we already compute — no extra syscall.
    private var sessionDown: UInt64 = 0
    private var sessionUp: UInt64 = 0
    /// Monotonic stamp — the idle readout is an elapsed time, and a wall
    /// clock stepping backward made it negative (hidden by the view's >= 1
    /// gate) or stepping forward inflated it by the step size.
    private var lastNetActivity: TimeInterval?

    // Owned helper instances — each SystemMonitor has its own, so the in-app
    // monitor and the menu-bar widget never race shared subscription state.
    //
    // Lazy, so each is built on first use by the queue that drives this
    // instance rather than on the main thread that creates it. The IOReport
    // subscription costs 60–90 ms and about half a megabyte, and the menu-bar
    // instance never reads a frequency; the IOHID client is only a fallback
    // for when SMC answers nothing.
    private lazy var ioReport = IOReportFreq()
    private lazy var smc = SMCReader()
    private lazy var ioHID = IOHIDThermal()

    /// Internal so a second, independent instance can back the menu-bar widget
    /// without sharing delta counters with the in-app monitor.
    ///
    /// `temperatureTTL` must be at least as long as the caller's sampling
    /// interval or the cache never hits: the menu bar ticks every 5 s against a
    /// 4 s TTL, so a full SMC key sweep plus IOHID walk ran on *every* tick,
    /// around the clock, for a chip that shows one number.
    init(temperatureTTL: TimeInterval = 4) {
        self.tempCacheTTL = temperatureTTL
    }

    /// Which temperatures a sample has to produce. Each costs its own SMC reads,
    /// and one that SMC cannot answer costs the IOHID walk, so a caller names
    /// only the ones it shows.
    public struct TemperatureSet: OptionSet, Sendable {
        public let rawValue: Int
        public init(rawValue: Int) { self.rawValue = rawValue }

        public static let cpu = TemperatureSet(rawValue: 1 << 0)
        public static let gpu = TemperatureSet(rawValue: 1 << 1)
        public static let battery = TemperatureSet(rawValue: 1 << 2)
        public static let all: TemperatureSet = [.cpu, .gpu, .battery]
    }

    /// Medium reading for the menu bar: CPU, memory, GPU load and CPU/GPU temps.
    /// GPU + temps are internally throttled (cached a few seconds), so this is
    /// still cheap on a short cadence. No processes / network / disk.
    public struct MenuReading: Sendable {
        public var cpu: Double
        /// Per-logical-core load, 0…100. `sampleCPU` already computes it for the
        /// main screen; the status bar's per-core layout reads the same array
        /// rather than sampling a second time.
        public var perCore: [Double]
        public var memPercent: Double
        public var memPressure: MemoryPressure
        public var gpu: Double?
        /// nil when not asked for, as well as when unreadable.
        public var cpuTemp: Double?
        public var gpuTemp: Double?
    }

    public func menuSample(includeGPU: Bool = true,
                           temperatures: TemperatureSet = [.cpu, .gpu]) -> MenuReading {
        let (cpu, perCore) = sampleCPU()
        let mem = sampleMemory()
        // GPU load needs an IOAccelerator registry walk; each temperature needs
        // its SMC key set. These are the app's always-on cost, so skip whatever
        // the bar isn't showing while the popover is closed.
        let gpu = includeGPU ? sampleGPUThrottled() : nil
        let temps = temperatures.isEmpty ? nil : sampleTemperaturesThrottled(temperatures)
        return MenuReading(
            cpu: cpu,
            perCore: perCore,
            memPercent: Double(mem.used) / Double(max(mem.total, 1)) * 100,
            memPressure: mem.pressure,
            gpu: gpu,
            cpuTemp: temperatures.contains(.cpu) ? temps?.cpu : nil,
            gpuTemp: temperatures.contains(.gpu) ? temps?.gpu : nil
        )
    }

    public func sample() -> SystemSnapshot {
        let nowMono = Self.monotonicNow()
        let dt = prevMono.map { nowMono - $0 } ?? 1
        prevMono = nowMono
        // Past the sleep gap the samplers keep the new baselines but report
        // zero rates so counters accumulated during the gap cannot spike.
        let slept = dt > Self.sleepGap
        let interval = min(max(0.2, dt), Self.sleepGap)

        let (cpu, cores) = sampleCPU()
        let mem = sampleMemory()
        let swap = sampleSwapUsed()
        let net = sampleNetwork(interval: interval, resetBaseline: slept)
        let disk = sampleDisk(interval: interval, resetBaseline: slept)
        let procs = listProcessesThrottled(limit: 40)
        let battery = sampleBattery()
        let temps = sampleTemperaturesThrottled(.all)
        let freqs = ioReport.sample()

        return SystemSnapshot(
            cpuPercent: cpu,
            perCorePercent: cores,
            memUsedBytes: mem.used,
            memTotalBytes: mem.total,
            memPressure: mem.pressure,
            memPressurePercent: mem.pressurePercent,
            memAppBytes: mem.app,
            memFileCacheBytes: mem.fileCache,
            memWiredBytes: mem.wired,
            memCompressedBytes: mem.compressed,
            swapUsedBytes: swap,
            netDownBytesPerSec: net.down,
            netUpBytesPerSec: net.up,
            netInterfaceBSDName: net.interfaceBSDName,
            netInterfaceName: net.interfaceBSDName.flatMap { displayName(for: $0) },
            netLocalAddress: net.localAddress,
            netSessionDownBytes: sessionDown,
            netSessionUpBytes: sessionUp,
            netIdleSeconds: net.idleSeconds,
            diskReadBytesPerSec: disk.read,
            diskWriteBytesPerSec: disk.write,
            diskOpsPerSec: disk.ops,
            storageDeviceName: storageDeviceNameCached(),
            ssdEndurance: ssdEnduranceCached(),
            processes: procs.items,
            processListID: procs.id,
            uptimeSeconds: uptimeSinceBoot(),
            threadCount: SystemProbes.systemThreadCount(),
            loadAverage1m: SystemProbes.loadAverage1m(),
            displayCount: displayCountThrottled(),
            batteryPercent: battery.percent,
            batteryCharging: battery.charging,
            batteryCycleCount: battery.cycles,
            batteryHealthPercent: battery.health,
            batteryCapacityMAh: battery.capacityMAh,
            batteryDesignCapacityMAh: battery.designMAh,
            powerAdapterWatts: powerAdapterThrottled(),
            // GPU load = IOAccelerator "Device Utilization %", the same figure
            // Activity Monitor's GPU history shows.
            //
            // NOT the IOReport residency: its non-OFF fraction counts every tick
            // the GPU is merely *powered on*, and macOS parks the GPU in its
            // lowest DVFS state (P1) to composite the desktop. Measured on an
            // otherwise idle M4, residency reported 12–33 % against 8–20 % from
            // IOAccelerator — it reads "awake", not "busy". Kept only as a
            // fallback for hardware that publishes no accelerator statistics.
            gpuPercent: sampleGPUThrottled() ?? freqs.gpuBusy,
            tempCPU: temps.cpu,
            tempGPU: temps.gpu,
            tempBattery: temps.battery,
            tempOrigin: temps.origin,
            freqECluster: freqs.e,
            freqPCluster: freqs.p,
            freqGPU: freqs.gpu
        )
    }

    // MARK: CPU

    private func sampleCPU() -> (overall: Double, perCore: [Double]) {
        // Overall via host_statistics
        var count = mach_msg_type_number_t(MemoryLayout<host_cpu_load_info>.stride / MemoryLayout<integer_t>.stride)
        var info = host_cpu_load_info()
        let overall: Double = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        } == KERN_SUCCESS ? computeOverallCPU(info) : 0

        let perCore = samplePerCore()
        return (overall, perCore)
    }

    private func computeOverallCPU(_ info: host_cpu_load_info) -> Double {
        defer { prevCPUTicks = info }
        guard let prev = prevCPUTicks else { return 0 }
        // cpu_ticks are cumulative UInt32 counters accruing at ~100 Hz × cores
        // since boot, so each wraps 2^32 after weeks of uptime. '&-' stays
        // exact across a wrap where checked '-' would trap and kill the app
        // mid-sample; samplePerCore already deltas its ticks the same way.
        let user = Double(info.cpu_ticks.0 &- prev.cpu_ticks.0)
        let system = Double(info.cpu_ticks.1 &- prev.cpu_ticks.1)
        let idle = Double(info.cpu_ticks.2 &- prev.cpu_ticks.2)
        let nice = Double(info.cpu_ticks.3 &- prev.cpu_ticks.3)
        let total = user + system + idle + nice
        guard total > 0 else { return 0 }
        return (user + system + nice) / total * 100
    }

    private func samplePerCore() -> [Double] {
        var cpuCount: natural_t = 0
        var infoArray: processor_info_array_t?
        var infoCount: mach_msg_type_number_t = 0

        let result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                         &cpuCount, &infoArray, &infoCount)
        guard result == KERN_SUCCESS, let array = infoArray else { return [] }
        defer {
            vm_deallocate(mach_task_self_, vm_address_t(bitPattern: array),
                          vm_size_t(infoCount) * vm_size_t(MemoryLayout<integer_t>.stride))
        }

        var current: [(user: UInt32, system: UInt32, idle: UInt32, nice: UInt32)] = []
        current.reserveCapacity(Int(cpuCount))
        for i in 0..<Int(cpuCount) {
            let base = i * Int(CPU_STATE_MAX)
            let user = UInt32(bitPattern: array[base + Int(CPU_STATE_USER)])
            let system = UInt32(bitPattern: array[base + Int(CPU_STATE_SYSTEM)])
            let idle = UInt32(bitPattern: array[base + Int(CPU_STATE_IDLE)])
            let nice = UInt32(bitPattern: array[base + Int(CPU_STATE_NICE)])
            current.append((user, system, idle, nice))
        }

        defer { prevPerCore = current }
        guard prevPerCore.count == current.count else { return Array(repeating: 0, count: current.count) }

        return current.enumerated().map { idx, c in
            let p = prevPerCore[idx]
            let user = Double(c.user &- p.user)
            let system = Double(c.system &- p.system)
            let idle = Double(c.idle &- p.idle)
            let nice = Double(c.nice &- p.nice)
            let total = user + system + idle + nice
            return total > 0 ? (user + system + nice) / total * 100 : 0
        }
    }

    // MARK: Memory

    /// VM page size queried at runtime (avoids the non-concurrency-safe global
    /// `vm_kernel_page_size`).
    private func pageSizeBytes() -> vm_size_t {
        var size: vm_size_t = 0
        return host_page_size(mach_host_self(), &size) == KERN_SUCCESS ? size : vm_size_t(4096)
    }

    /// One memory reading. The memory panel needs the breakdown fields, so they
    /// are carried out of the one `host_statistics64` call rather than being
    /// recomputed by a second one.
    private struct MemorySample {
        var used: UInt64
        var total: UInt64
        var pressure: MemoryPressure
        var pressurePercent: Double
        var app: UInt64
        var fileCache: UInt64
        var wired: UInt64
        var compressed: UInt64
    }

    private func sampleMemory() -> MemorySample {
        let total = ProcessInfo.processInfo.physicalMemory

        var stats = vm_statistics64()
        var count = mach_msg_type_number_t(MemoryLayout<vm_statistics64>.stride / MemoryLayout<integer_t>.stride)
        let result = withUnsafeMutablePointer(to: &stats) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics64(mach_host_self(), HOST_VM_INFO64, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else {
            return MemorySample(used: 0, total: total, pressure: .normal, pressurePercent: 0,
                                app: 0, fileCache: 0, wired: 0, compressed: 0)
        }

        let pageSize = UInt64(pageSizeBytes())
        let active = UInt64(stats.active_count) * pageSize
        let wired = UInt64(stats.wire_count) * pageSize
        let compressed = UInt64(stats.compressor_page_count) * pageSize
        // "Used" matching Activity Monitor / macmon: include inactive +
        // speculative, minus purgeable + external (file-backed). Plain
        // active+wired+compressed under-counts by ~2 GB.
        let inactive = UInt64(stats.inactive_count) * pageSize
        let speculative = UInt64(stats.speculative_count) * pageSize
        let purgeable = UInt64(stats.purgeable_count) * pageSize
        let external = UInt64(stats.external_page_count) * pageSize
        let gross = active + inactive + speculative + wired + compressed
        let reclaimable = purgeable + external
        let used = gross > reclaimable ? gross - reclaimable : gross

        // The memory panel's breakdown, using Activity Monitor's own definitions:
        //   App Memory   = internal (anonymous) pages minus the purgeable ones
        //   Cached Files = file-backed pages plus purgeable
        // These are not an independent estimate: on this kernel
        // internal + external == active + inactive + speculative, so
        // app + wired + compressed is algebraically the same `used` computed
        // above (checked to the byte: 5.85 + 3.53 + 3.65 == 13.03 GB). If a
        // future kernel breaks that invariant the panel would silently stop
        // adding up, so the parts are clamped rather than allowed to go
        // negative.
        let internalPages = UInt64(stats.internal_page_count) * pageSize
        let app = internalPages > purgeable ? internalPages - purgeable : 0
        let fileCache = external + purgeable

        // The colored bar magnitude still uses the wired+compressed share (a
        // reasonable "hard to reclaim" gauge), but the actual pressure LEVEL
        // (green/yellow/red) is read from the kernel — this is exactly what
        // Activity Monitor's memory-pressure gauge reflects, and a formula can't
        // reproduce it. Fall back to the heuristic only if the sysctl is missing.
        let hardToReclaim = Double(wired + compressed)
        let pct = total > 0 ? hardToReclaim / Double(total) * 100 : 0
        let pressure: MemoryPressure = Self.readPressureLevel() ?? {
            switch pct {
            case ..<50: return .normal
            case ..<75: return .warning
            default:    return .critical
            }
        }()
        return MemorySample(used: used, total: total, pressure: pressure, pressurePercent: pct,
                            app: app, fileCache: fileCache, wired: wired, compressed: compressed)
    }

    /// The real macOS memory-pressure level (matches Activity Monitor's gauge).
    /// `kern.memorystatus_vm_pressure_level`: 1 = normal, 2 = warning, 4 = critical.
    private static func readPressureLevel() -> MemoryPressure? {
        var level: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0
        else { return nil }
        switch level {
        case 4:  return .critical
        case 2:  return .warning
        default: return .normal
        }
    }

    // MARK: Swap (vm.swapusage)

    private func sampleSwapUsed() -> UInt64 {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return 0 }
        return usage.xsu_used
    }

    // MARK: Uptime (kern.boottime)

    /// Seconds since boot, sleep included. `ProcessInfo.systemUptime` is the
    /// awake-only clock (CLOCK_UPTIME_RAW — it tracks that clock to the
    /// microsecond), so on a laptop that sleeps it understated the panel's
    /// "up N days": measured here, 1.4 days shown against 2.94 days since
    /// restart. "Up N" means time since boot, which is wall clock minus
    /// `kern.boottime` — the same figure `uptime` and Activity Monitor report.
    private func uptimeSinceBoot() -> TimeInterval {
        var boot = timeval()
        var size = MemoryLayout<timeval>.size
        guard sysctlbyname("kern.boottime", &boot, &size, nil, 0) == 0, boot.tv_sec > 0 else {
            // No boot time to subtract — the awake clock is then the least
            // wrong figure available, never a fabricated one.
            return ProcessInfo.processInfo.systemUptime
        }
        let bootEpoch = Double(boot.tv_sec) + Double(boot.tv_usec) / 1_000_000
        return max(0, Date().timeIntervalSince1970 - bootEpoch)
    }

    // MARK: Network (physical interfaces only)

    struct NetworkCounters {
        struct Interface: Hashable {
            let name: String
            let index: UInt32
        }

        struct Bytes {
            let received: UInt32
            let sent: UInt32
        }

        struct Delta: Equatable {
            let received: UInt64
            let sent: UInt64
        }

        private var previous: [Interface: Bytes]?

        mutating func reset() { previous = nil }

        mutating func update(_ current: [Interface: Bytes]) -> Delta? {
            defer { previous = current }
            guard let previous else { return nil }
            var received: UInt64 = 0
            var sent: UInt64 = 0
            for (interface, bytes) in current {
                // A new link's lifetime counters are not session traffic. An
                // unplugged link contributes nothing and loses its baseline.
                guard let old = previous[interface] else { continue }
                // if_data counters wrap independently at 2^32. Delta each
                // retained link before widening and summing the byte counts.
                received += UInt64(bytes.received &- old.received)
                sent += UInt64(bytes.sent &- old.sent)
            }
            return Delta(received: received, sent: sent)
        }
    }

    private struct NetSample {
        var down: Double
        var up: Double
        var interfaceBSDName: String?
        var localAddress: String?
        var idleSeconds: TimeInterval?
    }

    /// Throughput over the physical links, plus the identity of the one that
    /// carries the default route (the "interface" / "local address" rows).
    ///
    /// Summing every non-loopback interface counts VPN traffic twice — once on
    /// the tunnel and again on the physical link that actually puts the packets
    /// on the wire (measured on a test Mac: utun13 carried 796 MB that en0 had
    /// already counted). `SystemProbes.isPhysicalLinkType` restricts the sum
    /// to real hardware, so tunnels, bridges and VLANs do not inflate it.
    private func sampleNetwork(interval: TimeInterval,
                               resetBaseline: Bool = false) -> NetSample {
        var counters: [NetworkCounters.Interface: NetworkCounters.Bytes] = [:]
        var ifaddr: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifaddr) == 0, let first = ifaddr else {
            networkCounters.reset()
            return NetSample(down: 0, up: 0, interfaceBSDName: nil, localAddress: nil, idleSeconds: nil)
        }
        defer { freeifaddrs(ifaddr) }

        var ptr: UnsafeMutablePointer<ifaddrs>? = first
        while let cur = ptr {
            defer { ptr = cur.pointee.ifa_next }
            guard let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                  let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self),
                  SystemProbes.isPhysicalLinkType(data.pointee.ifi_type)
            else { continue }
            let link = UnsafeRawPointer(addr).assumingMemoryBound(to: sockaddr_dl.self).pointee
            let interface = NetworkCounters.Interface(name: String(cString: cur.pointee.ifa_name),
                                                      index: UInt32(link.sdl_index))
            counters[interface] = NetworkCounters.Bytes(received: data.pointee.ifi_ibytes,
                                                        sent: data.pointee.ifi_obytes)
        }

        // Which physical link is carrying traffic. The routing table can name
        // several default routes at once (a transparent proxy inserts its own),
        // so prefer the first candidate that is physical — that is the interface
        // whose bytes the panel is showing, and the one whose address the user
        // recognises as theirs. Only if none of them is physical do we fall back
        // to naming the tunnel, which is then the literal truth.
        let candidates = defaultRouteInterfacesThrottled()
        let physical = candidates.first { name in
            var ptr: UnsafeMutablePointer<ifaddrs>? = first
            while let cur = ptr {
                defer { ptr = cur.pointee.ifa_next }
                guard String(cString: cur.pointee.ifa_name) == name,
                      let addr = cur.pointee.ifa_addr, addr.pointee.sa_family == UInt8(AF_LINK),
                      let data = cur.pointee.ifa_data?.assumingMemoryBound(to: if_data.self)
                else { continue }
                return SystemProbes.isPhysicalLinkType(data.pointee.ifi_type)
            }
            return false
        }
        let chosen = physical ?? candidates.first
        let address = chosen.flatMap { SystemProbes.address(of: $0, from: first) }

        guard let delta = networkCounters.update(counters) else {
            lastNetActivity = Self.monotonicNow()
            return NetSample(down: 0, up: 0, interfaceBSDName: chosen,
                             localAddress: address, idleSeconds: nil)
        }
        let downBytes = delta.received
        let upBytes = delta.sent
        sessionDown &+= downBytes
        sessionUp &+= upBytes

        // The panel shows "idle — no activity for N s" in place of the session
        // totals, so the idle clock is only meaningful while nothing is moving.
        var idle: TimeInterval?
        let nowMono = Self.monotonicNow()
        if downBytes == 0 && upBytes == 0 {
            idle = nowMono - (lastNetActivity ?? nowMono)
        } else {
            lastNetActivity = nowMono
        }

        // The deltas span a sleep (Power Nap can move real traffic — the
        // session totals above rightly keep it), but as a *rate* they would be
        // an hours-long average presented as current.
        if resetBaseline {
            return NetSample(down: 0, up: 0, interfaceBSDName: chosen,
                             localAddress: address, idleSeconds: idle)
        }

        return NetSample(down: Double(downBytes) / interval,
                         up: Double(upBytes) / interval,
                         interfaceBSDName: chosen,
                         localAddress: address,
                         idleSeconds: idle)
    }

    // MARK: Disk I/O (aggregate via IOKit block storage)

    struct DiskSample: Equatable {
        var read: Double = 0
        var write: Double = 0
        var ops: Double = 0
    }

    struct DiskCounters {
        struct Device {
            let read: UInt64
            let write: UInt64
            let ops: UInt64
        }

        private var previous: [UInt64: Device] = [:]

        mutating func update(_ current: [UInt64: Device], interval: TimeInterval,
                             resetBaseline: Bool = false) -> DiskSample {
            defer { previous = current }
            var sample = DiskSample()
            guard !resetBaseline else { return sample }
            for (id, value) in current {
                // New or reset drivers start a baseline. Their lifetime counters
                // cannot inflate the rate or hide activity on other drives.
                guard let old = previous[id], value.read >= old.read,
                      value.write >= old.write, value.ops >= old.ops else { continue }
                sample.read += Double(value.read - old.read) / interval
                sample.write += Double(value.write - old.write) / interval
                sample.ops += Double(value.ops - old.ops) / interval
            }
            return sample
        }
    }

    /// Byte rates and the "operations/s" row. "Operations (Read)"/"(Write)" sit in
    /// the same `Statistics` dictionary as the byte counters and are cumulative
    /// in exactly the same way, so the rate is the same delta ÷ interval.
    ///
    /// Mounted disk images are skipped. Their reads are not extra work for the
    /// machine — the DMG's backing file lives on the real drive, which has
    /// already counted them — so including them would double-count every install
    /// and every open archive. This is the same class of mistake as the
    /// VPN double-count in `sampleNetwork`. External drives are physical and
    /// still count.
    private func sampleDisk(interval: TimeInterval,
                            resetBaseline: Bool = false) -> DiskSample {
        var current: [UInt64: DiskCounters.Device] = [:]

        var iter = io_iterator_t()
        let match = IOServiceMatching("IOBlockStorageDriver")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else {
            return diskCounters.update([:], interval: interval)
        }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // The one property, not the whole table: copying every property
            // of the driver to read this key is most of the call's cost.
            guard let stats = IORegistryEntryCreateCFProperty(
                    service, "Statistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            var entryID: UInt64 = 0
            guard IORegistryEntryGetRegistryEntryID(service, &entryID) == KERN_SUCCESS,
                  !isVirtualBlockDevice(driver: service, entryID: entryID) else { continue }

            // The dictionary hands these back as Int64 or UInt64 depending on the
            // driver, hence the pair of casts (kept from the original code).
            func counter(_ key: String) -> UInt64 {
                if let v = stats[key] as? UInt64 { return v }
                if let v = stats[key] as? Int64 { return UInt64(max(0, v)) }
                return 0
            }
            current[entryID] = DiskCounters.Device(
                read: counter("Bytes (Read)"), write: counter("Bytes (Write)"),
                ops: counter("Operations (Read)") + counter("Operations (Write)"))
        }

        if IOIteratorIsValid(iter) == 0 { current.removeAll() }
        return diskCounters.update(current, interval: interval, resetBaseline: resetBaseline)
    }

    /// Whether a block-storage driver sits on a disk image rather than hardware.
    ///
    /// The verdict is a property of the device and never changes, but the set of
    /// devices does (every mounted DMG adds one), so it is memoized per
    /// IORegistry entry ID instead of being probed once: a cache miss costs one
    /// parent lookup, a hit costs nothing.
    private var virtualDeviceCache: [UInt64: Bool] = [:]

    private func isVirtualBlockDevice(driver: io_object_t, entryID: UInt64) -> Bool {
        if let known = virtualDeviceCache[entryID] { return known }
        // Unmounted images never come back under the same ID, so drop the whole
        // table once it has clearly outgrown the drives actually attached.
        if virtualDeviceCache.count > 64 { virtualDeviceCache.removeAll(keepingCapacity: true) }

        var parent = io_object_t()
        var virtual = false
        if IORegistryEntryGetParentEntry(driver, kIOServicePlane, &parent) == KERN_SUCCESS {
            defer { IOObjectRelease(parent) }
            // IOStorageProtocolCharacteristics.h: kIOPropertyPhysicalInterconnectTypeVirtual.
            virtual = SystemProbes.registryDictionary(parent, "Protocol Characteristics")?[
                "Physical Interconnect"] as? String == "Virtual Interface"
        }
        virtualDeviceCache[entryID] = virtual
        return virtual
    }

    // MARK: Battery (best-effort via IOKit power sources)

    private func sampleBattery() -> (percent: Double?, charging: Bool?, cycles: Int?, health: Double?,
                                     capacityMAh: Int?, designMAh: Int?) {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef]
        else { return (nil, nil, nil, nil, nil, nil) }
        // A connected UPS is a power source too, and taking `sources.first`
        // presented its charge as the Mac's battery — while cycles/health from
        // AppleSmartBattery stayed nil, a chimera panel. Only the internal
        // battery may fill the battery card; a UPS-equipped desktop shows "—"
        // like every other desktop.
        let internalDesc = sources.lazy
            .compactMap { IOPSGetPowerSourceDescription(blob, $0)?.takeUnretainedValue() as? [String: Any] }
            .first { $0[kIOPSTypeKey] as? String == kIOPSInternalBatteryType }
        guard let desc = internalDesc else { return (nil, nil, nil, nil, nil, nil) }

        var percent: Double?
        if let cur = desc[kIOPSCurrentCapacityKey] as? Double,
           let max = desc[kIOPSMaxCapacityKey] as? Double, max > 0 {
            percent = cur / max * 100
        }
        let charging = desc[kIOPSIsChargingKey] as? Bool
        let details = batteryDetails()
        return (percent, charging, details.cycles, details.health,
                details.capacityMAh, details.designMAh)
    }

    /// Cycle count, health (%) and the raw mAh pair from the AppleSmartBattery
    /// registry entry. The mAh figures are read here to compute health anyway,
    /// and the "full-charge capacity" row shows the numerator itself.
    private func batteryDetails() -> (cycles: Int?, health: Double?, capacityMAh: Int?, designMAh: Int?) {
        let match = IOServiceMatching("AppleSmartBattery")
        let service = IOServiceGetMatchingService(kIOMainPortDefault, match)
        guard service != 0 else { return (nil, nil, nil, nil) }
        defer { IOObjectRelease(service) }

        func intProp(_ key: String) -> Int? {
            (IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
                .takeRetainedValue()) as? Int
        }
        /// Nested `BatteryData` dictionary — where current macOS keeps the real
        /// mAh figures on Apple Silicon.
        let batteryData = (IORegistryEntryCreateCFProperty(
            service, "BatteryData" as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()) as? [String: Any]
        func dataInt(_ key: String) -> Int? { batteryData?[key] as? Int }

        let cycles = intProp("CycleCount")

        // Health = current maximum charge / design charge, both in mAh.
        //
        // Getting the *pair* right matters more than the exact numerator: on this
        // M4 running macOS 27 the top-level entry exposes only `MaxCapacity` = 100
        // (a normalized percentage) and no `AppleRawMaxCapacity` and no
        // `DesignCapacity` at all — the real values (DesignCapacity 4629,
        // NominalChargeCapacity 4493, FullChargeCapacity 4366) live inside
        // `BatteryData`. The previous lookup therefore found design == nil and
        // returned nil health on every Apple Silicon Mac; worse, had
        // `DesignCapacity` been present it would have divided the normalized 100
        // by 4629 mAh and reported a 2 % battery.
        //
        // Order: Intel's raw mAh key first, then Apple Silicon's nominal charge
        // (what macOS itself reports as "Maximum Capacity"), then full charge.
        let maxCap = intProp("AppleRawMaxCapacity")
            ?? dataInt("NominalChargeCapacity")
            ?? dataInt("FullChargeCapacity")
        let design = intProp("DesignCapacity") ?? dataInt("DesignCapacity")
        var health: Double?
        if let m = maxCap, let d = design, d > 0, m > 0 {
            health = min(100, Double(m) / Double(d) * 100)
        }
        return (cycles, health, maxCap, design)
    }

    // MARK: Temperatures (best-effort via SMC, throttled)

    private struct Temperatures {
        var cpu: Double?
        var gpu: Double?
        var battery: Double?
        var origin: TempOrigin
    }

    /// `covers` is what the cached reading was asked for: a reading taken for
    /// the CPU alone cannot answer a later request that includes the GPU.
    private var tempCache: (value: Temperatures, covers: TemperatureSet, at: TimeInterval)?
    private let tempCacheTTL: TimeInterval

    // Candidate SMC keys per sensor — first that reads wins. Intel uses
    // TC0D/TC0P/TG0P; Apple Silicon exposes different (often "Tp"/"Tg") keys,
    // many gated. We try a spread and accept whatever the hardware returns.
    // TC0D (die) sits deliberately ahead of TC0P (proximity): where both exist
    // the die sensor is the CPU temperature, and proximity reads several °C
    // low.
    private static let cpuTempKeys = ["TC0D", "TC0P", "TC0E", "TC0F", "Tp09", "Tp01", "Tp05", "Te05", "Te09", "TCAD"]
    private static let gpuTempKeys = ["TG0P", "TGDD", "Tg0G", "Tg0H", "Tg05", "Tg0D"]
    private static let batteryTempKeys = ["TB0T", "TB1T", "TB2T"]

    private func sampleTemperaturesThrottled(_ wanted: TemperatureSet) -> Temperatures {
        if let c = tempCache, c.covers.isSuperset(of: wanted),
           Self.monotonicNow() - c.at < tempCacheTTL {
            return c.value
        }
        let value = sampleTemperatures(wanted)
        tempCache = (value, wanted, Self.monotonicNow())
        return value
    }

    /// Every IOHID temperature sensor that reads, hottest first.
    ///
    /// Not part of `sample()`: no screen lists the sensors, and the walk costs
    /// about 45 ms for the 43 services on an M4. The sampler reads the same list
    /// only as the fallback for a temperature SMC could not produce.
    public func temperatureSensors() -> [TempSensor] {
        ioHID.readSensors()
            .enumerated()
            .map { TempSensor(index: $0.offset, name: $0.element.name, celsius: $0.element.value) }
            .sorted { $0.celsius > $1.celsius }
    }

    private func sampleTemperatures(_ wanted: TemperatureSet) -> Temperatures {
        let smc = self.smc
        func firstReadable(_ keys: [String]) -> Double? {
            for k in keys { if let v = smc.temperature(k) { return v } }
            return nil
        }

        // Primary: SMC Tp*/Te*/Ts* average — the all-core package temperature,
        // verified sample-for-sample against `macmon pipe` on an M4 (agreement
        // within 0.02 °C over a 20-sample run).
        // IOHID "PMU tdie" sensors are thermal-zone readings (~40 °C), not
        // per-core junction temps, so they read too low; used only as fallback.
        let smcSummary = smc.temperatureSummary(cpu: wanted.contains(.cpu),
                                                gpu: wanted.contains(.gpu))
        var cpu = smcSummary.cpu
        var gpu = smcSummary.gpu
        var origin = TempOrigin(
            cpu: cpu == nil ? .unavailable : .smc,
            gpu: gpu == nil ? .unavailable : .smc,
            smcDiagnostics: smc.diag
        )
        var battery = wanted.contains(.battery) ? firstReadable(Self.batteryTempKeys) : nil

        // The IOHID list backs only the fallbacks below, so it is read on the
        // first one that needs it and at most once. Where SMC answers every
        // requested value, the walk does not happen at all.
        lazy var hidSensors = temperatureSensors()

        func avgOf(_ hints: [String]) -> Double? {
            let m = hidSensors.filter { s in hints.contains { s.name.localizedCaseInsensitiveContains($0) } }
            guard !m.isEmpty else { return nil }
            return m.map(\.celsius).reduce(0, +) / Double(m.count)
        }

        // Fallbacks when SMC returns nothing. Mirror macmon's IOHID strategy:
        // average the dedicated per-cluster sensors (pACC/eACC MTR for CPU,
        // GPU MTR for GPU) rather than taking a single max — averaging is what
        // macmon/Stats report. A broader die-sensor average (PMU tdie) is only a
        // last resort: it reads a few °C below junction temp, so it's tried only
        // after the proper MTR sensors.
        // Each fallback records which subsystem answered, so the sensors panel
        // can state the source instead of leaving the user to guess whether a
        // number is a junction temperature or a thermal-zone die reading.
        // A value nobody asked for stays nil and never triggers a fallback.
        if wanted.contains(.cpu) {
            if cpu == nil {
                cpu = firstReadable(Self.cpuTempKeys)
                if cpu != nil { origin.cpu = .smcSingleKey }
            }
            if cpu == nil {
                cpu = avgOf(["pACC MTR Temp Sensor", "eACC MTR Temp Sensor"])
                if cpu != nil { origin.cpu = .iohidCluster }
            }
            if cpu == nil {
                cpu = avgOf(["pACC", "eACC", "PMU tdie", "tdie", "tdev"])
                if cpu != nil { origin.cpu = .iohidDie }
            }
        }
        if wanted.contains(.gpu) {
            if gpu == nil {
                gpu = firstReadable(Self.gpuTempKeys)
                if gpu != nil { origin.gpu = .smcSingleKey }
            }
            if gpu == nil {
                gpu = avgOf(["GPU MTR Temp Sensor"])
                if gpu != nil { origin.gpu = .iohidCluster }
            }
            if gpu == nil {
                gpu = avgOf(["GPU"])
                if gpu != nil { origin.gpu = .iohidDie }
            }
        }
        // Deliberately no `gpu = cpu` fallback: showing CPU temperature under a
        // GPU label is misleading. Leave GPU nil (UI shows "—") when nothing reads.
        if wanted.contains(.battery), battery == nil {
            battery = avgOf(["gas gauge", "battery"])
        }

        return Temperatures(cpu: cpu, gpu: gpu, battery: battery, origin: origin)
    }

    // MARK: GPU (best-effort, Apple Silicon via IOKit accelerator)

    // GPU/battery change slowly and the IOKit walk is costly, so cache for a
    // few seconds instead of querying every tick.
    private var gpuCache: (value: Double?, at: TimeInterval)?
    private let gpuCacheTTL: TimeInterval = 4

    private func sampleGPUThrottled() -> Double? {
        if let c = gpuCache, Self.monotonicNow() - c.at < gpuCacheTTL { return c.value }
        let v = sampleGPU()
        gpuCache = (v, Self.monotonicNow())
        return v
    }

    private func sampleGPU() -> Double? {
        var iter = io_iterator_t()
        let match = IOServiceMatching("IOAccelerator")
        guard IOServiceGetMatchingServices(kIOMainPortDefault, match, &iter) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iter) }

        var service = IOIteratorNext(iter)
        var best: Double?
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iter) }
            // Only the statistics key: copying the accelerator's whole property
            // table to read it costs about 0.9 ms against 0.02 ms. Either read
            // makes the driver close its utilization window, so the figure is
            // the same.
            guard let perf = IORegistryEntryCreateCFProperty(
                    service, "PerformanceStatistics" as CFString, kCFAllocatorDefault, 0)?
                    .takeRetainedValue() as? [String: Any] else { continue }
            // Several accelerators can enumerate at once (iGPU + dGPU, eGPU) in
            // unspecified IOKit order, and a powered-down GPU (automatic
            // graphics switching) reports 0 or stale utilization — letting the
            // last one win could show 3 % while the render GPU sat at 90 %.
            // The busiest accelerator is the one the user is asking about, and
            // an idle GPU can only pull the max toward the truth, never past
            // it. `best` stays nil when no accelerator publishes either key,
            // preserving the IOReport residency fallback.
            let util = (perf["Device Utilization %"] as? Int)
                ?? (perf["GPU Activity(%)"] as? Int)
            if let util = util {
                best = max(best ?? 0, Double(util))
            }
        }
        return best
    }

    // MARK: Detail panel facts — probed once, or throttled when they can change
    //
    // The sampler runs every 2 s in the app and every 5 s in the menu bar, so
    // nothing below may cost more than the IOKit walks already on that path.
    // Anything that cannot change without hardware being swapped is read once;
    // anything hot-pluggable gets the same few-second cache the GPU load uses.

    /// Active displays. Not a once-only probe despite being "static": monitors
    /// are hot-plugged, and `CGGetActiveDisplayList` costs ~0.3 ms, so a short
    /// cache keeps the hot path clean while the count still follows reality.
    private var displayCache: (value: Int?, at: TimeInterval)?

    private func displayCountThrottled() -> Int? {
        if let c = displayCache, Self.monotonicNow() - c.at < gpuCacheTTL { return c.value }
        let value = SystemProbes.activeDisplayCount()
        displayCache = (value, Self.monotonicNow())
        return value
    }

    /// Adapter wattage. Changes only when a cable is plugged or pulled.
    private var adapterCache: (value: Int?, at: TimeInterval)?

    private func powerAdapterThrottled() -> Int? {
        if let c = adapterCache, Self.monotonicNow() - c.at < gpuCacheTTL { return c.value }
        let value = SystemProbes.powerAdapterWatts()
        adapterCache = (value, Self.monotonicNow())
        return value
    }

    /// Default-route interfaces. The routing-table dump measures ~0.07 ms, but it
    /// scales with the size of the table, so it is refreshed on the same few-
    /// second cadence rather than every tick — a network change shows up within
    /// one cache period.
    private var routeCache: (value: [String], at: TimeInterval)?

    private func defaultRouteInterfacesThrottled() -> [String] {
        if let c = routeCache, Self.monotonicNow() - c.at < gpuCacheTTL { return c.value }
        let value = SystemProbes.defaultRouteInterfaces()
        routeCache = (value, Self.monotonicNow())
        return value
    }

    /// BSD name → macOS's own display name ("en0" → "Wi-Fi"). The lookup costs
    /// ~17 ms, far too much for the hot path, so it is built once and re-read
    /// only when a name shows up that it has never seen — i.e. when hardware was
    /// attached. `interfacesWithoutName` stops a tunnel (which SystemConfiguration
    /// never lists) from forcing that 17 ms rebuild on every single tick.
    private var interfaceNameCache: [String: String]?
    private var interfacesWithoutName: Set<String> = []

    private func displayName(for bsdName: String) -> String? {
        if let cached = interfaceNameCache?[bsdName] { return cached }
        if interfacesWithoutName.contains(bsdName) { return nil }
        let map = SystemProbes.interfaceDisplayNames()
        interfaceNameCache = map
        if let name = map[bsdName] { return name }
        interfacesWithoutName.insert(bsdName)
        return nil
    }

    /// Internal drive name — genuinely static, so it is probed once, including
    /// the "this Mac has no readable name" answer.
    private var storageDeviceProbed = false
    private var storageDeviceName: String?

    private func storageDeviceNameCached() -> String? {
        if !storageDeviceProbed {
            storageDeviceProbed = true
            storageDeviceName = SystemProbes.internalStorageDeviceName()
        }
        return storageDeviceName
    }

    /// SSD endurance. Percentage-used moves over months and one read costs 1–4 ms
    /// through the NVMe user client, so it is probed once per app run. A nil
    /// result is cached too — retrying a user client that this hardware does not
    /// have would burn milliseconds on every tick forever.
    private var ssdProbed = false
    private var ssdEndurance: SSDEndurance?

    private func ssdEnduranceCached() -> SSDEndurance? {
        if !ssdProbed {
            ssdProbed = true
            ssdEndurance = SystemProbes.nvmeEndurance()
        }
        return ssdEndurance
    }

    // MARK: Top processes (via `ps`)

    // The process list drives the bottom panel only and changes slowly, while
    // `sample()` runs every ~2 s for the live graphs. Forking `ps` every tick is
    // the single most expensive part of a sample, so we cache the result and
    // refresh it at most every few seconds — the graphs stay at full cadence,
    // the (cheap) process panel updates a little less often.
    private var procCache: (procs: [ProcessInfoItem], id: Int, at: TimeInterval)?
    private let procCacheTTL: TimeInterval = 5
    /// Counts fresh listings; becomes `SystemSnapshot.processListID`.
    private var procListCount = 0

    // Per-PID cumulative CPU time (ns) from the previous process sample, used to
    // compute %CPU as a delta. Rebuilt each sample so dead PIDs drop out (no leak,
    // and recycled PIDs can't inherit a stale baseline).
    private var prevProcCPU: [Int32: UInt64] = [:]
    private var prevProcAt: TimeInterval?

    private func listProcessesThrottled(limit: Int) -> (items: [ProcessInfoItem], id: Int) {
        if let c = procCache, Self.monotonicNow() - c.at < procCacheTTL {
            return (c.procs, c.id)
        }
        let procs = listProcesses(limit: limit)
        procListCount &+= 1
        procCache = (procs, procListCount, Self.monotonicNow())
        return (procs, procListCount)
    }

    private func listProcesses(limit: Int) -> [ProcessInfoItem] {
        // Enumerate all PIDs via libproc (no `ps` fork).
        let needed = proc_listpids(UInt32(PROC_ALL_PIDS), 0, nil, 0)
        guard needed > 0 else { return [] }
        let capacity = Int(needed) / MemoryLayout<pid_t>.size + 16
        var pids = [pid_t](repeating: 0, count: capacity)
        let got = proc_listpids(UInt32(PROC_ALL_PIDS), 0, &pids,
                                Int32(capacity * MemoryLayout<pid_t>.size))
        guard got > 0 else { return [] }
        let n = Int(got) / MemoryLayout<pid_t>.size

        let now = Self.uptimeNow()
        let wall = prevProcAt.map { now - $0 } ?? 0
        var newPrev: [Int32: UInt64] = [:]
        newPrev.reserveCapacity(n)

        struct Raw { let pid: Int32; let cpu: Double; let mem: UInt64 }
        var raws: [Raw] = []
        raws.reserveCapacity(n)

        for idx in 0..<n {
            let pid = pids[idx]
            if pid <= 0 { continue }

            // One rusage call yields phys_footprint (matches Activity Monitor's
            // "Memory" column) plus cumulative user+system CPU time in ns.
            var usage = rusage_info_current()
            let ok = withUnsafeMutablePointer(to: &usage) { ptr in
                ptr.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) { rebound in
                    proc_pid_rusage(pid, RUSAGE_INFO_CURRENT, rebound)
                }
            }
            guard ok == 0 else { continue }

            let cpuNs = usage.ri_user_time &+ usage.ri_system_time
            newPrev[pid] = cpuNs
            var cpu = 0.0
            if wall > 0, let prev = prevProcCPU[pid], cpuNs >= prev {
                cpu = Double(cpuNs - prev) / (wall * 1_000_000_000) * 100
            }
            raws.append(Raw(pid: pid, cpu: cpu, mem: usage.ri_phys_footprint))
        }

        prevProcCPU = newPrev
        prevProcAt = now

        // Rank by CPU then memory, and only resolve names for the top `limit`
        // (proc_name is a syscall per pid — skip it for rows we won't show).
        let top = raws.sorted {
            $0.cpu != $1.cpu ? $0.cpu > $1.cpu : $0.mem > $1.mem
        }.prefix(limit)

        return top.map { r in
            var nameBuf = [CChar](repeating: 0, count: 256)
            let nlen = proc_name(r.pid, &nameBuf, UInt32(nameBuf.count))
            let name = nlen > 0 ? String(cString: nameBuf) : "pid \(r.pid)"
            return ProcessInfoItem(id: r.pid, ppid: 0, name: name,
                                   cpuPercent: r.cpu, memBytes: r.mem)
        }
    }

    /// Groups processes that belong to the same app (e.g. "Chrome" and its
    /// "Chrome Helper (Renderer)" children) into expandable groups, summing
    /// CPU and memory. Grouping is by a normalized base name.
    public func groupProcesses(_ items: [ProcessInfoItem]) -> [ProcessGroup] {
        var buckets: [String: [ProcessInfoItem]] = [:]
        for item in items {
            buckets[Self.baseName(item.name), default: []].append(item)
        }
        return buckets.map { key, members in
            let cpu = members.reduce(0) { $0 + $1.cpuPercent }
            let mem = members.reduce(UInt64(0)) { $0 + $1.memBytes }
            let sortedMembers = members.sorted { $0.cpuPercent > $1.cpuPercent }
            return ProcessGroup(id: key, name: key, cpuPercent: cpu, memBytes: mem, children: sortedMembers)
        }
    }

    /// Normalizes a process name to its parent app: strips common helper
    /// suffixes like " Helper (Renderer)", " Helper (GPU)", " Helper".
    static func baseName(_ raw: String) -> String {
        var name = raw
        // Drop a trailing "(...)" qualifier.
        if let open = name.range(of: " (", options: .backwards) {
            name = String(name[..<open.lowerBound])
        }
        // Drop a trailing " Helper" token.
        for suffix in [" Helper", " Renderer", " (GPU)", " (Plugin)"] {
            if name.hasSuffix(suffix) {
                name = String(name.dropLast(suffix.count))
            }
        }
        return name.trimmingCharacters(in: .whitespaces).isEmpty ? raw : name.trimmingCharacters(in: .whitespaces)
    }

    // MARK: GPU temperature availability (cached after discovery)

    private var gpuTempProbed: Bool?
    private var nextGPUTempProbeAt: TimeInterval?

    /// Does this Mac expose a readable GPU temperature sensor? A failed initial
    /// discovery stays unresolved until SMC can enumerate the sensor descriptors.
    /// Hardware without a readable GPU thermal sensor returns false — callers
    /// use this to show GPU temp as *unsupported* rather than a transient "—",
    /// and to disable the menu-bar GPU-temp metric. Known results are cached.
    /// The first call enumerates the SMC keys
    /// (about 40 ms), so it belongs on the queue that drives this instance.
    public func probeGPUTempAvailable() -> Bool {
        if let p = gpuTempProbed { return p }
        if let next = nextGPUTempProbeAt, Self.monotonicNow() < next { return true }
        let available = sampleTemperaturesThrottled(.gpu).gpu != nil
        if available {
            gpuTempProbed = true
            return true
        }
        // Descriptor discovery and current values can fail independently. A
        // known sensor remains supported while power-gated; pending discovery
        // must not permanently disable or unpin its menu-bar metric.
        guard let descriptorsAvailable = smc.gpuSensorAvailability else {
            // An unresolved sensor must not trigger an IOHID fallback on every
            // menu-bar tick when no GPU temperature is actually on screen.
            nextGPUTempProbeAt = Self.monotonicNow() + 30
            return true
        }
        gpuTempProbed = descriptorsAvailable
        return descriptorsAvailable
    }

    // MARK: Machine info (sampled once, cached)

    private var cachedMachineInfo: MachineInfo?

    public func machineInfo() -> MachineInfo {
        if let cached = cachedMachineInfo { return cached }
        // `machdep.cpu.brand_string` returns a value on Intel ("Intel Core i9-...").
        // On Apple Silicon it returns nil, so we derive the chip name from hw.model.
        let chip = sysctlString("machdep.cpu.brand_string") ?? appleChipName() ?? sysctlString("hw.model") ?? "Mac"
        let model = sysctlString("hw.model") ?? "Mac"
        let total = sysctlInt("hw.ncpu") ?? ProcessInfo.processInfo.processorCount
        let perf = sysctlInt("hw.perflevel0.logicalcpu") ?? 0
        let eff = sysctlInt("hw.perflevel1.logicalcpu") ?? 0
        var clusterMap = clusterMapFromRegistry(expectedCount: total)
        // Ultra chips are two identical dies and XNU numbers cores per die —
        // die0-E, die0-P, die1-E, die1-P (M1 Ultra: E = 0–1 and 10–11) — so the
        // views' "E-cores first" fallback would miscolor half of each die. When
        // the registry map fails on an Ultra, synthesize the per-die layout,
        // but only if the counts actually describe two equal dies; otherwise
        // keep nil and let the views draw uniform bars.
        if clusterMap == nil, chip.contains("Ultra"),
           perf > 0, eff > 0, perf + eff == total,
           perf.isMultiple(of: 2), eff.isMultiple(of: 2) {
            let die = Array(repeating: "E", count: eff / 2)
                    + Array(repeating: "P", count: perf / 2)
            clusterMap = die + die
        }
        let info = MachineInfo(model: model, chip: chip, totalCores: total,
                               perfCores: perf, effCores: eff,
                               clusterMap: clusterMap)
        cachedMachineInfo = info
        return info
    }

    /// Reads the authoritative per-core cluster map from the device tree:
    /// IODeviceTree:/cpus children each expose `cluster-type` ("E"/"P"/…) and
    /// `cpu-id` (logical index). Unlike an "E-cores come first" assumption, it
    /// stays correct if a future chip adds a third cluster kind.
    /// Returns nil (→ heuristic fallback) when anything doesn't line up.
    private func clusterMapFromRegistry(expectedCount: Int) -> [String]? {
        let cpusEntry = IORegistryEntryFromPath(kIOMainPortDefault, "IODeviceTree:/cpus")
        guard cpusEntry != 0 else { return nil }
        defer { IOObjectRelease(cpusEntry) }

        var iter = io_iterator_t()
        guard IORegistryEntryGetChildIterator(cpusEntry, "IODeviceTree", &iter) == KERN_SUCCESS
        else { return nil }
        defer { IOObjectRelease(iter) }

        var byID: [Int: String] = [:]
        var child = IOIteratorNext(iter)
        while child != 0 {
            defer { IOObjectRelease(child); child = IOIteratorNext(iter) }
            guard
                let typeRef = IORegistryEntryCreateCFProperty(
                    child, "cluster-type" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                let idRef = IORegistryEntryCreateCFProperty(
                    child, "cpu-id" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue(),
                let typeData = typeRef as? Data, !typeData.isEmpty,
                let idData = idRef as? Data, idData.count >= 4
            else { continue }
            // cluster-type is a NUL-terminated ASCII string ("E"/"P"); cpu-id is LE UInt32.
            let type = String(bytes: typeData.prefix(while: { $0 != 0 }), encoding: .ascii) ?? ""
            let id = idData.withUnsafeBytes { Int($0.loadUnaligned(as: UInt32.self)) }
            guard !type.isEmpty else { continue }
            byID[id] = type
        }

        guard byID.count == expectedCount else { return nil }
        return (0..<expectedCount).map { byID[$0] ?? "?" }
    }

    /// Derives a human-readable Apple Silicon chip name from `hw.model`.
    ///
    /// Apple Silicon model identifiers follow the pattern "Mac<YY>,<N>".
    /// We map the known ones; anything unrecognised falls back to the raw
    /// identifier so the user at least sees something meaningful.
    ///
    /// The table is a fallback, consulted only when `machdep.cpu.brand_string`
    /// is unavailable, and it may lag behind newly released models.
    private func appleChipName() -> String? {
        guard let model = sysctlString("hw.model") else { return nil }

        // Mapping based on Apple's documented Model Identifier list.
        //
        // No "skip anything that starts with MacBook/iMac" pre-filter here: the
        // first Apple Silicon Macs kept the old-style identifiers
        // ("MacBookAir10,1", "MacBookPro17,1", "MacBookPro18,1"…), so such a guard
        // would make every one of those table entries unreachable and report the raw
        // identifier as the chip name. Intel Macs simply miss the table and fall
        // through to the identifier-shaped check below.
        let table: [String: String] = [
            // M1 family
            "Mac12,1": "Apple M1",
            "MacBookAir10,1": "Apple M1",
            "MacBookPro17,1": "Apple M1",
            "MacBookPro18,1": "Apple M1 Pro",
            "MacBookPro18,2": "Apple M1 Pro",
            "MacBookPro18,3": "Apple M1 Max",
            "MacBookPro18,4": "Apple M1 Max",
            "Mac13,1": "Apple M1 Pro",
            "Mac13,2": "Apple M1 Max",
            "Mac14,3": "Apple M1 Ultra",
            // M2 family
            "Mac14,2": "Apple M2",
            "Mac14,15": "Apple M2",
            "Mac14,7": "Apple M2",
            "Mac14,5": "Apple M2 Pro",
            "Mac14,9": "Apple M2 Pro",
            "Mac14,6": "Apple M2 Max",
            "Mac14,10": "Apple M2 Max",
            "Mac14,8": "Apple M2 Ultra",
            "Mac14,12": "Apple M2 Ultra",
            "Mac14,13": "Apple M2",
            "Mac14,14": "Apple M2",
            // M3 family
            "Mac15,3": "Apple M3",
            "Mac15,13": "Apple M3",
            "Mac15,6": "Apple M3 Pro",
            "Mac15,7": "Apple M3 Pro",
            "Mac15,8": "Apple M3 Max",
            "Mac15,9": "Apple M3 Max",
            "Mac15,10": "Apple M3 Max",
            "Mac15,11": "Apple M3 Max",
            "Mac15,12": "Apple M3 Ultra",
            "Mac15,14": "Apple M3 Ultra",
            // M4 family
            "Mac16,1": "Apple M4",
            "Mac16,2": "Apple M4",
            "Mac16,3": "Apple M4",
            "Mac16,5": "Apple M4 Pro",
            "Mac16,6": "Apple M4 Pro",
            "Mac16,7": "Apple M4 Pro",
            "Mac16,8": "Apple M4 Pro",
            "Mac16,9": "Apple M4 Max",
            "Mac16,10": "Apple M4",        // Mac mini (M4)
            "Mac16,11": "Apple M4 Pro",    // Mac mini (M4 Pro)
            "Mac16,12": "Apple M4",        // MacBook Air 13" (M4)
            "Mac16,13": "Apple M4",        // MacBook Air 15" (M4)
            "Mac16,15": "Apple M4 Max",    // Mac Studio (M4 Max)
        ]
        if let known = table[model] { return known }

        // Unknown identifier. Only claim "Apple Silicon" for the modern
        // "Mac<NN>,<N>" shape that Apple has used exclusively since the M2 — an
        // unrecognised "iMac20,1" is an Intel Mac and must not be labelled
        // Apple Silicon. Anything else falls back to the raw identifier.
        // e.g. "Mac17,1" → "Apple Silicon (Mac17,1)"
        let isModernIdentifier = model.hasPrefix("Mac")
            && !model.hasPrefix("MacBook") && !model.hasPrefix("MacPro")
            && !model.hasPrefix("MacMini") && !model.hasPrefix("Macmini")
        return isModernIdentifier ? "Apple Silicon (\(model))" : nil
    }

    private func sysctlString(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buf, &size, nil, 0) == 0 else { return nil }
        return String(cString: buf)
    }

    private func sysctlInt(_ name: String) -> Int? {
        var value: Int = 0
        var size = MemoryLayout<Int>.size
        guard sysctlbyname(name, &value, &size, nil, 0) == 0 else { return nil }
        return value
    }

    // MARK: Process control

    /// How a request to quit a process ended.
    public enum TerminationOutcome: Sendable {
        case exited
        /// The request was delivered and the process is still running — an
        /// app may be asking to save a document.
        case stillRunning
        case refused
    }

    /// Asks a process to quit and waits up to three seconds for it to go.
    ///
    /// An app gets the same request as ⌘Q, so it saves its state and can ask
    /// about unsaved documents; a bare SIGTERM would skip all of that. Other
    /// processes get SIGTERM. "Exited" is reported only once the process is
    /// gone, not when the signal was merely delivered.
    public func terminate(pid: Int32) async -> TerminationOutcome {
        let asked: Bool = await MainActor.run {
            if let app = NSRunningApplication(processIdentifier: pid), app.bundleURL != nil {
                return app.terminate()
            }
            return kill(pid, SIGTERM) == 0
        }
        guard asked else { return .refused }
        for _ in 0..<15 {
            // Signal 0 checks existence; ESRCH means the process is gone.
            if kill(pid, 0) != 0, errno == ESRCH { return .exited }
            try? await Task.sleep(nanoseconds: 200_000_000)
        }
        return .stillRunning
    }
}
