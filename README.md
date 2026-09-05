# encore for rocksky

An independent, unofficial Windows app that watches your music playback and scrobbles
your plays to [Rocksky](https://rocksky.app), a music scrobbling service built on the
AT Protocol / Bluesky ecosystem.

> **Not an official app.** encore for rocksky is a third-party project. It is not made
> by, endorsed by, or affiliated with Bluesky, Bluesky Social PBC, or Rocksky. The
> Bluesky and Rocksky names are used only to describe the services this app connects to.

## What it does

- **Real-time scrobbling** — watches the Windows System Media Transport Controls (SMTC),
  the native media plumbing behind the volume flyout and media keys, to detect what any
  supported player is playing, then writes the scrobble 30 seconds in.
- **Metadata enrichment** — looks each track up in MusicBrainz for its length,
  MusicBrainz IDs, release date and cover art before writing.
- **Lives in the tray** — minimising or closing hides the window to the notification
  area and keeps scrobbling; "End task" in the tray menu is how you actually quit.
- **Silent toasts** — one notification per scrobble, no chime, and a bell button to
  turn them off.

Scrobbles are written **only** to your own Bluesky PDS, as `app.rocksky.scrobble`
records created with a Bluesky app password. The app does not submit anything to the
Rocksky API. Your app password is exchanged once for a session and is never stored —
only the resulting session tokens are kept on disk, encrypted with the Windows Data
Protection API so a copy of the settings file is of no use on another machine or
account. See [`docs/authentication.md`](docs/authentication.md) for what that does
and does not protect against.

## Supported players

Any player that plugs into Windows' native media controls (SMTC — the same
plumbing behind the volume flyout and your media keys) can be watched. In
practice the app matches a list of known players, so that video in a browser
does not end up scrobbled as music:

Spotify, Apple Music, iTunes, Amazon Music, Deezer, Tidal, Qobuz, YouTube
Music desktop clients, VLC, foobar2000, MusicBee, Winamp, MediaMonkey, AIMP,
Dopamine, Cider, Groove Music, and the Windows 11 Media Player.

If several are running at once, the one actually playing wins. A player not on
the list is invisible to the app — open an issue naming it, or add its Windows
app ID to `kWatchedApps` in [`windows/runner/spotify_smtc.cpp`](windows/runner/spotify_smtc.cpp);
that array is the whole list, so adding a player is a one-line change.

Players are matched by the app identity they register with Windows, which is
why playback in a browser tab is invisible even for services on the list: the
session belongs to the browser, and browsers report video and music alike.
The IDs in the list are the standard ones each app registers, but not every
player has been verified against the app — if yours is playing and nothing is
detected, that is a bug worth reporting.

## Requirements

- Windows 10 or 11. Mica needs a recent Windows 11 build; older versions fall back to
  an opaque background.
- A desktop music player from the list above. Playback in a browser tab is not seen,
  because browsers report video and audio alike and cannot be told apart.
- The Flutter SDK, on a channel providing Dart `^3.11.0`.
- A Bluesky account and an app password, created in Bluesky's settings.

## Getting started

```
flutter pub get
flutter run -d windows
```

Run the tests with:

```
flutter test
```

See [`docs/overview.md`](docs/overview.md) for architecture and feature documentation,
and [`CHANGELOG.md`](CHANGELOG.md) for release notes.

### Portable builds

Flutter's Windows output is a directory, not a single file: the `.exe` is a host
stub that loads `flutter_windows.dll` and reads `data\` beside itself. Two
scripts turn it into something distributable.

```
pwsh -File tool\build_portable.ps1
```

A folder, plus a zip of it, that runs from a USB stick with no installer. The
packaging step puts a `PortableData\` directory next to the executable, so
settings live there rather than in `%APPDATA%` and travel with the folder
instead of staying on the host machine. The saved session is the exception: it
is encrypted to the Windows account that created it, so a stick moved to another
PC keeps its settings but asks for a fresh sign-in — which is also what you want
from a stick that goes missing.

```
pwsh -File tool\build_single_exe.ps1
```

One self-contained `.exe` to hand out. It unpacks into `%TEMP%`, runs the app,
and deletes the unpacked copy on exit; put a `PortableData\` folder next to it
to keep settings beside it as well. Needs the same Visual Studio C++ toolchain
that `flutter build windows` already requires.

See [`docs/portable-build.md`](docs/portable-build.md) for how the switch works,
what each shape costs, and the one thing a portable run does still leave on the
host.

### Releases

Pushing a tag (`git tag v1.0.0 && git push origin v1.0.0`) makes CI build the
portable zip and the single exe, and publish both to a GitHub Release using the
matching section of [`CHANGELOG.md`](CHANGELOG.md) as the notes. The single exe
is the download for people who want double-click-and-use with no install.

### Experimental features

Spotify extended-history import is **not built into default builds**. It can
write and, if you opt in, irreversibly delete `app.rocksky.scrobble` records on
your PDS, and it is not covered by tests. Enable it only if you understand
that:

```
flutter run -d windows --dart-define=ENABLE_SPOTIFY_IMPORT=true
```

Bug reports against it should say the flag was on. See
[`docs/spotify-import.md`](docs/spotify-import.md).

## Troubleshooting

The bug icon in the top bar opens a debug log with a Copy button — that log is the
right thing to attach to a bug report. It redacts your DID and any session tokens
before display, so it is safe to paste.

Two failure modes are worth knowing about:

- **Nothing playing, but your player is playing.** The app only matches SMTC
  sessions from the known-player list above, so browser playback and players
  not on the list are invisible to it.
- **The countdown finishes but nothing is scrobbled.** `app.rocksky.scrobble` requires
  a positive `duration`, and a record without one would be accepted by your PDS and
  then silently dropped by Rocksky. The app checks locally instead and skips the
  write, logging why. This happens when SMTC reports no track length *and* MusicBrainz
  has no match for the track.

## License

Licensed under the [GNU Affero General Public License v3.0 or later](LICENSE).

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, either version 3 of the License, or (at your option) any
later version. It is distributed WITHOUT ANY WARRANTY; without even the implied
warranty of MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.

The app icon is from [OpenMoji](https://openmoji.org) and is licensed
[CC BY-SA 4.0](https://creativecommons.org/licenses/by-sa/4.0/), separately from
the code. Bundled and vendored third-party components keep their own licenses —
see [`CREDITS.md`](CREDITS.md) for the full list.
