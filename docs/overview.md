# encore for rocksky — Overview

encore for rocksky is an independent, unofficial Flutter desktop app for Windows that scrobbles your music plays to [Rocksky](https://rocksky.app), a music scrobbling service built on the AT Protocol / Bluesky ecosystem.

## Documentation map

| Document | Covers |
|----------|--------|
| [`architecture.md`](architecture.md) | Layers, folder structure, dependencies, state, persisted keys |
| [`authentication.md`](authentication.md) | App-password login, PDS resolution, token refresh, sign-out |
| [`realtime-scrobbling.md`](realtime-scrobbling.md) | The main pipeline: SMTC → enrichment → PDS write |
| [`windows-native-bridge.md`](windows-native-bridge.md) | The C++/WinRT method channel and its contract |
| [`data-models.md`](data-models.md) | `TrackInfo`, `SpotifyHistoryEntry`, `EnrichedTrackMeta`, the record's required fields |
| [`spotify-import.md`](spotify-import.md) | The experimental, flag-gated history import |
| [`portable-build.md`](portable-build.md) | Packaging a USB-stick build that keeps its settings beside the `.exe` |
| [`../CREDITS.md`](../CREDITS.md) | Third-party licenses and the services the app talks to |
| [`../third_party/local_notifier/FORK.md`](../third_party/local_notifier/FORK.md) | Why `local_notifier` is vendored and what was patched |

## What it does

1. **Real-time scrobbling** — Watches the Windows System Media Transport Controls (SMTC) to detect what any supported player is playing, then writes an `app.rocksky.scrobble` record directly to your Bluesky PDS (Personal Data Server) 30 seconds after the track is detected. This is the only write path — the Rocksky API is not used.
2. **Metadata enrichment** — Every live scrobble is looked up in MusicBrainz first, for the track length, MusicBrainz IDs, release date and album art URL that the record carries. Album art *shown in the mini-player* comes from SMTC, or from the iTunes Search API when SMTC has none.
3. **Runs in the tray** — Minimising or closing hides the window to the notification area; polling and scrobbling continue with nothing on screen. Each scrobble raises a silent desktop toast, which can be switched off.
4. **Spotify history import** — Reads Spotify's extended streaming history JSON files and backfills scrobbles into the same PDS. Experimental and gated behind the `ENABLE_SPOTIFY_IMPORT` compile-time flag, so it is absent from default builds. The Spotify Web API is used for enrichment only on this path, and only with credentials the user supplies.

## Tech stack

- **Framework**: Flutter for Windows (Dart), SDK `^3.11.0`
- **UI**: [fluent_ui](https://pub.dev/packages/fluent_ui) — Windows Fluent Design 2 widgets
- **Window effects**: [flutter_acrylic](https://pub.dev/packages/flutter_acrylic) Mica background, with a graceful fallback on older Windows
- **Window & tray**: `window_manager` (1:1 aspect lock, size restore, hide-to-tray) and `tray_manager`
- **Platform integration**: Custom C++ method channel using Windows SMTC WinRT APIs
- **HTTP**: `package:http`
- **Local storage**: `shared_preferences`; the Bluesky session inside it is encrypted with the Windows Data Protection API
- **Notifications**: `local_notifier` — a **vendored fork**, see [`FORK.md`](../third_party/local_notifier/FORK.md)
- **File picker**: `file_picker`

## Key files

| File | Purpose |
|------|---------|
| `lib/main.dart` | App entry point, FluentApp setup, Mica / window / tray initialization |
| `lib/feature_flags.dart` | Compile-time flags; currently just `kSpotifyImportEnabled` |
| `lib/services/credential_store.dart` | Reads and writes the saved PDS session, encrypted at rest; migrates plaintext sessions |
| `lib/services/dpapi.dart` | `CryptProtectData` / `CryptUnprotectData` binding behind the credential store |
| `lib/services/portable_mode.dart` | Redirects saved state next to the executable for portable builds |
| `lib/screens/home_screen.dart` | Main UI: PDS auth form, mini-player, scrobble timer, history, debug logs |
| `lib/screens/spotify_import_dialog.dart` | Multi-step dialog for importing Spotify JSON history (experimental, flag-gated) |
| `lib/services/media_watcher_service.dart` | Polls Windows SMTC every 5 seconds for track changes |
| `lib/services/pds_service.dart` | PDS auth, token refresh, and `app.rocksky.scrobble` writes and deletes |
| `lib/services/track_enrichment_service.dart` | Spotify API + MusicBrainz metadata lookups |
| `lib/services/spotify_import_service.dart` | Parses Spotify extended streaming history JSON |
| `lib/services/notification_service.dart` | Desktop toasts and their lifecycle |
| `lib/services/tray_service.dart` | Notification-area icon, hide-to-tray, exit |
| `lib/services/window_state_service.dart` | Remembers the window size across restarts |
| `lib/services/log_buffer.dart` | In-memory rotating log, with DID / JWT redaction |
| `lib/models/track_info.dart` | Immutable currently-playing track |
| `lib/models/spotify_history_entry.dart` | One parsed history entry; also the internal shape for live scrobbles |
| `windows/runner/spotify_smtc.cpp` | C++ bridge to Windows SMTC via `GlobalSystemMediaTransportControlsSessionManager` |
| `windows/runner/flutter_window.cpp` | Registers the `encore/spotify_smtc` method channel |
| `windows/runner/main.cpp` | Creates the window at its default 400×400 size |

## Privacy posture

- The Bluesky **app password is never stored** — it is exchanged once for a session, and only the session tokens are persisted.
- Scrobbles go to the user's own PDS. Nothing is sent to the Rocksky API.
- The debug log redacts DIDs and JWTs *at the sink*, because the log dialog has a Copy button and its output ends up in bug reports.
- Outbound requests otherwise reach only MusicBrainz, Cover Art Archive, the iTunes Search API, and — on the import path with user-supplied credentials — the Spotify Web API. See [`../CREDITS.md`](../CREDITS.md#services).
