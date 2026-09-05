# Data Models

## `TrackInfo`

**File:** `lib/models/track_info.dart`

Immutable representation of a currently-playing track.

```dart
class TrackInfo {
  final String title;
  final String artist;
  final String album;
  final Uint8List? artBytes;
  final bool isPlaying;
  final int? durationMs;

  bool isSameTrack(TrackInfo? other) =>
      other != null && title == other.title && artist == other.artist;
}
```

- `isSameTrack` intentionally ignores `album`, `artBytes`, `isPlaying` and
  `durationMs` so that minor metadata updates don't reset the scrobble timer.
- `durationMs` is the track length reported by the SMTC timeline, or `null` when
  the session does not expose one. It is not cosmetic: `app.rocksky.scrobble`
  requires a positive `duration`, so this is the fallback when MusicBrainz
  enrichment fails. See [Required scrobble fields](#required-scrobble-fields).
- Used by `MediaWatcherService` and throughout `HomeScreen`.

## `SpotifyHistoryEntry`

**File:** `lib/models/spotify_history_entry.dart`

Parsed from Spotify's extended streaming history JSON. Also used as the internal
shape for live scrobbles — `PdsService.writeScrobble` wraps a `TrackInfo` in one
(with `msPlayed: 0`) so both write paths share `_scrobbleRecord`.

```dart
class SpotifyHistoryEntry {
  final DateTime timestamp;
  final String trackName;
  final String artistName;
  final String albumName;
  final int msPlayed;
  final String? spotifyTrackUri;
}
```

### JSON mapping

Spotify JSON key | Dart field
---|---
`ts` | `timestamp`
`master_metadata_track_name` | `trackName`
`master_metadata_album_artist_name` | `artistName`
`master_metadata_album_album_name` | `albumName` (defaults to `''` when absent)
`ms_played` | `msPlayed`
`spotify_track_uri` | `spotifyTrackUri`

`fromJson` returns `null` for podcasts or entries missing track/artist metadata.
The `skipped` flag is *not* mapped onto the model — `SpotifyImportService` reads
it off the raw JSON while filtering.

## `EnrichedTrackMeta`

**File:** `lib/services/track_enrichment_service.dart`

Immutable metadata container — every field is `final` and the constructor is
`const`. Enrichment steps that add a field (the ISRC → MBID pass, for instance)
build a new instance rather than mutating one.

```dart
class EnrichedTrackMeta {
  final int? durationMs;
  final int? trackNumber;
  final int? discNumber;
  final String? albumArtUrl;
  final String? releaseDate;
  final int? year;
  final String? spotifyUrl;
  final String? mbid;
  final List<Map<String, String>> artists;  // defaults to const []
}
```

Populated by either `TrackEnrichmentService` (Spotify Web API + MusicBrainz ISRC
lookups, import only) or `MusicBrainzEnrichmentService` (MusicBrainz-only). The
latter runs on **every live scrobble**, not just imports — `PdsService` owns a
`MusicBrainzEnrichmentService` so callers cannot accidentally create
metadata-poor records.

### Artist list format

```json
[
  {"name": "Artist Name", "mbid": "optional-musicbrainz-id"}
]
```

`mbid` is omitted rather than null when MusicBrainz has no id for the artist.

## Required scrobble fields

**File:** `lib/services/pds_service.dart` (`_missingRequiredField`)

Not a class, but the contract every record has to satisfy before it is written.
`app.rocksky.scrobble` marks these required:

| Field | Constraint |
|-------|-----------|
| `title` | non-empty string |
| `artist` | non-empty string |
| `album` | non-empty string |
| `albumArtist` | non-empty string (the app writes the artist name here) |
| `duration` | integer ≥ 1 (milliseconds) |

The check is client-side on purpose. A PDS only validates lexicons it can
resolve, and it cannot resolve third-party NSIDs, so writes come back
`validationStatus: "unknown"` — the PDS stores a malformed record and returns
200, and Rocksky's firehose consumer drops it at ingest. Without the local check,
a scrobble that never shows up on rocksky.app looks identical in the log to one
that worked. Records that fail it are skipped and logged, and during an import
counted as `failed`.

## `SpotifyTrack` (C++ struct)

**File:** `windows/runner/spotify_smtc.h`

Native struct returned by the Windows SMTC bridge.

```cpp
struct SpotifyTrack {
  std::wstring title;
  std::wstring artist;
  std::wstring album;
  std::vector<uint8_t> art;
  bool is_playing = false;
  int64_t position_ms = 0;
  int64_t duration_ms = 0;
};
```

All strings are wide (`std::wstring`) because WinRT APIs return `HSTRING` / `winrt::hstring`, which are UTF-16. The bridge converts them to UTF-8 `std::string` before sending to Dart.

`duration_ms` is `EndTime - StartTime` from the SMTC timeline, and stays `0` when
the session reports no timeline. `MediaWatcherService` maps that `0` to Dart
`null` rather than passing it through, so an absent length is never mistaken for
a zero-length track.
