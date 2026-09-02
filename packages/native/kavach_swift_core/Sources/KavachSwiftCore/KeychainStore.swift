import Foundation
import Security

public enum KeychainStoreError: Error {
    case unhandled(OSStatus)
    case corruptRecord
}

/// Persists decrypted `PasskeyRecord`s in the shared Keychain Access Group so
/// both the main app process and the (separate-process, memory-jailed)
/// credential-provider extension can read them, without ever putting private
/// key material through the App Group container as a plain file.
///
/// Populated by the main app only while the vault is unlocked (plan §6): on
/// unlock it upserts every passkey item's record here and syncs the identity
/// store; on lock it wipes this store entirely so a locked app leaves no
/// signable key material behind for the extension to use.
public final class KeychainStore {
    private let service = "com.kavach.passkey"
    private let accessGroup: String

    public init(accessGroup: String = SharedGroup.identifier) {
        self.accessGroup = accessGroup
    }

    public func upsert(_ record: PasskeyRecord) throws {
        let data = try JSONEncoder().encode(record)
        var query = baseQuery(account: record.credentialId)

        let attributesToUpdate: [String: Any] = [kSecValueData as String: data]
        let updateStatus = SecItemUpdate(query as CFDictionary, attributesToUpdate as CFDictionary)
        if updateStatus == errSecSuccess {
            return
        }
        if updateStatus != errSecItemNotFound {
            throw KeychainStoreError.unhandled(updateStatus)
        }

        query[kSecValueData as String] = data
        query[kSecAttrAccessible as String] = kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly
        let addStatus = SecItemAdd(query as CFDictionary, nil)
        guard addStatus == errSecSuccess else {
            throw KeychainStoreError.unhandled(addStatus)
        }
    }

    public func find(credentialId: String) throws -> PasskeyRecord? {
        var query = baseQuery(account: credentialId)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitOne

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return nil }
        guard status == errSecSuccess, let data = result as? Data else {
            throw KeychainStoreError.unhandled(status)
        }
        return try JSONDecoder().decode(PasskeyRecord.self, from: data)
    }

    public func findAll(rpId: String? = nil) throws -> [PasskeyRecord] {
        var query = baseQuery(account: nil)
        query[kSecReturnData as String] = true
        query[kSecMatchLimit as String] = kSecMatchLimitAll

        var result: CFTypeRef?
        let status = SecItemCopyMatching(query as CFDictionary, &result)
        if status == errSecItemNotFound { return [] }
        guard status == errSecSuccess, let items = result as? [Data] else {
            throw KeychainStoreError.unhandled(status)
        }
        let records = try items.map { try JSONDecoder().decode(PasskeyRecord.self, from: $0) }
        guard let rpId else { return records }
        return records.filter { $0.rpId == rpId }
    }

    public func delete(credentialId: String) throws {
        let query = baseQuery(account: credentialId)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }

    /// Wipes every passkey record this app owns in the shared group. Called
    /// on vault lock: an extension process reading the Keychain while the
    /// vault is locked should find nothing signable.
    public func deleteAll() throws {
        let query = baseQuery(account: nil)
        let status = SecItemDelete(query as CFDictionary)
        guard status == errSecSuccess || status == errSecItemNotFound else {
            throw KeychainStoreError.unhandled(status)
        }
    }

    private func baseQuery(account: String?) -> [String: Any] {
        var query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccessGroup as String: accessGroup,
        ]
        if let account {
            query[kSecAttrAccount as String] = account
        }
        return query
    }
}
