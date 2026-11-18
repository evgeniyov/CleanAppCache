import XCTest
import Darwin

enum TestHost {
    /// True under any hypervisor (GitHub's macos-* runners, Parallels, UTM).
    /// `kern.hv_vmm_present` is Apple's own check; a guest has no SMC, no
    /// IOReport DVFS tables, no battery and a synthetic IODeviceTree.
    /// `CAC_ASSUME_VM=1` forces it, so the guarded paths can be exercised on a
    /// real Mac.
    static let isVirtualMachine: Bool = {
        if ProcessInfo.processInfo.environment["CAC_ASSUME_VM"] == "1" { return true }
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        guard sysctlbyname("kern.hv_vmm_present", &value, &size, nil, 0) == 0 else { return false }
        return value != 0
    }()
}

extension XCTestCase {
    func skipUnlessRealHardware(_ what: String,
                                file: StaticString = #filePath, line: UInt = #line) throws {
        if TestHost.isVirtualMachine {
            throw XCTSkip("\(what) needs real Apple Silicon; this host is a VM", file: file, line: line)
        }
    }
}
