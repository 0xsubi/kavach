/// The `kavach://join` deep link that carries a device invite from the
/// inviting device to the joining one.
///
/// Typing a server URL, a UUID and a 40-odd character token by hand on a
/// phone is the worst part of onboarding a second device, so the inviting
/// device also renders this URI as a QR code. A phone's system camera
/// recognises the custom scheme, opens Kavach, and the join screen comes
/// up pre-filled.
///
/// Both halves of that round trip live here on purpose: the encoder and
/// the parser are the one place the wire format is defined, so the
/// extension popup (which only ever encodes) and the native app (which
/// does both) cannot drift apart.
class DeviceInviteUri {
  const DeviceInviteUri({
    required this.baseUrl,
    required this.vaultId,
    required this.inviteToken,
  });

  final String baseUrl;
  final String vaultId;
  final String inviteToken;

  /// Custom scheme rather than an `https://` universal link: a universal
  /// link would need a hosted, HTTPS-verified domain serving an
  /// apple-app-site-association / assetlinks.json file, which a
  /// self-hosted kavach-storage deployment has no way to provide. The
  /// tradeoff is that scanning does nothing unless Kavach is already
  /// installed — acceptable, since you install the app before joining.
  static const String scheme = 'kavach';
  static const String host = 'join';

  /// Bumped only on a breaking payload change. An unknown version is
  /// rejected outright rather than best-effort parsed, so an older app
  /// says "update Kavach" instead of silently misreading a field.
  static const int formatVersion = 1;

  static const String _versionParam = 'v';
  static const String _baseUrlParam = 'url';
  static const String _vaultIdParam = 'vault';
  static const String _tokenParam = 'token';

  String encode() => Uri(
    scheme: scheme,
    host: host,
    queryParameters: <String, String>{
      _versionParam: '$formatVersion',
      _baseUrlParam: baseUrl,
      _vaultIdParam: vaultId,
      _tokenParam: inviteToken,
    },
  ).toString();

  /// Returns null for anything that isn't a well-formed, current-version
  /// Kavach invite. Callers get this straight off a camera scan or an OS
  /// deep link — i.e. fully attacker-controlled input — so every failure
  /// mode is a null rather than an exception to surface in the UI.
  static DeviceInviteUri? tryParse(Uri uri) {
    if (uri.scheme.toLowerCase() != scheme) return null;

    // Accept both `kavach://join?…` (host) and `kavach:join?…` (first
    // path segment). Some QR readers and share sheets normalise one into
    // the other, and rejecting the variant would be a confusing failure.
    final target = uri.host.isNotEmpty
        ? uri.host
        : (uri.pathSegments.isNotEmpty ? uri.pathSegments.first : '');
    if (target.toLowerCase() != host) return null;

    return tryParseQueryParameters(uri.queryParameters);
  }

  /// Convenience for the raw-string case (camera payloads, `getInitialLink`).
  static DeviceInviteUri? tryParseString(String value) {
    final uri = Uri.tryParse(value.trim());
    return uri == null ? null : tryParse(uri);
  }

  /// The field-extraction half of [tryParse], split out for `apps/web`:
  /// a website has no custom scheme to register, so the same invite
  /// travels as an ordinary `https://<its own origin>/join?…` link
  /// instead of `kavach://join?…` — the scheme and host are already
  /// meaningless there (same-origin HTTPS is the whole point), only the
  /// query parameters carry the payload. Kept in sync with [tryParse] by
  /// construction: both funnel through this one validator, so a native
  /// deep link and a web link can never silently accept different shapes
  /// of the same field.
  static DeviceInviteUri? tryParseQueryParameters(Map<String, String> queryParameters) {
    if (queryParameters[_versionParam] != '$formatVersion') return null;

    final baseUrl = queryParameters[_baseUrlParam]?.trim() ?? '';
    final vaultId = queryParameters[_vaultIdParam]?.trim() ?? '';
    final token = queryParameters[_tokenParam]?.trim() ?? '';
    if (baseUrl.isEmpty || vaultId.isEmpty || token.isEmpty) return null;

    // The joining device is about to register itself against whatever
    // server this names, so constrain it to real HTTP(S) origins. Scanning
    // a hostile QR still can't leak the vault key (that only ever arrives
    // wrapped to this device's public key, and an existing device must
    // approve first), but there's no reason to hand an arbitrary scheme
    // to the HTTP client.
    final parsedBase = Uri.tryParse(baseUrl);
    if (parsedBase == null) return null;
    if (parsedBase.scheme != 'http' && parsedBase.scheme != 'https') return null;
    if (parsedBase.host.isEmpty) return null;

    return DeviceInviteUri(
      baseUrl: baseUrl,
      vaultId: vaultId,
      inviteToken: token,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is DeviceInviteUri &&
      other.baseUrl == baseUrl &&
      other.vaultId == vaultId &&
      other.inviteToken == inviteToken;

  @override
  int get hashCode => Object.hash(baseUrl, vaultId, inviteToken);

  /// Deliberately omits the token — this type ends up in error paths and
  /// log lines, and the token is a live credential.
  @override
  String toString() => 'DeviceInviteUri(baseUrl: $baseUrl, vaultId: $vaultId, inviteToken: <redacted>)';
}
