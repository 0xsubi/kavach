import 'dart:io' show Platform;

import 'package:flutter/services.dart';
import 'package:kavach_core/kavach_core.dart';
import 'package:uuid/uuid.dart';

/// Dart side of the native passkey bridge (plan §6): pushes the vault's
/// decrypted passkeys into the shared Keychain whenever the vault
/// unlocks/locks, and drains whatever the native credential-provider
/// extension created since the app last ran. Everything here is best-effort
/// — a password vault must keep working even where passkey provisioning
/// (App Groups, AutoFill Credential Provider — both require real Apple
/// signing, unlike the rest of the app) isn't set up yet, so every method
/// swallows platform-channel failures rather than surfacing them.
abstract class PasskeyBridge {
  Future<void> syncUnlocked(List<VaultItem> passkeyItems);
  Future<void> clearOnLock();
  Future<List<VaultItem>> drainOutboxAsVaultItems({required String deviceId});
}

class MethodChannelPasskeyBridge implements PasskeyBridge {
  MethodChannelPasskeyBridge() : _channel = const MethodChannel('com.kavach.passkeys');

  final MethodChannel _channel;
  static const Uuid _uuid = Uuid();

  bool get _supported => Platform.isIOS || Platform.isMacOS;

  @override
  Future<void> syncUnlocked(List<VaultItem> passkeyItems) async {
    if (!_supported) return;
    final payload = passkeyItems.map((item) {
      final d = item.data as PasskeyItemData;
      return {
        'rpId': d.rpId,
        'rpName': d.rpName,
        'userHandle': d.userHandle,
        'userName': d.userName,
        'credentialId': d.credentialId,
        'privateKey': d.privateKey,
        'publicKeyCose': d.publicKeyCose,
        'signCount': d.signCount,
        'discoverable': d.discoverable,
        'createdAtEpochMs': d.createdAt.millisecondsSinceEpoch,
      };
    }).toList();
    await _guard(() => _channel.invokeMethod<void>('syncUnlocked', payload));
  }

  @override
  Future<void> clearOnLock() async {
    if (!_supported) return;
    await _guard(() => _channel.invokeMethod<void>('clearOnLock'));
  }

  @override
  Future<List<VaultItem>> drainOutboxAsVaultItems({required String deviceId}) async {
    if (!_supported) return const [];
    final raw = await _guard(() => _channel.invokeMethod<List<Object?>>('drainOutbox'));
    if (raw == null) return const [];
    return raw.map((entry) {
      final m = Map<String, dynamic>.from(entry! as Map);
      return VaultItem(
        id: _uuid.v7(),
        version: 1,
        updatedAt: DateTime.now().toUtc(),
        updatedByDevice: deviceId,
        data: VaultItemData.passkey(
          rpId: m['rpId'] as String,
          rpName: m['rpName'] as String,
          userHandle: m['userHandle'] as String,
          userName: m['userName'] as String,
          credentialId: m['credentialId'] as String,
          privateKey: m['privateKey'] as String,
          publicKeyCose: m['publicKeyCose'] as String,
          signCount: m['signCount'] as int,
          discoverable: m['discoverable'] as bool,
          createdAt: DateTime.fromMillisecondsSinceEpoch(m['createdAtEpochMs'] as int, isUtc: true),
        ),
      );
    }).toList();
  }

  Future<T?> _guard<T>(Future<T> Function() body) async {
    try {
      return await body();
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }
}
