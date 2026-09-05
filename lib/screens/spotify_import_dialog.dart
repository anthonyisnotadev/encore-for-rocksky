import 'package:file_picker/file_picker.dart';
import 'package:fluent_ui/fluent_ui.dart';
import '../models/spotify_history_entry.dart';
import '../services/pds_service.dart';
import '../services/spotify_import_service.dart';
import '../services/track_enrichment_service.dart';

enum _Step { select, importing, done }

class SpotifyImportDialog extends StatefulWidget {
  const SpotifyImportDialog({super.key});

  @override
  State<SpotifyImportDialog> createState() => _SpotifyImportDialogState();
}

class _SpotifyImportDialogState extends State<SpotifyImportDialog> {
  _Step _step = _Step.select;

  // File selection
  List<String> _filePaths = [];
  List<SpotifyHistoryEntry>? _entries;
  int _rawCount = 0;
  bool _includeSkipped = false;
  bool _parsing = false;
  String? _parseError;

  // PDS auth
  final _handleController = TextEditingController();
  final _passwordController = TextEditingController();

  /// Delete existing scrobbles whose timestamps match the imported ones before
  /// writing. Off by default and never implied: this issues `applyWrites#delete`
  /// against the user's PDS and the removed records cannot be recovered.
  bool _overwrite = false;

  // Enrichment

  /// Whether to try the Spotify Web API. MusicBrainz enrichment is *not*
  /// gated on this: with it off, `PdsService.writeScrobbles` falls back to
  /// its own `MusicBrainzEnrichmentService` for every entry — the same
  /// lookup the dialog's inline enricher would have run. So the only
  /// observable effect is whether the Spotify path is attempted, which is
  /// what the label now says.
  ///
  /// Do not relabel this as a general "enrich metadata" switch. Enrichment
  /// is the only source of `duration` on the import path, and a record
  /// without one is dropped by the required-field check before it is
  /// written — a checkbox that really disabled MusicBrainz would silently
  /// import nothing.
  ///
  /// Off by default: it does nothing without credentials, and most people
  /// importing a history export do not have a Spotify app registered. Leaving
  /// it off also keeps two empty credential fields out of the dialog until
  /// someone asks for them.
  bool _useSpotifyApi = false;
  final _spotifyClientIdController = TextEditingController();
  final _spotifyClientSecretController = TextEditingController();

  // Import progress
  int _completed = 0;
  int _total = 0;
  bool _cancelled = false;
  String _statusText = '';

  // Results
  int _succeeded = 0;
  int _failed = 0;

  @override
  void dispose() {
    _handleController.dispose();
    _passwordController.dispose();
    _spotifyClientIdController.dispose();
    _spotifyClientSecretController.dispose();
    super.dispose();
  }

  Future<void> _pickFiles() async {
    final result = await FilePicker.pickFiles(
      allowMultiple: true,
      type: FileType.custom,
      allowedExtensions: ['json'],
      dialogTitle: 'Select Spotify streaming history files',
    );
    if (result == null || result.files.isEmpty) return;

    final paths = result.files
        .where((f) => f.path != null)
        .map((f) => f.path!)
        .toList();
    if (paths.isEmpty) return;

    setState(() {
      _filePaths = paths;
      _parseError = null;
    });
    await _parseFiles();
  }

  Future<void> _parseFiles() async {
    setState(() => _parsing = true);
    try {
      final service = SpotifyImportService();
      final result = await service.parseFiles(
        _filePaths,
        includeSkipped: _includeSkipped,
      );
      if (!mounted) return;
      setState(() {
        _entries = result.entries;
        _rawCount = result.rawCount;
        _parsing = false;
      });
    } on FormatException catch (e) {
      if (!mounted) return;
      setState(() {
        _parseError = 'Invalid JSON: $e';
        _parsing = false;
        _entries = null;
      });
    }
  }

