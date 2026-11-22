import Foundation

struct StorageAPFSVolume: Codable, Sendable {
    let device: String
    let name: String
    let roles: [String]
    let bytes: UInt64?
    var uuid: String? = nil
}

struct StorageAPFSVolumes: Sendable {
    let members: [StorageAPFSVolume]
    let isPartial: Bool
    var timeLimited = false

    static func read(startup: StorageStartupVolume) async -> Self? {
        guard startup.isAPFS else { return nil }
        let response = await DirectorySizeProbe.captureResponse(
            executable: URL(fileURLWithPath: "/usr/sbin/diskutil"),
            arguments: ["apfs", "list", "-plist"], timeout: 12)
        if let response, response.succeeded, let volumes = parse(response.data, dataDevice: startup.device) {
            return volumes
        }
        guard !Task.isCancelled else { return nil }

        // diskutil also knows about unmounted volumes. Mounted statistics
        // remain useful when DiskManagement is unavailable.
        let paths = [("/", "System"), ("/System/Volumes/Preboot", "Preboot"),
                     ("/System/Volumes/Recovery", "Recovery"), ("/System/Volumes/VM", "VM"),
                     ("/System/Volumes/Update", "Update")]
        // The first 's' after "disk" separates the container and its volume.
        let prefix = startup.device.dropFirst(4).prefix(while: \.isNumber)
        let volumePrefix = "disk" + prefix + "s"
        guard !prefix.isEmpty else { return .init(members: [], isPartial: true, timeLimited: response?.timedOut == true) }
        let mounted = paths.compactMap { path, role -> StorageAPFSVolume? in
            guard let volume = StorageStartupVolume.readMount(path), volume.isAPFS,
                  volume.device.hasPrefix(volumePrefix), volume.device != startup.device else { return nil }
            return .init(device: volume.device, name: "", roles: [role], bytes: mountedAllocation(path))
        }
        return .init(members: mounted, isPartial: true, timeLimited: response?.timedOut == true)
    }

    private static func mountedAllocation(_ path: String) -> UInt64? {
        var attributes = attrlist()
        attributes.bitmapcount = UInt16(ATTR_BIT_MAP_COUNT)
        attributes.volattr = UInt32(ATTR_VOL_INFO) | UInt32(ATTR_VOL_SPACEUSED)
        // getattrlist packs the Int64 immediately after the UInt32 length.
        var buffer = [UInt8](repeating: 0, count: 12)
        let status = buffer.withUnsafeMutableBytes {
            getattrlist(path, &attributes, $0.baseAddress, $0.count, 0)
        }
        guard status == 0 else { return nil }
        return buffer.withUnsafeBytes {
            guard $0.loadUnaligned(as: UInt32.self) == 12 else { return nil }
            return UInt64(exactly: $0.loadUnaligned(fromByteOffset: 4, as: Int64.self))
        }
    }

    static func parse(_ data: Data, dataDevice: String) -> Self? {
        guard let list = try? PropertyListDecoder().decode(ContainerList.self, from: data),
              let container = list.containers.first(where: { $0.volumes.contains { $0.device == dataDevice } }) else { return nil }
        let volumes = container.volumes.filter { $0.device != dataDevice }.map {
            StorageAPFSVolume(device: $0.device, name: $0.name ?? "", roles: $0.roles ?? [], bytes: $0.bytes, uuid: $0.uuid)
        }
        return .init(members: volumes, isPartial: volumes.contains { $0.bytes == nil })
    }

    private struct ContainerList: Decodable {
        let containers: [Container]
        enum CodingKeys: String, CodingKey { case containers = "Containers" }
    }

    private struct Container: Decodable {
        let volumes: [Volume]
        enum CodingKeys: String, CodingKey { case volumes = "Volumes" }
    }

    private struct Volume: Decodable {
        let device: String
        let name: String?
        let roles: [String]?
        let bytes: UInt64?
        let uuid: String?

        enum CodingKeys: String, CodingKey {
            case device = "DeviceIdentifier"
            case name = "Name"
            case roles = "Roles"
            case bytes = "CapacityInUse"
            case uuid = "APFSVolumeUUID"
        }
    }
}

struct StorageStartupVolume: Sendable {
    static let dataPath = "/System/Volumes/Data"

    let url: URL
    let device: String
    let isAPFS: Bool
    let totalBytes: UInt64
    let freeBytes: UInt64

    static func read() -> Self? {
        if let data = readMount(dataPath), data.isAPFS { return data }
        return readMount("/")
    }

    static func readMount(_ path: String) -> Self? {
        var fs = statfs()
        guard statfs(path, &fs) == 0, fs.f_blocks > 0, fs.f_bsize > 0 else { return nil }
        let mount = withUnsafeBytes(of: &fs.f_mntonname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        guard mount == path else { return nil }
        let type = withUnsafeBytes(of: &fs.f_fstypename) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let source = withUnsafeBytes(of: &fs.f_mntfromname) {
            String(cString: $0.bindMemory(to: CChar.self).baseAddress!)
        }
        let block = UInt64(fs.f_bsize)
        // APFS exposes container capacity and physical free space here.
        return .init(url: URL(fileURLWithPath: path), device: URL(fileURLWithPath: source).lastPathComponent,
                     isAPFS: type == "apfs", totalBytes: fs.f_blocks * block, freeBytes: fs.f_bfree * block)
    }

    var capacity: StorageInfo {
        let free = min(freeBytes, totalBytes)
        return StorageInfo(totalBytes: totalBytes, freeBytes: free, usedBytes: totalBytes - free)
    }
}
