import 'dart:math';

/// Character set options for [PasswordGenerator.generate].
class PasswordPolicy {
  const PasswordPolicy({
    this.length = 20,
    this.useUppercase = true,
    this.useLowercase = true,
    this.useDigits = true,
    this.useSymbols = true,
    this.excludeAmbiguous = false,
  }) : assert(length > 0);

  final int length;
  final bool useUppercase;
  final bool useLowercase;
  final bool useDigits;
  final bool useSymbols;

  /// Excludes visually-ambiguous characters (`0 O o 1 l I |`).
  final bool excludeAmbiguous;
}

/// Word-list-based passphrase policy, e.g. `correct-horse-battery-staple`.
class PassphrasePolicy {
  const PassphrasePolicy({
    this.wordCount = 5,
    this.separator = '-',
    this.capitalize = false,
    this.includeNumber = false,
  }) : assert(wordCount > 0);

  final int wordCount;
  final String separator;
  final bool capitalize;
  final bool includeNumber;
}

/// Generates random passwords and passphrases using a CSPRNG.
///
/// Uses [Random.secure] rather than [PasswordCrypto]'s libsodium RNG so this
/// class has no dependency on the async Sodium init path and can be used
/// synchronously anywhere in the UI (e.g. a live "regenerate" slider).
class PasswordGenerator {
  const PasswordGenerator({Random? random}) : _random = random ?? const _LazySecureRandom();

  final Random _random;

  static const String _uppercase = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  static const String _lowercase = 'abcdefghijklmnopqrstuvwxyz';
  static const String _digits = '0123456789';
  static const String _symbols = r'!@#$%^&*()-_=+[]{};:,.<>?';
  static const String _ambiguous = '0Oo1lI|';

  String generatePassword(PasswordPolicy policy) {
    final buffer = StringBuffer();
    if (policy.useUppercase) buffer.write(_uppercase);
    if (policy.useLowercase) buffer.write(_lowercase);
    if (policy.useDigits) buffer.write(_digits);
    if (policy.useSymbols) buffer.write(_symbols);

    var pool = buffer.toString();
    if (pool.isEmpty) {
      throw ArgumentError('At least one character class must be enabled.');
    }
    if (policy.excludeAmbiguous) {
      pool = pool.split('').where((c) => !_ambiguous.contains(c)).join();
    }

    // Guarantee at least one char from each enabled class, then fill the
    // rest uniformly at random, then shuffle so the guaranteed chars aren't
    // always in the first N positions.
    final required = <String>[
      if (policy.useUppercase) _pick(_stripAmbiguous(_uppercase, policy)),
      if (policy.useLowercase) _pick(_stripAmbiguous(_lowercase, policy)),
      if (policy.useDigits) _pick(_stripAmbiguous(_digits, policy)),
      if (policy.useSymbols) _pick(_stripAmbiguous(_symbols, policy)),
    ];
    if (required.length > policy.length) {
      throw ArgumentError(
        'length (${policy.length}) is too short to include one of each enabled character class (${required.length}).',
      );
    }

    final chars = <String>[
      ...required,
      for (var i = required.length; i < policy.length; i++) _pick(pool),
    ]..shuffle(_random);

    return chars.join();
  }

  String _stripAmbiguous(String pool, PasswordPolicy policy) {
    if (!policy.excludeAmbiguous) return pool;
    return pool.split('').where((c) => !_ambiguous.contains(c)).join();
  }

  String _pick(String pool) => pool[_random.nextInt(pool.length)];

  String generatePassphrase(PassphrasePolicy policy, {List<String>? wordList}) {
    final words = wordList ?? defaultWordList;
    if (words.isEmpty) {
      throw ArgumentError('wordList must not be empty.');
    }
    final chosen = List.generate(policy.wordCount, (_) => words[_random.nextInt(words.length)]);
    final transformed = chosen.map((w) => policy.capitalize ? _capitalize(w) : w).toList();
    if (policy.includeNumber) {
      transformed.add(_random.nextInt(100).toString());
    }
    return transformed.join(policy.separator);
  }

  String _capitalize(String word) =>
      word.isEmpty ? word : word[0].toUpperCase() + word.substring(1);

  /// A small bundled fallback word list. Callers should normally supply a
  /// proper EFF-style large word list as an asset via [wordList].
  static const List<String> defaultWordList = [
    'anchor', 'basil', 'canyon', 'delta', 'ember', 'falcon', 'granite',
    'harbor', 'indigo', 'jasper', 'kernel', 'lumen', 'maple', 'nebula',
    'onyx', 'pepper', 'quartz', 'raven', 'summit', 'tundra', 'umber',
    'violet', 'willow', 'xenon', 'yonder', 'zephyr',
  ];

  /// Rough entropy estimate in bits, for UI strength meters.
  static double estimateEntropyBits(PasswordPolicy policy) {
    var poolSize = 0;
    if (policy.useUppercase) poolSize += _uppercase.length;
    if (policy.useLowercase) poolSize += _lowercase.length;
    if (policy.useDigits) poolSize += _digits.length;
    if (policy.useSymbols) poolSize += _symbols.length;
    if (poolSize == 0) return 0;
    return policy.length * (log(poolSize) / ln2);
  }
}

class _LazySecureRandom implements Random {
  const _LazySecureRandom();

  static Random get _instance => Random.secure();

  @override
  bool nextBool() => _instance.nextBool();

  @override
  double nextDouble() => _instance.nextDouble();

  @override
  int nextInt(int max) => _instance.nextInt(max);
}
