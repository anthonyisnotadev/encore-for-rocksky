import 'dart:convert';
import 'package:http/http.dart' as http;
import 'log_buffer.dart';

final _log = LogBuffer.instance;

/// MusicBrainz asks every client to identify itself with an application name,
/// a version, and a contact address. Requests without real contact info are
/// throttled harder and get 503s sooner, so both enrichment paths send this.
/// See https://musicbrainz.org/doc/MusicBrainz_API/Rate_Limiting
const _musicBrainzUserAgent = 'EncoreForRocksky/1.0.0 ( hey@anthonyisnota.dev )';

class EnrichedTrackMeta {
  final int? durationMs;
  final int? trackNumber;
  final int? discNumber;
  final String? albumArtUrl;
  final String? releaseDate;
  final int? year;
  final String? spotifyUrl;
  final String? mbid;
  final List<Map<String, String>> artists;

  const EnrichedTrackMeta({
    this.durationMs,
    this.trackNumber,
    this.discNumber,
    this.albumArtUrl,
    this.releaseDate,
    this.year,
    this.spotifyUrl,
    this.mbid,
    this.artists = const [],
  });
}

// ─── Spotify + MusicBrainz enrichment (requires Spotify API creds) ──────────

class TrackEnrichmentService {
  final String clientId;
  final String clientSecret;

  String? _token;

  TrackEnrichmentService({
    required this.clientId,
    required this.clientSecret,
  });

  Future<bool> authenticate() async {
    try {
      final credentials =
          base64Encode(utf8.encode('$clientId:$clientSecret'));
      final resp = await http.post(
        Uri.parse('https://accounts.spotify.com/api/token'),
        headers: {
          'Authorization': 'Basic $credentials',
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=client_credentials',
      ).timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        _log.log('Spotify auth failed: ${resp.statusCode} ${resp.body}',
            name: 'enrich');
        return false;
      }

      _token = (jsonDecode(resp.body))['access_token'] as String;
      _log.log('Spotify auth OK', name: 'enrich');
      return true;
    } catch (e) {
      _log.log('Spotify auth error: $e', name: 'enrich');
      return false;
    }
  }

