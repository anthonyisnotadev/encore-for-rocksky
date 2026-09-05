# Vendored fork of `local_notifier` 0.1.6

Upstream: https://github.com/leanflutter/local_notifier (pub.dev `local_notifier` 0.1.6)

Wired in through `dependency_overrides` in the app's `pubspec.yaml`.

## Why the fork

`LocalNotification` accepts a `silent` flag and `toJson()` puts it on the wire,
but the Windows plugin never reads it: `Notify()` in
`windows/local_notifier_plugin.cpp` pulled only `identifier`, `title`, `body`
and `actions`, then called `showToast()` without ever touching the template's
audio option. `silent: true` therefore compiled, looked correct, and still
played the default Windows notification sound.

## Patch 1 — the `silent` flag is ignored on Windows

`windows/local_notifier_plugin.cpp`, in `Notify()`: read `silent` from the
method-call arguments and call

```cpp
toast.setAudioOption(silent ? WinToastTemplate::AudioOption::Silent
                            : WinToastTemplate::AudioOption::Default);
```

WinToast turns `AudioOption::Silent` into `<audio silent="true"/>` in the toast
XML, which is Windows' own "show the banner, play no sound" switch. The banner
still appears and still lands in Action Center.

The lookup is tolerant of a missing or non-bool `silent` key, so the plugin
keeps working against any Dart caller that omits it.

## Patch 2 — dispatching to a released notification throws

`lib/src/local_notifier.dart`, in `_methodCallHandler()`: return early when the
incoming `notificationId` is not in `_notifications`.

Upstream looks the id up into a nullable local and then dereferences it as
`localNotification!` in all four dispatch branches. That lookup misses whenever
a callback arrives for a notification that is no longer registered, and the `!`
turns the miss into a thrown exception inside the method-call handler.

This is not an exotic state: `destroy()` is the only thing that ever releases a
notification (it is what calls `removeListener()` and `_notifications.remove()`),
so any caller that avoids leaking must call it — and from that moment a late or
repeated terminal event for that id throws. The app hits this deliberately:
`NotificationService` caps how many toasts it keeps outstanding, and trimming a
toast that Windows has not finished with produces exactly this callback.

There is nothing to dispatch when the lookup misses, so the guard drops the
callback rather than raising. The `!` in the branches below it is then
unreachable-safe and left untouched to keep the diff small.

## Patch 3 — stale notification shortcut hides the app icon

On Windows, WinToast assigns the process an AppUserModelID and backs it with a
Start Menu shortcut. Upstream validates only the shortcut's AppUserModelID, so
moving or renaming a development checkout leaves the shortcut pointing at the
old executable. Windows then groups the running window through that broken
shortcut and shows a generic taskbar icon even though the current executable
contains the correct icon.

`windows/wintoastlib.cpp` now also validates the shortcut target. When stale,
it updates the executable, working directory, and explicit icon location. New
shortcuts receive the same corrected working directory and explicit icon.

## Not changed

The Linux and macOS plugin sources are unmodified upstream copies, kept only so
the package's declared platforms stay honest. The upstream `example/` and
`screenshots/` directories are not vendored.

All three patches are defensive fixes to upstream bugs, not features. The toast
lifecycle itself is managed by the app in `lib/services/notification_service.dart`,
deliberately kept out of this fork.
