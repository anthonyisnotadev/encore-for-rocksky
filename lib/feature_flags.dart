/// Compile-time feature flags.
///
/// These are `const bool.fromEnvironment` rather than runtime fields on
/// purpose: the AOT compiler folds them at build time, so a disabled feature's
/// widgets and services are tree-shaken out of the release binary instead of
/// shipping dormant.
library;

/// Spotify extended-streaming-history import.
///
/// Off by default — the feature is experimental and its overwrite path issues
/// irreversible `applyWrites#delete` calls against the user's PDS. Default
/// builds do not contain it. Enable for development with:
///
/// ```
/// flutter run -d windows --dart-define=ENABLE_SPOTIFY_IMPORT=true
/// ```
///
/// See `docs/spotify-import.md`.
const bool kSpotifyImportEnabled = bool.fromEnvironment(
  'ENABLE_SPOTIFY_IMPORT',
);
