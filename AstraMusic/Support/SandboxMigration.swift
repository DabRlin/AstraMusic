import Foundation

/// One-time recovery of state that used to live inside the app-sandbox container.
///
/// Early builds ran sandboxed, so `library.json` and the `UserDefaults` domain
/// were written under `~/Library/Containers/com.dang.AstraMusic/Data/…`. The
/// distributed build runs unsandboxed (see `AstraMusic.entitlements`), where the
/// same relative paths resolve to `~/Library/…` instead. Without this the first
/// un-sandboxed launch looks like a wiped install: likes, recents, the device
/// fingerprint, and the playback mode would all silently reset.
///
/// Everything here is best-effort and idempotent: a failed copy leaves the
/// container file untouched, so a later launch retries.
enum SandboxMigration {
    /// `~/Library/Containers/<bundle id>/Data`, or `nil` when this install never
    /// ran sandboxed — in which case there is nothing to recover.
    private static var legacyContainerData: URL? {
        guard let bundleID = Bundle.main.bundleIdentifier else { return nil }
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appending(path: "Library/Containers", directoryHint: .isDirectory)
            .appending(path: bundleID, directoryHint: .isDirectory)
            .appending(path: "Data", directoryHint: .isDirectory)
        return FileManager.default.fileExists(atPath: url.path) ? url : nil
    }

    /// Copies the container's preference domain into the standard one.
    ///
    /// Must run before anything touches `UserDefaults.standard` (see
    /// `AstraMusicApp.init`): the store resolves and caches its backing file on
    /// first access, so a later copy would be ignored for the rest of the launch.
    /// Keys already present in the standard domain win — this only fills gaps —
    /// and a completion marker keeps the scan to once per install.
    static func migratePreferencesIfNeeded() {
        let defaults = UserDefaults.standard
        let marker = "sandboxMigration.preferencesApplied"
        guard !defaults.bool(forKey: marker) else { return }
        defer { defaults.set(true, forKey: marker) }

        guard let container = legacyContainerData,
              let bundleID = Bundle.main.bundleIdentifier,
              let legacy = NSDictionary(
                  contentsOf: container.appending(path: "Library/Preferences/\(bundleID).plist")
              )
        else { return }

        for (key, value) in legacy {
            guard let key = key as? String, defaults.object(forKey: key) == nil else { continue }
            defaults.set(value, forKey: key)
        }
    }

    /// Copies a file out of the container's Application Support into
    /// `destination`, when `destination` does not exist yet. The original is left
    /// in place as a backup.
    static func copyLegacyFileIfNeeded(to destination: URL, named name: String) {
        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: destination.path),
              let container = legacyContainerData
        else { return }

        let legacy = container
            .appending(path: "Library/Application Support/AstraMusic", directoryHint: .isDirectory)
            .appending(path: name)
        guard fileManager.fileExists(atPath: legacy.path) else { return }

        do {
            try fileManager.copyItem(at: legacy, to: destination)
        } catch {
            // `LibraryStore.load()` seeds an empty library when the file is
            // missing, so a failure here is not fatal — and because the original
            // is untouched, the next launch tries again.
        }
    }
}
