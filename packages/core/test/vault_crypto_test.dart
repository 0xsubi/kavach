import 'dart:convert';
import 'dart:typed_data';

import 'package:kavach_core/src/crypto/aad.dart';
import 'package:kavach_core/src/crypto/vault_crypto.dart';
import 'package:sodium/sodium_sumo.dart';
import 'package:test/test.dart';

import 'support/sodium_test_support.dart';

void main() {
  late SodiumSumo sodium;
  late VaultCrypto crypto;

  setUpAll(() async {
    sodium = await loadTestSodium();
    crypto = VaultCrypto(sodium);
  });

  test('vault item round-trips through encrypt/decrypt with matching AAD', () {
    final vaultKey = crypto.generateVaultKey();
    final plaintext = Uint8List.fromList(utf8.encode('{"hello":"vault"}'));
    final aad = itemAad(itemId: 'item-1', epoch: 1);

    final sealed = crypto.encryptItem(plaintext: plaintext, vaultKey: vaultKey, aad: aad);
    final opened = crypto.decryptItem(sealed: sealed, vaultKey: vaultKey, aad: aad);

    expect(utf8.decode(opened), '{"hello":"vault"}');
  });

  test('decrypt fails when AAD does not match (file-swap protection)', () {
    final vaultKey = crypto.generateVaultKey();
    final plaintext = Uint8List.fromList(utf8.encode('secret'));
    final sealed = crypto.encryptItem(
      plaintext: plaintext,
      vaultKey: vaultKey,
      aad: itemAad(itemId: 'item-1', epoch: 1),
    );

    expect(
      () => crypto.decryptItem(
        sealed: sealed,
        vaultKey: vaultKey,
        aad: itemAad(itemId: 'item-2', epoch: 1),
      ),
      throwsA(anything),
    );
  });

  test('decrypt fails when a different vault key is used', () {
    final vaultKey = crypto.generateVaultKey();
    final wrongKey = crypto.generateVaultKey();
    final aad = itemAad(itemId: 'item-1', epoch: 1);
    final sealed = crypto.encryptItem(
      plaintext: Uint8List.fromList(utf8.encode('secret')),
      vaultKey: vaultKey,
      aad: aad,
    );

    expect(
      () => crypto.decryptItem(sealed: sealed, vaultKey: wrongKey, aad: aad),
      throwsA(anything),
    );
  });

  test('vault key wraps/unwraps between two device keypairs', () {
    final vaultKey = crypto.generateVaultKey();
    final approver = crypto.generateDeviceKeyPair();
    final newDevice = crypto.generateDeviceKeyPair();

    final wrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: newDevice.publicKey,
      senderKeyPair: approver,
    );

    final unwrapped = crypto.unwrapVaultKey(
      wrapped: wrapped,
      senderPublicKey: approver.publicKey,
      recipientKeyPair: newDevice,
    );

    expect(unwrapped.extractBytes(), vaultKey.extractBytes());
  });

  test('wrapped vault key cannot be opened by the wrong device', () {
    final vaultKey = crypto.generateVaultKey();
    final approver = crypto.generateDeviceKeyPair();
    final newDevice = crypto.generateDeviceKeyPair();
    final attacker = crypto.generateDeviceKeyPair();

    final wrapped = crypto.wrapVaultKeyForDevice(
      vaultKey: vaultKey,
      recipientPublicKey: newDevice.publicKey,
      senderKeyPair: approver,
    );

    expect(
      () => crypto.unwrapVaultKey(
        wrapped: wrapped,
        senderPublicKey: approver.publicKey,
        recipientKeyPair: attacker,
      ),
      throwsA(anything),
    );
  });

  test('master password recovers an escrowed vault key end to end', () {
    final vaultKey = crypto.generateVaultKey();
    final salt = crypto.generateMasterSalt();
    final masterKey = crypto.deriveMasterKey(masterPassword: 'correct horse battery staple', salt: salt);

    final escrow = crypto.encryptEscrow(vaultKey: vaultKey, masterKey: masterKey);

    final rederivedMasterKey = crypto.deriveMasterKey(
      masterPassword: 'correct horse battery staple',
      salt: salt,
    );
    final recovered = crypto.decryptEscrow(sealed: escrow, masterKey: rederivedMasterKey);

    expect(recovered.extractBytes(), vaultKey.extractBytes());
  });

  test('escrow recovery fails with the wrong master password', () {
    final vaultKey = crypto.generateVaultKey();
    final salt = crypto.generateMasterSalt();
    final masterKey = crypto.deriveMasterKey(masterPassword: 'right password', salt: salt);
    final escrow = crypto.encryptEscrow(vaultKey: vaultKey, masterKey: masterKey);

    final wrongMasterKey = crypto.deriveMasterKey(masterPassword: 'wrong password', salt: salt);

    expect(
      () => crypto.decryptEscrow(sealed: escrow, masterKey: wrongMasterKey),
      throwsA(anything),
    );
  });
}
