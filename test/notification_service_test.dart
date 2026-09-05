import 'package:encore_for_rocksky/models/track_info.dart';
import 'package:encore_for_rocksky/services/notification_service.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:local_notifier/local_notifier.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Covers the toast lifecycle in [NotificationService]: every notification it
/// raises registers itself as a listener on the global `localNotifier` and is
/// filed in a global map, and only `destroy()` undoes either. These assert the
/// service hands each toast back, so a long tray session does not accumulate
/// one retained object per scrobbled track.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('local_notifier');
  final codec = const StandardMethodCodec();
  late List<MethodCall> calls;

  /// Identifiers passed to `notify`, oldest first.
  List<String> notified() => calls
      .where((c) => c.method == 'notify')
      .map((c) => (c.arguments as Map)['identifier'] as String)
      .toList();

  /// Identifiers the service asked the plugin to close.
  List<String> closed() => calls
      .where((c) => c.method == 'close')
      .map((c) => (c.arguments as Map)['identifier'] as String)
      .toList();

  /// Delivers a platform -> Dart callback the way the Windows plugin does, and
  /// returns the reply envelope the plugin's handler produced.
  ///
  /// The reply is what makes a failed dispatch observable: an exception thrown
  /// inside a method-call handler is caught by the channel machinery and
  /// encoded as an error envelope rather than propagating to the caller, so
  /// awaiting the call alone would pass either way.
  Future<ByteData?> fire(
    String method,
    String id, [
    Map<String, Object?>? extra,
  ]) async {
    ByteData? reply;
    await TestDefaultBinaryMessengerBinding
        .instance
        .defaultBinaryMessenger
        .handlePlatformMessage(
          channel.name,
          codec.encodeMethodCall(
            MethodCall(method, {'notificationId': id, ...?extra}),
          ),
          (value) => reply = value,
        );
    return reply;
  }

  Future<void> settle() => Future<void>.delayed(Duration.zero);

  setUp(() async {
    calls = [];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return true;
        });
    SharedPreferences.setMockInitialValues({});
    await NotificationService.instance.init();
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const track = TrackInfo(title: 'Teardrop', artist: 'Massive Attack', album: 'Mezzanine');

  test('a dismissed toast is released back to the plugin', () async {
    final before = localNotifier.listeners.length;

    NotificationService.instance.showScrobbled(track);
    await settle();

    expect(notified(), hasLength(1));
    expect(
      localNotifier.listeners.length,
      before + 1,
      reason: 'the toast registers itself as a global listener',
    );

    await fire('onLocalNotificationClose', notified().single, {
      'closeReason': 'timedOut',
    });
    await settle();

    expect(closed(), notified(), reason: 'the toast was handed back');
    expect(
      localNotifier.listeners.length,
      before,
      reason: 'and its listener registration was undone',
    );
  });

  test('a clicked toast is released too', () async {
    final before = localNotifier.listeners.length;

    NotificationService.instance.showScrobbled(track);
    await settle();
    await fire('onLocalNotificationClick', notified().single);
    await settle();

    expect(closed(), notified());
    expect(localNotifier.listeners.length, before);
  });

  test('releasing twice does not close twice', () async {
    NotificationService.instance.showScrobbled(track);
    await settle();
    final id = notified().single;

    await fire('onLocalNotificationClick', id);
    await settle();
    await fire('onLocalNotificationClose', id, {'closeReason': 'timedOut'});
    await settle();

    expect(closed(), [id], reason: 'the second release is a no-op');
  });

  test('a callback for an already-released toast does not throw', () async {
    NotificationService.instance.showScrobbled(track);
    await settle();
    final id = notified().single;

    await fire('onLocalNotificationClose', id, {'closeReason': 'timedOut'});
    await settle();

    // Upstream dereferences the missing map entry with `!`; the forked
    // dispatcher drops the callback instead. Raise a second, still-live toast
    // first so the dispatch loop actually has a listener to walk.
    NotificationService.instance.showScrobbled(track);
    await settle();

    final reply = await fire('onLocalNotificationClose', id, {
      'closeReason': 'unknown',
    });

    expect(
      () => codec.decodeEnvelope(reply!),
      returnsNormally,
      reason: 'the dispatcher must drop the callback, not raise on it',
    );

    // The service is a singleton, so release the live toast rather than
    // carrying it into the next test.
    await fire('onLocalNotificationClose', notified().last, {
      'closeReason': 'timedOut',
    });
    await settle();
  });

  test('lost terminal events cannot grow the listener list without bound',
      () async {
    final before = localNotifier.listeners.length;

    // Never fire a terminal event — this is the dropped-callback case that
    // `toastFailed` (a no-op in the plugin) produces.
    for (var i = 0; i < 80; i++) {
      NotificationService.instance.showScrobbled(track);
    }
    await settle();
    await settle();

    expect(
      localNotifier.listeners.length - before,
      lessThanOrEqualTo(32),
      reason: 'the backstop trims the oldest past the cap',
    );
    // Restrict to this test's own toasts: the service is a singleton, so an
    // earlier test's leftovers may be trimmed first.
    final mine = notified().toSet();
    final closedMine = closed().where(mine.contains).toList();
    expect(
      closedMine,
      notified().take(closedMine.length),
      reason: 'and it trims oldest-first',
    );
    expect(closedMine, isNotEmpty);
  });
}
