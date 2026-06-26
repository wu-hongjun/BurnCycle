import Foundation

/// Canonical on-disk locations used across BurnCycle services.
///
/// All paths are derived from `~/Library/Application Support/BurnCycle/`.
/// The directory is created on first access so callers never need to repeat
/// the `createDirectory` boilerplate.
enum AppPaths {
    /// `~/Library/Application Support/BurnCycle/` — created on first access.
    static var supportDirectory: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            .appendingPathComponent("BurnCycle", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }
}
