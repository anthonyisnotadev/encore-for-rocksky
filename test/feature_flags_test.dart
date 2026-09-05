import 'package:encore_for_rocksky/feature_flags.dart';
import 'package:flutter_test/flutter_test.dart';

/// Guards the default-off contract for experimental features.
///
/// `flutter test` runs without `--dart-define`, so this asserts what a plain
/// `flutter build windows --release` produces. If someone flips the flag's
/// default, or gives it a `defaultValue: true`, this fails rather than quietly
/// shipping an experimental destructive path to users.
void main() {
  test('Spotify import is off unless explicitly enabled at build time', () {
    expect(kSpotifyImportEnabled, isFalse);
  });
}
