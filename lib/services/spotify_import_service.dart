import 'dart:convert';
import 'dart:io';
import '../models/spotify_history_entry.dart';
import 'log_buffer.dart';

final _log = LogBuffer.instance;

class SpotifyImportService {
  static const _minPlayMs = 30000; // 30 seconds

  /// Parses Spotify extended streaming history JSON files.
  /// Returns the raw entry count and filtered, deduplicated entries sorted
  /// chronologically.
  Future<({int rawCount, List<SpotifyHistoryEntry> entries})> parseFiles(
    List<String> paths, {
    bool includeSkipped = false,
  }) async {
    final all = <SpotifyHistoryEntry>[];
    var rawCount = 0;

    for (final path in paths) {
      try {
        final content = await File(path).readAsString();
        final List<dynamic> json = jsonDecode(content);
        rawCount += json.length;
        for (final item in json) {
          final entry = SpotifyHistoryEntry.fromJson(item as Map<String, dynamic>);
          if (entry == null) continue;
          if (entry.msPlayed < _minPlayMs) continue;
          if (!includeSkipped && item['skipped'] == true) continue;
          all.add(entry);
        }
        _log.log('Parsed ${json.length} entries from ${path.split(Platform.pathSeparator).last}',
            name: 'import');
      } on FormatException catch (e) {
        _log.log('Invalid JSON in $path: $e', name: 'import');
        rethrow;
      }
    }

    // Deduplicate by (artist, track, timestamp)
    final seen = <String>{};
    final deduped = <SpotifyHistoryEntry>[];
    for (final e in all) {
      final key =
          '${e.artistName}|${e.trackName}|${e.timestamp.millisecondsSinceEpoch}';
      if (seen.add(key)) deduped.add(e);
    }

    deduped.sort((a, b) => a.timestamp.compareTo(b.timestamp));
    _log.log('${deduped.length} entries after filtering & dedup', name: 'import');
    return (rawCount: rawCount, entries: deduped);
  }
}
