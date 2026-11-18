import XCTest
@testable import CleanAppCacheLib

final class SMCRecoveryTests: XCTestCase {
    func testFailedKeyCountRetriesAfterBackoff() throws {
        let driver = FakeSMC()
        driver.unreadableInfo.insert(FakeSMC.code("#KEY"))
        let reader = driver.reader()

        XCTAssertNil(reader.gpuSensorAvailability)
        XCTAssertNil(reader.temperatureSummary().cpu)
        XCTAssertNil(reader.gpuSensorAvailability, "a failed probe cannot establish unsupported hardware")
        XCTAssertEqual(driver.countInfoReads, 1)
        driver.unreadableInfo.removeAll()
        driver.time = 29
        XCTAssertNil(reader.temperatureSummary().cpu)
        XCTAssertEqual(driver.countInfoReads, 1, "unavailable SMC must not enumerate every tick")

        driver.time = 30
        let recovered = reader.temperatureSummary()
        XCTAssertEqual(try XCTUnwrap(recovered.cpu), 65, accuracy: 0.001)
        XCTAssertEqual(try XCTUnwrap(recovered.gpu), 45, accuracy: 0.001)
        XCTAssertEqual(reader.gpuSensorAvailability, true)
        XCTAssertEqual(driver.countInfoReads, 2)
    }

    func testZeroKeyCountRemainsRetryable() throws {
        let driver = FakeSMC()
        driver.countOverride = 0
        let reader = driver.reader()
        XCTAssertNil(reader.temperatureSummary().cpu)
        XCTAssertNil(reader.gpuSensorAvailability)

        driver.countOverride = nil
        driver.time = 30
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 65, accuracy: 0.001)
        XCTAssertEqual(driver.countInfoReads, 2)
    }

    func testPartialEnumerationDoesNotCommitLowerTemperature() throws {
        // Losing either the key's name or descriptor must not permanently omit
        // the hotter sensor from an otherwise plausible CPU average.
        for failDescriptor in [false, true] {
            let driver = FakeSMC()
            if failDescriptor {
                driver.unreadableInfo.insert(FakeSMC.code("Tp01"))
            } else {
                driver.unreadableNames.insert(1)
            }
            let reader = driver.reader()
            let partial = reader.temperatureSummary()
            XCTAssertNil(partial.cpu)
            XCTAssertNil(partial.gpu, "CPU and GPU descriptors commit together")
            XCTAssertNil(reader.gpuSensorAvailability)
            XCTAssertTrue(reader.diag.contains("retry"))

            driver.unreadableInfo.removeAll()
            driver.unreadableNames.removeAll()
            driver.time = 20
            XCTAssertNil(reader.temperatureSummary().cpu)
            XCTAssertEqual(driver.countInfoReads, 1)
            driver.time = 30
            XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 65, accuracy: 0.001)
            XCTAssertEqual(reader.gpuSensorAvailability, true)
            XCTAssertEqual(driver.countInfoReads, 2)
        }
    }

    func testTemporarilyUnreadableValueRejoinsWithoutEnumeration() throws {
        let driver = FakeSMC()
        driver.values[FakeSMC.code("Tp01")] = nil
        let reader = driver.reader()
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 50, accuracy: 0.001)

        driver.values[FakeSMC.code("Tp01")] = 80
        driver.time = 60
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 65, accuracy: 0.001)
        XCTAssertEqual(driver.countInfoReads, 1, "value failure must not remove a valid descriptor")
    }

    func testMalformedDescriptorRemainsRetryable() throws {
        let driver = FakeSMC()
        driver.invalidSizes[FakeSMC.code("Tp01")] = 0
        let reader = driver.reader()
        XCTAssertNil(reader.temperatureSummary().cpu)

        driver.invalidSizes.removeAll()
        driver.time = 30
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 65, accuracy: 0.001)
        XCTAssertEqual(driver.countInfoReads, 2)
    }

    func testPowerGatedValueRejoinsWithoutEnumeration() throws {
        let driver = FakeSMC()
        driver.values[FakeSMC.code("Tp01")] = 0
        let reader = driver.reader()
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 50, accuracy: 0.001)

        driver.values[FakeSMC.code("Tp01")] = 80
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 65, accuracy: 0.001)
        XCTAssertEqual(driver.countInfoReads, 1)
    }

    func testUnsupportedEncodingDoesNotTriggerRepeatedEnumeration() throws {
        let driver = FakeSMC()
        driver.unsupportedTypes.insert(FakeSMC.code("Tp01"))
        let reader = driver.reader()
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 50, accuracy: 0.001)
        driver.time = 60
        XCTAssertEqual(try XCTUnwrap(reader.temperatureSummary().cpu), 50, accuracy: 0.001)
        XCTAssertEqual(driver.countInfoReads, 1, "unsupported metadata is a stable hardware property")
    }

    func testSkippingAppleSiliconEnumerationDoesNotEstablishIntelSensorAbsence() {
        let driver = FakeSMC()
        let reader = driver.reader(appleSilicon: false)
        XCTAssertNil(reader.temperatureSummary().gpu)
        XCTAssertNil(reader.gpuSensorAvailability)
        XCTAssertEqual(driver.countInfoReads, 0)
    }

    func testUnreadableGPUValueStillHasAvailableDescriptor() {
        let driver = FakeSMC()
        driver.values[FakeSMC.code("Tg00")] = nil
        let reader = driver.reader()

        XCTAssertNil(reader.gpuSensorAvailability)
        XCTAssertNil(reader.temperatureSummary(cpu: false).gpu)
        XCTAssertEqual(reader.gpuSensorAvailability, true)
        XCTAssertEqual(driver.countInfoReads, 1)
    }

    func testCompletedEnumerationCanEstablishAbsentGPUDescriptor() {
        let driver = FakeSMC()
        driver.keys.removeAll { $0 == FakeSMC.code("Tg00") }
        let reader = driver.reader()

        XCTAssertNil(reader.gpuSensorAvailability)
        XCTAssertNil(reader.temperatureSummary(cpu: false).gpu)
        XCTAssertEqual(reader.gpuSensorAvailability, false)
        XCTAssertEqual(driver.countInfoReads, 1)
    }
}

