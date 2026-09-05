import 'package:flutter/foundation.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../models/track_info.dart';

class NotificationService {
  static const _prefEnabled = 'notifications_enabled';

  static final NotificationService instance = NotificationService._();
  NotificationService._();

  /// Whether scrobble toasts are raised at all. Listenable so the toggle in the
  /// title bar reflects the stored preference without the screen re-reading it.
  final ValueNotifier<bool> enabled = ValueNotifier<bool>(true);

  Future<void> init() async {
    await localNotifier.setup(appName: 'encore for rocksky');
    final prefs = await SharedPreferences.getInstance();
    enabled.value = prefs.getBool(_prefEnabled) ?? true;
  }

  Future<void> setEnabled(bool value) async {
    if (enabled.value == value) return;
    enabled.value = value;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_prefEnabled, value);
  }

  void showScrobbled(TrackInfo track) {
    _show(title: 'Scrobbled', body: '${track.artist} — ${track.title}');
  }

  void showScrobbleFailed(TrackInfo track, String? error) {
    _show(
      title: 'Scrobble failed',
      body: '${track.artist} — ${track.title}'
          '${error != null ? '\n$error' : ''}',
    );
  }

  /// Every toast this app raises is a footnote to music the user is already
  /// listening to, so none of them are ever worth a sound. `silent: true` keeps
  /// the banner and the Action Center entry but drops the Windows chime.
  ///
  /// Upstream local_notifier 0.1.6 accepts `silent` and then ignores it on
  /// Windows; the flag only works because of the vendored fork wired up in
  /// `pubspec.yaml`. See `third_party/local_notifier/FORK.md`.
  void _show({required String title, required String body}) {
    if (!enabled.value) return;

    final notification = LocalNotification(
      title: title,
      body: body,
      silent: true,
    );

    // Windows raises exactly one terminal event per toast — Activated,
    // Dismissed or Failed — so at most one of these ever runs. `_release` is
    // idempotent anyway, which keeps the backstop below from double-releasing.
    notification.onClose = (_) => _release(notification);
    notification.onClick = () => _release(notification);

    _live[notification.identifier] = notification;
    while (_live.length > _maxLive) {
      _release(_live.values.first);
    }

    notification.show();
  }

  /// Toasts raised but not yet handed back to the plugin.
  ///
  /// `LocalNotification`'s constructor registers itself as a listener on the
  /// global `localNotifier`, and `notify()` files it in a global map.
  /// `localNotifier.destroy()` is the only thing that undoes either, so without
  /// this bookkeeping a tray session that scrobbles all day retains one object
  /// per track forever — and every toast callback walks the whole listener list
  /// to find its owner, so dispatch cost grows with it. `destroy()` also frees
  /// the plugin's native `toast_id_map_` entry and the COM pointer WinToast
  /// parks in `_buffer`, neither of which is released on dismissal either.
  ///
  /// Insertion-ordered, so `values.first` is always the oldest.
  final Map<String, LocalNotification> _live = {};

  /// How many toasts may be outstanding before the backstop trims the oldest.
  ///
  /// Windows dismisses a toast within seconds and this app raises at most one
  /// per scrobbled track, so real overlap never approaches this. Reaching it
  /// means terminal events are going missing — the plugin's `toastFailed`
  /// reports nothing back to Dart, and its `Dismissed` handler stays silent
  /// when `get_Reason` fails — and the cap is what stops a dropped callback
  /// from quietly restoring the unbounded growth.
  static const _maxLive = 32;

  /// Hands a toast back to the plugin.
  ///
  /// Safe to call twice: the first call takes it out of [_live] synchronously,
  /// so a second one returns before touching the plugin again.
  void _release(LocalNotification notification) {
    if (_live.remove(notification.identifier) == null) return;
    notification.destroy();
  }
}
