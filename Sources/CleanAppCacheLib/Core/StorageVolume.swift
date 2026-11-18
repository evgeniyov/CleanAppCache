import Foundation

struct StorageVolume: Hashable, Sendable {
    let url: URL
    let name: String
    let uuid: String?
    let device: dev_t

    static func mountedExternal() -> [Self] {
        let keys: Set<URLResourceKey> = [.volumeIsInternalKey, .volumeIsLocalKey,
                                         .volumeLocalizedNameKey, .volumeUUIDStringKey]
        let urls = FileManager.default.mountedVolumeURLs(includingResourceValuesForKeys: Array(keys),
                                                         options: [.skipHiddenVolumes]) ?? []
        return urls.compactMap { entry in
            // Disk images are local but may have no physical internal/external flag.
            guard entry.path != "/", let values = try? entry.resourceValues(forKeys: keys),
                  values.volumeIsInternal != true, values.volumeIsLocal == true else { return nil }
            let url = entry.standardizedFileURL.resolvingSymlinksInPath()
            var metadata = stat()
            guard lstat(url.path, &metadata) == 0 else { return nil }
            return Self(url: url, name: values.volumeLocalizedName ?? url.lastPathComponent,
                        uuid: values.volumeUUIDString, device: metadata.st_dev)
        }.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    func isMounted() -> Bool {
        var metadata = stat()
        guard lstat(url.path, &metadata) == 0, metadata.st_dev == device,
              metadata.st_mode & S_IFMT == S_IFDIR else { return false }
        guard let uuid else { return true }
        let fresh = URL(fileURLWithPath: url.path)
        return (try? fresh.resourceValues(forKeys: [.volumeUUIDStringKey]))?.volumeUUIDString == uuid
    }

    func readCapacity() -> StorageInfo? {
        guard isMounted() else { return nil }
        return StorageInfo.read(volume: URL(fileURLWithPath: url.path))
    }
}
