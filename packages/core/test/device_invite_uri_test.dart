import 'package:kavach_core/kavach_core.dart';
import 'package:test/test.dart';

void main() {
  const invite = DeviceInviteUri(
    baseUrl: 'https://kavach.example.com',
    vaultId: '11111111-2222-3333-4444-555555555555',
    inviteToken: 'aGVsbG8td29ybGQtdG9rZW4=',
  );

  group('encode', () {
    test('round-trips through tryParse', () {
      expect(DeviceInviteUri.tryParseString(invite.encode()), invite);
    });

    test('emits the kavach://join scheme and host', () {
      final uri = Uri.parse(invite.encode());
      expect(uri.scheme, 'kavach');
      expect(uri.host, 'join');
      expect(uri.queryParameters['v'], '1');
    });

    test('percent-escapes values that would otherwise break the query', () {
      const awkward = DeviceInviteUri(
        baseUrl: 'https://example.com:8443/base',
        vaultId: 'vault&id=weird',
        inviteToken: 'tok en/with+chars&=',
      );
      // The point of the test is that the reader recovers the exact bytes,
      // not what the escaping looks like on the wire.
      expect(DeviceInviteUri.tryParseString(awkward.encode()), awkward);
    });

    test('stays short enough to scan off a screen', () {
      // Payload length drives QR module count, and a denser code is
      // harder for a phone to read off a laptop screen. A realistic
      // invite (43-char base64url token from the server's 32 random
      // bytes, UUID vault id) should stay inside byte-mode capacity at
      // error-correction level M for a version the widget renders at a
      // comfortable module size. Adding a field here is exactly the
      // change that would silently degrade scanning.
      const realistic = DeviceInviteUri(
        baseUrl: 'https://kavach-storage.example.com',
        vaultId: '3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
        inviteToken: 'dGhpcy1pcy00My1jaGFycy1vZi1iYXNlNjR1cmwtdG9r',
      );
      expect(realistic.encode().length, lessThan(180));

      // The LAN case self-hosters actually hit is shorter still.
      const lan = DeviceInviteUri(
        baseUrl: 'http://192.168.1.42:8080',
        vaultId: '3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d',
        inviteToken: 'dGhpcy1pcy00My1jaGFycy1vZi1iYXNlNjR1cmwtdG9r',
      );
      expect(lan.encode().length, lessThan(160));
    });

    test('keeps the token out of toString', () {
      expect(invite.toString(), isNot(contains(invite.inviteToken)));
      expect(invite.toString(), contains(invite.vaultId));
    });
  });

  group('tryParse rejects', () {
    test('a foreign scheme', () {
      expect(
        DeviceInviteUri.tryParseString(
          'https://join?v=1&url=https://a.com&vault=v&token=t',
        ),
        isNull,
      );
    });

    test('a kavach URI that is not a join link', () {
      expect(
        DeviceInviteUri.tryParseString(
          'kavach://unlock?v=1&url=https://a.com&vault=v&token=t',
        ),
        isNull,
      );
    });

    test('an unknown format version', () {
      expect(
        DeviceInviteUri.tryParseString(
          'kavach://join?v=2&url=https://a.com&vault=v&token=t',
        ),
        isNull,
      );
    });

    test('a missing format version', () {
      expect(
        DeviceInviteUri.tryParseString(
          'kavach://join?url=https://a.com&vault=v&token=t',
        ),
        isNull,
      );
    });

    test('any missing or blank field', () {
      const cases = [
        'kavach://join?v=1&vault=v&token=t',
        'kavach://join?v=1&url=https://a.com&token=t',
        'kavach://join?v=1&url=https://a.com&vault=v',
        'kavach://join?v=1&url=&vault=v&token=t',
        'kavach://join?v=1&url=https://a.com&vault=%20&token=t',
      ];
      for (final raw in cases) {
        expect(DeviceInviteUri.tryParseString(raw), isNull, reason: raw);
      }
    });

    test('a non-HTTP base url', () {
      // A scanned QR is attacker-controlled; the base url goes straight to
      // an HTTP client, so nothing but http/https should get through.
      const cases = [
        'kavach://join?v=1&url=file%3A%2F%2F%2Fetc%2Fpasswd&vault=v&token=t',
        'kavach://join?v=1&url=javascript%3Aalert(1)&vault=v&token=t',
        'kavach://join?v=1&url=not-a-url&vault=v&token=t',
        'kavach://join?v=1&url=https%3A%2F%2F&vault=v&token=t',
      ];
      for (final raw in cases) {
        expect(DeviceInviteUri.tryParseString(raw), isNull, reason: raw);
      }
    });

    test('arbitrary non-URI junk from a camera scan', () {
      for (final raw in ['', '   ', 'hello world', '::::']) {
        expect(DeviceInviteUri.tryParseString(raw), isNull, reason: raw);
      }
    });
  });

  group('tryParse accepts', () {
    test('plain http for a LAN / self-hosted server', () {
      final parsed = DeviceInviteUri.tryParseString(
        'kavach://join?v=1&url=http%3A%2F%2F192.168.1.10%3A8080&vault=v&token=t',
      );
      expect(parsed?.baseUrl, 'http://192.168.1.10:8080');
    });

    test('the path-segment spelling some readers normalise to', () {
      final parsed = DeviceInviteUri.tryParseString(
        'kavach:join?v=1&url=https%3A%2F%2Fa.com&vault=v&token=t',
      );
      expect(parsed?.vaultId, 'v');
    });

    test('surrounding whitespace and stray field padding', () {
      final parsed = DeviceInviteUri.tryParseString(
        '  kavach://join?v=1&url=https%3A%2F%2Fa.com&vault=%20v%20&token=%20t%20  ',
      );
      expect(parsed?.vaultId, 'v');
      expect(parsed?.inviteToken, 't');
    });
  });
}