  /// Enriches tracks using Spotify API + MusicBrainz ISRC lookups.
  Future<Map<String, EnrichedTrackMeta>> enrichTracks(
    Set<String> spotifyUris, {
    void Function(String status)? onStatus,
    bool Function()? isCancelled,
  }) async {
    if (_token == null) return {};

    final results = <String, EnrichedTrackMeta>{};

    // Extract track IDs from URIs
    final uriToId = <String, String>{};
    for (final uri in spotifyUris) {
      final parts = uri.split(':');
      if (parts.length == 3 && parts[1] == 'track') {
        uriToId[uri] = parts[2];
      }
    }
    if (uriToId.isEmpty) return {};

    // ── Spotify batch fetch (50 per request) ──
    final entries = uriToId.entries.toList();
    final isrcMap = <String, String>{}; // trackUri → ISRC

    for (var i = 0; i < entries.length; i += 50) {
      if (isCancelled?.call() == true) break;

      final end = (i + 50).clamp(0, entries.length);
      final batch = entries.sublist(i, end);
      final ids = batch.map((e) => e.value).join(',');

      onStatus?.call(
          'Spotify metadata: ${(i + batch.length).clamp(0, entries.length)}/${entries.length} tracks');

      try {
        final resp = await http.get(
          Uri.parse('https://api.spotify.com/v1/tracks?ids=$ids'),
          headers: {'Authorization': 'Bearer $_token'},
        ).timeout(const Duration(seconds: 30));

        if (resp.statusCode != 200) {
          _log.log('Spotify tracks failed: ${resp.statusCode}',
              name: 'enrich');
          continue;
        }

        final data = jsonDecode(resp.body);
        final tracks = data['tracks'] as List;

        for (var j = 0; j < tracks.length; j++) {
          final track = tracks[j];
          if (track == null) continue;

          final uri = batch[j].key;
          final album = track['album'] as Map<String, dynamic>?;
          final images = album?['images'] as List?;
          final relDate = album?['release_date'] as String?;
          final relPrecision =
              album?['release_date_precision'] as String? ?? 'day';
          final externalIds =
              track['external_ids'] as Map<String, dynamic>?;
          final isrc = externalIds?['isrc'] as String?;

          if (isrc != null) isrcMap[uri] = isrc;

          int? year;
          String? fullReleaseDate;
          if (relDate != null && relDate.length >= 4) {
            year = int.tryParse(relDate.substring(0, 4));
            fullReleaseDate = switch (relPrecision) {
              'day' => '${relDate}T00:00:00.000Z',
              'month' => '$relDate-01T00:00:00.000Z',
              _ => '$relDate-01-01T00:00:00.000Z',
            };
          }

          String? artUrl;
          if (images != null && images.isNotEmpty) {
            artUrl = images[0]['url'] as String?;
          }

          final artistList = <Map<String, String>>[];
          final trackArtists = track['artists'] as List?;
          if (trackArtists != null) {
            for (final a in trackArtists) {
              artistList.add({'name': a['name'] as String? ?? ''});
            }
          }

          final externalUrls =
              track['external_urls'] as Map<String, dynamic>?;

          results[uri] = EnrichedTrackMeta(
            durationMs: (track['duration_ms'] as num?)?.toInt(),
            trackNumber: (track['track_number'] as num?)?.toInt(),
            discNumber: (track['disc_number'] as num?)?.toInt(),
            albumArtUrl: artUrl,
            releaseDate: fullReleaseDate,
            year: year,
            spotifyUrl: externalUrls?['spotify'] as String?,
            artists: artistList,
          );
        }

        _log.log('Enriched ${batch.length} tracks from Spotify',
            name: 'enrich');
      } catch (e) {
        _log.log('Spotify batch error: $e', name: 'enrich');
      }
    }

    // ── MusicBrainz ISRC → mbid lookups (1 req/sec) ──
    if (isrcMap.isNotEmpty && isCancelled?.call() != true) {
      var done = 0;
      for (final entry in isrcMap.entries) {
        if (isCancelled?.call() == true) break;
        if (!results.containsKey(entry.key)) continue;

        done++;
        onStatus?.call('MusicBrainz ISRC lookup: $done/${isrcMap.length}');

        try {
          final resp = await http.get(
            Uri.parse(
                'https://musicbrainz.org/ws/2/isrc/${entry.value}?fmt=json'),
            headers: {'User-Agent': _musicBrainzUserAgent},
          ).timeout(const Duration(seconds: 10));

          if (resp.statusCode == 200) {
            final data = jsonDecode(resp.body);
            final recordings = data['recordings'] as List?;
            if (recordings != null && recordings.isNotEmpty) {
              final rec = recordings[0];
              final recMbid = rec['id'] as String?;

              final enrichedArtists = <Map<String, String>>[];
              final credits = rec['artist-credit'] as List?;
              if (credits != null) {
                for (final credit in credits) {
                  final artist =
                      credit['artist'] as Map<String, dynamic>?;
                  if (artist != null) {
                    final m = <String, String>{
                      'name': artist['name'] as String? ?? '',
                    };
                    final aid = artist['id'] as String?;
                    if (aid != null) m['mbid'] = aid;
                    enrichedArtists.add(m);
                  }
                }
              }

              final existing = results[entry.key]!;
              results[entry.key] = EnrichedTrackMeta(
                durationMs: existing.durationMs,
                trackNumber: existing.trackNumber,
                discNumber: existing.discNumber,
                albumArtUrl: existing.albumArtUrl,
                releaseDate: existing.releaseDate,
                year: existing.year,
                spotifyUrl: existing.spotifyUrl,
                mbid: recMbid,
                artists: enrichedArtists.isNotEmpty
                    ? enrichedArtists
                    : existing.artists,
              );
            }
          }

          await Future.delayed(const Duration(milliseconds: 1100));
        } catch (e) {
          _log.log('MusicBrainz error for ${entry.value}: $e',
              name: 'enrich');
        }
      }
      _log.log('MusicBrainz: looked up $done ISRCs', name: 'enrich');
    }

    _log.log('Enrichment done: ${results.length} tracks', name: 'enrich');
    return results;
  }
}

// ─── MusicBrainz-only enrichment (no credentials needed) ───────────────────

class MusicBrainzEnrichmentService {
  static const _ua = _musicBrainzUserAgent;
  static const _mbBase = 'https://musicbrainz.org/ws/2';

  final _cache = <String, EnrichedTrackMeta?>{}; // artist|title|album → meta
  final _artCache = <String, String?>{}; // release mbid → art URL

  /// Tracks that MusicBrainz genuinely has no match for. Kept separate from
  /// [_cache] so a *transient* failure (503, timeout) is not remembered as
  /// "this track has no metadata" for the rest of the process — which is how
  /// one blip used to disable enrichment for a song permanently.
  final _noMatch = <String>{};

