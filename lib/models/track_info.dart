import 'dart:typed_data';

class TrackInfo {
  final String title;
  final String artist;
  final String album;
  final Uint8List? artBytes;
  final bool isPlaying;

  /// Track length reported by SMTC, or `null` when the session does not
  /// expose one. Rocksky's lexicon requires a positive `duration` on every
  /// scrobble, so this is the fallback when MusicBrainz enrichment fails.
  final int? durationMs;

  const TrackInfo({
    required this.title,
    required this.artist,
    required this.album,
    this.artBytes,
    this.isPlaying = false,
    this.durationMs,
  });

  bool isSameTrack(TrackInfo? other) =>
      other != null && title == other.title && artist == other.artist;

  @override
  String toString() => '$artist — $title';
}