private final class FakeSMC {
    var time: TimeInterval = 0
    var countOverride: UInt32?
    var unreadableNames: Set<Int> = []
    var unreadableInfo: Set<UInt32> = []
    var unsupportedTypes: Set<UInt32> = []
    var invalidSizes: [UInt32: UInt32] = [:]
    var countInfoReads = 0
    var keys = ["Tp00", "Tp01", "Tg00"].map(code)
    var values: [UInt32: Float] = [code("Tp00"): 50, code("Tp01"): 80, code("Tg00"): 45]

    func reader(appleSilicon: Bool = true) -> SMCReader {
        SMCReader(keyAccess: .init(
            info: { [self] key in
                if key == Self.code("#KEY") { countInfoReads += 1 }
                guard !unreadableInfo.contains(key) else { return nil }
                let type = key == Self.code("#KEY") ? Self.code("ui32") : Self.code("flt ")
                return (invalidSizes[key] ?? 4, unsupportedTypes.contains(key) ? Self.code("xxxx") : type)
            },
            bytes: { [self] key, _ in
                if key == Self.code("#KEY") {
                    var count = (countOverride ?? UInt32(keys.count)).bigEndian
                    return withUnsafeBytes(of: &count) { Array($0) }
                }
                guard let value = values[key] else { return nil }
                var bits = value.bitPattern.littleEndian
                return withUnsafeBytes(of: &bits) { Array($0) }
            },
            name: { [self] index in
                guard keys.indices.contains(index), !unreadableNames.contains(index) else { return nil }
                return keys[index]
            }
        ), appleSilicon: appleSilicon, now: { [self] in time })
    }

    static func code(_ string: String) -> UInt32 {
        string.utf8.reduce(0) { ($0 << 8) | UInt32($1) }
    }
}