  /// Looks up a single track. Successful results and confirmed
  /// "no such recording" answers are cached by (artist, title, album) so
  /// repeated plays of the same track only hit the API once. Transient
  /// failures are not cached, so the next play retries.
  Future<EnrichedTrackMeta?> lookupTrack({
    required String artist,
    required String title,
    required String album,
    String? spotifyTrackUri,
  }) async {
    final cacheKey = '$artist|$title|$album';
    if (_cache.containsKey(cacheKey)) return _cache[cacheKey];
    if (_noMatch.contains(cacheKey)) return null;

    try {
      // ── Search recording ──
      final query = _buildQuery(artist, title, album);
      final searchResp = await _mbGet(
        '$_mbBase/recording?query=$query&fmt=json&limit=5',
      );

      if (searchResp == null || searchResp.statusCode != 200) {
        // Transient — deliberately not cached, so the next play retries.
        _log.log(
            'MB search failed: $artist — $title '
            '(${searchResp?.statusCode ?? 'no response'}); will retry on next play',
            name: 'enrich');
        return null;
      }

      final searchData = jsonDecode(searchResp.body);
      final recordings = searchData['recordings'] as List?;
      if (recordings == null || recordings.isEmpty) {
        // A real answer, not a failure — remember it.
        _log.log('No MB result: $artist — $title', name: 'enrich');
        _noMatch.add(cacheKey);
        return null;
      }

      final searchRec = recordings[0] as Map<String, dynamic>;
      final searchMbid = searchRec['id'] as String?;
      final rec = searchMbid != null
          ? await _lookupRecordingDetails(searchMbid) ?? searchRec
          : searchRec;
      final recMbid = rec['id'] as String?;
      final length = (rec['length'] as num?)?.toInt();

      // Artist credits with mbids
      final artistList = <Map<String, String>>[];
      final credits = rec['artist-credit'] as List?;
      if (credits != null) {
        for (final credit in credits) {
          final a = credit['artist'] as Map<String, dynamic>?;
          if (a != null) {
            final m = <String, String>{'name': a['name'] as String? ?? ''};
            final aid = a['id'] as String?;
            if (aid != null) m['mbid'] = aid;
            artistList.add(m);
          }
        }
      }

      // ── Release info ──
      String? releaseDate;
      int? year;
      String? releaseMbid;
      int? trackNumber;
      int? discNumber;

      final releases = rec['releases'] as List?;
      if (releases != null && releases.isNotEmpty) {
        Map<String, dynamic>? bestRelease;
        if (album.isNotEmpty) {
          for (final rel in releases) {
            if (rel is Map<String, dynamic>) {
              final relTitle = (rel['title'] as String?) ?? '';
              if (relTitle.toLowerCase() == album.toLowerCase()) {
                bestRelease = rel;
                break;
              }
            }
          }
        }
        bestRelease ??= releases[0] as Map<String, dynamic>;

        releaseMbid = bestRelease['id'] as String?;
        final date = bestRelease['date'] as String?;
        if (date != null && date.length >= 4) {
          year = int.tryParse(date.substring(0, 4));
          releaseDate = switch (date.length) {
            >= 10 => '${date.substring(0, 10)}T00:00:00.000Z',
            >= 7 => '${date.substring(0, 7)}-01T00:00:00.000Z',
            _ => '$date-01-01T00:00:00.000Z',
          };
        }

        final media = bestRelease['media'] as List?;
        if (media != null) {
          for (final disc in media) {
            if (disc is! Map<String, dynamic>) continue;
            final tracks = (disc['tracks'] ?? disc['track']) as List?;
            if (tracks != null) {
              for (final trk in tracks) {
                if (trk is! Map<String, dynamic>) continue;
                final trkRecording = trk['recording'] as Map<String, dynamic>?;
                final trkRecordingId = trkRecording?['id'] as String?;
                final trkTitle = (trk['title'] as String?) ?? '';
                final matchesRecording = recMbid != null &&
                    trkRecordingId != null &&
                    trkRecordingId == recMbid;
                final matchesTitle = trkTitle.toLowerCase() ==
                    (rec['title'] as String? ?? '').toLowerCase();
                if (matchesRecording || matchesTitle) {
                  trackNumber = _parseTrackNumber(trk['number']);
                  discNumber = (disc['position'] as num?)?.toInt();
                  break;
                }
              }
            }
            if (trackNumber != null) break;
          }
        }
      }

      // ── Cover art from Cover Art Archive ──
      String? artUrl;
      if (releaseMbid != null) {
        if (_artCache.containsKey(releaseMbid)) {
          artUrl = _artCache[releaseMbid];
        } else {
          try {
            final caaResp = await http.get(
              Uri.parse('https://coverartarchive.org/release/$releaseMbid'),
              headers: {'User-Agent': _ua},
            ).timeout(const Duration(seconds: 10));

            if (caaResp.statusCode == 200) {
              final caaData = jsonDecode(caaResp.body);
              final images = caaData['images'] as List?;
              if (images != null && images.isNotEmpty) {
                for (final img in images) {
                  if (img['front'] == true) {
                    final thumbs =
                        img['thumbnails'] as Map<String, dynamic>?;
                    artUrl = thumbs?['500'] as String? ??
                        thumbs?['large'] as String? ??
                        img['image'] as String?;
                    break;
                  }
                }
                artUrl ??= images[0]['image'] as String?;
              }
            }

            _artCache[releaseMbid] = artUrl;
            await Future.delayed(const Duration(milliseconds: 500));
          } catch (e) {
            _artCache[releaseMbid] = null;
            _log.log('CAA error for $releaseMbid: $e', name: 'enrich');
          }
        }
      }

      // Convert spotify:track:ID → URL
      String? spotifyUrl;
      if (spotifyTrackUri != null) {
        final parts = spotifyTrackUri.split(':');
        if (parts.length == 3 && parts[1] == 'track') {
          spotifyUrl = 'https://open.spotify.com/track/${parts[2]}';
        }
      }

      final meta = EnrichedTrackMeta(
        durationMs: length,
        trackNumber: trackNumber,
        discNumber: discNumber,
        albumArtUrl: artUrl,
        releaseDate: releaseDate,
        year: year,
        spotifyUrl: spotifyUrl,
        mbid: recMbid,
        artists: artistList,
      );

      _cache[cacheKey] = meta;
      return meta;
    } catch (e) {
      // Transient — deliberately not cached, so the next play retries.
      _log.log('MB error: $artist — $title: $e; will retry on next play',
          name: 'enrich');
      await Future.delayed(const Duration(milliseconds: 1100));
      return null;
    }
  }

