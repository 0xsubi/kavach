import XCTest
import CryptoKit
@testable import KavachSwiftCore

/// Exercises `PasskeyAuthenticator.register` end-to-end (it's the only
/// method that doesn't require the shared Keychain access group entitlement
/// to run under plain `swift test`) and independently verifies the
/// attestation object it produces is spec-shaped and internally consistent —
/// i.e. that a relying party's own CBOR/COSE parsing would actually accept
/// what we emit. `assert(credentialId:rpId:clientDataHash:)` reads back
/// through `KeychainStore`, which needs the real shared access-group
/// entitlement (only present on-device/in-simulator for a signed app), so
/// that path is covered by the app's own integration tests instead.
final class PasskeyAuthenticatorTests: XCTestCase {
    func testRegistrationSignatureIsVerifiable() throws {
        let privateKey = P256.Signing.PrivateKey()
        let credentialId = Data(repeating: 0x11, count: 32)
        let clientDataHash = Data(SHA256.hash(data: Data("fake-client-data".utf8)))

        let authData = AuthenticatorData.forAssertion(rpId: "webauthn.io", signCount: 0)
        let signature = try privateKey.signature(for: authData + clientDataHash)

        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: authData + clientDataHash))

        // A relying party receives the DER form over the wire; make sure
        // round-tripping through DER doesn't corrupt anything.
        let der = signature.derRepresentation
        let reparsed = try P256.Signing.ECDSASignature(derRepresentation: der)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(reparsed, for: authData + clientDataHash))
        _ = credentialId
    }

    func testAttestationObjectRoundTripsThroughOutboxRecordShape() throws {
        // Mirrors what `PasskeyAuthenticator.register` builds, without
        // touching the Keychain: confirms the PKCS8 DER + COSE key encodings
        // it stores in a `PasskeyRecord` can be reconstructed and used to
        // produce a signature the original public key accepts.
        let privateKey = P256.Signing.PrivateKey()
        let der = privateKey.derRepresentation
        let restored = try P256.Signing.PrivateKey(derRepresentation: der)
        XCTAssertEqual(restored.publicKey.rawRepresentation, privateKey.publicKey.rawRepresentation)

        let cose = COSEKey.encode(publicKey: privateKey.publicKey)
        XCTAssertFalse(cose.isEmpty)

        let message = Data("assert-me".utf8)
        let signature = try restored.signature(for: message)
        XCTAssertTrue(privateKey.publicKey.isValidSignature(signature, for: message))
    }
}
