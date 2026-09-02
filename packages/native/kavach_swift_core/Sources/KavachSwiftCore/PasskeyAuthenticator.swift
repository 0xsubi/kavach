import Foundation
import CryptoKit

public enum PasskeyAuthenticatorError: Error {
    case credentialNotFound
    case corruptStoredKey
}

/// The authenticator itself: everything the credential-provider extension
/// needs to answer a WebAuthn `create()` or `get()` ceremony, built entirely
/// from `CryptoKit` + the shared Keychain + the outbox. No networking, no
/// Flutter engine, no vault crypto — matches plan §6's "extension only ever
/// does a Keychain read + CryptoKit sign for normal use."
public final class PasskeyAuthenticator {
    private let keychain: KeychainStore
    private let outbox: PasskeyOutbox

    public init(keychain: KeychainStore = KeychainStore(), outbox: PasskeyOutbox = PasskeyOutbox()) {
        self.keychain = keychain
        self.outbox = outbox
    }

    public struct RegistrationResult {
        public let credentialId: Data
        public let attestationObject: Data
        public let record: PasskeyRecord
    }

    /// Handles `authenticatorMakeCredential`: generates a fresh P-256
    /// keypair, stores it in the shared Keychain (so it's immediately usable
    /// for a same-session assertion) and in the outbox (so the main app
    /// permanently persists it into the encrypted vault next launch), and
    /// returns the CBOR attestation object the OS/browser expects.
    public func register(
        rpId: String,
        rpName: String,
        userName: String,
        userHandle: Data
    ) throws -> RegistrationResult {
        let privateKey = P256.Signing.PrivateKey()
        let credentialId = Data((0..<32).map { _ in UInt8.random(in: 0...255) })

        let authData = AuthenticatorData.forRegistration(
            rpId: rpId,
            signCount: 0,
            aaguid: UUID(uuidString: "6b6b6176-6163-6b68-2d6b-617661636800") ?? UUID(),
            credentialId: credentialId,
            publicKey: privateKey.publicKey
        )
        let attestationObject = CBOREncoder.encode(.map([
            (.textString("fmt"), .textString("none")),
            (.textString("attStmt"), .map([])),
            (.textString("authData"), .byteString(authData)),
        ]))

        let record = PasskeyRecord(
            rpId: rpId,
            rpName: rpName,
            userHandle: userHandle.base64EncodedString(),
            userName: userName,
            credentialId: credentialId.base64EncodedString(),
            privateKey: privateKey.derRepresentation.base64EncodedString(),
            publicKeyCose: COSEKey.encode(publicKey: privateKey.publicKey).base64EncodedString(),
            signCount: 0,
            discoverable: true,
            createdAtEpochMs: Int64(Date().timeIntervalSince1970 * 1000)
        )

        try keychain.upsert(record)
        try outbox.append(record)

        return RegistrationResult(credentialId: credentialId, attestationObject: attestationObject, record: record)
    }

    public struct AssertionResult {
        public let authenticatorData: Data
        public let signature: Data
        public let userHandle: Data
    }

    /// Handles `authenticatorGetAssertion` for a specific, already-known
    /// credential ID (the OS resolves *which* credential via the identity
    /// store before ever invoking the extension).
    ///
    /// `signCount` is kept permanently at 0 rather than incremented and
    /// written back: WebAuthn (§6.1.1) explicitly allows an authenticator
    /// that doesn't implement a counter to always report 0, and relying
    /// parties are only supposed to flag a *nonzero, non-increasing* counter
    /// as a possible clone. Always-0 avoids needing to push counter updates
    /// back through the shared vault on every sign.
    public func assert(credentialId: Data, rpId: String, clientDataHash: Data) throws -> AssertionResult {
        guard let record = try keychain.find(credentialId: credentialId.base64EncodedString()) else {
            throw PasskeyAuthenticatorError.credentialNotFound
        }
        guard let keyDER = Data(base64Encoded: record.privateKey),
              let privateKey = try? P256.Signing.PrivateKey(derRepresentation: keyDER),
              let userHandle = Data(base64Encoded: record.userHandle)
        else {
            throw PasskeyAuthenticatorError.corruptStoredKey
        }

        let authData = AuthenticatorData.forAssertion(rpId: rpId, signCount: 0)
        let signedData = authData + clientDataHash
        let signature = try privateKey.signature(for: signedData).derRepresentation

        return AssertionResult(authenticatorData: authData, signature: signature, userHandle: userHandle)
    }
}
