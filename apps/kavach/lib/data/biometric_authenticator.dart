import 'package:local_auth/local_auth.dart';

/// Gates unlocking behind Face ID/Touch ID/device credential (plan §10
/// phase 3 "biometric unlock"), on top of — not instead of — the vault-key
/// cache: this only decides whether to *call* [VaultRepository.unlock],
/// never how the vault key itself is protected.
///
/// Abstracted so tests can inject a fake instead of the real
/// [LocalAuthentication] plugin, which would otherwise show a real system
/// Touch ID/password prompt during automated `flutter test -d macos` runs.
abstract class BiometricAuthenticator {
  Future<bool> isAvailable();
  Future<bool> authenticate();
}

class LocalAuthBiometricAuthenticator implements BiometricAuthenticator {
  final LocalAuthentication _auth = LocalAuthentication();

  @override
  Future<bool> isAvailable() async {
    try {
      final supported = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      return supported && canCheck;
    } catch (_) {
      return false;
    }
  }

  @override
  Future<bool> authenticate() async {
    try {
      return await _auth.authenticate(
        localizedReason: 'unlock your kavach vault',
        options: const AuthenticationOptions(stickyAuth: true),
      );
    } catch (_) {
      return false;
    }
  }
}
