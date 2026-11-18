import XCTest
@testable import CleanAppCacheLib

/// Tests the sensor stack — the readings the Monitor screen and the menu bar
/// present as fact. Every expectation here was checked against `macmon` and the
/// system tools (`df`, `ioreg`, `launchctl`) on an M4 (Mac16,12) before being
/// written down.
final class SensorsTests: XCTestCase {

    // MARK: - Temperature plausibility window

    /// The upper bound has to clear the real junction maximum. A 125/130 °C
    /// cutoff dropped the hottest P-core keys — which pass 100 °C under load —
    /// so the reported average fell as the machine got hotter.
    func testTemperaturePlausibilityWindow() {
        XCTAssertFalse(SMCReader.isPlausibleTemp(0))      // power-gated sensor
        XCTAssertFalse(SMCReader.isPlausibleTemp(-22))    // IOHID parks unused sensors here
        XCTAssertFalse(SMCReader.isPlausibleTemp(-999))   // "als-temp" when absent
        XCTAssertTrue(SMCReader.isPlausibleTemp(28))      // battery
        XCTAssertTrue(SMCReader.isPlausibleTemp(93.6))    // observed P-core hot spot
        XCTAssertTrue(SMCReader.isPlausibleTemp(110))     // sustained load
        XCTAssertTrue(SMCReader.isPlausibleTemp(150))     // inclusive upper bound
        XCTAssertFalse(SMCReader.isPlausibleTemp(151))
        XCTAssertFalse(SMCReader.isPlausibleTemp(.nan))
        XCTAssertFalse(SMCReader.isPlausibleTemp(.infinity))
        XCTAssertFalse(SMCReader.isPlausibleTemp(-.infinity))
    }

    // MARK: - IOReport availability

    /// The IOReport symbols live in `/usr/lib/libIOReport.dylib`, which nothing
    /// in the app links. Without an explicit `dlopen`, every `dlsym` returns nil
    /// and P/E/GPU frequencies are permanently unavailable.
    func testIOReportResolvesOnAppleSilicon() throws {
        #if arch(arm64)
        // A hypervisor guest has no AppleARMIODevice voltage tables, so every
        // frequency is nil there and the assertion below would blame dlopen.
        try skipUnlessRealHardware("IOReport DVFS sampling")
        // Each instance keeps its own previous sample; the first call on *this*
        // instance primes the delta, the later ones carry values. (Priming a
        // throwaway instance instead of the one being read proves nothing.)
        let freq = IOReportFreq()
        _ = freq.sample()
        Thread.sleep(forTimeInterval: 0.4)
        _ = freq.sample()
        Thread.sleep(forTimeInterval: 0.4)
        let third = freq.sample()

        let anyFrequency = third.e ?? third.p ?? third.gpu
        XCTAssertNotNil(anyFrequency, "IOReport produced no frequency — is libIOReport loaded?")
        if let e = third.e { XCTAssertTrue((100...4_000).contains(e), "E-cluster \(e) MHz out of range") }
        if let p = third.p { XCTAssertTrue((100...5_000).contains(p), "P-cluster \(p) MHz out of range") }
        if let g = third.gpu { XCTAssertTrue((100...3_000).contains(g), "GPU \(g) MHz out of range") }
        #else
        throw XCTSkip("IOReport DVFS tables are Apple Silicon only")
        #endif
    }

    // MARK: - Storage

    /// One definition of free space for the whole app. The Storage screen and the
    /// menu bar's low-disk alert used different volume keys that disagreed by
    /// 17 GB on a real machine, so the alert could contradict the screen.
    func testStorageInfoIsSelfConsistent() throws {
        let info = try XCTUnwrap(StorageInfo.read())
        XCTAssertGreaterThan(info.totalBytes, 0)
        XCTAssertLessThanOrEqual(info.freeBytes, info.totalBytes)
        XCTAssertEqual(info.usedBytes + info.freeBytes, info.totalBytes)
        XCTAssertEqual(info.usedPercent + info.freePercent, 1.0, accuracy: 0.0001)
    }

    // MARK: - Machine info

