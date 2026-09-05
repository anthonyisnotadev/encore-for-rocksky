import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'package:fluent_ui/fluent_ui.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import '../feature_flags.dart';
import '../models/track_info.dart';
import '../services/browser.dart';
import '../services/credential_store.dart';
import '../services/log_buffer.dart';
import '../services/media_watcher_service.dart';
import '../services/pds_service.dart';
import '../services/notification_service.dart';
import 'spotify_import_dialog.dart';

final _log = LogBuffer.instance;

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {

  /// Bluesky's app-password management page, opened for the user when the
  /// saved session turns out to be dead and a new app password is needed.
  static const _appPasswordsUrl = 'https://bsky.app/settings/app-passwords';

  /// Keys written by earlier builds that could scrobble through the Rocksky
  /// API. Scrobbles now go only to the user's Bluesky PDS, so these are purged
  /// on launch and on sign-out rather than left sitting on disk.
  static const _legacyPrefKeys = <String>[
    'rocksky_api_key',
    'rocksky_shared_secret',
    'rocksky_session_key',
    'use_direct_pds_writes',
  ];

  // Auth
  PdsService? _pdsService;
  final _handleController = TextEditingController();
  final _appPasswordController = TextEditingController();

  // Auth flow state
  bool _busy = false;
  String? _authError;

  /// True until a restored session has been checked against the PDS. The
  /// sign-in form stays disabled meanwhile, so a sign-in started mid-check
  /// cannot be wiped by the check's conclusion arriving afterwards.
  bool _restoringSession = true;

  /// Guards the expired-session dialog against the service firing
  /// [PdsService.onSessionInvalid] again while it is already up.
  bool _sessionExpiredDialogShowing = false;

  // Media
  final _watcher = MediaWatcherService();

  // Scrobble state
  TrackInfo? _currentTrack;
  Timer? _scrobbleTimer;
  Timer? _countdownTimer;
  bool _scrobbled = false;
  String? _scrobbleError;
  int _secondsLeft = 0;

  // In-memory history
  final List<({TrackInfo track, DateTime time})> _history = [];

  @override
  void initState() {
    super.initState();
    _loadCredentials();
  }

  Future<void> _loadCredentials() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      for (final key in _legacyPrefKeys) {
        await prefs.remove(key);
      }
      if (!mounted) return;

      // Decrypts, and migrates a plaintext session from an older build.
      // Returns null for anything unreadable, which lands the user on the
      // sign-in form.
      final session = await CredentialStore.instance.load();
      if (session == null || !mounted) return;

      final service = PdsService.fromSession(
        pdsUrl: session.pdsUrl,
        accessJwt: session.accessJwt,
        refreshJwt: session.refreshJwt,
        did: session.did,
        onSessionRefreshed: _savePdsSession,
        onSessionInvalid: _onPdsSessionInvalid,
      );

      // Prove the session still works before scrobbling depends on it.
      // Without this a revoked app password would surface only as a silent
      // stream of failed scrobbles. The service fires onSessionInvalid as
      // well when the check is rejected; it is ignored here because
      // _pdsService is still null — this branch is the handler.
      final validity = await service.checkSession();
      if (!mounted) return;

      if (validity == PdsSessionValidity.invalid) {
        // The refresh token is dead and no retry can revive it. Drop the
        // saved copy and ask for a new app password.
        _log.log(
          'Saved session is no longer valid; it has been discarded',
          name: 'auth',
        );
        await CredentialStore.instance.clear();
        _showSessionExpiredDialog();
        return;
      }

      if (validity == PdsSessionValidity.unverified) {
        // Network or PDS trouble — not proof the session is bad. Resume and
        // let the first real write decide; a genuine rejection there lands
        // in _onPdsSessionInvalid.
        _log.log(
          'Saved session could not be verified (network?); resuming anyway',
          name: 'auth',
        );
      }

      setState(() {
        _pdsService = service;
        _restoringSession = false;
      });
      _startWatcher();
    } finally {
      if (mounted) setState(() => _restoringSession = false);
    }
  }

  /// Fired when the PDS rejects the refresh token mid-run: the app password
  /// was revoked, or the session expired while the app sat closed. Signing
  /// out is not optional here — the saved tokens can never work again — so
  /// unlike the manual sign-out there is no confirmation step, just an
  /// explanation and a shortcut to a new app password.
  Future<void> _onPdsSessionInvalid(PdsService service) async {
    // Ignore if the dead session has already been replaced or removed (the
    // startup check routes through here while _pdsService is still null).
    if (!mounted || _pdsService != service) return;
    _teardownWatcher();
    await CredentialStore.instance.clear();
    if (!mounted) return;
    _resetSessionState();
    _showSessionExpiredDialog();
  }

  /// Tells the user scrobbling stopped and why, and offers the Bluesky
  /// app-passwords page. The app is already back on the sign-in form by the
  /// time this is up — clicking either button leaves them there.
  void _showSessionExpiredDialog() {
    if (!mounted || _sessionExpiredDialogShowing) return;
    _sessionExpiredDialogShowing = true;
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Bluesky session expired'),
        content: const Text(
          'Your saved Bluesky session is no longer valid — the app password '
          'was revoked or has expired, so scrobbles have stopped.\n\n'
          'Create a new app password, then sign in again to resume.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
          FilledButton(
            onPressed: () {
              openInBrowser(_appPasswordsUrl);
              Navigator.pop(ctx);
            },
            child: const Text('Open app passwords'),
          ),
        ],
      ),
    ).whenComplete(() => _sessionExpiredDialogShowing = false);
  }

  bool get _isConnected => _pdsService != null;

  void _startWatcher() {
    if (_pdsService == null) return;

    _watcher.trackNotifier.removeListener(_onTrackChanged);
    _watcher.trackNotifier.addListener(_onTrackChanged);
    _watcher.onRepeatDetected = _onRepeatDetected;
    _watcher.start();
  }

  void _onTrackChanged() {
    final next = _watcher.trackNotifier.value;

    if (next == null) {
      _cancelTimer();
      setState(() => _currentTrack = null);
      return;
    }

    if (next.isSameTrack(_currentTrack)) {
      // Same track — update art, playback status or a late-arriving track
      // length without resetting the timer.
      final wasPlaying = _currentTrack?.isPlaying ?? false;
      if (next.artBytes != null && _currentTrack?.artBytes == null ||
          next.isPlaying != _currentTrack?.isPlaying ||
          next.durationMs != null && _currentTrack?.durationMs == null) {
        setState(() => _currentTrack = next);
      }
      // The 30 seconds are listening time, not wall-clock time: pausing
      // drops the pending scrobble, and resuming re-arms it from the full
      // 30 seconds.
      if (wasPlaying && !next.isPlaying) {
        _cancelTimer();
      } else if (!wasPlaying &&
          next.isPlaying &&
          !_scrobbled &&
          _scrobbleTimer == null) {
        setState(() => _secondsLeft = 30);
        _startCountdown(next);
      }
      return;
    }

    _cancelTimer();

    setState(() {
      _currentTrack = next;
      _scrobbled = false;
      _scrobbleError = null;
      _secondsLeft = 30;
    });

    // Fetch cover art from iTunes if SMTC didn't provide it.
    if (next.artBytes == null) {
      _fetchCoverArt(next);
    }

    // A track that arrives paused (every watched player paused) is not a
    // listen in progress — arming the timer here would write it 30 seconds
    // later no matter how long it stays paused.
    if (next.isPlaying) _startCountdown(next);
  }

  bool get _canWriteScrobble => _pdsService != null;

  void _onRepeatDetected() {
    if (!mounted || _currentTrack == null || !_canWriteScrobble) return;
    // A paused session can reset its SMTC timeline without the song
    // playing; only a playing track restarting counts as a repeat listen.
    if (!_currentTrack!.isPlaying) return;

    _cancelTimer();

    setState(() {
      _scrobbled = false;
      _scrobbleError = null;
      _secondsLeft = 30;
    });

    _startCountdown(_currentTrack!);
  }

  /// Arms the 30-second scrobble timer and its visible countdown for a
  /// track that is currently playing. The timer only writes the scrobble
  /// if the same track is still playing when it fires.
  void _startCountdown(TrackInfo track) {
    final start = DateTime.now();
    _countdownTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (!mounted) return;
      setState(() {
        if (_secondsLeft > 0) _secondsLeft--;
      });
    });

    _scrobbleTimer = Timer(const Duration(seconds: 30), () async {
      if (!mounted) return;
      if (_currentTrack?.isSameTrack(track) == true &&
          _currentTrack?.isPlaying == true &&
          !_scrobbled &&
          _canWriteScrobble) {
        _countdownTimer?.cancel();
        // Prefer `_currentTrack`: same song, but it may have picked up a
        // track length that SMTC did not report at detection time.
        await _scrobbleWithRetry(_currentTrack ?? track, start, retries: 3);
      }
    });
  }

  Future<void> _fetchCoverArt(TrackInfo track) async {
    try {
      final query = Uri.encodeComponent('${track.artist} ${track.title}');
      final resp = await http.get(
        Uri.parse(
          'https://itunes.apple.com/search?term=$query&media=music&entity=song&limit=1',
        ),
      );
      if (resp.statusCode != 200) return;

      final data = jsonDecode(resp.body);
      final results = data['results'] as List?;
      if (results == null || results.isEmpty) return;

      var artUrl = results[0]['artworkUrl100'] as String?;
      if (artUrl == null) return;
      artUrl = artUrl.replaceAll('100x100bb', '600x600bb');

      final imgResp = await http.get(Uri.parse(artUrl));
      if (imgResp.statusCode != 200 || imgResp.bodyBytes.isEmpty) return;
      if (!mounted || !track.isSameTrack(_currentTrack)) return;
      if (_currentTrack?.artBytes != null) return; // SMTC art arrived first

      setState(() {
        _currentTrack = TrackInfo(
          title: _currentTrack!.title,
          artist: _currentTrack!.artist,
          album: _currentTrack!.album,
          artBytes: imgResp.bodyBytes,
          isPlaying: _currentTrack!.isPlaying,
        );
      });
    } catch (_) {}
  }

  Future<void> _scrobbleWithRetry(
    TrackInfo track,
    DateTime start, {
    required int retries,
  }) async {
    const lastError = 'Direct Bluesky PDS write failed';

    for (var attempt = 1; attempt <= retries; attempt++) {
      if (!mounted || _scrobbled) return;
      if (_currentTrack?.isSameTrack(track) != true) return;

      // Re-read every attempt — the user may sign out mid-retry.
      final pds = _pdsService;
      if (pds == null) return;

      setState(() {
        _scrobbleError = attempt > 1 ? 'Retry $attempt/$retries...' : null;
        _secondsLeft = 0;
      });

      LogBuffer.instance.log(
        'Enriching live PDS scrobble: ${track.artist} — ${track.title}',
        name: 'enrich',
      );

      final success = await pds.writeScrobble(track, start);
      // A failed write can be the one that got the session revoked; either
      // way, signed out means this loop's remaining attempts are moot.
      if (!mounted || _pdsService == null) return;

      if (success) {
        setState(() {
          _scrobbled = true;
          _scrobbleError = null;
          _history.insert(0, (track: _currentTrack ?? track, time: start));
          if (_history.length > 10) _history.removeLast();
        });
        NotificationService.instance.showScrobbled(track);
        return;
      }

      if (attempt < retries) {
        final delay = Duration(seconds: 5 * attempt);
        setState(
          () => _scrobbleError = '$lastError — retrying in ${delay.inSeconds}s',
        );
        await Future.delayed(delay);
      } else {
        setState(() => _scrobbleError = lastError);
        NotificationService.instance.showScrobbleFailed(track, lastError);
      }
    }
  }

  void _cancelTimer() {
    _scrobbleTimer?.cancel();
    _scrobbleTimer = null;
    _countdownTimer?.cancel();
    _countdownTimer = null;
  }

  void _togglePlayPause() {
    MediaWatcherService.controlPlayback('toggle');
    if (_currentTrack != null) {
      setState(() {
        _currentTrack = TrackInfo(
          title: _currentTrack!.title,
          artist: _currentTrack!.artist,
          album: _currentTrack!.album,
          artBytes: _currentTrack!.artBytes,
          isPlaying: !_currentTrack!.isPlaying,
        );
      });
    }
  }

  Future<void> _connect() async {
    // A session restore is still being checked against the PDS; letting a
    // sign-in through now would race the check's conclusion, which may
    // clear the store it just saved into.
    if (_restoringSession) return;

    final handle = _handleController.text.trim();
    final appPassword = _appPasswordController.text.trim();

    if (handle.isEmpty) {
      setState(() => _authError = 'Bluesky handle is required');
      return;
    }
    if (appPassword.isEmpty) {
      setState(() => _authError = 'Bluesky app password is required');
      return;
    }

    setState(() {
      _busy = true;
      _authError = null;
    });

    final pdsService = await PdsService.login(
      handle: handle,
      appPassword: appPassword,
      onSessionRefreshed: _savePdsSession,
      onSessionInvalid: _onPdsSessionInvalid,
    );
    if (!mounted) return;

    if (pdsService == null) {
      setState(() {
        _busy = false;
        _authError =
            'PDS authorization failed — check your handle and app password';
      });
      return;
    }

    await _savePdsSession(pdsService);
    if (!mounted) return;

    setState(() {
      _pdsService = pdsService;
      _busy = false;
    });
    _appPasswordController.clear();
    _startWatcher();
  }

  Future<void> _savePdsSession(PdsService service) async {
    // A false result is already logged by the store. Scrobbling still works
    // this session; only resuming it after a restart is lost.
    await CredentialStore.instance.save((
      pdsUrl: service.pdsUrl,
      accessJwt: service.accessJwt,
      refreshJwt: service.refreshJwt,
      did: service.did,
    ));
  }

  /// Confirms before signing out — the saved PDS session is discarded and the
  /// user has to re-enter their handle and app password to come back.
  Future<void> _confirmDisconnect(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Sign out?'),
        content: const Text(
          'This removes the saved Bluesky session from this device and stops '
          'scrobbling. You will need your handle and app password to sign '
          'back in.',
        ),
        actions: [
          Button(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Sign out'),
          ),
        ],
      ),
    );

    if (confirmed == true) await _disconnect();
  }

  Future<void> _disconnect() async {
    _teardownWatcher();
    await CredentialStore.instance.clear();
    final prefs = await SharedPreferences.getInstance();
    for (final key in _legacyPrefKeys) {
      await prefs.remove(key);
    }
    if (!mounted) return;
    _resetSessionState();
  }

  /// Stops listening for tracks and drops the session client. Shared by the
  /// confirmed sign-out and the forced sign-out when the PDS rejects the
  /// saved session.
  void _teardownWatcher() {
    _watcher.trackNotifier.removeListener(_onTrackChanged);
    _watcher.onRepeatDetected = null;
    _watcher.stop();
    _cancelTimer();
  }

  /// Puts the UI back on the sign-in form with no trace of the previous
  /// session.
  void _resetSessionState() {
    setState(() {
      _pdsService = null;
      _currentTrack = null;
      _scrobbled = false;
      _scrobbleError = null;
      _secondsLeft = 0;
      _authError = null;
      _history.clear();
      _handleController.clear();
      _appPasswordController.clear();
    });
  }

  void _showLogs(BuildContext context) {
    final outerContext = context;
    final logs = LogBuffer.instance.export();
    showDialog(
      context: context,
      builder: (ctx) => ContentDialog(
        title: const Text('Debug Logs'),
        content: SizedBox(
          width: 500,
          height: 400,
          child: SelectionArea(
            child: SingleChildScrollView(
              reverse: true,
              child: Text(
                logs.isEmpty ? 'No logs yet.' : logs,
                style: const TextStyle(fontSize: 11, fontFamily: 'Consolas'),
              ),
            ),
          ),
        ),
        actions: [
          Button(
            onPressed: () {
              Clipboard.setData(ClipboardData(text: logs));
              displayInfoBar(
                outerContext,
                builder: (context, close) {
                  return InfoBar(
                    title: const Text('Copied to clipboard'),
                    severity: InfoBarSeverity.success,
                    onClose: close,
                  );
                },
              );
            },
            child: const Text('Copy'),
          ),
          Button(
            onPressed: () {
              LogBuffer.instance.clear();
              Navigator.pop(ctx);
            },
            child: const Text('Clear'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  void dispose() {
    _watcher.trackNotifier.removeListener(_onTrackChanged);
    _watcher.onRepeatDetected = null;
    _watcher.stop();
    _cancelTimer();
    _handleController.dispose();
    _appPasswordController.dispose();
    super.dispose();
  }

  // ─── Top action bar ──────────────────────────────────────────────────────────

  Widget _buildTopBar(BuildContext context, bool overlay) {
    final color = overlay ? const Color(0xB3FFFFFF) : null;
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 0),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Tooltip(
            message: 'Debug logs',
            child: IconButton(
              icon: Icon(FluentIcons.bug, color: color, size: 14),
              onPressed: () => _showLogs(context),
            ),
          ),
          if (_isConnected) ...[
            // Experimental; absent from default builds. See feature_flags.dart.
            if (kSpotifyImportEnabled)
              Tooltip(
                message: 'Import Spotify history (experimental)',
                child: IconButton(
                  icon: Icon(FluentIcons.import, color: color, size: 14),
                  onPressed: () => showDialog(
                    context: context,
                    builder: (_) => const SpotifyImportDialog(),
                  ),
                ),
              ),
            ValueListenableBuilder<bool>(
              valueListenable: NotificationService.instance.enabled,
              builder: (context, enabled, _) => Tooltip(
                message: enabled
                    ? 'Scrobble notifications on'
                    : 'Scrobble notifications off',
                child: IconButton(
                  icon: Icon(
                    enabled ? FluentIcons.ringer : FluentIcons.ringer_off,
                    color: color,
                    size: 14,
                  ),
                  onPressed: () =>
                      NotificationService.instance.setEnabled(!enabled),
                ),
              ),
            ),
            Tooltip(
              message: 'Sign out',
              child: IconButton(
                icon: Icon(FluentIcons.sign_out, color: color, size: 14),
                onPressed: () => _confirmDisconnect(context),
              ),
            ),
          ],
        ],
      ),
    );
  }

  // ─── Build ───────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    // Setup view — form on Mica background.
    if (!_isConnected) {
      return ScaffoldPage(
        content: Column(
          children: [
            _buildTopBar(context, false),
            Expanded(
              child: _SetupView(
                handleController: _handleController,
                appPasswordController: _appPasswordController,
                busy: _busy || _restoringSession,
                error: _authError,
                onConnect: _connect,
              ),
            ),
          ],
        ),
      );
    }

    // Mini-player view.
    final hasTrack = _currentTrack != null;
    final hasArt = _currentTrack?.artBytes != null;

    return ScaffoldPage(
      padding: EdgeInsets.zero,
      content: Stack(
        fit: StackFit.expand,
        children: [
          // Layer 1: Album art (full bleed).
          if (hasArt)
            Image.memory(
              _currentTrack!.artBytes!,
              fit: BoxFit.cover,
              gaplessPlayback: true,
            ),

          // Layer 2: Dark gradient overlay.
          if (hasTrack)
            const DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  stops: [0.15, 0.65],
                  colors: [Color(0x00000000), Color(0xE0000000)],
                ),
              ),
            ),

          // Layer 3: Content.
          Column(
            children: [
              _buildTopBar(context, hasTrack),
              if (hasTrack) ...[
                const Spacer(),
                _buildTrackInfo(),
                const SizedBox(height: 24),
                _buildPlaybackControls(),
                const SizedBox(height: 16),
                _StatusChip(
                  scrobbled: _scrobbled,
                  secondsLeft: _secondsLeft,
                  paused: _currentTrack != null && !_currentTrack!.isPlaying,
                ),
                if (_scrobbleError != null) ...[
                  const SizedBox(height: 6),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Text(
                      _scrobbleError!,
                      style: const TextStyle(
                        color: Color(0x99FFFFFF),
                        fontSize: 12,
                      ),
                      textAlign: TextAlign.center,
                    ),
                  ),
                ],
                const SizedBox(height: 24),
              ] else
                Expanded(child: _buildNothingPlaying(context)),
            ],
          ),
        ],
      ),
    );
  }

  // ─── Track info ──────────────────────────────────────────────────────────────

  Widget _buildTrackInfo() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            _currentTrack!.title,
            style: const TextStyle(
              color: Color(0xFFFFFFFF),
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
            textAlign: TextAlign.center,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 4),
          Text(
            _currentTrack!.album.isNotEmpty
                ? '${_currentTrack!.artist} — ${_currentTrack!.album}'
                : _currentTrack!.artist,
            style: const TextStyle(color: Color(0xB3FFFFFF), fontSize: 14),
            textAlign: TextAlign.center,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ],
      ),
    );
  }

  // ─── Playback controls ─────────────────────────────────────────────────────

  Widget _buildPlaybackControls() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        IconButton(
          icon: const Icon(
            FluentIcons.previous,
            color: Color(0xFFFFFFFF),
            size: 24,
          ),
          onPressed: () => MediaWatcherService.controlPlayback('previous'),
        ),
        const SizedBox(width: 24),
        IconButton(
          icon: Icon(
            _currentTrack!.isPlaying ? FluentIcons.pause : FluentIcons.play,
            color: const Color(0xFFFFFFFF),
            size: 36,
          ),
          onPressed: _togglePlayPause,
        ),
        const SizedBox(width: 24),
        IconButton(
          icon: const Icon(
            FluentIcons.next,
            color: Color(0xFFFFFFFF),
            size: 24,
          ),
          onPressed: () => MediaWatcherService.controlPlayback('next'),
        ),
      ],
    );
  }

  // ─── Nothing playing ──────────────────────────────────────────────────────

  Widget _buildNothingPlaying(BuildContext context) {
    final theme = FluentTheme.of(context);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            FluentIcons.music_note,
            size: 48,
            color: theme.resources.textFillColorSecondary,
          ),
          const SizedBox(height: 8),
          Text(
            'Nothing playing',
            style: theme.typography.body?.apply(
              color: theme.resources.textFillColorSecondary,
            ),
          ),
        ],
      ),
    );
  }
}

