import 'package:kavach_core/src/generator/password_generator.dart';
import 'package:test/test.dart';

void main() {
  const generator = PasswordGenerator();

  test('generates a password of the requested length', () {
    final password = generator.generatePassword(const PasswordPolicy(length: 32));
    expect(password.length, 32);
  });

  test('respects disabled character classes', () {
    final password = generator.generatePassword(
      const PasswordPolicy(length: 40, useUppercase: false, useSymbols: false, useDigits: false),
    );
    expect(password, matches(RegExp(r'^[a-z]+$')));
  });

  test('includes at least one char from every enabled class', () {
    final password = generator.generatePassword(const PasswordPolicy(length: 24));
    expect(password, matches(RegExp('[A-Z]')));
    expect(password, matches(RegExp('[a-z]')));
    expect(password, matches(RegExp(r'[0-9]')));
    expect(password, matches(RegExp(r'[^A-Za-z0-9]')));
  });

  test('excludes ambiguous characters when requested', () {
    for (var i = 0; i < 20; i++) {
      final password = generator.generatePassword(
        const PasswordPolicy(length: 64, excludeAmbiguous: true),
      );
      expect(password.contains(RegExp('[0Oo1lI|]')), isFalse);
    }
  });

  test('throws when the length is too short for the required classes', () {
    expect(
      () => generator.generatePassword(const PasswordPolicy(length: 2)),
      throwsArgumentError,
    );
  });

  test('throws when every character class is disabled', () {
    expect(
      () => generator.generatePassword(
        const PasswordPolicy(
          useUppercase: false,
          useLowercase: false,
          useDigits: false,
          useSymbols: false,
        ),
      ),
      throwsArgumentError,
    );
  });

  test('generates a passphrase with the requested word count and separator', () {
    final phrase = generator.generatePassphrase(const PassphrasePolicy(wordCount: 6, separator: '_'));
    expect(phrase.split('_'), hasLength(6));
  });

  test('passphrase capitalization and trailing number are applied', () {
    final phrase = generator.generatePassphrase(
      const PassphrasePolicy(wordCount: 3, capitalize: true, includeNumber: true),
    );
    final parts = phrase.split('-');
    expect(parts, hasLength(4)); // 3 words + 1 number
    for (final word in parts.take(3)) {
      expect(word[0], word[0].toUpperCase());
    }
    expect(int.tryParse(parts.last), isNotNull);
  });

  test('entropy estimate increases with pool size and length', () {
    final small = PasswordGenerator.estimateEntropyBits(
      const PasswordPolicy(length: 10, useUppercase: false, useDigits: false, useSymbols: false),
    );
    final large = PasswordGenerator.estimateEntropyBits(const PasswordPolicy(length: 20));
    expect(large, greaterThan(small));
  });
}
