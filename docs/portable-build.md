# Portable builds

The app can run from a USB stick, a network share or an unpacked download
without an installer and without leaving its settings on the host machine.
There are two scripts, producing two shapes of the same thing.

| | Script | Output |
|---|---|---|
| **Folder** | `tool\build_portable.ps1` | `build\portable\encore-for-rocksky-portable-<version>\` and a zip of it |
| **Single file** | `tool\build_single_exe.ps1` | `build\portable\encore-for-rocksky.exe` |

```
pwsh -File tool\build_portable.ps1
pwsh -File tool\build_single_exe.ps1
```

Both take `-SkipBuild` to pack the existing Release output instead of
rebuilding. `build_portable.ps1` takes `-NoZip`; `build_single_exe.ps1` takes
`-OutputName` to change the filename and `-KeepIntermediates` to leave
`build\sfx\` in place for inspection.

Pick the folder when the app is going to live somewhere — a stick it will be run
from repeatedly, or an unpacked install. Pick the single file when it is being
handed to someone: one file to send, one to double-click, nothing to unpack.

## What "portable" means here, and what it doesn't

Two different properties get called portability, and this build has one of them
for free and the other by design.

**No installer.** Flutter's Windows release output already has this. Nothing is
written to `Program Files`, no registry keys, no uninstaller. It is not,
however, a single file: `encore_for_rocksky.exe` is a small Win32 host stub
that loads `flutter_windows.dll` — the engine — and resolves `data\app.so`,
`data\icudtl.dat` and `data\flutter_assets\` relative to its own location. Each
plugin ships its own DLL alongside. The whole directory has to travel together;
copying the `.exe` out of it produces a binary that will not start.

**Settings travel with the app.** This is what the packaging script and
`lib/services/portable_mode.dart` add. An ordinary build stores preferences at

```
%APPDATA%\encore for rocksky contributors\encore for rocksky\shared_preferences.json
```

a path `path_provider_windows` derives from the version resource compiled into
the `.exe` by `windows/runner/Runner.rc`. For an installed copy that is correct.
For a portable copy it is not: the session tokens and window size stay on
whichever machine ran it last, and the app starts over on the next one.

## How the switch works

Portable mode is selected by the layout on disk, not by a build flag — the same
binary serves both cases, and a copy can be converted either way by creating or
deleting one folder. VS Code and the PortableApps.com launchers use the same
signal.

If a directory named `PortableData` sits next to the executable, `PortableMode
.init()` swaps the preference store's path provider for one whose
`getApplicationSupportPath()` returns `PortableData\settings`:

```
encore-for-rocksky-portable-1.0.0\
  encore_for_rocksky.exe
  flutter_windows.dll
  ...plugin DLLs...
  data\                       <- Flutter's asset bundle, shipped by the build
  PortableData\               <- the marker; added by the packaging script
    README.txt
    settings\
      shared_preferences.json <- written on first save
