import 'dart:ffi';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

import 'log_buffer.dart';

final _log = LogBuffer.instance;

/// Opens [url] in the user's default browser. Returns whether Windows
/// dispatched it.
///
/// `ShellExecuteW` is the same resolution path Explorer uses, so the URL is
/// handed to whatever the user's default-browser setting points at. The
/// `url_launcher` package would do the same through the identical API and is
/// deliberately not pulled in for this one call.
///
/// Failure is logged, not fatal: the dialog that sent the user here still
/// names the settings page, so it can be reached by hand.
bool openInBrowser(String url) {
  return using((Arena arena) {
    final operation = 'open'.toNativeUtf16(allocator: arena);
    final target = url.toNativeUtf16(allocator: arena);
    // A NULL parent means no owner window: the browser must not die with this
    // app, which keeps scrobbling from the tray after its window is gone.
    final result = ShellExecute(
      NULL,
      operation,
      target,
      nullptr,
      nullptr,
      SW_SHOWNORMAL,
    );
    // ShellExecuteW returns an instance handle above 32 on success; at or
    // below 32 is a documented error code (2 = file not found, and so on).
    final ok = result > 32;
    if (!ok) {
      _log.log(
        'Could not open $url in a browser (ShellExecuteW → $result)',
        name: 'shell',
      );
    }
    return ok;
  });
}