// ─── Setup view ──────────────────────────────────────────────────────────────

class _SetupView extends StatefulWidget {
  final TextEditingController handleController;
  final TextEditingController appPasswordController;
  final bool busy;
  final String? error;
  final VoidCallback onConnect;

  const _SetupView({
    required this.handleController,
    required this.appPasswordController,
    required this.busy,
    required this.error,
    required this.onConnect,
  });

  @override
  State<_SetupView> createState() => _SetupViewState();
}

class _SetupViewState extends State<_SetupView> {
  /// Held here so Enter in the handle field moves to the password field rather
  /// than just dropping focus.
  final _passwordFocus = FocusNode();

  @override
  void dispose() {
    _passwordFocus.dispose();
    super.dispose();
  }

  void _submit() {
    if (!widget.busy) widget.onConnect();
  }

  @override
  Widget build(BuildContext context) {
    final theme = FluentTheme.of(context);
    final typography = theme.typography;
    final resources = theme.resources;

    // A 400px outer window leaves roughly 330 logical pixels here once the
    // caption and the top bar are taken out, so the vertical budget is the
    // binding constraint: the art plate sits beside the title rather than above
    // it, and the long-form trust copy is footer-weight. Below ~300 the plate
    // goes entirely, and the scroll view catches whatever is left over.
    return LayoutBuilder(
      builder: (context, constraints) {
        final showPlate = constraints.maxHeight >= 300;

        return Center(
          child: SingleChildScrollView(
            padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Row(
                    children: [
                      if (showPlate) ...[
                        const _ArtPlate(),
                        const SizedBox(width: 14),
                      ],
                      Expanded(
                        child: Text(
                          'Sign in to track music',
                          style: typography.subtitle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 24),
                  InfoLabel(
                    label: 'Bluesky handle',
                    child: TextBox(
                      controller: widget.handleController,
                      placeholder: 'you.bsky.social',
                      autofocus: true,
                      enabled: !widget.busy,
                      prefix: Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: Text(
                          '@',
                          style: TextStyle(
                            color: resources.textFillColorTertiary,
                          ),
                        ),
                      ),
                      onSubmitted: (_) => _passwordFocus.requestFocus(),
                    ),
                  ),
                  const SizedBox(height: 10),
                  InfoLabel(
                    label: 'App password',
                    child: PasswordBox(
                      controller: widget.appPasswordController,
                      focusNode: _passwordFocus,
                      enabled: !widget.busy,
                      placeholder: 'xxxx-xxxx-xxxx-xxxx',
                      onSubmitted: (_) => _submit(),
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'From Bluesky settings. Never your account password.',
                    style: typography.caption?.apply(
                      color: resources.textFillColorSecondary,
                    ),
                  ),
                  if (widget.error != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 10),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Icon(
                            FluentIcons.error_badge,
                            size: 12,
                            color: resources.systemFillColorCritical,
                          ),
                          const SizedBox(width: 6),
                          Expanded(
                            child: Text(
                              widget.error!,
                              style: typography.caption?.apply(
                                color: resources.systemFillColorCritical,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  const SizedBox(height: 14),
                  FilledButton(
                    onPressed: widget.busy ? null : widget.onConnect,
                    child: widget.busy
                        ? const Row(
                            mainAxisSize: MainAxisSize.min,
                            mainAxisAlignment: MainAxisAlignment.center,
                            children: [
                              SizedBox.square(
                                dimension: 14,
                                child: ProgressRing(strokeWidth: 2),
                              ),
                              SizedBox(width: 8),
                              Text('Signing in'),
                            ],
                          )
                        : const Text('Sign in'),
                  ),
                  const SizedBox(height: 14),
                  Text(
                    'Independent and unofficial — not affiliated with Bluesky '
                    'or Rocksky. Scrobbles go only to your own PDS, as '
                    'app.rocksky.scrobble records.',
                    style: typography.caption?.apply(
                      color: resources.textFillColorTertiary,
                    ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }
}

// ─── Art plate ───────────────────────────────────────────────────────────────

/// The album-art square from the mini-player, shown empty at sign-in with a
/// four-bar equaliser in the system accent colour. Same geometry the cover art
/// fills once a track is playing, so setup reads as the same app rather than a
/// settings pane bolted onto the front.
class _ArtPlate extends StatefulWidget {
  const _ArtPlate();

  @override
  State<_ArtPlate> createState() => _ArtPlateState();
}

class _ArtPlateState extends State<_ArtPlate>
    with SingleTickerProviderStateMixin {
  static const _side = 56.0;

  /// Resting heights as a fraction of the bar track. Doubles as the static
  /// shape drawn under reduced motion.
  static const _rest = <double>[0.5, 0.85, 0.35, 0.65];

  late final AnimationController _controller = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2400),
  );

  @override
  void initState() {
    super.initState();
    _controller.repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = FluentTheme.of(context).accentColor;
    // Honours the Windows "show animations" setting, which Flutter surfaces as
    // disableAnimations — the bars fall back to their resting heights.
    final animate = !MediaQuery.disableAnimationsOf(context);

    return Container(
      width: _side,
      height: _side,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [accent.dark, accent.darker],
        ),
        boxShadow: [
          BoxShadow(
            color: accent.darkest.withValues(alpha: 0.3),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: Center(
        child: SizedBox(
          width: 28,
          height: 22,
          child: AnimatedBuilder(
            animation: _controller,
            builder: (context, _) => Row(
              crossAxisAlignment: CrossAxisAlignment.end,
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: List.generate(_rest.length, (i) {
                // Each bar runs the same cycle a beat behind the last, so the
                // group reads as one travelling wave, not four blinkers.
                final phase = (_controller.value + i / _rest.length) * 2 * pi;
                final swing = animate ? sin(phase) * 0.3 : 0.0;
                return _EqualiserBar(
                  fraction: (_rest[i] + swing).clamp(0.15, 1.0),
                );
              }),
            ),
          ),
        ),
      ),
    );
  }
}

class _EqualiserBar extends StatelessWidget {
  final double fraction;
  const _EqualiserBar({required this.fraction});

  @override
  Widget build(BuildContext context) {
    return FractionallySizedBox(
      heightFactor: fraction,
      child: Container(
        width: 4,
        decoration: BoxDecoration(
          color: const Color(0xE6FFFFFF),
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}
// ─── Status chip (overlay style) ─────────────────────────────────────────────

class _StatusChip extends StatelessWidget {
  final bool scrobbled;
  final int secondsLeft;
  final bool paused;
  const _StatusChip({
    required this.scrobbled,
    required this.secondsLeft,
    this.paused = false,
  });

  @override
  Widget build(BuildContext context) {
    final waiting = !scrobbled && !paused && secondsLeft > 0;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
      decoration: BoxDecoration(
        color: scrobbled ? const Color(0x33FFFFFF) : const Color(0x1AFFFFFF),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            scrobbled ? FluentIcons.check_mark : FluentIcons.clock,
            size: 12,
            color: const Color(0xFFFFFFFF),
          ),
          const SizedBox(width: 4),
          Text(
            scrobbled
                ? 'Scrobbled'
                : paused
                ? 'Paused'
                : waiting
                ? '${secondsLeft}s'
                : 'Waiting',
            style: const TextStyle(color: Color(0xFFFFFFFF), fontSize: 12),
          ),
        ],
      ),
    );
  }
}
