# Real-Time Scrobbling Pipeline

This is the app's core feature: detecting what any supported player is playing and writing the scrobble straight to the user's Bluesky PDS.

## Flow

```
Windows SMTC
     │
     ▼
spotify_smtc.cpp (C++ method channel)
     │
     ▼
media_watcher_service.dart  ──polls every 5s──►  trackNotifier
     │                                              │
     │                                              ▼
     │                                    home_screen.dart _onTrackChanged()
     │                                              │
     │                    ┌────────────────────────┘
     │                    │
     │                    ▼
     │            iTunes cover-art fetch (fallback)
     │                    │
     │                    ▼
     │           30-second countdown timer
     │                    │
     │                    ▼
     │        MusicBrainz enrichment (pds_service.dart)
     │                    │
     │                    ▼
     │        required-field check (title / artist / album /
     │        albumArtist / duration) — skipped if incomplete
     │                    │
     │                    ▼
     │              pds_service.dart
     │         com.atproto.repo.createRecord
     │                    │
     │                    ▼
     │     app.rocksky.scrobble record on the user's PDS
     │
     ▼
  Desktop toast (success / failure, when toasts are enabled)
```

## 1. Windows SMTC polling

`MediaWatcherService` polls the native platform channel every **5 seconds**:

```dart
Timer.periodic(const Duration(seconds: 5), (_) => _poll());
```

`start()` also polls once immediately, so signing in does not cost a 5-second
wait before the mini-player fills in.

The C++ side enumerates all SMTC sessions and picks the one to watch: sessions from
the known-player list in `kWatchedApps` (Spotify, Apple Music, Tidal, Deezer, VLC, and
so on — browsers playing video are deliberately excluded), preferring a session that
is actually playing when several qualify. It returns:

- `title`
- `artist`
- `album`
- `is_playing`
- `position_ms` (used for repeat detection)
- `duration_ms` (track length; `0` when SMTC reports no timeline)
- `art` (thumbnail image bytes, if available)

`_poll` maps a `duration_ms` of `0` to Dart `null` rather than passing it
through. See `windows/runner/spotify_smtc.cpp` for the WinRT implementation and
[`windows-native-bridge.md`](windows-native-bridge.md) for the channel contract.

## 2. Track change detection

`MediaWatcherService` uses `TrackInfo.isSameTrack()` — equality based on `title + artist` only — to decide whether a new track started:

```dart
if (!track.isSameTrack(current)) {
  trackNotifier.value = track;   // New track
} else {
  // Same track — republish only if art, playback state, or a late-arriving
  // track length changed. Anything else would reset the scrobble timer.
}
```

That "late-arriving track length" case is not hypothetical: Spotify often
reports an empty SMTC timeline on the first poll after a track change, so
`durationMs` shows up several seconds in. The scrobble fires 30 s in and needs
it, so the watcher republishes when it arrives and `HomeScreen` updates
`_currentTrack` in place without restarting the countdown.

## 3. Repeat / loop detection

If the same track is still playing but the playback position suddenly jumps backward (was past 15 s, now under 5 s), the service fires `onRepeatDetected`:

```dart
if (_lastPositionMs > 15000 && positionMs < 5000) {
  onRepeatDetected?.call();
}
```

`HomeScreen` handles this by cancelling the old scrobble timer and starting a fresh 30-second countdown, so loops count as separate plays.

Because the trigger is a backward *jump* in position, a manual scrub back to the
start of the song is indistinguishable from a repeat and also re-arms the timer.

## 4. The 30-second rule

When a new track is detected, `HomeScreen`:

1. Cancels any existing scrobble timer.
2. Starts a **1-second countdown UI timer** (`_countdownTimer`) to show `30s → 0s`.
3. Starts a **30-second scrobble timer** (`_scrobbleTimer`).

When the 30-second timer fires:

```dart
if (_currentTrack?.isSameTrack(next) == true &&
    !_scrobbled &&
    _canWriteScrobble) {
  _countdownTimer?.cancel();
  // Prefer `_currentTrack`: same song, but it may have picked up a track
  // length that SMTC did not report at detection time.
  await _scrobbleWithRetry(_currentTrack ?? next, start, retries: 3);
}
```

