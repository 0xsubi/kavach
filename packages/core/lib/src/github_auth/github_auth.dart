import 'dart:convert';

import 'package:http/http.dart' as http;

/// A usable GitHub access token plus enough metadata to know when to refresh
/// it. `null` [expiresAt] means the token (e.g. a classic PAT) doesn't
/// expire on its own.
class GitHubSession {
  const GitHubSession({required this.token, this.expiresAt});

  final String token;
  final DateTime? expiresAt;

  bool get isExpired => expiresAt != null && DateTime.now().isAfter(expiresAt!);
}

/// How the app obtains a GitHub token for reading/writing the vault repo.
/// Deliberately separate from [VaultCrypto]'s key material (plan §3) — this
/// is transport auth only, never used to derive or wrap any secret.
abstract class GitHubAuthenticator {
  Future<GitHubSession> currentSession();
}

/// Simplest possible authenticator: the user pastes a fine-grained Personal
/// Access Token scoped to the single vault repo. Ships first because it
/// needs no GitHub App registration; [GitHubDeviceFlowAuthenticator]
/// supersedes it once the app is registered.
class PatAuthenticator implements GitHubAuthenticator {
  const PatAuthenticator(this._readToken);

  final Future<String?> Function() _readToken;

  @override
  Future<GitHubSession> currentSession() async {
    final token = await _readToken();
    if (token == null || token.isEmpty) {
      throw StateError('No GitHub PAT configured.');
    }
    return GitHubSession(token: token);
  }
}

/// GitHub App Device Authorization Flow (RFC 8628). Works identically from a
/// native app and a browser-extension popup via plain `fetch`/`http` calls —
/// no redirect URI or client secret needed (plan §3).
class GitHubDeviceFlowAuthenticator implements GitHubAuthenticator {
  GitHubDeviceFlowAuthenticator({required this.clientId, http.Client? httpClient})
      : _http = httpClient ?? http.Client();

  final String clientId;
  final http.Client _http;

  static final Uri _codeEndpoint = Uri.parse('https://github.com/login/device/code');
  static final Uri _tokenEndpoint = Uri.parse('https://github.com/login/oauth/access_token');

  /// Starts the flow: returns the `user_code`/`verification_uri` pair to
  /// show the user, plus a [pollForToken] continuation.
  Future<DeviceFlowStart> start({List<String> scopes = const ['repo']}) async {
    final response = await _http.post(
      _codeEndpoint,
      headers: {'Accept': 'application/json'},
      body: {'client_id': clientId, 'scope': scopes.join(' ')},
    );
    final body = jsonDecode(response.body) as Map<String, dynamic>;
    return DeviceFlowStart(
      deviceCode: body['device_code'] as String,
      userCode: body['user_code'] as String,
      verificationUri: body['verification_uri'] as String,
      intervalSeconds: (body['interval'] as num).toInt(),
      expiresInSeconds: (body['expires_in'] as num).toInt(),
    );
  }

  Future<GitHubSession> pollForToken(DeviceFlowStart start) async {
    var interval = Duration(seconds: start.intervalSeconds);
    final deadline = DateTime.now().add(Duration(seconds: start.expiresInSeconds));
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(interval);
      final response = await _http.post(
        _tokenEndpoint,
        headers: {'Accept': 'application/json'},
        body: {
          'client_id': clientId,
          'device_code': start.deviceCode,
          'grant_type': 'urn:ietf:params:oauth:grant-type:device_code',
        },
      );
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      if (body['access_token'] != null) {
        return GitHubSession(token: body['access_token'] as String);
      }
      final error = body['error'] as String?;
      if (error == 'authorization_pending') continue;
      if (error == 'slow_down') {
        interval += const Duration(seconds: 5);
        continue;
      }
      throw StateError('GitHub device flow failed: ${error ?? body}');
    }
    throw StateError('GitHub device flow timed out before the user authorized the app.');
  }

  @override
  Future<GitHubSession> currentSession() {
    throw UnimplementedError(
      'GitHubDeviceFlowAuthenticator requires the caller to drive start()/pollForToken() '
      'once and persist the resulting token via SecureKeyStore; currentSession() should '
      'be backed by that cached token in the concrete app-layer wiring.',
    );
  }
}

class DeviceFlowStart {
  const DeviceFlowStart({
    required this.deviceCode,
    required this.userCode,
    required this.verificationUri,
    required this.intervalSeconds,
    required this.expiresInSeconds,
  });

  final String deviceCode;
  final String userCode;
  final String verificationUri;
  final int intervalSeconds;
  final int expiresInSeconds;
}