    func testMachineInfoMatchesSysctl() {
        let info = SystemMonitor.shared.machineInfo()
        XCTAssertGreaterThan(info.totalCores, 0)
        XCTAssertFalse(info.chip.isEmpty)
        // The rest are claims about real hardware: a guest commonly exposes
        // neither hw.perflevel key, so 0 + 0 never equals ncpu there.
        if TestHost.isVirtualMachine { return }
        XCTAssertEqual(info.perfCores + info.effCores, info.totalCores,
                       "perflevel0 + perflevel1 must account for every logical core")
        if let map = info.clusterMap {
            XCTAssertEqual(map.count, info.totalCores)
            XCTAssertEqual(map.filter { $0 == "E" }.count, info.effCores)
            XCTAssertEqual(map.filter { $0 == "P" }.count, info.perfCores)
        }
    }

    // MARK: - Snapshot sanity

    /// A whole sample, checked for internally impossible values rather than
    /// against fixed numbers.
    func testSnapshotValuesAreInRange() {
        let monitor = SystemMonitor(temperatureTTL: 0)
        _ = monitor.sample()                       // prime the deltas
        Thread.sleep(forTimeInterval: 0.5)
        let snap = monitor.sample()

        XCTAssertTrue((0...100).contains(snap.cpuPercent), "cpu \(snap.cpuPercent)")
        for core in snap.perCorePercent {
            XCTAssertTrue((0...100).contains(core), "per-core \(core)")
        }
        XCTAssertGreaterThan(snap.memTotalBytes, 0)
        XCTAssertLessThanOrEqual(snap.memUsedBytes, snap.memTotalBytes)
        XCTAssertGreaterThanOrEqual(snap.netDownBytesPerSec, 0)
        XCTAssertGreaterThanOrEqual(snap.diskReadBytesPerSec, 0)

        if let t = snap.tempCPU { XCTAssertTrue(SMCReader.isPlausibleTemp(t), "cpu temp \(t)") }
        if let t = snap.tempGPU { XCTAssertTrue(SMCReader.isPlausibleTemp(t), "gpu temp \(t)") }
        if let t = snap.tempBattery { XCTAssertTrue(SMCReader.isPlausibleTemp(t), "bat temp \(t)") }
        // The IOHID list is read on demand rather than with every sample.
        let sensors = monitor.temperatureSensors()
        for sensor in sensors {
            XCTAssertTrue(SMCReader.isPlausibleTemp(sensor.celsius), "\(sensor.name) \(sensor.celsius)")
        }
        XCTAssertEqual(sensors.map(\.celsius), sensors.map(\.celsius).sorted(by: >),
                       "sensors are listed hottest first")
        // IOHID reports several services sharing one Product string; ids must
        // still be unique or SwiftUI's ForEach renders undefined results.
        let ids = sensors.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "TempSensor ids must be unique")

        if let g = snap.gpuPercent { XCTAssertTrue((0...100).contains(g), "gpu \(g)") }
        if let b = snap.batteryPercent { XCTAssertTrue((0...100).contains(b), "battery \(b)") }
        if let h = snap.batteryHealthPercent { XCTAssertTrue((0...100).contains(h), "health \(h)") }
    }

    /// The menu bar asks only for the temperatures it shows; the rest come back
    /// nil instead of being read.
    func testMenuSampleReturnsOnlyRequestedTemperatures() {
        let monitor = SystemMonitor(temperatureTTL: 0)
        let none = monitor.menuSample(includeGPU: false, temperatures: [])
        XCTAssertNil(none.gpu)
        XCTAssertNil(none.cpuTemp)
        XCTAssertNil(none.gpuTemp)

        let cpuOnly = monitor.menuSample(includeGPU: false, temperatures: .cpu)
        XCTAssertNil(cpuOnly.gpuTemp)
        if let t = cpuOnly.cpuTemp { XCTAssertTrue(SMCReader.isPlausibleTemp(t), "cpu temp \(t)") }
    }

    /// Battery health is derived from mAh capacities. On Apple Silicon those live
    /// in the nested `BatteryData` dictionary — a top-level `DesignCapacity`
    /// lookup finds nothing there and returns nil every time.
    func testBatteryHealthIsReadableWhenABatteryExists() {
        let monitor = SystemMonitor(temperatureTTL: 0)
        let snap = monitor.sample()
        guard snap.batteryPercent != nil else {
            return   // desktop Mac: nothing to assert
        }
        let health = snap.batteryHealthPercent
        XCTAssertNotNil(health, "a Mac with a battery must report a health percentage")
        if let health {
            XCTAssertTrue((1...100).contains(health), "implausible health \(health)")
        }
    }
}
