import 'dart:ffi';
import 'dart:io';

import 'package:sodium/sodium_sumo.dart';

/// Loads a [SodiumSumo] instance backed by the system's native libsodium,
/// for use in VM tests. Real apps load the bundled binary via `sodium_libs`
/// instead (plan §9) — this is test-only plumbing.
Future<SodiumSumo> loadTestSodium() async {
  return SodiumSumoInit.init(() async => DynamicLibrary.open(_findLibsodium()));
}

String _findLibsodium() {
  final override = Platform.environment['KAVACH_LIBSODIUM_PATH'];
  if (override != null) return override;

  final candidates = switch (Platform.operatingSystem) {
    'macos' => [
        '/opt/homebrew/lib/libsodium.dylib',
        '/usr/local/lib/libsodium.dylib',
      ],
    'linux' => [
        '/usr/lib/x86_64-linux-gnu/libsodium.so',
        '/usr/lib/libsodium.so',
        '/usr/lib64/libsodium.so',
      ],
    _ => <String>[],
  };

  for (final path in candidates) {
    if (File(path).existsSync()) return path;
  }

  throw StateError(
    'Could not find a native libsodium to load for tests. Install it '
    '(e.g. `brew install libsodium` / `apt install libsodium23`) or set '
    'KAVACH_LIBSODIUM_PATH to its full path.',
  );
}
