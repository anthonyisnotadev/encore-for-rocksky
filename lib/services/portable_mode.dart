import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider_windows/path_provider_windows.dart';
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';
import 'package:shared_preferences_windows/shared_preferences_windows.dart';

import 'log_buffer.dart';

final _log = LogBuffer.instance;

/// Keeps saved state next to the executable so the app can be run from a USB
/// stick without leaving settings on the host machine.
///
/// An ordinary build stores preferences under
/// `%APPDATA%\<company>\<product>\shared_preferences.json`, a path
/// `path_provider_windows` derives from the version resource compiled into the
/// `.exe`. That is the right default for an installed copy and the wrong one
/// for a portable copy: the session tokens and window size stay behind on
/// whichever machine ran it last, and the app starts over on the next one.
///
/// Portable mode is opted into by the layout on disk rather than by a build
/// flag, so one binary serves both cases and a copy can be converted either way
/// by creating or deleting a folder — the same signal VS Code and the
/// PortableApps.com launchers use.
class PortableMode {
  PortableMode._();

  /// Directory beside the executable that switches portable mode on and holds
  /// the state.
  ///
  /// *Not* `Data`, which is the PortableApps.com convention: the Flutter runner
  /// already ships a `data\` directory next to the `.exe` for `app.so`,
  /// `icudtl.dat` and the asset bundle, and Windows paths are case-insensitive.
  /// A marker named `Data` would therefore always be present — portable mode
  /// could never be turned off — and settings would be written inside the asset
  /// bundle.
  static const _dataDirName = 'PortableData';

  /// Stands in for `getApplicationSupportPath()`.
  ///
  /// Kept one level below [_dataDirName], matching the PortableApps.com
  /// `Data\settings\` shape, so anything stored later — caches, exported logs —
  /// has somewhere of its own to go rather than sharing a directory with the
  /// preferences file.
  static const _settingsDirName = 'settings';

  /// Set by the single-file launcher (`tool/sfx`) to the directory the
  /// distributed `.exe` sits in.
  ///
  /// That build unpacks the application into `%TEMP%` and runs it from there,
  /// so `Platform.resolvedExecutable` points at a directory that is deleted on
  /// exit — useless for deciding where settings belong. The launcher passes the
  /// real location through the environment instead. Must match `kHostDirEnv`
  /// in `tool/sfx/sfx_stub.cpp`.
  static const _hostDirEnv = 'ENCORE_PORTABLE_HOST_DIR';

  static bool _active = false;

  /// Whether state is being read from and written beside the executable.
  static bool get isActive => _active;

  /// Redirects `shared_preferences` into [_dataDirName] when that directory is
  /// present next to the running executable.
  ///
  /// Must run before the first `SharedPreferences.getInstance()`. The Windows
  /// store reads the whole file once and caches it in memory, so a redirect
  /// applied afterwards would go on serving — and then overwrite with — the
  /// roaming profile's copy.
  static void init() {
    if (!Platform.isWindows) return;

    final settingsPath = settingsPathIn(_appDirectory());
    if (settingsPath == null) return;

    final store = SharedPreferencesStorePlatform.instance;
    if (store is! SharedPreferencesWindows) {
      // Either the plugin registrant has not run yet or shared_preferences
      // changed which implementation it registers on Windows. Bailing out keeps
      // the roaming profile rather than silently dropping every write.
      _log.log(
        'Portable layout found but the preference store is '
        '${store.runtimeType} — keeping the roaming profile',
        name: 'portable',
      );
      return;
    }

    // `pathProvider` is annotated visible-for-testing upstream. It is also the
    // only seam the Windows store exposes for relocating its file: the path is
    // resolved inside a private helper that takes this field, and the store is
    // otherwise not subclassable in a useful way. The alternative is
    // reimplementing SharedPreferencesStorePlatform, which would fork the
    // file format for no gain. Pinned by pubspec.lock; revisit on upgrade.
    // ignore: invalid_use_of_visible_for_testing_member
    store.pathProvider = _PortablePathProvider(settingsPath);
    _active = true;
    // The absolute path contains the user's account name on a fixed-disk copy,
    // so only the relative tail is logged — LogBuffer backs a copyable
    // on-screen log.
    _log.log(
      'Portable mode on — settings in $_dataDirName\\$_settingsDirName',
      name: 'portable',
    );
  }

  /// Where the app should look for [_dataDirName]: the directory the
  /// distributed executable lives in.
  ///
  /// Usually the running executable's own directory. Under the single-file
  /// launcher those differ, and only the launcher knows the real one.
  static String _appDirectory() =>
      appDirectoryFrom(Platform.environment, Platform.resolvedExecutable);

  /// [_appDirectory] with its two ambient inputs passed in, so the precedence
  /// between them can be tested without spawning a process.
  @visibleForTesting
  static String appDirectoryFrom(
    Map<String, String> environment,
    String executablePath,
  ) {
    final hostDir = environment[_hostDirEnv];
    // An empty value is treated as absent: an unset variable and one set to
    // nothing should not behave differently.
    if (hostDir != null && hostDir.isNotEmpty) return hostDir;
    return File(executablePath).parent.path;
  }

  /// The portable settings directory for an app distributed in [appDir], or
  /// null when [_dataDirName] is not there and the app should use the roaming
  /// profile.
  ///
  /// The directory is not created here; the preference store creates it, with
  /// its parents, on the first write. That keeps a read-only medium from
  /// failing at startup — it degrades to settings that do not persist, which is
  /// what a read-only stick can offer, instead of silently reverting to storage
  /// on the host.
  @visibleForTesting
  static String? settingsPathIn(String appDir) {
    final dataDir = Directory(_join(appDir, _dataDirName));
    // Returns false for a *file* of the same name, which is the wanted
    // behaviour: a stray `PortableData` file is not a portable layout.
    if (!dataDir.existsSync()) return null;
    return _join(dataDir.path, _settingsDirName);
  }

  static String _join(String a, String b) => '$a${Platform.pathSeparator}$b';
}

/// A [PathProviderWindows] pinned to the portable settings directory.
///
/// Only `getApplicationSupportPath` is overridden — it is the one method
/// `shared_preferences_windows` calls — so anything else that reaches for a
/// known folder, such as the downloads directory behind the log export, still
/// gets the real one.
class _PortablePathProvider extends PathProviderWindows {
  _PortablePathProvider(this.supportPath);

  final String supportPath;

  @override
  Future<String?> getApplicationSupportPath() async => supportPath;
}
