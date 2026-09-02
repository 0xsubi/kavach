import XCTest
import CryptoKit
@testable import KavachSwiftCore

final class AuthenticatorDataTests: XCTestCase {
    func testAssertionHeaderShape() {
        let data = AuthenticatorData.forAssertion(rpId: "webauthn.io", signCount: 0)
        // 32-byte rpIdHash + 1 flags byte + 4 signCount bytes, no attested data.
        XCTAssertEqual(data.count, 37)

        let expectedHash = Data(SHA256.hash(data: Data("webauthn.io".utf8)))
        XCTAssertEqual(data.prefix(32), expectedHash)

        let flags = data[data.index(data.startIndex, offsetBy: 32)]
        XCTAssertEqual(flags & 0x01, 0x01) // user present
        XCTAssertEqual(flags & 0x04, 0x04) // user verified
        XCTAssertEqual(flags & 0x40, 0x00) // no attested credential data

        let signCountBytes = data.suffix(4)
        XCTAssertEqual(Array(signCountBytes), [0, 0, 0, 0])
    }

    func testRegistrationHeaderIncludesAttestedCredentialData() {
        let privateKey = P256.Signing.PrivateKey()
        let credentialId = Data(repeating: 0xAB, count: 16)
        let aaguid = UUID()

        let data = AuthenticatorData.forRegistration(
            rpId: "webauthn.io",
            signCount: 0,
            aaguid: aaguid,
            credentialId: credentialId,
            publicKey: privateKey.publicKey
        )

        let flags = data[data.index(data.startIndex, offsetBy: 32)]
        XCTAssertEqual(flags & 0x40, 0x40) // attested credential data present

        // 37-byte header + 16-byte aaguid + 2-byte credIdLen + 16-byte credId + COSE key
        let coseKey = COSEKey.encode(publicKey: privateKey.publicKey)
        XCTAssertEqual(data.count, 37 + 16 + 2 + 16 + coseKey.count)

        let credIdLenOffset = 37 + 16
        let credIdLenBytes = data[data.index(data.startIndex, offsetBy: credIdLenOffset)..<data.index(data.startIndex, offsetBy: credIdLenOffset + 2)]
        let credIdLen = (UInt16(credIdLenBytes.first!) << 8) | UInt16(credIdLenBytes.last!)
        XCTAssertEqual(credIdLen, 16)
    }
}
