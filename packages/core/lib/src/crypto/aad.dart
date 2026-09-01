import 'dart:convert';
import 'dart:typed_data';

/// Additional authenticated data for sealed vault files, used with
/// [VaultCrypto.encryptItem]/[VaultCrypto.decryptItem].
///
/// Binds ciphertext to its logical identity (an item id, or "the index")
/// and to the vault-key epoch that encrypted it, so a file can't be
/// silently swapped for another item's ciphertext, or replayed from a
/// previous epoch after a key rotation.
///
/// Deliberately excludes the item version: the version lives inside the
/// plaintext itself (and inside the separately-AAD-bound index entry for
/// that item). Binding the item's own AAD to its own version would be
/// circular — the AAD has to be known *before* the item can be decrypted.
/// Rollback-to-a-stale-version-of-the-same-item is instead prevented by
/// only ever reading blobs reachable from the current git HEAD, not by the
/// AAD.
Uint8List itemAad({required String itemId, required int epoch}) =>
    Uint8List.fromList(utf8.encode('item|$itemId|$epoch'));

Uint8List indexAad({required int epoch}) => Uint8List.fromList(utf8.encode('index|$epoch'));