```

### Why not `Data\`

`Data\` is the PortableApps.com convention, and it cannot be used here. Flutter
already ships a `data\` directory next to the executable, and Windows paths are
case-insensitive, so `Data` and `data` are the same directory. A marker with
that name would always exist — portable mode could never be off — and settings
would be written inside the asset bundle. `test/portable_mode_test.dart` has a
regression test for exactly this.

### Ordering

`PortableMode.init()` runs immediately after `WidgetsFlutterBinding
.ensureInitialized()` and before anything that touches `SharedPreferences`. The
Windows store reads the whole file once and caches it in memory, so a redirect
applied later would go on serving — and then overwrite with — the roaming
profile's copy.

### The seam it uses

`shared_preferences_windows` resolves its file inside a private helper that
takes the store's `pathProvider` field. That field is annotated
`@visibleForTesting` upstream, and it is the only way to relocate the file short
of reimplementing `SharedPreferencesStorePlatform` and forking the file format.
The version is pinned by `pubspec.lock`; the assignment is worth re-checking on
a `shared_preferences` upgrade. `PortableMode.init()` bails out and keeps the
roaming profile if the registered store is not a `SharedPreferencesWindows`,
rather than silently dropping every write.

### Read-only media

The settings directory is not created at startup, only on the first write, by
the preference store. On a write-protected stick the app therefore runs with
settings that do not persist, instead of failing at launch or quietly reverting
to storage on the host.

## The single-file build

`tool\build_single_exe.ps1` wraps the whole Release directory in one executable
that can be handed out on its own. The pieces live in `tool\sfx\`.

Packaging compresses the Release tree into a cabinet with `makecab` and links it
into the launcher from `tool\sfx\sfx_stub.cpp` as an `RCDATA` resource. Running
the result:

1. unpacks the cabinet into `%TEMP%\efr-<pid>-<ticks>\`,
2. sets `ENCORE_PORTABLE_HOST_DIR` to the directory the `.exe` itself is in,
3. starts the unpacked `encore_for_rocksky.exe` and waits,
4. deletes the unpacked copy when the app exits.

Unpacking 9.8 MB costs about 1.7 seconds between the double-click and a window,
and happens on every launch — nothing is cached between runs, which is what
makes "leaves nothing behind" true.

### Why a cabinet, and why a native stub

Windows ships both halves of the cabinet: `makecab.exe` packs with LZX, and
`setupapi.dll`'s `SetupIterateCabinet` unpacks with the directory structure
intact. No compression library is bundled and no helper process is spawned, so
there is no console window to suppress. LZX takes the 28.8 MB payload to
9.8 MB, close to what zip manages.

The stub is C++ because the toolchain it needs — MSVC — is the same one
`flutter build windows` already requires, so the single-file build adds no build
dependency at all. A C# launcher would be shorter but would require .NET on
every machine the file is handed to. The C runtime is statically linked
(`/MT`), so no Visual C++ redistributable is needed either.

### Where settings go

`PortableMode` normally looks for `PortableData\` next to
`Platform.resolvedExecutable`. Under this build that directory is inside
`%TEMP%` and is about to be deleted, so the answer would always be wrong. The
launcher passes the real location in `ENCORE_PORTABLE_HOST_DIR` and
`PortableMode.appDirectoryFrom` prefers it.

The behaviour that follows is the same as for the folder build, and the choice
stays with whoever runs it:

- **`rockstar.exe` on its own** — settings go to `%APPDATA%`, like any installed
  app. This is what someone who was just sent the file gets.
- **`rockstar.exe` next to a `PortableData\` folder** — settings go in there.
  Creating that empty folder is the whole opt-in.

### Orphaned extractions

The stub holds `.lock` open in its extraction directory with no sharing, for as
long as it runs. On startup it looks at every other `efr-*` directory under
`%TEMP%` and deletes the ones whose `.lock` it can open — which is exactly the
ones no live instance is using. That way a run ended by a crash, or by killing
the process from Task Manager, is cleaned up by the next one instead of leaking
29 MB, and a second copy running at the same time is never touched.

### Costs of this shape

- **SmartScreen.** The file is unsigned and self-extracting, which is the shape
  malware droppers have. Expect a warning on first download until it builds
  reputation, and expect some antivirus products to want a look.
- **Two processes.** The launcher waits for the app for the whole session, so
  Task Manager shows both. That wait is what makes cleanup possible.
- **A stale toast shortcut.** The Start Menu shortcut described below is created
  pointing at the temporary copy, so its target is gone once the app exits.
  Toasts still work — Windows matches on the identifier in the shortcut, not on
  its target — but the Start Menu entry will not launch anything. The folder
  build does not have this problem.

## What a portable run still leaves behind

One thing, and it is not avoidable while toasts work. Windows requires a
desktop app to own a Start Menu shortcut carrying its Application User Model ID
before it may raise toast notifications; `local_notifier` is configured with
`ShortcutPolicy.requireCreate`, so WinToast creates one the first time
`NotificationService.init()` runs:

```
%APPDATA%\Microsoft\Windows\Start Menu\Programs\encore for rocksky.lnk
```

It is created once, points at whatever path the app ran from, and holds no user
data. Deleting it costs only the toasts on the next run. Setting the policy to
`ignore` would suppress the shortcut but is not the default, because on Windows
10 it also suppresses the notifications.

Beyond that a run touches nothing on the host: no registry writes, no
`Program Files`, and — with `PortableData\` present — no `%APPDATA%` state of
its own.

## Distribution notes

The packaging script writes a `README.txt` into `PortableData\` as well as the
one at the root. That is not only documentation: `Compress-Archive` and many
extractors drop empty directories, so an empty `PortableData\` would vanish from
the zip and portable mode would silently switch itself off for everyone who
downloaded it — the app would run, look correct, and write to `%APPDATA%`.

`PortableData\settings\shared_preferences.json` holds the Bluesky session, but
not in the clear: it is encrypted with the Windows Data Protection API, whose
key belongs to the Windows account that saved it. Two consequences, and the
README in that folder states both.

The good one: a stick that goes missing does not hand over a credential that can
delete the owner's scrobble history. The awkward one: the session does **not**
travel. Settings follow the folder, but the same stick in a different PC — or a
different Windows account on the same PC — cannot decrypt them and asks for a
fresh sign-in. Window size and the notification toggle are unaffected, since
those are stored in the clear.

Making the session travel would mean a key that travels with it, which means a
passphrase typed at every launch. See
[`authentication.md`](authentication.md#what-dpapi-does-and-does-not-protect-against).

The script builds without `--dart-define=ENABLE_SPOTIFY_IMPORT=true`. The
experimental import can irreversibly delete records from a user's PDS and must
not ship in a distributable build — see [`spotify-import.md`](spotify-import.md).
