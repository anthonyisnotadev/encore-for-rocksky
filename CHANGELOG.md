# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [1.0.0] - 2026-09-03

### Added

- Real-time scrobbling to Rocksky from Spotify, Apple Music, iTunes, Amazon
  Music, Deezer, Tidal, Qobuz, YouTube Music desktop clients, VLC, foobar2000,
  MusicBee, Winamp, MediaMonkey, AIMP, Dopamine, Cider, Groove Music, and the
  Windows 11 Media Player — any watched player that integrates with the
  Windows System Media Transport Controls (SMTC). The scrobble is written 30
  seconds into each track, and when several watched players are running, the
  one actually playing is scrobbled.
- Metadata enrichment through MusicBrainz: track length, MusicBrainz IDs,
  release date and cover art.
- Sign-in with a Bluesky app password; scrobbles are written only to your own
  PDS as `app.rocksky.scrobble` records. The app password is never stored —
  session tokens are encrypted at rest with the Windows Data Protection API.
- Tray-resident operation: minimising or closing hides the window and keeps
  scrobbling; "End task" in the tray menu quits.
- Silent scrobble toasts with a bell button to disable notifications.
- Portable and single-exe build shapes via `tool\build_portable.ps1` and
  `tool\build_single_exe.ps1`.
- Optional, experimental Spotify extended-history import behind the
  `ENABLE_SPOTIFY_IMPORT=true` dart-define (not built into default builds).

### Fixed

- Paused players can no longer leak into the scrobble stream. A scrobble
  now requires 30 seconds of actual playback: a track detected while
  every watched player is paused is not written, pausing mid-track
  cancels the pending scrobble, and resuming re-arms it. Previously,
  switching between players (or a player's session dropping out) could
  re-detect another player's paused track and scrobble it again.
- A revoked or expired Bluesky session no longer fails every scrobble in
  silence. The saved session is checked against the PDS on launch, and if it
  is rejected there or on any later refresh, the app signs out and explains
  why: a dialog offers a button that opens
  <https://bsky.app/settings/app-passwords> in the default browser, after
  which the app waits at the sign-in form for a new app password. Network
  failures are not treated as revocations — the session is kept and retried.
