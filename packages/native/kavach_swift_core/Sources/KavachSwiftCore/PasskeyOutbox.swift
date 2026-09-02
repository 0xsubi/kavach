import Foundation

public enum PasskeyOutboxError: Error {
    case noSharedContainer
}

/// A durable drop box, in the shared App Group container, for passkeys the
/// credential-provider extension creates. The extension process only ever
/// *appends* here (it has no access to the vault key or the sync engine);
/// the main app drains it on next launch/foreground, wraps each record into
/// an encrypted `VaultItem`, and syncs it (plan §6).
///
/// Deliberately file-based rather than `UserDefaults(suiteName:)`: outbox
/// entries carry raw private key bytes, and a flat JSON file the main app
/// deletes immediately after draining is easier to reason about than a
/// defaults plist that lingers.
public final class PasskeyOutbox {
    private let groupIdentifier: String
    private let fileManager: FileManager

    public init(groupIdentifier: String = SharedGroup.identifier, fileManager: FileManager = .default) {
        self.groupIdentifier = groupIdentifier
        self.fileManager = fileManager
    }

    private func fileURL() throws -> URL {
        guard let container = fileManager.containerURL(forSecurityApplicationGroupIdentifier: groupIdentifier) else {
            throw PasskeyOutboxError.noSharedContainer
        }
        return container.appendingPathComponent("passkey-outbox.json")
    }

    /// Appends a newly created passkey record. Safe to call from the
    /// extension process even if the main app is not running.
    public func append(_ record: PasskeyRecord) throws {
        let url = try fileURL()
        var existing = (try? drain(deleteAfter: false)) ?? []
        existing.append(record)
        let data = try JSONEncoder().encode(existing)
        try data.write(to: url, options: .atomic)
    }

    /// Returns every pending record. When `deleteAfter` is true (the main
    /// app's normal drain call), the file is removed once read so nothing is
    /// double-synced.
    public func drain(deleteAfter: Bool = true) throws -> [PasskeyRecord] {
        let url = try fileURL()
        guard fileManager.fileExists(atPath: url.path) else { return [] }
        let data = try Data(contentsOf: url)
        let records = try JSONDecoder().decode([PasskeyRecord].self, from: data)
        if deleteAfter {
            try? fileManager.removeItem(at: url)
        }
        return records
    }
}
