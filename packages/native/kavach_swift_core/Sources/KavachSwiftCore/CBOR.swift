import Foundation

/// A minimal, encode-only CBOR (RFC 8949) writer covering exactly the value
/// shapes WebAuthn needs: unsigned/negative integers, byte strings, text
/// strings, maps, and arrays, all in definite-length form. Decoding is
/// deliberately not implemented — `ASCredentialProviderExtension` hands us
/// already-parsed request fields (rpId, clientDataHash, userHandle, ...), so
/// this authenticator only ever needs to *produce* CBOR (COSE public keys,
/// attestation objects), never parse it.
public enum CBORValue {
    case unsigned(UInt64)
    case negative(Int64) // stores the actual (negative) value, e.g. -7
    case byteString(Data)
    case textString(String)
    case array([CBORValue])
    case map([(CBORValue, CBORValue)]) // order preserved; caller controls canonical ordering
}

public enum CBOREncoder {
    public static func encode(_ value: CBORValue) -> Data {
        var out = Data()
        write(value, into: &out)
        return out
    }

    private static func write(_ value: CBORValue, into out: inout Data) {
        switch value {
        case .unsigned(let v):
            writeHead(major: 0, argument: v, into: &out)
        case .negative(let v):
            precondition(v < 0, "CBORValue.negative must hold a negative value")
            let magnitude = UInt64(-1 - v)
            writeHead(major: 1, argument: magnitude, into: &out)
        case .byteString(let d):
            writeHead(major: 2, argument: UInt64(d.count), into: &out)
            out.append(d)
        case .textString(let s):
            let d = Data(s.utf8)
            writeHead(major: 3, argument: UInt64(d.count), into: &out)
            out.append(d)
        case .array(let items):
            writeHead(major: 4, argument: UInt64(items.count), into: &out)
            for item in items { write(item, into: &out) }
        case .map(let pairs):
            writeHead(major: 5, argument: UInt64(pairs.count), into: &out)
            for (k, v) in pairs {
                write(k, into: &out)
                write(v, into: &out)
            }
        }
    }

    /// Writes a CBOR "initial byte" plus the (possibly multi-byte) length/value
    /// argument, always in the shortest-but-one canonical width bucket CBOR
    /// defines (direct/1/2/4/8 bytes) — sufficient for our sizes (COSE keys,
    /// authenticator data) which never approach the 32-bit boundary.
    private static func writeHead(major: UInt8, argument: UInt64, into out: inout Data) {
        let majorByte = major << 5
        switch argument {
        case 0...23:
            out.append(majorByte | UInt8(argument))
        case 24...0xFF:
            out.append(majorByte | 24)
            out.append(UInt8(argument))
        case 0x100...0xFFFF:
            out.append(majorByte | 25)
            out.append(UInt8((argument >> 8) & 0xFF))
            out.append(UInt8(argument & 0xFF))
        case 0x1_0000...0xFFFF_FFFF:
            out.append(majorByte | 26)
            for shift in stride(from: 24, through: 0, by: -8) {
                out.append(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        default:
            out.append(majorByte | 27)
            for shift in stride(from: 56, through: 0, by: -8) {
                out.append(UInt8((argument >> UInt64(shift)) & 0xFF))
            }
        }
    }
}
