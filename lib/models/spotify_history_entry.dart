class SpotifyHistoryEntry {
  final DateTime timestamp;
  final String trackName;
  final String artistName;
  final String albumName;
  final int msPlayed;
  final String? spotifyTrackUri;

  const SpotifyHistoryEntry({
    required this.timestamp,
    required this.trackName,
    required this.artistName,
    required this.albumName,
    required this.msPlayed,
    this.spotifyTrackUri,
  });

  /// Parses a single entry from Spotify's extended streaming history JSON.
  /// Returns `null` for podcasts or entries with missing track/artist metadata.
  static SpotifyHistoryEntry? fromJson(Map<String, dynamic> json) {
    final track = json['master_metadata_track_name'] as String?;
    final artist = json['master_metadata_album_artist_name'] as String?;
    if (track == null || artist == null) return null;

    return SpotifyHistoryEntry(
      timestamp: DateTime.parse(json['ts'] as String),
      trackName: track,
      artistName: artist,
      albumName: (json['master_metadata_album_album_name'] as String?) ?? '',
      msPlayed: (json['ms_played'] as num).toInt(),
      spotifyTrackUri: json['spotify_track_uri'] as String?,
    );
  }
}