  Future<void> _startImport() async {
    final entries = _entries;
    if (entries == null || entries.isEmpty) return;

    final handle = _handleController.text.trim();
    final password = _passwordController.text.trim();
    if (handle.isEmpty || password.isEmpty) {
      setState(() => _parseError = 'Handle and app password are required');
      return;
    }

    setState(() {
      _step = _Step.importing;
      _completed = 0;
      _total = entries.length;
      _cancelled = false;
      _statusText = 'Authenticating with PDS...';
    });

    // ── Authenticate PDS ──
    final pds = await PdsService.login(
      handle: handle,
      appPassword: password,
    );

    if (!mounted) return;
    if (pds == null) {
      setState(() {
        _step = _Step.done;
        _succeeded = 0;
        _failed = entries.length;
        _statusText = 'PDS authentication failed';
      });
      return;
    }

    // ── Determine enrichment strategy ──
    //
    // Leaving both of these null does not mean "no enrichment":
    // writeScrobbles then runs PdsService's own MusicBrainz lookup per
    // entry. That is why the checkbox is scoped to the Spotify API rather
    // than to enrichment at large.
    Map<String, EnrichedTrackMeta>? preEnrichment;
    Future<EnrichedTrackMeta?> Function(SpotifyHistoryEntry)? inlineEnrichFn;

    if (_useSpotifyApi && !_cancelled) {
      final clientId = _spotifyClientIdController.text.trim();
      final clientSecret = _spotifyClientSecretController.text.trim();

      if (clientId.isNotEmpty && clientSecret.isNotEmpty) {
        // Spotify API path: pre-enrich in bulk, then write
        setState(() => _statusText = 'Authenticating with Spotify...');

        final enricher = TrackEnrichmentService(
          clientId: clientId,
          clientSecret: clientSecret,
        );

        if (await enricher.authenticate()) {
          final uris = <String>{};
          for (final e in entries) {
            if (e.spotifyTrackUri != null) uris.add(e.spotifyTrackUri!);
          }

          preEnrichment = await enricher.enrichTracks(
            uris,
            onStatus: (status) {
              if (mounted) setState(() => _statusText = status);
            },
            isCancelled: () => _cancelled,
          );
        } else if (mounted) {
          setState(() => _statusText =
              'Spotify auth failed, falling back to MusicBrainz...');
        }
      }

      // MusicBrainz inline fallback (no creds, enrich as we go)
      if (preEnrichment == null && !_cancelled) {
        final mbEnricher = MusicBrainzEnrichmentService();
        inlineEnrichFn = (entry) => mbEnricher.lookupTrack(
              artist: entry.artistName,
              title: entry.trackName,
              album: entry.albumName,
              spotifyTrackUri: entry.spotifyTrackUri,
            );
      }
    }

    if (_cancelled || !mounted) return;

    // ── Write to PDS ──
    final result = await pds.writeScrobbles(
      entries,
      isCancelled: () => _cancelled,
      onProgress: (completed, total) {
        if (mounted) {
          setState(() {
            _completed = completed;
            _total = total;
          });
        }
      },
      onStatus: (status) {
        if (mounted) setState(() => _statusText = status);
      },
      enrichment: preEnrichment,
      enrichFn: inlineEnrichFn,
      overwrite: _overwrite,
    );

    if (mounted) {
      setState(() {
        _step = _Step.done;
        _succeeded = result.succeeded;
        _failed = result.failed;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final typography = theme.typography;
    final resources = theme.resources;

    return ContentDialog(
      title: const Text('Import Spotify History'),
      content: SizedBox(
        width: 480,
        child: switch (_step) {
          _Step.select => _buildSelectStep(typography, resources),
          _Step.importing => _buildImportingStep(typography, resources),
          _Step.done => _buildDoneStep(typography, resources),
        },
      ),
      actions: switch (_step) {
        _Step.select => [
            Button(
              onPressed: () => Navigator.pop(context),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed:
                  (_entries != null && _entries!.isNotEmpty && !_parsing)
                      ? _startImport
                      : null,
              child: Text(
                _entries != null
                    ? 'Import ${_entries!.length} to PDS'
                    : 'Import',
              ),
            ),
          ],
        _Step.importing => [
            Button(
              onPressed: () => setState(() => _cancelled = true),
              child: const Text('Cancel'),
            ),
          ],
        _Step.done => [
            FilledButton(
              onPressed: () => Navigator.pop(context),
              child: const Text('Close'),
            ),
          ],
      },
    );
  }

  Widget _buildSelectStep(Typography typography, ResourceDictionary resources) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          'Select your Spotify extended streaming history JSON files.',
          style: typography.body,
        ),
        const SizedBox(height: 4),
        Text(
          'Download from spotify.com/account/privacy',
          style: typography.caption?.apply(
            color: resources.textFillColorSecondary,
          ),
        ),
        const SizedBox(height: 16),
        FilledButton(
          onPressed: _parsing ? null : _pickFiles,
          child: _parsing
              ? const SizedBox.square(
                  dimension: 16, child: ProgressRing(strokeWidth: 2))
              : const Text('Select Files...'),
        ),
        if (_filePaths.isNotEmpty) ...[
          const SizedBox(height: 16),
          Text('Selected files:', style: typography.caption),
          const SizedBox(height: 4),
          for (final path in _filePaths)
            Padding(
              padding: const EdgeInsets.only(bottom: 2),
              child: Text(
                path.split(RegExp(r'[/\\]')).last,
                style: typography.caption?.apply(
                  color: resources.textFillColorSecondary,
                ),
              ),
            ),
        ],
        if (_entries != null) ...[
          const SizedBox(height: 12),
          Text(
            '$_rawCount total entries found',
            style: typography.body,
          ),
          Text(
            '${_entries!.length} after filtering (30s minimum${_includeSkipped ? '' : ', no skips'})',
            style: typography.caption?.apply(
              color: resources.textFillColorSecondary,
            ),
          ),
          if (_entries!.isNotEmpty) ...[
            const SizedBox(height: 4),
            Text(
              '${_formatDate(_entries!.first.timestamp)} — ${_formatDate(_entries!.last.timestamp)}',
              style: typography.caption?.apply(
                color: resources.textFillColorSecondary,
              ),
            ),
          ],
        ],
        if (_parseError != null) ...[
          const SizedBox(height: 12),
          InfoBar(
            title: Text(_parseError!),
            severity: InfoBarSeverity.error,
            isLong: false,
          ),
        ],
        if (_filePaths.isNotEmpty) ...[
          const SizedBox(height: 12),
          Checkbox(
            checked: _includeSkipped,
            content: const Text('Include skipped tracks'),
            onChanged: (v) {
              setState(() => _includeSkipped = v ?? false);
              if (_filePaths.isNotEmpty) _parseFiles();
            },
          ),
          const SizedBox(height: 16),
          InfoLabel(
            label: 'Bluesky handle',
            child: TextBox(
              controller: _handleController,
              placeholder: 'you.bsky.social',
            ),
          ),
          const SizedBox(height: 8),
          InfoLabel(
            label: 'App password',
            child: PasswordBox(
              controller: _passwordController,
              placeholder: 'Create one at bsky.app/settings/app-passwords',
            ),
          ),
          const SizedBox(height: 12),
          Checkbox(
            checked: _overwrite,
            content: const Text('Replace existing scrobbles at these times'),
            onChanged: (v) => setState(() => _overwrite = v ?? false),
          ),
          const SizedBox(height: 4),
          Text(
            _overwrite
                ? 'Existing records matching an imported timestamp will be '
                      'permanently deleted from your PDS before the import '
                      'writes. This cannot be undone.'
                : 'Leave off to add records only. Re-importing the same history '
                      'again will create duplicates.',
            style: typography.caption?.apply(
              color: _overwrite
                  ? resources.systemFillColorCritical
                  : resources.textFillColorSecondary,
            ),
          ),
          const SizedBox(height: 12),
          Checkbox(
            checked: _useSpotifyApi,
            content: const Text('Also use the Spotify Web API'),
            onChanged: (v) => setState(() => _useSpotifyApi = v ?? false),
          ),
          if (_useSpotifyApi) ...[
            const SizedBox(height: 4),
            Text(
              'MusicBrainz runs either way — album art, duration, track '
              'numbers and MBIDs.\n'
              'Spotify credentials add a faster bulk lookup, matched on the '
              'track IDs already in the history files. Without them this '
              'box changes nothing.',
              style: typography.caption?.apply(
                color: resources.textFillColorSecondary,
              ),
            ),
            const SizedBox(height: 8),
            InfoLabel(
              label: 'Spotify Client ID',
              child: TextBox(controller: _spotifyClientIdController),
            ),
            const SizedBox(height: 8),
            InfoLabel(
              label: 'Spotify Client Secret',
              child: PasswordBox(controller: _spotifyClientSecretController),
            ),
          ],
        ],
      ],
    );
  }

  Widget _buildImportingStep(
      Typography typography, ResourceDictionary resources) {
    final progress = _total > 0 ? _completed / _total : 0.0;

    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _cancelled ? 'Cancelling...' : _statusText,
          style: typography.body,
        ),
        const SizedBox(height: 16),
        ProgressBar(value: progress * 100),
        const SizedBox(height: 8),
        Text(
          '$_completed / $_total records',
          style: typography.caption?.apply(
            color: resources.textFillColorSecondary,
          ),
        ),
      ],
    );
  }

  Widget _buildDoneStep(Typography typography, ResourceDictionary resources) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          _cancelled ? 'Import cancelled.' : 'Import complete!',
          style: typography.body,
        ),
        const SizedBox(height: 8),
        Text(
          '$_succeeded scrobbles imported successfully.',
          style: typography.body,
        ),
        if (_failed > 0)
          Text(
            '$_failed failed.',
            style: typography.body?.apply(
              color: resources.systemFillColorCritical,
            ),
          ),
      ],
    );
  }

  String _formatDate(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }
}
