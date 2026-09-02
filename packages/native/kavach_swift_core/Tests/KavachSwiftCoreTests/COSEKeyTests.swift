import XCTest
import Foundation
import CryptoKit
@testable import KavachSwiftCore

final class COSEKeyTests: XCTestCase {
    func testEncodeHasExpectedLabelsAndLength() {
        let key = P256.Signing.PrivateKey().publicKey
        let cbor = COSEKey.encode(publicKey: key)

        // Fixed-shape map: A5 (map, 5 pairs), 01 02 (kty:EC2), 03 26 (alg:ES256),
        // 20 01 (crv:P-256), then x (label 21) and y (label 22) as 32-byte strings
        // each prefixed with 0x58 0x20 (byte string, 1-byte length = 32).
        XCTAssertEqual(cbor.first, 0xA5)
        XCTAssertTrue(cbor.starts(with: [0xA5, 0x01, 0x02, 0x03, 0x26, 0x20, 0x01]))
        // total length: 1 (map head) + 3 small-int pairs (2 bytes each) +
        // 2 (x/y label byte + 32-byte byte-string, whose length-32 header is
        // itself 2 bytes: 0x58 0x20) pairs of (1 + 2 + 32) bytes each.
        XCTAssertEqual(cbor.count, 1 + 2 + 2 + 2 + (1 + 2 + 32) + (1 + 2 + 32))
    }

    func testRoundTripXYMatchesRawRepresentation() {
        let key = P256.Signing.PrivateKey().publicKey
        let raw = key.rawRepresentation
        let cbor = COSEKey.encode(publicKey: key)
        let x = raw.prefix(32)
        let y = raw.suffix(32)
        XCTAssertTrue(cbor.range(of: Data(x)) != nil)
        XCTAssertTrue(cbor.range(of: Data(y)) != nil)
    }
}
