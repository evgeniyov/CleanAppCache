import Foundation
import Darwin
import CoreGraphics
import IOKit
import IOKit.ps
import SystemConfiguration

// MARK: - Low-level system probes
//
// Everything the Monitor's detail panels need that isn't a CPU/memory/battery
// counter already sampled by `SystemMonitor`. Kept in its own file because these
// are self-contained syscall/IOKit bridges with no shared state — every entry
// point is a `static` function over local storage, so it is safe to call from
// the monitor's background sampling queue and satisfies StrictConcurrency
// without a lock. All caching lives in `SystemMonitor`, which owns one instance
// per sampler (in-app and menu bar) and therefore never races itself.
//
// Rule for this whole file: a probe that cannot read its value returns nil. It
// never substitutes a plausible number — an unreadable value is shown as a
// dash, and the project's sensor policy treats a wrong figure as worse than one.

/// NVMe SSD endurance, straight out of the controller's SMART / Health
/// Information log page (NVM Express 1.4, §5.14.1.2). Every field here is
/// reported by the drive itself; nothing is derived or estimated.
public struct SSDEndurance: Sendable {
    /// "Percentage Used": the vendor's own estimate of consumed endurance,
    /// 0…255. Values above 100 are legal and mean the drive is past its rated
    /// life — do NOT clamp before showing it, that would hide a dying disk.
    public let percentageUsed: Int
    /// "Available Spare" and its threshold, both in percent. The controller
    /// raises `criticalWarning` bit 0 itself when spare drops below threshold.
    public let availableSparePercent: Int
    public let availableSpareThresholdPercent: Int
    /// "Data Units Read/Written" converted to bytes. The NVMe spec reports these
    /// in thousands of 512-byte units, i.e. one unit = 512 000 bytes.
    public let bytesWritten: UInt64
    public let bytesRead: UInt64
    /// "Critical Warning" bitfield; 0 means the controller flags nothing wrong.
    public let criticalWarning: UInt8

    /// The "SSD endurance" figure — remaining rated endurance.
    public var remainingPercent: Double { max(0, 100 - Double(percentageUsed)) }

    /// The "SMART status" figure. Driven purely by the controller's own warning
    /// bitfield: bit 0 is already "available spare below threshold", so there is
    /// no need (and no justification) for us to invent a second rule on top.
    public var isHealthy: Bool { criticalWarning == 0 }
}

enum SystemProbes {

    // MARK: Threads

