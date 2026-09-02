import 'dart:io';

import 'package:kavach_core/kavach_core.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// iOS/Android Keychain/Keystore entries are **not** tied to an app's
/// install lifecycle the way its sandboxed files are: deleting and
/// reinstalling the app wipes its local database and documents, but prior
/// Keychain items (device id, device keypair, cached vault key, GitHub
/// token) survive untouched. Left unhandled, a "fresh" reinstall silently
/// inherits a stale device identity/vault-key state from whatever the app
/// last did on that device — surfacing as a reinstalled app going straight
/// to "waiting for approval" for a device/vault that no longer exists
/// anywhere.
///
/// Detects this by writing a marker file in the sandboxed application-
/// support directory (which genuinely does get wiped on uninstall, unlike
/// Keychain/Keystore) on first successful run, and wiping [secureStore]
/// whenever that marker is missing — which is true both on a real first
/// launch (nothing to wipe, harmless no-op) and right after a reinstall
/// (the case this actually exists for).
Future<void> ensureFreshInstallState(SecureKeyStore secureStore) async {
  final dir = await getApplicationSupportDirectory();
  final marker = File(p.join(dir.path, '.kavach_install_marker'));
  if (await marker.exists()) return;
  await secureStore.deleteAll();
  await marker.create(recursive: true);
}
