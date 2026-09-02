import XCTest
@testable import KavachSwiftCore

final class CBOREncoderTests: XCTestCase {
    func testUnsignedSmall() {
        XCTAssertEqual(CBOREncoder.encode(.unsigned(0)), Data([0x00]))
        XCTAssertEqual(CBOREncoder.encode(.unsigned(23)), Data([0x17]))
    }

    func testUnsigned1Byte() {
        XCTAssertEqual(CBOREncoder.encode(.unsigned(24)), Data([0x18, 0x18]))
        XCTAssertEqual(CBOREncoder.encode(.unsigned(255)), Data([0x18, 0xFF]))
    }

    func testUnsigned2Byte() {
        XCTAssertEqual(CBOREncoder.encode(.unsigned(256)), Data([0x19, 0x01, 0x00]))
    }

    func testNegative() {
        // -7 (ES256 alg id) => major type 1, value 6
        XCTAssertEqual(CBOREncoder.encode(.negative(-7)), Data([0x26]))
        // -1 => major type 1, value 0
        XCTAssertEqual(CBOREncoder.encode(.negative(-1)), Data([0x20]))
    }

    func testByteString() {
        let d = Data([0x01, 0x02, 0x03])
        XCTAssertEqual(CBOREncoder.encode(.byteString(d)), Data([0x43, 0x01, 0x02, 0x03]))
    }

    func testTextString() {
        XCTAssertEqual(CBOREncoder.encode(.textString("fmt")), Data([0x63, 0x66, 0x6D, 0x74]))
    }

    func testEmptyMap() {
        XCTAssertEqual(CBOREncoder.encode(.map([])), Data([0xA0]))
    }

    func testSimpleMap() {
        // {"a": 1} => A1 61 61 01
        let encoded = CBOREncoder.encode(.map([(.textString("a"), .unsigned(1))]))
        XCTAssertEqual(encoded, Data([0xA1, 0x61, 0x61, 0x01]))
    }

    func testArray() {
        let encoded = CBOREncoder.encode(.array([.unsigned(1), .unsigned(2), .unsigned(3)]))
        XCTAssertEqual(encoded, Data([0x83, 0x01, 0x02, 0x03]))
    }
}
