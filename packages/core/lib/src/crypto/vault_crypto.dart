import 'dart:typed_data';

import 'package:sodium/sodium_sumo.dart';

/// Envelope-encryption crypto core for Kavach (plan §3).
///
/// Depends only on [SodiumSumo] — the abstract libsodium binding interface
/// — never on a concrete loader like `sodium_libs`. Each platform target is
/// responsible for producing a `SodiumSumo` instance (loading the native
/// binary or wasm build) and injecting it here, so `core` stays platform-
/// independent. `SodiumSumo` (rather than the plain `Sodium`) is required
/// because Argon2id (`crypto_pwhash`) is a "sumo"-only libsodium API.
///
/// Three distinct secrets are modeled by this class and are never
/// conflated (plan §3):
///  1. A device's own X25519 keypair ([generateDeviceKeyPair]).
///  2. The vault key: one random symmetric key shared by all of a user's
///     approved devices, used to encrypt every item ([generateVaultKey],
///     [encryptItem]/[decryptItem]).
///  3. The master password, used only to unlock a recovery escrow copy of
///     the vault key ([deriveMasterKey], [encryptEscrow]/[decryptEscrow]).
class VaultCrypto {
  const VaultCrypto(this._sodium);

  final SodiumSumo _sodium;

  // ---------------------------------------------------------------------
  // 1. Vault item AEAD — XChaCha20-Poly1305 (plan §2/§3).
  // ---------------------------------------------------------------------

  SecureKey generateVaultKey() => _sodium.crypto.aeadXChaCha20Poly1305IETF.keygen();

