import 'dart:convert';
import 'package:http/http.dart' as http;
import '../models/spotify_history_entry.dart';
import '../models/track_info.dart';
import 'log_buffer.dart';
import 'track_enrichment_service.dart';

final _log = LogBuffer.instance;

/// What [PdsService.checkSession] decided about a restored session.
enum PdsSessionValidity {
  /// The session works — the refresh token was accepted and rotated.
  valid,

  /// The PDS definitively rejected the session: the app password was revoked
  /// or the session expired. Signing in again is the only way forward;
  /// retrying cannot succeed.
  invalid,

  /// The check could not reach a conclusion — network or server trouble. The
  /// session may still be fine.
  unverified,
}

enum _RefreshOutcome { success, rejected, failed }

class PdsService {
  final String pdsUrl;
  String accessJwt;
  String refreshJwt;
  final String did;
  final Future<void> Function(PdsService service)? onSessionRefreshed;

  /// Fired once when the PDS definitively rejects the refresh token — the app
  /// password was revoked or the session expired. The session can never work
  /// again, so the app signs the user out and asks for a new app password
  /// instead of failing every write until the app restarts. Not fired for
  /// network failures or server errors, which may clear on their own.
  final Future<void> Function(PdsService service)? onSessionInvalid;
  final MusicBrainzEnrichmentService _mbEnricher =
      MusicBrainzEnrichmentService();
  bool _invalidNotified = false;

  PdsService._({
    required this.pdsUrl,
    required this.accessJwt,
    required this.refreshJwt,
    required this.did,
    this.onSessionRefreshed,
    this.onSessionInvalid,
  });

  static DateTime? _jwtExpiresAt(String jwt) {
    try {
      final parts = jwt.split('.');
      if (parts.length < 2) return null;
      final normalized = base64Url.normalize(parts[1]);
      final payload = utf8.decode(base64Url.decode(normalized));
      final data = jsonDecode(payload) as Map<String, dynamic>;
      final exp = data['exp'];
      if (exp is! num) return null;
      return DateTime.fromMillisecondsSinceEpoch(
        exp.toInt() * 1000,
        isUtc: true,
      );
    } catch (_) {
      return null;
    }
  }

  static String _jwtExpiryDescription(String jwt) {
    final expiresAt = _jwtExpiresAt(jwt);
    if (expiresAt == null) return 'JWT exp unavailable';
    final now = DateTime.now().toUtc();
    final delta = expiresAt.difference(now);
    final abs = delta.abs();
    final minutes = abs.inMinutes;
    final seconds = abs.inSeconds % 60;
    final direction = delta.isNegative ? 'expired' : 'expires in';
    return '$direction ${minutes}m ${seconds}s (exp ${expiresAt.toIso8601String()})';
  }

  void _logSessionState(String context) {
    _log.log(
      '$context: did=$did pds=$pdsUrl accessJwt ${_jwtExpiryDescription(accessJwt)}; refreshJwt ${_jwtExpiryDescription(refreshJwt)}',
      name: 'pds',
    );
  }

  bool get _accessJwtNeedsRefresh {
    final expiresAt = _jwtExpiresAt(accessJwt);
    if (expiresAt == null) return false;
    return expiresAt.difference(DateTime.now().toUtc()) <=
        const Duration(minutes: 2);
  }

