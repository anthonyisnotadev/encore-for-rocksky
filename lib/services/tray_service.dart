import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';
import 'log_buffer.dart';
import 'window_state_service.dart';

final _log = LogBuffer.instance;

/// Keeps the app reachable from the Windows notification area (the icons beside
/// the clock).
///
/// Both minimising and closing hide the window rather than parking it on the
/// taskbar or exiting — the tray icon becomes the way back, and "End task" in
/// its right-click menu is the only way out. The Dart isolate keeps running
/// while hidden, so `MediaWatcherService` carries on polling and scrobbles
/// still land.
class TrayService with TrayListener, WindowListener {
  static final TrayService instance = TrayService._();
  TrayService._();

  /// Resolved by tray_manager under `data/flutter_assets`, so this must match
  /// the `assets:` entry in pubspec.yaml — not the icon baked into the .exe.
  static const _iconPath = 'assets/app_icon.ico';
  static const _tooltip = 'encore for rocksky';

  static const _menuKeyShow = 'show';
  static const _menuKeyEndTask = 'end_task';

  bool _initialized = false;

  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;

    trayManager.addListener(this);
    windowManager.addListener(this);

    // Swallow the native WM_CLOSE so the X button hides to tray instead of
    // exiting. `windowManager.destroy()` still gets out — it posts WM_QUIT
    // directly rather than going through WM_CLOSE.
    await windowManager.setPreventClose(true);

    await trayManager.setIcon(_iconPath);
    // setToolTip must follow setIcon — the icon has to exist first.
    await trayManager.setToolTip(_tooltip);
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: _menuKeyShow, label: 'Show encore'),
          MenuItem.separator(),
          MenuItem(key: _menuKeyEndTask, label: 'End task'),
        ],
      ),
    );

    _log.log('Tray icon installed', name: 'tray');
  }

  /// Brings the window back from the tray.
  ///
  /// `onWindowMinimize` leaves the window both minimised *and* hidden, so the
  /// minimised state has to be cleared first or `show()` reveals a window that
  /// is still collapsed.
  Future<void> showWindow() async {
    if (await windowManager.isMinimized()) {
      await windowManager.restore();
    }
    await windowManager.show();
    await windowManager.focus();
  }

  /// Actually exits. Removes the tray icon first — Windows leaves a ghost icon
  /// in the notification area if the process dies while it is still registered.
  Future<void> _endTask() async {
    _log.log('End task from tray menu', name: 'tray');
    await WindowStateService.instance.saveNow();
    await trayManager.destroy();
    await windowManager.destroy();
  }

  // ─── WindowListener ────────────────────────────────────────────────────────

  @override
  void onWindowMinimize() {
    _log.log('Minimised to tray', name: 'tray');
    windowManager.hide();
  }

  @override
  void onWindowClose() {
    // Reached only because setPreventClose(true) stopped the real close.
    _hideToTray();
  }

  /// Saves the size before hiding — the window is still visible and unminimised
  /// here, which is the last moment its geometry can be read.
  Future<void> _hideToTray() async {
    await WindowStateService.instance.saveNow();
    _log.log('Close button — hiding to tray', name: 'tray');
    await windowManager.hide();
  }

  // ─── TrayListener ──────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    showWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case _menuKeyShow:
        showWindow();
      case _menuKeyEndTask:
        _endTask();
    }
  }
}
