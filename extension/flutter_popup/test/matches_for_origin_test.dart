import 'package:flutter_popup/data/vault_repository.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:kavach_core/kavach_core.dart';

/// Host matching is what decides whether the in-page autofill dropdown
/// appears at all, and it has to cope with whatever users actually typed
/// into the item editor's free-text URL field. Two real bugs shipped here
/// before this suite existed: a bare `amazon.in` matched nothing (Dart's
/// `Uri.parse` reports no host for a string with no scheme), and a saved
/// `amazon.in` failed against a page served from `www.amazon.in`.
void main() {
  VaultItem passwordItem({required String name, required List<String> uris}) => VaultItem(
        id: 'id-$name',
        version: 1,
        updatedAt: DateTime.utc(2026, 1, 1),
        updatedByDevice: 'test-device',
        data: VaultItemData.password(
          name: name,
          username: '$name@example.com',
          password: 'secret-$name',
          uris: uris,
        ),
      );

  VaultItem passkeyItem() => VaultItem(
        id: 'passkey-id',
        version: 1,
        updatedAt: DateTime.utc(2026, 1, 1),
        updatedByDevice: 'test-device',
        data: VaultItemData.passkey(
          rpId: 'example.com',
          rpName: 'example',
          userHandle: 'handle',
          userName: 'user',
          credentialId: 'cred',
          privateKey: 'priv',
          publicKeyCose: 'pub',
          createdAt: DateTime.utc(2026, 1, 1),
        ),
      );

  List<String> namesOf(List<VaultItem> items) =>
      items.map((item) => (item.data as PasswordItemData).name).toList();

  group('matchesForOrigin', () {
    test('matches a stored URI that has a scheme', () {
      final items = [
        passwordItem(name: 'amazon', uris: ['https://www.amazon.in']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://www.amazon.in')), ['amazon']);
    });

    test('matches a bare domain stored without a scheme', () {
      // Regression: `Uri.parse('amazon.in').host` is '', not 'amazon.in', so
      // an exact-host comparison silently matched nothing.
      final items = [
        passwordItem(name: 'amazon', uris: ['amazon.in']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://amazon.in')), ['amazon']);
    });

    test('ignores a www. prefix on either side', () {
      final saved = [
        passwordItem(name: 'amazon', uris: ['amazon.in']),
      ];
      expect(namesOf(matchesForOrigin(saved, 'https://www.amazon.in')), ['amazon']);

      final savedWithWww = [
        passwordItem(name: 'amazon', uris: ['https://www.amazon.in']),
      ];
      expect(namesOf(matchesForOrigin(savedWithWww, 'https://amazon.in')), ['amazon']);
    });

    test('matches regardless of path, port, or query on the stored URI', () {
      final items = [
        passwordItem(name: 'gh', uris: ['https://github.com/login?return_to=%2F']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://github.com')), ['gh']);
    });

    test('is case-insensitive on the host', () {
      final items = [
        passwordItem(name: 'amazon', uris: ['HTTPS://WWW.AMAZON.IN']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://www.amazon.in')), ['amazon']);
    });

    test('does not match a different top-level domain', () {
      // amazon.in and amazon.com are genuinely different sites and may hold
      // different accounts, so this must NOT match.
      final items = [
        passwordItem(name: 'amazon-com', uris: ['https://www.amazon.com']),
      ];
      expect(matchesForOrigin(items, 'https://www.amazon.in'), isEmpty);
    });

    test('does not match a different subdomain', () {
      final items = [
        passwordItem(name: 'mail', uris: ['https://mail.example.com']),
      ];
      expect(matchesForOrigin(items, 'https://calendar.example.com'), isEmpty);
    });

    test('does not match on a substring of the host', () {
      // 'evil-amazon.in' contains 'amazon.in'; a naive substring check (an
      // earlier implementation's fallback) would have matched it and offered
      // the user's real credential to a lookalike domain.
      final items = [
        passwordItem(name: 'amazon', uris: ['https://amazon.in']),
      ];
      expect(matchesForOrigin(items, 'https://evil-amazon.in'), isEmpty);
      expect(matchesForOrigin(items, 'https://amazon.in.evil.com'), isEmpty);
    });

    test('returns every item that matches, not just the first', () {
      final items = [
        passwordItem(name: 'personal', uris: ['https://github.com']),
        passwordItem(name: 'work', uris: ['https://github.com']),
        passwordItem(name: 'elsewhere', uris: ['https://gitlab.com']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://github.com')), ['personal', 'work']);
    });

    test('matches when any one of several stored URIs matches', () {
      final items = [
        passwordItem(name: 'multi', uris: ['https://example.com', 'https://www.amazon.in']),
      ];
      expect(namesOf(matchesForOrigin(items, 'https://amazon.in')), ['multi']);
    });

    test('skips items with no URIs', () {
      final items = [passwordItem(name: 'no-uris', uris: [])];
      expect(matchesForOrigin(items, 'https://example.com'), isEmpty);
    });

    test('skips passkey items, which autofill does not handle', () {
      expect(matchesForOrigin([passkeyItem()], 'https://example.com'), isEmpty);
    });

    test('returns nothing for an origin with no parseable host', () {
      final items = [
        passwordItem(name: 'amazon', uris: ['https://amazon.in']),
      ];
      expect(matchesForOrigin(items, ''), isEmpty);
      // Chrome reports "null" as the origin for sandboxed/opaque frames.
      expect(matchesForOrigin(items, 'null'), isEmpty);
    });

    test('does not match a stored URI with no parseable host', () {
      final items = [passwordItem(name: 'junk', uris: ['', '   '])];
      expect(matchesForOrigin(items, 'https://example.com'), isEmpty);
    });
  });
}
