# Architecture

The app is organized into three layers: **UI screens**, **services**, and **models**. A custom Windows C++ bridge sits below the services layer.

```
┌─────────────────────────────────────────┐
│  UI Layer (Flutter / fluent_ui)         │
│  home_screen.dart                       │
│  spotify_import_dialog.dart (flagged)   │
├─────────────────────────────────────────┤
│  Service Layer (Dart)                   │
│  media_watcher_service.dart             │
│  pds_service.dart                       │
│  track_enrichment_service.dart          │
│  spotify_import_service.dart            │
│  notification_service.dart              │
│  tray_service.dart                      │
│  window_state_service.dart              │
│  log_buffer.dart                        │
├─────────────────────────────────────────┤
│  Platform Channel (C++ / WinRT)         │
│  spotify_smtc.cpp / .h                  │
│  flutter_window.cpp                     │
└─────────────────────────────────────────┘
```

Three of the services sit outside the scrobbling path and are wired up in
`main()` before `runApp()`, not by a screen: `NotificationService`,
`TrayService` and `WindowStateService`. Order matters there — see the comments
in `lib/main.dart`.

## Folder structure

```
lib/
  main.dart                          # Entry point, theme, Mica, window + tray init
  feature_flags.dart                 # Compile-time flags (kSpotifyImportEnabled)
  screens/
    home_screen.dart                 # Auth form + mini-player + scrobble state
    spotify_import_dialog.dart       # 3-step import wizard (select → importing → done)
                                     #   experimental: compiled in only when
                                     #   ENABLE_SPOTIFY_IMPORT is defined
  services/
    media_watcher_service.dart       # SMTC polling, repeat detection
    pds_service.dart                 # AT Protocol PDS auth & record writes
    track_enrichment_service.dart    # Spotify API + MusicBrainz lookups
    spotify_import_service.dart      # JSON parsing, filtering, dedup
    notification_service.dart        # Desktop toasts + their lifecycle
    tray_service.dart                # Notification-area icon, hide-to-tray, exit
    window_state_service.dart        # Remembers the window size across restarts
    log_buffer.dart                  # In-memory rotating log (200 lines max)
  models/
    track_info.dart                  # Immutable track data + equality check
    spotify_history_entry.dart       # Parsed Spotify JSON entry

test/
  feature_flags_test.dart            # Asserts the import flag is off by default
  log_buffer_test.dart               # Redaction of DIDs and JWTs
  notification_service_test.dart     # Toast lifecycle / no unbounded retention
  pds_delete_scrobbles_test.dart     # Selectivity of the destructive delete path
  widget_test.dart                   # Placeholder — real UI needs a live SMTC

third_party/
  local_notifier/                    # Vendored fork of local_notifier 0.1.6
```

Run the suite with `flutter test`. It needs no Windows-specific setup — the two
tests that touch platform code fake the method channel and the HTTP client
rather than driving the real ones.

## Dependencies

Key pub dependencies and why they're used:

| Package | Purpose |
|---------|---------|
| `fluent_ui` | Windows Fluent Design 2 widgets (buttons, text boxes, dialogs, progress bars) |
| `flutter_acrylic` | Acrylic / Mica window background effects |
| `system_theme` | Reads the Windows accent color for theming |
| `window_manager` | Aspect-ratio lock, minimum size, size restore, hide-to-tray, exit |
| `tray_manager` | Notification-area icon and its context menu |
| `http` | All outbound HTTP requests (PDS, Spotify, MusicBrainz, Cover Art Archive, iTunes) |
| `shared_preferences` | Persist the PDS session, the notification toggle and the window size |
| `file_picker` | Select Spotify extended streaming history JSON files |
| `local_notifier` | Show desktop toast when a track is scrobbled or fails |

`local_notifier` is pinned to a **vendored fork** under `third_party/` via
`dependency_overrides`, because upstream 0.1.6 ignores the `silent` flag on
Windows and throws when a callback arrives for a released notification. See
[`third_party/local_notifier/FORK.md`](../third_party/local_notifier/FORK.md).

## State management

The app uses plain Flutter `setState` and `ValueNotifier` — no external state-management packages.

- `_HomeScreenState` holds all auth and playback state.
- `MediaWatcherService.trackNotifier` is a `ValueNotifier<TrackInfo?>` that the screen listens to.
- `NotificationService.instance.enabled` is a `ValueNotifier<bool>` so the toggle
  in the top bar reflects the stored preference without the screen re-reading it.
- `LogBuffer` is a singleton for in-memory logs that screens and services both write to.
  It redacts DIDs and session tokens as entries are added, because the buffer backs the
  Debug Logs dialog and its Copy button. See `redact()` in `log_buffer.dart`.

`NotificationService`, `TrayService`, `WindowStateService` and `LogBuffer` are
singletons (`Foo.instance`); everything else is constructed by its owner.
`HomeScreen` owns the one `MediaWatcherService`, and `PdsService` owns its own
`MusicBrainzEnrichmentService`.

## Persisted keys

All in `SharedPreferences`:

| Key | Written by | Holds |
|-----|-----------|-------|
| `pds_url`, `pds_access_jwt`, `pds_refresh_jwt`, `pds_did` | `HomeScreen` | The PDS session. The app password is never stored. |
| `notifications_enabled` | `NotificationService` | Toast toggle, defaults to on |
| `window_side` | `WindowStateService` | Last window side length in logical pixels |

Keys written by earlier builds are cleaned up on launch, two different ways:

- `rocksky_api_key`, `rocksky_shared_secret`, `rocksky_session_key` and
  `use_direct_pds_writes` are **deleted** — that scrobbling path no longer
  exists. `HomeScreen` also re-purges them on sign-out. See
  [`authentication.md`](authentication.md#legacy-credential-cleanup).
- `window_width` / `window_height`, from before the window was locked square,
  are **migrated** into `window_side` (larger dimension wins, so the window
  never reopens smaller than it was left) and then removed.
