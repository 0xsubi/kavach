import Foundation
import CryptoKit

/// Builds a COSE_Key CBOR map (RFC 9053) for a P-256 public key, in the
/// EC2/ES256 shape every WebAuthn relying party expects inside
/// `attestedCredentialData`.
public enum COSEKey {
    public static func encode(publicKey: P256.Signing.PublicKey) -> Data {
        // `.rawRepresentation` for a P-256 key is exactly X (32 bytes) || Y
        // (32 bytes), with no leading format-tag byte.
        let raw = publicKey.rawRepresentation
        precondition(raw.count == 64, "unexpected P-256 raw representation length")
        let x = raw.prefix(32)
        let y = raw.suffix(32)

        let map = CBORValue.map([
            (.unsigned(1), .unsigned(2)), // kty: EC2
            (.unsigned(3), .negative(-7)), // alg: ES256
            (.negative(-1), .unsigned(1)), // crv: P-256
            (.negative(-2), .byteString(Data(x))), // x
            (.negative(-3), .byteString(Data(y))), // y
        ])
        return CBOREncoder.encode(map)
    }
}
