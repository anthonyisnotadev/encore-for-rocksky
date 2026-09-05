import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import '../models/track_info.dart';

class MediaWatcherService {
  static const _channel = MethodChannel('encore/spotify_smtc');

  final trackNotifier = ValueNotifier<TrackInfo?>(null);
  Timer? _timer;
  int _lastPositionMs = 0;

  /// Called when the same song restarts (repeat / loop detected).
  VoidCallback? onRepeatDetected;

  void start() {
    _timer?.cancel();
    _poll();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _poll());
  }

  /// Stops polling and clears the cached track.
  ///
  /// Clearing matters: `_poll` only notifies when the track *changes*, so a
  /// stale value here would make the next `start()` (after signing back in)
  /// see "same track" and stay silent, leaving the UI on "Nothing playing".
  void stop() {
    _timer?.cancel();
    _timer = null;
    _lastPositionMs = 0;
    trackNotifier.value = null;
  }

  static Future<bool> controlPlayback(String action) async {
    try {
      final result = await _channel.invokeMethod<bool>('controlPlayback', action);
      return result ?? false;
    } on PlatformException {
      return false;
    }
  }

  Future<void> _poll() async {
    try {
      final result = await _channel.invokeMethod<Map>('getCurrentTrack');
      if (result == null) {
        trackNotifier.value = null;
        return;
      }
      final track = TrackInfo(
        title: result['title'] as String? ?? '',
        artist: result['artist'] as String? ?? '',
        album: result['album'] as String? ?? '',
        artBytes: result['art'] as Uint8List?,
        isPlaying: result['is_playing'] as bool? ?? false,
        durationMs: switch (result['duration_ms']) {
          final int ms when ms > 0 => ms,
          _ => null,
        },
      );
      final positionMs = result['position_ms'] as int? ?? 0;
      final current = trackNotifier.value;
      if (!track.isSameTrack(current)) {
        _lastPositionMs = positionMs;
        trackNotifier.value = track;
      } else {
        // Same track — check if position jumped backwards (song restarted).
        if (_lastPositionMs > 15000 && positionMs < 5000) {
          _lastPositionMs = positionMs;
          onRepeatDetected?.call();
        } else {
          _lastPositionMs = positionMs;
        }
        // Spotify often reports an empty SMTC timeline on the first poll
        // after a track change, so the length can arrive a few seconds late.
        // Publish it when it does — the scrobble fires 30s in and needs it.
        final durationArrived =
            track.durationMs != null && current?.durationMs == null;
        if (track.artBytes != null && current?.artBytes == null ||
            track.isPlaying != current?.isPlaying ||
            durationArrived) {
          trackNotifier.value = track;
        }
      }
    } on PlatformException {
      trackNotifier.value = null;
    }
  }
}
