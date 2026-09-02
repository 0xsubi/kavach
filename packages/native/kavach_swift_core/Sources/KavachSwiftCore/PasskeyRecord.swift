import Foundation

/// Mirrors `PasskeyItemData` in `packages/core/lib/src/models/vault_item.dart`
/// field-for-field, so a record can cross the Dart<->Swift boundary (via the
/// method channel) and the shared-Keychain<->outbox boundary (between the
/// main app and the credential-provider extension) without translation.
public struct PasskeyRecord: Codable, Equatable {
    public var rpId: String
    public var rpName: String
    public var userHandle: String
    public var userName: String
    public var credentialId: String // base64
    public var privateKey: String // base64, PKCS8 DER
    public var publicKeyCose: String // base64
    public var signCount: UInt32
    public var discoverable: Bool
    public var createdAtEpochMs: Int64

    public init(
        rpId: String,
        rpName: String,
        userHandle: String,
        userName: String,
        credentialId: String,
        privateKey: String,
        publicKeyCose: String,
        signCount: UInt32,
        discoverable: Bool,
        createdAtEpochMs: Int64
    ) {
        self.rpId = rpId
        self.rpName = rpName
        self.userHandle = userHandle
        self.userName = userName
        self.credentialId = credentialId
        self.privateKey = privateKey
        self.publicKeyCose = publicKeyCose
        self.signCount = signCount
        self.discoverable = discoverable
        self.createdAtEpochMs = createdAtEpochMs
    }
}
