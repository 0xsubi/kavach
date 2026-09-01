/// Kavach's font families (plan §8). Bundled as package assets — see this
/// package's `pubspec.yaml` — rather than fetched at runtime, so the app
/// never makes a network call just to render text.
///
/// Flutter auto-prefixes fonts declared inside a package's own pubspec with
/// `packages/<package_name>/` to avoid cross-package family-name
/// collisions, so consumers outside this package (i.e. the app) must use
/// that full prefixed name — a bare `'Space Grotesk'` silently falls back
/// to the system font instead of erroring.
abstract final class KavachFonts {
  /// Headings, labels, and general UI text.
  static const String display = 'packages/neopop_theme/Space Grotesk';

  /// Passwords, generated-password output, and other literal secret/value
  /// text, where a fixed-width face makes similar-looking characters
  /// (`0`/`O`, `1`/`l`/`I`) easier to tell apart.
  static const String mono = 'packages/neopop_theme/Overpass Mono';
}