The track must still be the same one (the user didn't skip early), must not have
been scrobbled already, and there must still be a signed-in PDS session.

This is a **wall-clock** timer, not accumulated playback time: pausing for 30
seconds and resuming still scrobbles, since a pause does not change the track's
identity. The `createdAt` written into the record is the moment the track was
*detected*, not the moment the write happened.

## 5. Enrichment and the required-field check

Before writing, `PdsService.writeScrobble` looks the track up in MusicBrainz
through its own `MusicBrainzEnrichmentService`. The live path owns that lookup
rather than taking metadata from the caller, so no caller can accidentally
produce a metadata-poor record.

`duration` is then resolved as `musicBrainzDuration ?? smtcDurationMs`, and the
record is checked locally against the fields `app.rocksky.scrobble` marks
required — `title`, `artist`, `album`, `albumArtist`, and a `duration` of at
least 1 ms. **A record missing any of them is never sent**; the attempt is
logged and reported as a failure.

The check exists because a PDS cannot resolve a third-party NSID, so it accepts
malformed records with `validationStatus: "unknown"` and returns 200 — and
Rocksky's firehose consumer then drops them at ingest. Without the local check,
a scrobble that never appears on rocksky.app is indistinguishable in the log
from one that worked. The log line records where the duration came from
(`musicbrainz=…, smtc=…`) so a regression in either source stays visible.

Note the consequence: a Spotify session reporting no SMTC timeline **and** a
track MusicBrainz cannot match will not scrobble. That is intentional — the
alternative is baking a wrong duration into a permanent record.

## 6. Retry logic

`_scrobbleWithRetry` attempts up to 3 times, with a backoff of 5 s then 10 s:

```dart
for (var attempt = 1; attempt <= retries; attempt++) {
  if (!mounted || _scrobbled) return;
  if (_currentTrack?.isSameTrack(track) != true) return;  // user skipped
  // Re-read each attempt — the user may sign out mid-retry.
  final pds = _pdsService;
  if (pds == null) return;

  final success = await pds.writeScrobble(track, start);
  if (success) {
    // Add to in-app history (last 10), show toast
    return;
  }
  await Future.delayed(Duration(seconds: 5 * attempt));
}
```

Retries abandon early if the user skips the track or signs out. If all three
fail, a desktop toast reports it and the error stays on screen under the status
chip.

Note that a record rejected by the required-field check consumes retries the
same way a network failure does — it will fail identically all three times.

The in-app history is memory-only: the last 10 scrobbles, cleared on sign-out
and lost on exit. It is a confirmation display, not a record — the records live
on the PDS.

## 7. Cover art fallback

If SMTC does not provide album art, `HomeScreen` fetches from the iTunes Search API:

```dart
http.get(Uri.parse(
  'https://itunes.apple.com/search?term=$query&media=music&entity=song&limit=1'))
```

It grabs `artworkUrl100`, upgrades it to `600x600bb`, and loads the image bytes.
If SMTC art arrives first, or the user has moved on to another track by the time
it returns, the iTunes result is dropped.

This is display-only. The `albumArtUrl` written into the record comes from
MusicBrainz / Cover Art Archive during enrichment, never from iTunes.

## 8. Notifications

Each outcome raises one desktop toast — "Scrobbled" or "Scrobble failed" —
unless the user has turned them off with the bell button in the top bar
(persisted as `notifications_enabled`).

Toasts are raised `silent: true`: the banner and the Action Center entry appear,
but Windows plays no chime. That flag only works because of the vendored
`local_notifier` fork; upstream 0.1.6 accepts it and then ignores it on Windows.
See [`third_party/local_notifier/FORK.md`](../third_party/local_notifier/FORK.md).

`NotificationService` hands each toast back to the plugin with `destroy()` when
Windows reports it dismissed or clicked, and caps outstanding toasts at 32.
Without that bookkeeping, a tray session scrobbling all day retains one object
per track forever, and every toast callback walks the whole listener list.

## 9. Running in the tray

Both minimising and closing hide the window rather than exiting; the tray icon
is the way back, and its "End task" menu item is the only way out. The Dart
isolate keeps running while hidden, so polling continues and scrobbles still
land with no window on screen. See `tray_service.dart`.

## 10. Watcher lifecycle across sign-out

`MediaWatcherService.stop()` clears `trackNotifier` as well as cancelling the
timer:

```dart
void stop() {
  _timer?.cancel();
  _timer = null;
  _lastPositionMs = 0;
  trackNotifier.value = null;
}
```

This matters because `_poll()` only pushes a value when the track *changes*. If
the notifier kept the last track across a sign-out, the first poll after signing
back in would see "same track, nothing new" and stay silent — leaving the UI
stuck on **Nothing playing** until the user manually skipped to another song.
Clearing on stop makes the next `start()` treat the current song as new.

`HomeScreen` removes its listener *before* calling `stop()`, so the clearing
write does not fire `_onTrackChanged` during teardown.
