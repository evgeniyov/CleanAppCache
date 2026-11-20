import Foundation
import Darwin

/// Identity and nanosecond timestamps read without following the final symlink.
struct FileSnapshot: Equatable, Sendable {
    let device: dev_t
    let inode: ino_t
    let mode: mode_t
    let size: off_t
    let allocatedBytes: UInt64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int

    init(_ info: stat) {
        device = info.st_dev; inode = info.st_ino; mode = info.st_mode; size = info.st_size
        allocatedBytes = UInt64(max(0, info.st_blocks)) * 512
        modifiedSeconds = info.st_mtimespec.tv_sec
        modifiedNanoseconds = info.st_mtimespec.tv_nsec
        changedSeconds = info.st_ctimespec.tv_sec
        changedNanoseconds = info.st_ctimespec.tv_nsec
    }

    init?(at url: URL) {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return nil }
        self.init(info)
    }

    var isRegularFile: Bool { mode & S_IFMT == S_IFREG }
    func matches(_ url: URL) -> Bool { FileSnapshot(at: url) == self }

    func isSameObject(at url: URL) -> Bool {
        guard let current = FileSnapshot(at: url) else { return false }
        return isSameObject(as: current)
    }

    func isSameObject(as other: Self) -> Bool {
        device == other.device && inode == other.inode && mode & S_IFMT == other.mode & S_IFMT
    }
}
