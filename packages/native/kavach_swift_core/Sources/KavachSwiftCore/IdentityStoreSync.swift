import Foundation
import AuthenticationServices

/// Registers which (relying party, credential) pairs exist with the OS's
/// `ASCredentialIdentityStore`, so Password AutoFill can offer them and route
/// a selection to our credential-provider extension without the extension
/// ever needing to enumerate the whole vault itself. Only the main app calls
/// this — it runs whenever the set of unlocked passkeys changes (unlock,
/// lock, new item added, item deleted).
@available(iOS 17.0, macOS 14.0, *)
public enum IdentityStoreSync {
    public static func replaceAll(with records: [PasskeyRecord]) async throws {
        let identities: [ASPasskeyCredentialIdentity] = records.compactMap { record in
            guard let credentialId = Data(base64Encoded: record.credentialId),
                  let userHandle = Data(base64Encoded: record.userHandle)
            else {
                return nil
            }
            return ASPasskeyCredentialIdentity(
                relyingPartyIdentifier: record.rpId,
                userName: record.userName,
                credentialID: credentialId,
                userHandle: userHandle,
                recordIdentifier: record.credentialId
            )
        }
        try await ASCredentialIdentityStore.shared.replaceCredentialIdentities(identities)
    }

    /// Called on vault lock: a locked vault has no signable keys, so the OS
    /// should not offer any of them for AutoFill either.
    public static func clearAll() async throws {
        try await ASCredentialIdentityStore.shared.removeAllCredentialIdentities()
    }
}
