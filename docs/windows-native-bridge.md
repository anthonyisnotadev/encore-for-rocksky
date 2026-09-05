# Windows Native Bridge (SMTC)

Because Flutter does not have built-in Windows SMTC APIs, the app implements a custom platform channel in C++.

## Channel name

```
encore/spotify_smtc
```

Registered in `windows/runner/flutter_window.cpp` during `FlutterWindow::OnCreate()`.
The channel is stored in `smtc_channel_` so it outlives `OnCreate` — a
`MethodChannel` stops dispatching once it is destroyed.

## Methods

### `getCurrentTrack`

**Dart caller:** `media_watcher_service.dart` (`_poll()`)

**C++ handler:** the `getCurrentTrack` branch of the method-call handler in
`flutter_window.cpp`, which calls `GetSpotifyCurrentTrack()`.

Returns a map with keys:

| Key | Type | Description |
|-----|------|-------------|
| `title` | `String` | Track title |
| `artist` | `String` | Artist name |
| `album` | `String` | Album name |
| `is_playing` | `bool` | Whether playback is active |
| `position_ms` | `int` | Current playback position in milliseconds |
| `duration_ms` | `int` | Track length from the SMTC timeline; `0` when the session reports none |
| `art` | `Uint8List` | Thumbnail JPEG/PNG bytes — **key omitted entirely** when SMTC has no thumbnail |

Returns `null` when there is **no SMTC session from any watched player** (they are
closed, or have never played anything this session). A *paused* player still has a
session, so it returns a map with `is_playing: false` — the Dart side keeps
showing the track and its artwork rather than falling back to "Nothing playing".

`duration_ms` matters beyond display: `app.rocksky.scrobble` requires a positive
`duration`, and this is the fallback when MusicBrainz enrichment produces none.
See [`realtime-scrobbling.md`](realtime-scrobbling.md).

### `controlPlayback`

**Dart caller:** `MediaWatcherService.controlPlayback(action)`

**C++ handler:** the `controlPlayback` branch of the same handler, which calls
`SpotifyControl()`.

Argument is a `String`: `"toggle"`, `"next"`, or `"previous"`.

Returns a `bool` indicating whether the SMTC command succeeded. A non-string
argument gets a `bad_args` error instead; any other method name gets
`NotImplemented`.

## C++ implementation

The actual SMTC logic lives in `windows/runner/spotify_smtc.cpp`.

### `GetSpotifyCurrentTrack()`

1. Dispatches to a background MTA thread via `std::async` because WinRT async `.get()` must not block an STA thread.
2. Calls `GlobalSystemMediaTransportControlsSessionManager::RequestAsync().get()`.
3. Iterates sessions and filters for those whose `SourceAppUserModelId` contains `"Spotify"`.
4. Reads, each in its own `try`/`catch` so one unavailable property does not lose the whole track:
   - Media properties (`Title`, `Artist`, `AlbumTitle`)
   - Playback info (`PlaybackStatus == Playing`)
   - Timeline properties — `Position` for repeat detection, and
     `EndTime - StartTime` as the track length, both converted from 100-ns ticks to ms
   - Thumbnail stream (reads up to 5 MB of image bytes)
5. Returns `std::optional<SpotifyTrack>` — the first matching session, or `std::nullopt`.

Spotify frequently reports an empty timeline on the first poll after a track
change, so `duration_ms` can be `0` for a few seconds before the real length
arrives. `MediaWatcherService` republishes the track when it does.

### `SpotifyControl(action)`

1. Same MTA-thread dispatch.
2. Finds the Spotify SMTC session.
3. Calls one of:
   - `TryTogglePlayPauseAsync()`
   - `TrySkipNextAsync()`
   - `TrySkipPreviousAsync()`

## Why MTA threading?

The Flutter platform thread is an STA (single-threaded apartment). WinRT `IAsyncOperation::get()` deadlocks on STA threads, so every SMTC call is wrapped in `std::async(std::launch::async, ...)`.

## Window sizing

`flutter_window.cpp` is also where Flutter gets a crack at window messages via
`HandleTopLevelWindowProc`. The window's own geometry rules live elsewhere:
the create-time size is hardcoded in `windows/runner/main.cpp` (400×400, square
because the aspect-ratio lock only governs drag-resizes), and the restored size,
minimum size and 1:1 lock are applied from Dart in `main.dart` and
`window_state_service.dart`.

## Data flow diagram

```
Dart: MediaWatcherService._poll()
    │
    │  MethodChannel.invokeMethod('getCurrentTrack')
    ▼
C++: flutter_window.cpp handler
    │
    ▼
C++: GetSpotifyCurrentTrack()
    │
    ▼
WinRT: GlobalSystemMediaTransportControlsSessionManager
    │
    ▼
Spotify (via Windows SMTC)
```
