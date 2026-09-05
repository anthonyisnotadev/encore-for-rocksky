import 'package:flutter/widgets.dart' show Size;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';
import 'log_buffer.dart';

final _log = LogBuffer.instance;

/// Remembers the window size across restarts.
///
/// The runner always creates the window at the size hardcoded in
/// `windows/runner/main.cpp`; this restores the user's last size over the top
/// of it before the window is ever shown.
///
/// The window is locked to 1:1 by `windowManager.setAspectRatio` in main.dart,
/// so a single side length describes it completely.
class WindowStateService with WindowListener {
  static final WindowStateService instance = WindowStateService._();
  WindowStateService._();

  static const _prefSide = 'window_side';

  /// Written by builds from before the window was square. Read once so an
  /// upgrade keeps roughly the size the user had, then discarded.
  static const _legacyPrefWidth = 'window_width';
  static const _legacyPrefHeight = 'window_height';

  /// Must match `windowManager.setMinimumSize` in main.dart. A stored side
  /// below the floor means the prefs were written by an older build or hand
  /// edited — treat it as corrupt rather than restoring an unusable window.
  ///
  /// The floor is square because the aspect-ratio lock rewrites the window rect
  /// in WM_SIZING, *after* Windows has clamped the drag to the minimum track
  /// size and with no re-clamp afterwards. Against a taller-than-wide floor, a
  /// horizontal drag would square the window down past the vertical floor.
  static const minSide = 340.0;

  /// Backstop against absurd stored values — a size larger than any real
  /// display, or the sentinel coordinates Windows reports for a minimised
  /// window.
  static const _maxDimension = 10000.0;

  /// Restores the saved size.
  ///
  /// Call after `windowManager.ensureInitialized()`, `setAspectRatio` and
  /// `setMinimumSize`, but before `runApp()`. The runner creates the window
  /// hidden and only shows it from `SetNextFrameCallback` on the first Flutter
  /// frame, so resizing at this point happens off-screen — no visible flash at
  /// the default size.
  Future<void> restore() async {
    final prefs = await SharedPreferences.getInstance();
    final side = prefs.getDouble(_prefSide) ?? await _migrateLegacySide(prefs);

    if (side == null) {
      _log.log('No saved window size — using the runner default', name: 'window');
      return;
    }

    if (!_isSane(side)) {
      _log.log(
        'Ignoring out-of-range saved window size $side',
        name: 'window',
      );
      await prefs.remove(_prefSide);
      return;
    }

    // setSize() resizes through SetWindowPos, which never raises WM_SIZING —
    // the native aspect-ratio lock does not see it. Passing a square is what
    // keeps the restored window square.
    await windowManager.setSize(Size(side, side));
    _log.log('Restored window size ${side.round()}x${side.round()}', name: 'window');
  }

  /// Starts persisting size changes. Safe to call once, after [restore].
  void startTracking() => windowManager.addListener(this);

  /// Persists the current size immediately.
  ///
  /// [onWindowResized] only fires for drag-resizes (WM_EXITSIZEMOVE); any
  /// programmatic resize goes through WM_SIZE and emits nothing. Calling this
  /// on the way out — while the window is still visible — catches those cases.
  Future<void> saveNow() => _save();

  /// Folds a size saved before the 1:1 lock down to one side length. The larger
  /// dimension wins so the window never reopens smaller than it was left.
  Future<double?> _migrateLegacySide(SharedPreferences prefs) async {
    final width = prefs.getDouble(_legacyPrefWidth);
    final height = prefs.getDouble(_legacyPrefHeight);
    await prefs.remove(_legacyPrefWidth);
    await prefs.remove(_legacyPrefHeight);
    if (width == null || height == null) return null;

    final side = width > height ? width : height;
    _log.log(
      'Migrated saved window size ${width.round()}x${height.round()} to a '
      '${side.round()}px square',
      name: 'window',
    );
    return side;
  }

  static bool _isSane(double side) =>
      side >= minSide && side <= _maxDimension;

  Future<void> _save() async {
    // Skip states whose reported geometry isn't the size we want to reopen at:
    // a minimised window reports sentinel coordinates, a hidden one (sitting in
    // the tray) is mid-teardown, and a maximised one wouldn't be square anyway.
    if (await windowManager.isMinimized()) return;
    if (await windowManager.isMaximized()) return;
    if (!await windowManager.isVisible()) return;

    final size = await windowManager.getSize();
    // Under the aspect-ratio lock height always tracks width, so width alone is
    // the side length.
    final side = size.width;
    if (!_isSane(side)) return;

    final prefs = await SharedPreferences.getInstance();
    await prefs.setDouble(_prefSide, side);
    _log.log('Saved window size ${side.round()}x${side.round()}', name: 'window');
  }

  // ─── WindowListener ────────────────────────────────────────────────────────

  @override
  void onWindowResized() {
    // Fires from WM_EXITSIZEMOVE — once, when the drag ends — so this needs no
    // debouncing. (`onWindowResize` is the continuous one, fired per WM_SIZING.)
    _save();
  }
}