  /// GETs a MusicBrainz URL, honouring the 1 req/sec rate limit and retrying
  /// the throttling/overload responses (429, 503) it hands back under load.
  /// Returns `null` when every attempt failed.
  Future<http.Response?> _mbGet(String url, {int attempts = 3}) async {
    http.Response? last;
    for (var attempt = 1; attempt <= attempts; attempt++) {
      try {
        last = await http
            .get(Uri.parse(url), headers: {'User-Agent': _ua})
            .timeout(const Duration(seconds: 10));
      } catch (e) {
        last = null;
        _log.log('MB request error (attempt $attempt/$attempts): $e',
            name: 'enrich');
      }

      // MusicBrainz allows one request per second per client.
      await Future.delayed(const Duration(milliseconds: 1100));

      if (last != null &&
          last.statusCode != 429 &&
          last.statusCode != 503) {
        return last;
      }
      if (attempt < attempts) {
        // Back off before retrying a throttled/overloaded response.
        await Future.delayed(Duration(seconds: attempt * 2));
      }
    }
    return last;
  }

  static String _buildQuery(String artist, String title, String album) {
    var q =
        'recording:"${_escape(title)}" AND artist:"${_escape(artist)}"';
    if (album.isNotEmpty) {
      q += ' AND release:"${_escape(album)}"';
    }
    return Uri.encodeComponent(q);
  }

  static String _escape(String s) {
    return s.replaceAll(RegExp(r'[+\-&|!(){}\[\]^"~*?:\\]'), ' ').trim();
  }

  Future<Map<String, dynamic>?> _lookupRecordingDetails(String mbid) async {
    try {
      final resp = await _mbGet(
        '$_mbBase/recording/$mbid?inc=artist-credits+releases+media&fmt=json',
      );

      if (resp == null || resp.statusCode != 200) {
        _log.log(
            'MB recording detail failed: $mbid '
            '(${resp?.statusCode ?? 'no response'})',
            name: 'enrich');
        return null;
      }

      final data = jsonDecode(resp.body);
      return data is Map<String, dynamic> ? data : null;
    } catch (e) {
      _log.log('MB recording detail error for $mbid: $e', name: 'enrich');
      await Future.delayed(const Duration(milliseconds: 1100));
      return null;
    }
  }

  static int? _parseTrackNumber(dynamic value) {
    if (value == null) return null;
    if (value is num) return value.toInt();
    final text = value.toString().trim();
    final parsed = int.tryParse(text);
    if (parsed != null) return parsed;
    final match = RegExp(r'\d+').firstMatch(text);
    return match == null ? null : int.tryParse(match.group(0)!);
  }
}
