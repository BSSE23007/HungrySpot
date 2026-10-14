import Foundation
import Darwin
import HungrySpotCore

struct AppPaths {
    let root: URL
    private let processLock: StoreProcessLock
    var databaseURL: URL { root.appendingPathComponent("database/spot.sqlite3") }
    var images: URL { root.appendingPathComponent("images", isDirectory: true) }
    var backups: URL { root.appendingPathComponent("backups", isDirectory: true) }

    init(root: URL? = nil) throws {
        let fm = FileManager.default
        self.root = try root ?? fm.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("TheHungrySpot", isDirectory: true)
        try fm.createDirectory(at: self.root, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        self.processLock = try StoreProcessLock(url: self.root.appendingPathComponent(".store.lock"))
        try Self.recoverInterruptedRestore(in: self.root)
        for directory in [databaseURL.deletingLastPathComponent(), images, images.appendingPathComponent("products"), images.appendingPathComponent("categories"), backups] {
            try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    // A restore is a directory swap protected by a durable journal. A crash before
    // the commit marker always returns to the original database and image set.
    static func recoverInterruptedRestore(in root: URL) throws {
        let fm = FileManager.default
        let children = try fm.contentsOfDirectory(at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey])
        for journal in children where journal.lastPathComponent.hasPrefix(".restore-") {
            let values = try journal.resourceValues(forKeys: [.isDirectoryKey, .isSymbolicLinkKey])
            guard values.isDirectory == true, values.isSymbolicLink != true else { continue }
            if !fm.fileExists(atPath: journal.appendingPathComponent("committed").path) {
                for name in ["database", "images"] {
                    let old = journal.appendingPathComponent("old-\(name)")
                    let live = root.appendingPathComponent(name)
                    if fm.fileExists(atPath: old.path) {
                        if fm.fileExists(atPath: live.path) { try fm.removeItem(at: live) }
                        try fm.moveItem(at: old, to: live)
                    }
                }
            }
            try fm.removeItem(at: journal)
        }
    }
}

private final class StoreProcessLock {
    private static let registryLock = NSLock()
    private static var lockedPaths = Set<String>()

    private let descriptor: Int32
    private let lockPath: String

    init(url: URL) throws {
        lockPath = url.standardizedFileURL.path

        Self.registryLock.lock()
        if Self.lockedPaths.contains(lockPath) {
            Self.registryLock.unlock()
            throw SpotError.validation(
                "The Hungry Spot is already using this data folder. Close the other instance before opening it again."
            )
        }
        Self.lockedPaths.insert(lockPath)
        Self.registryLock.unlock()

        descriptor = Darwin.open(
            url.path,
            O_CREAT | O_RDWR,
            mode_t(0o600)
        )

        guard descriptor >= 0 else {
            Self.registryLock.lock()
            Self.lockedPaths.remove(lockPath)
            Self.registryLock.unlock()

            throw SpotError.validation(
                "The restaurant data folder could not be locked. Check its permissions."
            )
        }

        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)

            Self.registryLock.lock()
            Self.lockedPaths.remove(lockPath)
            Self.registryLock.unlock()

            throw SpotError.validation(
                "The Hungry Spot is already using this data folder. Close the other instance before opening it again."
            )
        }
    }

    deinit {
        Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)

        Self.registryLock.lock()
        Self.lockedPaths.remove(lockPath)
        Self.registryLock.unlock()
    }
}