    /// Total live threads across the system, from the default processor set —
    /// the same source `top`'s "N threads" line uses. Verified against
    /// `top -l 1`: 4475 vs 4474 (the difference is the counting process itself).
    ///
    /// One Mach call, ~microseconds, so it is safe on the 2 s hot path.
    static func systemThreadCount() -> Int? {
        var pset = processor_set_name_t()
        guard processor_set_default(mach_host_self(), &pset) == KERN_SUCCESS else { return nil }
        defer { mach_port_deallocate(mach_task_self_, pset) }

        var info = processor_set_load_info()
        var count = mach_msg_type_number_t(
            MemoryLayout<processor_set_load_info>.stride / MemoryLayout<natural_t>.stride)
        let kr = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                processor_set_statistics(pset, PROCESSOR_SET_LOAD_INFO, $0, &count)
            }
        }
        guard kr == KERN_SUCCESS, info.thread_count > 0 else { return nil }
        return Int(info.thread_count)
    }

    // MARK: Load average

    /// The kernel's 1-minute load average (`vm.loadavg`), as a plain Double.
    ///
    /// Deliberately NOT the `load_average` field of `processor_set_load_info`:
    /// that one is a differently-scaled, differently-smoothed figure and does not
    /// match what `uptime` prints. `vm.loadavg` does — measured 2.806 against
    /// `top`'s "Load Avg: 2.81".
    static func loadAverage1m() -> Double? {
        var avg = loadavg()
        var size = MemoryLayout<loadavg>.size
        guard sysctlbyname("vm.loadavg", &avg, &size, nil, 0) == 0, avg.fscale > 0 else { return nil }
        return Double(avg.ldavg.0) / Double(avg.fscale)
    }

    // MARK: Displays

    /// Number of active displays. `CGGetActiveDisplayList` is safe off the main
    /// actor; `NSScreen.screens` is not (it is main-actor-isolated and would have
    /// to hop, which the sampler must never do).
    static func activeDisplayCount() -> Int? {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success else { return nil }
        return Int(count)
    }

    // MARK: Network interfaces

    /// True for links that are real hardware rather than an overlay riding on
    /// another interface.
    ///
    /// This is the test that fixes the long-standing double-count recorded in the
    /// project notes: `utunN` (IFT_OTHER), `gifN`, `stfN`, `bridgeN` and VLANs all
    /// carry the *same* packets that the physical link underneath already
    /// counted, so summing "everything that isn't lo0" reported VPN traffic
    /// twice — on `en0` and on `utunN`. Measured live on this Mac: en0 3.3 GB in
    /// against utun13 796 MB in, i.e. ~24 % of the reported total was phantom.
    ///
    /// macOS reports Wi-Fi as IFT_ETHER (verified: en0 → 0x06), so there is no
    /// separate 802.11 case to add. IFT_IEEE1394 covers FireWire targets.
    static func isPhysicalLinkType(_ type: UInt8) -> Bool {
        let t = Int32(type)
        return t == IFT_ETHER || t == IFT_IEEE1394
    }

    /// BSD names of every interface holding a default (0.0.0.0 / ::) route with
    /// a gateway, in the order the kernel's routing table returns them.
    ///
    /// Read from the routing table rather than `SCDynamicStore`'s
    /// `State:/Network/Global/IPv4` because the caller wants to choose among the
    /// candidates: with a transparent proxy up, SCDynamicStore names only the
    /// tunnel (measured here: `PrimaryInterface: utun13`, router 198.18.0.1),
    /// while the panel needs the physical link whose bytes it is showing.
    ///
    /// IPv4 is authoritative when present; on an IPv6-only network (no IPv4
    /// default route at all) the identical dump is repeated for AF_INET6 so the
    /// interface and address rows fill in instead of showing "—" while the byte
    /// rates flow — `address(of:)` already falls back to a global IPv6 address
    /// on its own.
    static func defaultRouteInterfaces() -> [String] {
        let v4 = defaultRouteInterfaces(family: AF_INET)
        return v4.isEmpty ? defaultRouteInterfaces(family: AF_INET6) : v4
    }

    private static func defaultRouteInterfaces(family: Int32) -> [String] {
        var mib: [Int32] = [CTL_NET, PF_ROUTE, 0, family, NET_RT_FLAGS, RTF_GATEWAY]
        var needed = 0
        guard sysctl(&mib, 6, nil, &needed, nil, 0) == 0, needed > 0 else { return [] }
        var buffer = [UInt8](repeating: 0, count: needed)
        var length = needed
        guard sysctl(&mib, 6, &buffer, &length, nil, 0) == 0, length > 0 else { return [] }

        let headerSize = MemoryLayout<rt_msghdr>.size
        var names: [String] = []
        buffer.withUnsafeBytes { raw in
            var offset = 0
            while offset + headerSize <= length {
                let header = raw.loadUnaligned(fromByteOffset: offset, as: rt_msghdr.self)
                let messageLength = Int(header.rtm_msglen)
                // A zero/short length would spin forever on a malformed table.
                guard messageLength >= headerSize, offset + messageLength <= length else { break }
                defer { offset += messageLength }

                // The destination sockaddr, when present, is the first one after
                // the header. A default route is the one whose destination is
                // all-zero (0.0.0.0 or ::).
                guard header.rtm_addrs & RTA_DST != 0 else { continue }
                let isDefault: Bool
                if family == AF_INET6 {
                    guard offset + headerSize + MemoryLayout<sockaddr_in6>.size <= length else { continue }
                    let destination = raw.loadUnaligned(fromByteOffset: offset + headerSize,
                                                        as: sockaddr_in6.self)
                    isDefault = destination.sin6_family == UInt8(AF_INET6)
                        && withUnsafeBytes(of: destination.sin6_addr) { bytes in
                            bytes.allSatisfy { $0 == 0 }
                        }
                } else {
                    guard offset + headerSize + MemoryLayout<sockaddr_in>.size <= length else { continue }
                    let destination = raw.loadUnaligned(fromByteOffset: offset + headerSize,
                                                        as: sockaddr_in.self)
                    isDefault = destination.sin_family == UInt8(AF_INET)
                        && destination.sin_addr.s_addr == 0
                }
                guard isDefault else { continue }

                var nameBuffer = [CChar](repeating: 0, count: Int(IF_NAMESIZE))
                if if_indextoname(UInt32(header.rtm_index), &nameBuffer) != nil {
                    names.append(String(cString: nameBuffer))
                }
            }
        }
        return names
    }

    /// macOS's own localized names for the hardware interfaces ("en0" → "Wi-Fi",
    /// "bridge0" → "Thunderbolt Bridge"). Costs ~17 ms, so the caller caches it:
    /// the mapping only changes when hardware is attached or removed.
    static func interfaceDisplayNames() -> [String: String] {
        guard let interfaces = SCNetworkInterfaceCopyAll() as? [SCNetworkInterface] else { return [:] }
        var map: [String: String] = [:]
        for interface in interfaces {
            guard let bsd = SCNetworkInterfaceGetBSDName(interface) as String?,
                  let name = SCNetworkInterfaceGetLocalizedDisplayName(interface) as String?
            else { continue }
            map[bsd] = name
        }
        return map
    }

    /// Presentable IP address of `interface`, preferring a routable IPv4 address
    /// and falling back to a global IPv6 one. Link-local (169.254/16, fe80::) is
    /// skipped: it means "no usable address", and printing it would read as a
    /// working connection.
    static func address(of interface: String, from list: UnsafeMutablePointer<ifaddrs>?) -> String? {
        var ipv6: String?
        var pointer = list
        while let current = pointer {
            defer { pointer = current.pointee.ifa_next }
            guard String(cString: current.pointee.ifa_name) == interface,
                  let raw = current.pointee.ifa_addr else { continue }

            if raw.pointee.sa_family == UInt8(AF_INET) {
                var addr = UnsafeRawPointer(raw).loadUnaligned(as: sockaddr_in.self)
                // 169.254.0.0/16 — self-assigned, means the DHCP lease failed.
                if UInt32(bigEndian: addr.sin_addr.s_addr) >> 16 == 0xA9FE { continue }
                var text = [CChar](repeating: 0, count: Int(INET_ADDRSTRLEN))
                if inet_ntop(AF_INET, &addr.sin_addr, &text, socklen_t(INET_ADDRSTRLEN)) != nil {
                    return String(cString: text)   // IPv4 wins outright
                }
            } else if raw.pointee.sa_family == UInt8(AF_INET6), ipv6 == nil {
                var addr = UnsafeRawPointer(raw).loadUnaligned(as: sockaddr_in6.self)
                let bytes = withUnsafeBytes(of: addr.sin6_addr) { Array($0) }
                if bytes.count >= 2, bytes[0] == 0xFE, bytes[1] & 0xC0 == 0x80 { continue }  // fe80::/10
                var text = [CChar](repeating: 0, count: Int(INET6_ADDRSTRLEN))
                if inet_ntop(AF_INET6, &addr.sin6_addr, &text, socklen_t(INET6_ADDRSTRLEN)) != nil {
                    ipv6 = String(cString: text)
                }
            }
        }
        return ipv6
    }

    // MARK: Storage device identity

    /// Marketing name of the boot/internal drive, from the IOBlockStorageDevice's
    /// "Device Characteristics" (e.g. "APPLE SSD AP0256Z").
    ///
    /// Picks a device whose "Physical Interconnect Location" is "Internal" so a
    /// plugged-in USB stick or a mounted disk image cannot claim the slot; falls
    /// back to the first non-virtual device on Macs booted from external media.
    static func internalStorageDeviceName() -> String? {
        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault,
                                           IOServiceMatching("IOBlockStorageDevice"),
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var internals: [(name: String, interconnect: String?)] = []
        var fallback: String?
        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }
            guard let name = registryDictionary(service, "Device Characteristics")?["Product Name"] as? String,
                  !name.isEmpty else { continue }
            let protocolInfo = registryDictionary(service, "Protocol Characteristics")
            let interconnect = protocolInfo?["Physical Interconnect"] as? String
            // IOStorageProtocolCharacteristics.h: kIOPropertyPhysicalInterconnectTypeVirtual.
            if interconnect == "Virtual Interface" { continue }
            if protocolInfo?["Physical Interconnect Location"] as? String == "Internal" {
                internals.append((name, interconnect))
            } else if fallback == nil {
                fallback = name
            }
        }
        // A Fusion iMac has TWO internal devices (SSD + HDD) and IOKit
        // iterator order is unspecified, so "first internal wins" could name
        // the HDD member for what the user sees as one drive. Prefer the
        // member on a solid-state interconnect (PCI-Express / Apple Fabric) —
        // the device whose behavior the I/O figures reflect most — then any
        // internal, then the non-virtual fallback for external-media boots.
        let solidState = internals.first {
            $0.interconnect == "PCI-Express" || $0.interconnect == "Apple Fabric"
        }
        return (solidState ?? internals.first)?.name ?? fallback
    }

    /// Convenience for the `[String: Any]` sub-dictionaries the storage stack uses.
    static func registryDictionary(_ service: io_object_t, _ key: String) -> [String: Any]? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue() as? [String: Any]
    }

    // MARK: NVMe SMART

    /// Reads the SMART / Health Information log from the internal NVMe drive.
    ///
    /// Route: `IOCreatePlugInInterfaceForService` against any service carrying
    /// the "NVMe SMART Capable" property — the lookup NVMeSMARTLibExternal.h
    /// itself prescribes, so it works on both Apple Silicon
    /// (`IOEmbeddedNVMeBlockDevice`) and Intel without hardcoding a class name.
    /// Verified on this Mac: it needs no entitlement and no root, and one read
    /// costs 1–4 ms. Returns nil on any hardware that has no NVMe SMART user
    /// client (older SATA Macs, VMs) — the caller must then show "—" rather than
    /// deriving a wear figure from write counters, which would be a guess.
    ///
    /// `IONVMeSMARTInterface` lives in `IOKit/storage/nvme/`, which is NOT in
    /// IOKit's module map, so Swift cannot see the struct. The vtable is
    /// therefore walked by byte offset; the offsets below were taken from
    /// `offsetof` on the SDK header (QueryInterface 8, AddRef 16, Release 24,
    /// version 32, revision 34, SMARTReadData 40) and the field offsets from
    /// `NVMeSMARTData`, whose layout is fixed by the NVMe spec and `#pragma
    /// pack(1)`. Reading raw offsets instead of redeclaring the struct in Swift
    /// keeps us independent of Swift's (unguaranteed) struct layout.
    static func nvmeEndurance() -> SSDEndurance? {
        typealias SMARTReadData = @convention(c) (UnsafeMutableRawPointer?, UnsafeMutableRawPointer?) -> IOReturn
        typealias ReleaseInterface = @convention(c) (UnsafeMutableRawPointer?) -> UInt32

        // kIOCFPlugInInterfaceID / kIONVMeSMARTUserClientTypeID / kIONVMeSMARTInterfaceID:
        // C macros around CFUUIDGetConstantUUIDWithBytes, which Swift cannot import.
        let plugInInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
            0xC2, 0x44, 0xE8, 0x58, 0x10, 0x9C, 0x11, 0xD4,
            0x91, 0xD4, 0x00, 0x50, 0xE4, 0xC6, 0x42, 0x6F)
        let userClientTypeID = CFUUIDGetConstantUUIDWithBytes(nil,
            0xAA, 0x0F, 0xA6, 0xF9, 0xC2, 0xD6, 0x45, 0x7F,
            0xB1, 0x0B, 0x59, 0xA1, 0x32, 0x53, 0x29, 0x2F)
        let smartInterfaceID = CFUUIDGetConstantUUIDWithBytes(nil,
            0xCC, 0xD1, 0xDB, 0x19, 0xFD, 0x9A, 0x4D, 0xAF,
            0xBF, 0x95, 0x12, 0x45, 0x4B, 0x23, 0x0A, 0xB6)

        guard let matching = IOServiceMatching("IOService") as NSMutableDictionary? else { return nil }
        // kIOPropertyNVMeSMARTCapableKey, per NVMeSMARTLibExternal.h.
        matching[kIOPropertyMatchKey] = ["NVMe SMART Capable": true]

        var iterator = io_iterator_t()
        guard IOServiceGetMatchingServices(kIOMainPortDefault, matching as CFDictionary,
                                           &iterator) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(iterator) }

        var service = IOIteratorNext(iterator)
        while service != 0 {
            defer { IOObjectRelease(service); service = IOIteratorNext(iterator) }

            var plugIn: UnsafeMutablePointer<UnsafeMutablePointer<IOCFPlugInInterface>?>?
            var score: Int32 = 0
            guard IOCreatePlugInInterfaceForService(service, userClientTypeID, plugInInterfaceID,
                                                    &plugIn, &score) == KERN_SUCCESS,
                  let plug = plugIn, let plugVTable = plug.pointee else { continue }
            defer { IODestroyPlugInInterface(plug) }

            var opaque: LPVOID?
            let queried = withUnsafeMutablePointer(to: &opaque) {
                plugVTable.pointee.QueryInterface(plug, CFUUIDGetUUIDBytes(smartInterfaceID), $0)
            }
            guard queried == S_OK, let interface = opaque else { continue }

            // COM layout: `interface` is the instance, its first word points at
            // the function table.
            let vtable = interface.load(as: UnsafeMutableRawPointer.self)
            let readData = vtable.load(fromByteOffset: 40, as: SMARTReadData.self)
            let release = vtable.load(fromByteOffset: 24, as: ReleaseInterface.self)
            defer { _ = release(interface) }

            var log = [UInt8](repeating: 0, count: 512)   // sizeof(NVMeSMARTData)
            let result = log.withUnsafeMutableBytes { readData(interface, $0.baseAddress) }
            guard result == kIOReturnSuccess else { continue }

            return log.withUnsafeBytes { bytes -> SSDEndurance in
                // Field offsets are the NVMe 1.4 §5.14.1.2 log-page layout.
                let unitsRead = bytes.loadUnaligned(fromByteOffset: 32, as: UInt64.self)
                let unitsWritten = bytes.loadUnaligned(fromByteOffset: 48, as: UInt64.self)
                // One data unit = 1000 × 512 B. Only the low 64 bits are used:
                // the spec field is 128-bit, but the high word overflowing would
                // mean ~9 ZB written, which no drive will reach.
                let unitBytes: UInt64 = 512_000
                return SSDEndurance(
                    percentageUsed: Int(bytes.loadUnaligned(fromByteOffset: 5, as: UInt8.self)),
                    availableSparePercent: Int(bytes.loadUnaligned(fromByteOffset: 3, as: UInt8.self)),
                    availableSpareThresholdPercent: Int(bytes.loadUnaligned(fromByteOffset: 4, as: UInt8.self)),
                    bytesWritten: unitsWritten.multipliedReportingOverflow(by: unitBytes).overflow
                        ? UInt64.max : unitsWritten * unitBytes,
                    bytesRead: unitsRead.multipliedReportingOverflow(by: unitBytes).overflow
                        ? UInt64.max : unitsRead * unitBytes,
                    criticalWarning: bytes.loadUnaligned(fromByteOffset: 0, as: UInt8.self)
                )
            }
        }
        return nil
    }

    // MARK: Power adapter

    /// Wattage of the attached power adapter, or nil when running on battery —
    /// `IOPSCopyExternalPowerAdapterDetails` returns nothing when nothing is
    /// plugged in, which is the honest answer, not 0 W.
    static func powerAdapterWatts() -> Int? {
        guard let details = IOPSCopyExternalPowerAdapterDetails()?
            .takeRetainedValue() as? [String: Any] else { return nil }
        guard let watts = details[kIOPSPowerAdapterWattsKey] as? Int, watts > 0 else { return nil }
        return watts
    }
}