  Future<_RefreshOutcome> _refreshSession({
    String reason = 'access token refresh',
  }) async {
    _log.log('$reason: calling refreshSession', name: 'pds');

    try {
      final resp = await http
          .post(
            Uri.parse('$pdsUrl/xrpc/com.atproto.server.refreshSession'),
            headers: {'Authorization': 'Bearer $refreshJwt'},
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        _log.log(
          'PDS refreshSession failed: ${resp.statusCode} ${resp.body}',
          name: 'pds',
        );
        if (_isAuthRejection(resp)) {
          _log.log(
            'PDS rejected the refresh token — the app password was revoked '
            'or the session expired. Sign-in required; further writes will '
            'fail until then.',
            name: 'pds',
          );
          await _notifySessionInvalid();
          return _RefreshOutcome.rejected;
        }
        return _RefreshOutcome.failed;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      accessJwt = data['accessJwt'] as String;
      refreshJwt = data['refreshJwt'] as String;
      _logSessionState('PDS session refreshed');
      await onSessionRefreshed?.call(this);
      return _RefreshOutcome.success;
    } catch (e) {
      _log.log('PDS refreshSession error: $e', name: 'pds');
      return _RefreshOutcome.failed;
    }
  }

  /// True when the server's answer is about the token itself being dead — a
  /// revoked app password, an expired or invalidated session — rather than a
  /// network or server problem. Only such answers justify forcing a sign-out:
  /// a 5xx or a timeout may clear on the next attempt.
  bool _isAuthRejection(http.Response resp) {
    if (resp.statusCode != 400 && resp.statusCode != 401) return false;
    try {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return const {'ExpiredToken', 'InvalidToken', 'InvalidRefreshToken'}
          .contains(data['error']);
    } catch (_) {
      return false;
    }
  }

  Future<void> _notifySessionInvalid() async {
    if (_invalidNotified) return;
    _invalidNotified = true;
    await onSessionInvalid?.call(this);
  }

  /// Verifies a restored session before the scrobble path has to depend on it.
  ///
  /// Refreshing is the definitive test: the access token is a stateless JWT
  /// that the PDS keeps accepting until it expires even after the app password
  /// was revoked, so an unexpired access token proves nothing. A refresh that
  /// comes back rejected means the session is dead for good.
  Future<PdsSessionValidity> checkSession() async {
    switch (await _refreshSession(reason: 'Session check on startup')) {
      case _RefreshOutcome.success:
        return PdsSessionValidity.valid;
      case _RefreshOutcome.rejected:
        return PdsSessionValidity.invalid;
      case _RefreshOutcome.failed:
        return PdsSessionValidity.unverified;
    }
  }

  Future<bool> _ensureFreshSession() async {
    if (!_accessJwtNeedsRefresh) return true;
    final outcome = await _refreshSession(
      reason: 'Access JWT near/after expiry',
    );
    return outcome == _RefreshOutcome.success;
  }

  bool _isExpiredTokenResponse(http.Response resp) {
    if (resp.statusCode != 400 && resp.statusCode != 401) return false;
    try {
      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      return data['error'] == 'ExpiredToken';
    } catch (_) {
      return false;
    }
  }

  Future<http.Response?> _postWithAuthRefresh(
    Uri uri, {
    Map<String, String>? headers,
    Object? body,
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await _ensureFreshSession();

    http.Response resp = await http
        .post(
          uri,
          headers: {
            ...?headers,
            'Authorization': 'Bearer $accessJwt',
          },
          body: body,
        )
        .timeout(timeout);

    if (_isExpiredTokenResponse(resp)) {
      _log.log(
        'PDS write got ExpiredToken; refreshing session and retrying once',
        name: 'pds',
      );
      final refreshed = await _refreshSession(reason: 'ExpiredToken response');
      if (refreshed == _RefreshOutcome.success) {
        resp = await http
            .post(
              uri,
              headers: {
                ...?headers,
                'Authorization': 'Bearer $accessJwt',
              },
              body: body,
            )
            .timeout(timeout);
      }
    }

    return resp;
  }

  Future<http.Response?> _getWithAuthRefresh(
    Uri uri, {
    Duration timeout = const Duration(seconds: 15),
  }) async {
    await _ensureFreshSession();

    http.Response resp = await http
        .get(uri, headers: {'Authorization': 'Bearer $accessJwt'})
        .timeout(timeout);

    if (_isExpiredTokenResponse(resp)) {
      _log.log(
        'PDS read got ExpiredToken; refreshing session and retrying once',
        name: 'pds',
      );
      final refreshed = await _refreshSession(reason: 'ExpiredToken response');
      if (refreshed == _RefreshOutcome.success) {
        resp = await http
            .get(uri, headers: {'Authorization': 'Bearer $accessJwt'})
            .timeout(timeout);
      }
    }

    return resp;
  }

  /// Recreates a PDS client from stored session details.
  factory PdsService.fromSession({
    required String pdsUrl,
    required String accessJwt,
    required String refreshJwt,
    required String did,
    Future<void> Function(PdsService service)? onSessionRefreshed,
    Future<void> Function(PdsService service)? onSessionInvalid,
  }) {
    final service = PdsService._(
      pdsUrl: pdsUrl,
      accessJwt: accessJwt,
      refreshJwt: refreshJwt,
      did: did,
      onSessionRefreshed: onSessionRefreshed,
      onSessionInvalid: onSessionInvalid,
    );
    service._logSessionState('Restored PDS session');
    return service;
  }

  /// Authenticates with the user's PDS via app password.
  /// Resolves the actual PDS endpoint from the DID document.
  static Future<PdsService?> login({
    required String handle,
    required String appPassword,
    Future<void> Function(PdsService service)? onSessionRefreshed,
    Future<void> Function(PdsService service)? onSessionInvalid,
  }) async {
    return _createSession(
      handle: handle,
      appPassword: appPassword,
      pdsUrl: 'https://bsky.social',
      onSessionRefreshed: onSessionRefreshed,
      onSessionInvalid: onSessionInvalid,
    );
  }

  static Future<PdsService?> _createSession({
    required String handle,
    required String appPassword,
    required String pdsUrl,
    Future<void> Function(PdsService service)? onSessionRefreshed,
    Future<void> Function(PdsService service)? onSessionInvalid,
  }) async {
    try {
      final resp = await http
          .post(
            Uri.parse('$pdsUrl/xrpc/com.atproto.server.createSession'),
            headers: {'Content-Type': 'application/json'},
            body: jsonEncode({'identifier': handle, 'password': appPassword}),
          )
          .timeout(const Duration(seconds: 15));

      if (resp.statusCode != 200) {
        _log.log(
          'PDS auth failed: ${resp.statusCode} ${resp.body}',
          name: 'pds',
        );
        return null;
      }

      final data = jsonDecode(resp.body) as Map<String, dynamic>;
      final did = data['did'] as String;
      final jwt = data['accessJwt'] as String;
      final refreshJwt = data['refreshJwt'] as String;

      // Resolve actual PDS endpoint from DID document
      var actualPds = pdsUrl;
      final didDoc = data['didDoc'] as Map<String, dynamic>?;
      if (didDoc != null) {
        final services = didDoc['service'] as List?;
        if (services != null) {
          for (final svc in services) {
            if (svc is Map && svc['id'] == '#atproto_pds') {
              actualPds = svc['serviceEndpoint'] as String;
              break;
            }
          }
        }
      }

      // Re-authenticate at the actual PDS if different
      if (actualPds != pdsUrl) {
        _log.log('Redirecting to PDS: $actualPds', name: 'pds');
        // Await so a failure here is caught by this function's own try/catch
        // instead of escaping to the caller as an unhandled error.
        return await _createSession(
          handle: handle,
          appPassword: appPassword,
          pdsUrl: actualPds,
          onSessionRefreshed: onSessionRefreshed,
          onSessionInvalid: onSessionInvalid,
        );
      }

      final service = PdsService._(
        pdsUrl: actualPds,
        accessJwt: jwt,
        refreshJwt: refreshJwt,
        did: did,
        onSessionRefreshed: onSessionRefreshed,
        onSessionInvalid: onSessionInvalid,
      );
      service._logSessionState('Authenticated PDS session');
      return service;
    } catch (e) {
      _log.log('PDS auth error: $e', name: 'pds');
      return null;
    }
  }

  /// Converts `spotify:track:ID` to `https://open.spotify.com/track/ID`.
  static String? _spotifyUriToUrl(String? uri) {
    if (uri == null) return null;
    final parts = uri.split(':');
    if (parts.length == 3 && parts[1] == 'track') {
      return 'https://open.spotify.com/track/${parts[2]}';
    }
    return uri;
  }

  /// Fields that `app.rocksky.scrobble` marks as required, plus their
  /// `minLength` / `minimum` constraints.
  ///
  /// A PDS only validates lexicons it can resolve, and it cannot resolve
  /// third-party NSIDs — every write here comes back
  /// `validationStatus: "unknown"`. So the PDS stores malformed records
  /// happily and returns 200, and Rocksky's firehose consumer silently drops
  /// them at ingest. A scrobble that never appears on rocksky.app looks
  /// identical in the log to one that worked. Check the constraints locally
  /// so the failure is visible.
  static String? _missingRequiredField(Map<String, dynamic> record) {
    for (final key in const ['title', 'artist', 'album', 'albumArtist']) {
      final value = record[key];
      if (value is! String || value.isEmpty) return key;
    }
    final duration = record['duration'];
    if (duration is! int || duration < 1) return 'duration';
    return null;
  }

  /// Builds the record body. [durationMsFallback] supplies `duration` when
  /// MusicBrainz enrichment produced none — without it the record is invalid
  /// and Rocksky drops it.
  Map<String, dynamic> _scrobbleRecord(
    SpotifyHistoryEntry e, {
    EnrichedTrackMeta? meta,
    int? durationMsFallback,
  }) {
    final duration = meta?.durationMs ?? durationMsFallback;
    return {
      '\$type': 'app.rocksky.scrobble',
      'title': e.trackName,
      'artist': e.artistName,
      'album': e.albumName,
      'albumArtist': e.artistName,
      'artists': meta?.artists.isNotEmpty == true
          ? meta!.artists
          : [
              {'name': e.artistName},
            ],
      'createdAt': e.timestamp.toUtc().toIso8601String(),
      'tags': [],
      if (meta?.spotifyUrl != null)
        'spotifyLink': meta!.spotifyUrl
      else if (e.spotifyTrackUri != null)
        'spotifyLink': _spotifyUriToUrl(e.spotifyTrackUri),
      if (meta?.mbid != null) 'mbid': meta!.mbid,
      if (meta?.year != null) 'year': meta!.year,
      if (meta?.releaseDate != null) 'releaseDate': meta!.releaseDate,
      if (duration != null && duration > 0) 'duration': duration,
      if (meta?.trackNumber != null) 'trackNumber': meta!.trackNumber,
      if (meta?.discNumber != null) 'discNumber': meta!.discNumber,
      if (meta?.albumArtUrl != null) 'albumArtUrl': meta!.albumArtUrl,
    };
  }

  Future<EnrichedTrackMeta?> _lookupMusicBrainzMeta(SpotifyHistoryEntry entry) {
    return _mbEnricher.lookupTrack(
      artist: entry.artistName,
      title: entry.trackName,
      album: entry.albumName,
      spotifyTrackUri: entry.spotifyTrackUri,
    );
  }

  /// Writes a live scrobble directly to the user's Bluesky PDS.
  ///
  /// Direct PDS writes are responsible for their own MusicBrainz enrichment so
  /// callers cannot accidentally create basic-only records. A caller-provided
  /// [meta] value is still used when already available to avoid duplicate
  /// lookups.
  Future<bool> writeScrobble(
    TrackInfo track,
    DateTime startedAt, {
    EnrichedTrackMeta? meta,
  }) async {
    final entry = SpotifyHistoryEntry(
      timestamp: startedAt,
      trackName: track.title,
      artistName: track.artist,
      albumName: track.album,
      msPlayed: 0,
    );

    try {
      final resolvedMeta = meta ?? await _lookupMusicBrainzMeta(entry);

      _logSessionState('About to write live PDS scrobble');

      if (resolvedMeta == null) {
        _log.log(
          'No MusicBrainz metadata for direct PDS scrobble; '
          'falling back to SMTC track length',
          name: 'enrich',
        );
      }

      final record = _scrobbleRecord(
        entry,
        meta: resolvedMeta,
        durationMsFallback: track.durationMs,
      );

      // `duration` is the field Rocksky rejects records for, and the PDS will
      // not complain about its absence. Say where it came from, so a silent
      // regression in either source is visible in the log.
      _log.log(
        'duration=${record['duration'] ?? 'MISSING'} '
        '(musicbrainz=${resolvedMeta?.durationMs ?? '-'}, '
        'smtc=${track.durationMs ?? '-'})',
        name: 'enrich',
      );

      final missing = _missingRequiredField(record);
      if (missing != null) {
        _log.log(
          'Skipping scrobble ${track.artist} — ${track.title}: '
          'app.rocksky.scrobble requires "$missing". The PDS would accept '
          'this record but Rocksky would drop it at ingest.',
          name: 'pds',
        );
        return false;
      }

      final resp = await _postWithAuthRefresh(
        Uri.parse('$pdsUrl/xrpc/com.atproto.repo.createRecord'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({
          'repo': did,
          'collection': 'app.rocksky.scrobble',
          'record': record,
        }),
      );

      if (resp == null) return false;

      _log.log(
        'Direct PDS scrobble → ${resp.statusCode}: ${resp.body}',
        name: 'pds',
      );

      if (resp.statusCode == 400) {
        try {
          final data = jsonDecode(resp.body) as Map<String, dynamic>;
          final error = data['error'];
          if (error == 'ExpiredToken') {
            _log.log(
              'Diagnosis signal: PDS rejected accessJwt as ExpiredToken; ${_jwtExpiryDescription(accessJwt)}',
              name: 'pds',
            );
          }
        } catch (_) {}
      }

      return resp.statusCode >= 200 && resp.statusCode < 300;
    } catch (e) {
      _log.log('Direct PDS scrobble error: $e', name: 'pds');
      return false;
    }
  }

  /// Deletes existing scrobble records that match the given timestamps,
  /// so reimports overwrite instead of duplicating.
  Future<int> deleteMatchingScrobbles(
    Set<String> createdAtValues, {
    void Function(String status)? onStatus,
  }) async {
    final toDelete = <String>[]; // rkeys
    String? cursor;

    // Paginate through existing records (newest first)
    onStatus?.call('Scanning existing records...');
    while (true) {
      final uri = Uri.parse(
        '$pdsUrl/xrpc/com.atproto.repo.listRecords'
        '?repo=$did&collection=app.rocksky.scrobble&limit=100&reverse=true'
        '${cursor != null ? '&cursor=$cursor' : ''}',
      );

      try {
        final resp = await _getWithAuthRefresh(uri);

        if (resp == null) {
          _log.log('listRecords failed: no response', name: 'pds');
          break;
        }

        if (resp.statusCode != 200) {
          _log.log('listRecords failed: ${resp.statusCode}', name: 'pds');
          break;
        }

        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final records = data['records'] as List;

        for (final rec in records) {
          final value = rec['value'] as Map<String, dynamic>?;
          final ca = value?['createdAt'] as String?;
          if (ca != null && createdAtValues.contains(ca)) {
            final atUri = rec['uri'] as String;
            // Extract rkey from at://did/collection/rkey
            final rkey = atUri.split('/').last;
            toDelete.add(rkey);
          }
        }

        cursor = data['cursor'] as String?;
        if (cursor == null || records.isEmpty) break;

        // If we've found all matches, stop early
        if (toDelete.length >= createdAtValues.length) break;
      } catch (e) {
        _log.log('listRecords error: $e', name: 'pds');
        break;
      }
    }

    if (toDelete.isEmpty) return 0;

    // Delete in batches using applyWrites
    onStatus?.call('Deleting ${toDelete.length} existing records...');
    var deleted = 0;
    for (var i = 0; i < toDelete.length; i += 200) {
      final end = (i + 200).clamp(0, toDelete.length);
      final batch = toDelete.sublist(i, end);

      final writes = batch
          .map(
            (rkey) => <String, String>{
              '\$type': 'com.atproto.repo.applyWrites#delete',
              'collection': 'app.rocksky.scrobble',
              'rkey': rkey,
            },
          )
          .toList();

      try {
        final resp = await _postWithAuthRefresh(
          Uri.parse('$pdsUrl/xrpc/com.atproto.repo.applyWrites'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({'repo': did, 'writes': writes}),
          timeout: const Duration(seconds: 30),
        );

        if (resp == null) {
          _log.log('Delete failed: no response', name: 'pds');
          continue;
        }

        if (resp.statusCode == 200) {
          deleted += batch.length;
          _log.log('Deleted ${batch.length} records', name: 'pds');
        } else {
          _log.log(
            'Delete failed: ${resp.statusCode} ${resp.body}',
            name: 'pds',
          );
        }
      } catch (e) {
        _log.log('Delete error: $e', name: 'pds');
      }
    }

    return deleted;
  }

  /// Writes scrobble records to PDS one at a time via createRecord.
  /// If [enrichment] map is provided, uses pre-fetched metadata.
  /// If [enrichFn] is provided, calls it per-entry for inline enrichment.
  /// If [overwrite] is true, deletes existing records with matching timestamps first.
  Future<({int succeeded, int failed})> writeScrobbles(
    List<SpotifyHistoryEntry> entries, {
    required bool Function() isCancelled,
    void Function(int completed, int total)? onProgress,
    void Function(String status)? onStatus,
    Map<String, EnrichedTrackMeta>? enrichment,
    Future<EnrichedTrackMeta?> Function(SpotifyHistoryEntry entry)? enrichFn,
    bool overwrite = false,
  }) async {
    // Delete existing records that would be overwritten
    if (overwrite) {
      final timestamps = entries
          .map((e) => e.timestamp.toUtc().toIso8601String())
          .toSet();
      final deleted = await deleteMatchingScrobbles(
        timestamps,
        onStatus: onStatus,
      );
      if (deleted > 0) {
        _log.log('Overwrote $deleted existing records', name: 'pds');
      }
    }

    var succeeded = 0;
    var failed = 0;

    for (var i = 0; i < entries.length; i++) {
      if (isCancelled()) break;

      final entry = entries[i];

      if (i == 0) {
        _logSessionState('About to write PDS import batch');
      }

      // Resolve metadata: inline enrichment > pre-fetched map > built-in MB.
      // Direct PDS writes should always try to create fully-enriched records,
      // even when callers do not provide an enrichment strategy.
      EnrichedTrackMeta? meta;
      if (enrichFn != null) {
        onStatus?.call(
          'Enriching & writing ${i + 1}/${entries.length}: '
          '${entry.artistName} — ${entry.trackName}',
        );
        meta = await enrichFn(entry);
      } else {
        onStatus?.call('Enriching & writing ${i + 1}/${entries.length}...');
        final uri = entry.spotifyTrackUri;
        meta = (uri != null && enrichment != null) ? enrichment[uri] : null;
        meta ??= await _lookupMusicBrainzMeta(entry);
        if (meta == null) {
          _log.log(
            'No MusicBrainz metadata for ${entry.artistName} — ${entry.trackName}; writing basic record',
            name: 'enrich',
          );
        }
      }

      final record = _scrobbleRecord(entry, meta: meta);
      final missing = _missingRequiredField(record);
      if (missing != null) {
        // Deliberately not falling back to `entry.msPlayed`: that is how long
        // the track played, which only equals its length on a complete play.
        // A wrong duration would be baked into a permanent record.
        failed++;
        _log.log(
          'Skipped: ${entry.artistName} — ${entry.trackName}: '
          'app.rocksky.scrobble requires "$missing"; Rocksky would drop it',
          name: 'pds',
        );
        onProgress?.call(succeeded + failed, entries.length);
        continue;
      }

      try {
        final resp = await _postWithAuthRefresh(
          Uri.parse('$pdsUrl/xrpc/com.atproto.repo.createRecord'),
          headers: {'Content-Type': 'application/json'},
          body: jsonEncode({
            'repo': did,
            'collection': 'app.rocksky.scrobble',
            'record': record,
          }),
        );

        if (resp == null) {
          failed++;
          _log.log('Failed: ${entry.trackName} — no response', name: 'pds');
          onProgress?.call(succeeded + failed, entries.length);
          continue;
        }

        if (resp.statusCode == 200) {
          succeeded++;
          _log.log(
            'Created: ${entry.artistName} — ${entry.trackName}',
            name: 'pds',
          );
        } else {
          failed++;
          _log.log(
            'Failed: ${entry.trackName} — ${resp.statusCode} ${resp.body}',
            name: 'pds',
          );
        }
      } catch (e) {
        failed++;
        _log.log('Error: ${entry.trackName} — $e', name: 'pds');
      }

      onProgress?.call(succeeded + failed, entries.length);
    }

    _log.log('PDS import done: $succeeded OK, $failed failed', name: 'pds');
    return (succeeded: succeeded, failed: failed);
  }
}
