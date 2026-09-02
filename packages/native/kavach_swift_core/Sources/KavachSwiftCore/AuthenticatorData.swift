import Foundation
import CryptoKit

/// Builds the raw `authenticatorData` byte string WebAuthn defines
/// (§6.1 of the spec): `rpIdHash(32) || flags(1) || signCount(4) ||
/// [attestedCredentialData]`. Kavach never emits extension data.
public enum AuthenticatorData {
    private struct Flags {
        static let userPresent: UInt8 = 1 << 0
        static let userVerified: UInt8 = 1 << 2
        static let attestedCredentialDataIncluded: UInt8 = 1 << 6
    }

    /// For a registration ceremony (`authenticatorMakeCredential`): includes
    /// the attested credential data block (aaguid, credential ID, COSE key).
    public static func forRegistration(
        rpId: String,
        signCount: UInt32,
        aaguid: UUID,
        credentialId: Data,
        publicKey: P256.Signing.PublicKey
    ) -> Data {
        var out = header(rpId: rpId, signCount: signCount, attested: true)

        var aaguidBytes = [UInt8](repeating: 0, count: 16)
        withUnsafeBytes(of: aaguid.uuid) { raw in
            for i in 0..<16 { aaguidBytes[i] = raw[i] }
        }
        out.append(contentsOf: aaguidBytes)

        let credIdLen = UInt16(credentialId.count)
        out.append(UInt8((credIdLen >> 8) & 0xFF))
        out.append(UInt8(credIdLen & 0xFF))
        out.append(credentialId)

        out.append(COSEKey.encode(publicKey: publicKey))
        return out
    }

    /// For an assertion ceremony (`authenticatorGetAssertion`): no attested
    /// credential data, just the fixed 37-byte header.
    public static func forAssertion(rpId: String, signCount: UInt32) -> Data {
        header(rpId: rpId, signCount: signCount, attested: false)
    }

    private static func header(rpId: String, signCount: UInt32, attested: Bool) -> Data {
        var out = Data(SHA256.hash(data: Data(rpId.utf8)))

        var flags = Flags.userPresent | Flags.userVerified
        if attested { flags |= Flags.attestedCredentialDataIncluded }
        out.append(flags)

        out.append(UInt8((signCount >> 24) & 0xFF))
        out.append(UInt8((signCount >> 16) & 0xFF))
        out.append(UInt8((signCount >> 8) & 0xFF))
        out.append(UInt8(signCount & 0xFF))
        return out
    }
}