  /// Encrypts [plaintext] for storage as `items/<shard>/<id>.json.enc`.
  /// [aad] should be `"<itemId>|<epoch>|<version>"` (plan §2) to bind the
  /// ciphertext to its logical location and prevent file-swap attacks.
  ///
  /// Output layout: `nonce(24B) || ciphertext+tag`.
  Uint8List encryptItem({
    required Uint8List plaintext,
    required SecureKey vaultKey,
    required Uint8List aad,
  }) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = _sodium.randombytes.buf(aead.nonceBytes);
    final ciphertext = aead.encrypt(
      message: plaintext,
      nonce: nonce,
      key: vaultKey,
      additionalData: aad,
    );
    return Uint8List.fromList([...nonce, ...ciphertext]);
  }

  Uint8List decryptItem({
    required Uint8List sealed,
    required SecureKey vaultKey,
    required Uint8List aad,
  }) {
    final aead = _sodium.crypto.aeadXChaCha20Poly1305IETF;
    final nonce = Uint8List.sublistView(sealed, 0, aead.nonceBytes);
    final ciphertext = Uint8List.sublistView(sealed, aead.nonceBytes);
    return aead.decrypt(
      cipherText: ciphertext,
      nonce: nonce,
      key: vaultKey,
      additionalData: aad,
    );
  }

  // ---------------------------------------------------------------------
  // 2. Device identity — X25519 keypair (plan §3).
  // ---------------------------------------------------------------------

  /// Generates a device's own long-lived X25519 keypair on first install.
  /// The secret key must be persisted via `SecureKeyStore`, never synced.
  KeyPair generateDeviceKeyPair() => _sodium.crypto.box.keyPair();

  // ---------------------------------------------------------------------
  // 3. Vault key wrapping — authenticated crypto_box (not an anonymous
  //    sealed box), so a wrapped-key file corroborates which device wrapped
  //    it (plan §3). Stored as `keys/vault-key.<epoch>.<device-id>.json`.
  // ---------------------------------------------------------------------

  /// Wraps [vaultKey] so only the holder of the secret key matching
  /// [recipientPublicKey] can unwrap it. [senderKeyPair] is the approving
  /// device's own keypair — its secret key is what makes this box
  /// "authenticated" rather than anonymous.
  Uint8List wrapVaultKeyForDevice({
    required SecureKey vaultKey,
    required Uint8List recipientPublicKey,
    required KeyPair senderKeyPair,
  }) {
    final box = _sodium.crypto.box;
    final nonce = _sodium.randombytes.buf(box.nonceBytes);
    final plaintext = vaultKey.extractBytes();
    final ciphertext = box.easy(
      message: plaintext,
      nonce: nonce,
      publicKey: recipientPublicKey,
      secretKey: senderKeyPair.secretKey,
    );
    plaintext.fillRange(0, plaintext.length, 0);
    return Uint8List.fromList([...nonce, ...ciphertext]);
  }

  /// Unwraps a vault key that the device behind [senderPublicKey] wrapped
  /// for us, using our own [recipientKeyPair].
  SecureKey unwrapVaultKey({
    required Uint8List wrapped,
    required Uint8List senderPublicKey,
    required KeyPair recipientKeyPair,
  }) {
    final box = _sodium.crypto.box;
    final nonce = Uint8List.sublistView(wrapped, 0, box.nonceBytes);
    final ciphertext = Uint8List.sublistView(wrapped, box.nonceBytes);
    final plaintext = box.openEasy(
      cipherText: ciphertext,
      nonce: nonce,
      publicKey: senderPublicKey,
      secretKey: recipientKeyPair.secretKey,
    );
    final key = SecureKey.fromList(_sodium, plaintext);
    plaintext.fillRange(0, plaintext.length, 0);
    return key;
  }

  // ---------------------------------------------------------------------
  // 4. Master password — Argon2id KDF + escrow blob (plan §3/§5). Never
  //    used to derive the vault key directly, so a password change only
  //    rewrites the escrow blob, not the whole vault.
  // ---------------------------------------------------------------------

  /// Default KDF algorithm: Argon2id, per plan §3.
  static const CryptoPwhashAlgorithm masterKeyAlgorithm = CryptoPwhashAlgorithm.argon2id13;

  Uint8List generateMasterSalt() => _sodium.randombytes.buf(_sodium.crypto.pwhash.saltBytes);

  /// Derives a master key from [masterPassword] and [salt]. Callers should
  /// run a one-time per-device benchmark (as Bitwarden's KDF settings screen
  /// does) to pick [opsLimit]/[memLimit]; these default to libsodium's
  /// "moderate" preset, which is a safe starting point.
  SecureKey deriveMasterKey({
    required String masterPassword,
    required Uint8List salt,
    int? opsLimit,
    int? memLimit,
  }) {
    final pwhash = _sodium.crypto.pwhash;
    return pwhash(
      outLen: _sodium.crypto.secretBox.keyBytes,
      password: masterPassword.toCharArray(),
      salt: salt,
      opsLimit: opsLimit ?? pwhash.opsLimitModerate,
      memLimit: memLimit ?? pwhash.memLimitModerate,
      alg: masterKeyAlgorithm,
    );
  }

  /// Encrypts [vaultKey] into the `keys/escrow.<epoch>.json` blob.
  Uint8List encryptEscrow({required SecureKey vaultKey, required SecureKey masterKey}) {
    final secretBox = _sodium.crypto.secretBox;
    final nonce = _sodium.randombytes.buf(secretBox.nonceBytes);
    final plaintext = vaultKey.extractBytes();
    final ciphertext = secretBox.easy(message: plaintext, nonce: nonce, key: masterKey);
    plaintext.fillRange(0, plaintext.length, 0);
    return Uint8List.fromList([...nonce, ...ciphertext]);
  }

  /// Recovers the vault key from an escrow blob given the derived master
  /// key (plan §5 "master-password recovery" flow).
  SecureKey decryptEscrow({required Uint8List sealed, required SecureKey masterKey}) {
    final secretBox = _sodium.crypto.secretBox;
    final nonce = Uint8List.sublistView(sealed, 0, secretBox.nonceBytes);
    final ciphertext = Uint8List.sublistView(sealed, secretBox.nonceBytes);
    final plaintext = secretBox.openEasy(cipherText: ciphertext, nonce: nonce, key: masterKey);
    final key = SecureKey.fromList(_sodium, plaintext);
    plaintext.fillRange(0, plaintext.length, 0);
    return key;
  }
}
