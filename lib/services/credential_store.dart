import 'dart:convert';
import 'dart:typed_data';

import 'package:shared_preferences/shared_preferences.dart';

import 'dpapi.dart';
import 'log_buffer.dart';

final _log = LogBuffer.instance;

/// The saved Bluesky session: everything needed to resume scrobbling without
/// the app password.
typedef PdsSession = ({
  String pdsUrl,
  String accessJwt,
  String refreshJwt,
  String did,
});

/// Reads and writes the saved PDS session, encrypted at rest.
///
/// The four values used to sit in `shared_preferences.json` as plain strings.
/// `refreshJwt` in particular is a bearer credential for the user's whole
/// repository — it mints access tokens indefinitely and authorises
/// `applyWrites#delete`, so a leaked copy can erase a scrobble history, not
/// merely add to it. They are now stored as a single [Dpapi]-protected blob.
///
/// The protection this gives is against the file being read somewhere it should
/// not be: a backup, a synced folder, another account on the same PC, a USB
/// stick. It cannot protect against code running as the user while the app
/// runs, which can ask Windows to decrypt exactly as this does. See
/// `docs/authentication.md`.
class CredentialStore {
  static final CredentialStore instance = CredentialStore._();
  CredentialStore._();

  /// Base64 of the DPAPI blob wrapping the session as JSON.
  static const _prefSession = 'pds_session';

  /// Keys that builds before encryption wrote in the clear. Read once so an
  /// upgrade does not sign the user out, then deleted.
  static const _legacyPdsUrl = 'pds_url';
  static const _legacyAccessJwt = 'pds_access_jwt';
  static const _legacyRefreshJwt = 'pds_refresh_jwt';
  static const _legacyDid = 'pds_did';

  static const _legacyKeys = <String>[
    _legacyPdsUrl,
    _legacyAccessJwt,
    _legacyRefreshJwt,
    _legacyDid,
  ];

  /// The saved session, or null when there is none to resume.
  ///
  /// Returns null rather than throwing whenever the stored blob cannot be read
  /// back — a copy carried to another machine or Windows account, a blob
  /// damaged in transit, a format from some future version. Every one of those
  /// means the same thing to the user: sign in again.
  Future<PdsSession?> load() async {
    final prefs = await SharedPreferences.getInstance();
    final stored = prefs.getString(_prefSession);
    if (stored != null) return _decrypt(stored, prefs);
    return _migrateLegacy(prefs);
  }

  /// Encrypts and stores [session], reporting whether it was saved.
  ///
  /// False means Windows refused to encrypt. Nothing is written in that case:
  /// falling back to plaintext would quietly undo the only thing this class is
  /// for. The consequence is that the session lasts until the app closes.
  Future<bool> save(PdsSession session) async {
    final plaintext = Uint8List.fromList(
      utf8.encode(
        json.encode(<String, String>{
          'pdsUrl': session.pdsUrl,
          'accessJwt': session.accessJwt,
          'refreshJwt': session.refreshJwt,
          'did': session.did,
        }),
      ),
    );

    final blob = Dpapi.protect(plaintext);
    plaintext.fillRange(0, plaintext.length, 0);

    if (blob == null) {
      _log.log(
        'Windows would not encrypt the session, so it has not been saved. '
        'Scrobbling continues until the app closes; signing in will be '
        'needed next time.',
        name: 'auth',
      );
      return false;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_prefSession, base64Encode(blob));
    return true;
  }

  /// Forgets the session, including any plaintext left by an older build.
  Future<void> clear() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove(_prefSession);
    await _removeLegacy(prefs);
  }

  Future<PdsSession?> _decrypt(String stored, SharedPreferences prefs) async {
    Uint8List? plaintext;
    try {
      plaintext = Dpapi.unprotect(base64Decode(stored));
    } on FormatException {
      plaintext = null;
    }

    if (plaintext == null) {
      _log.log(
        'The saved session could not be decrypted — it belongs to a different '
        'Windows account or machine, or it was damaged. Signing in again is '
        'needed.',
        name: 'auth',
      );
      // Dropping it keeps the app from retrying a blob that cannot ever work
      // on this machine, on every launch.
      await prefs.remove(_prefSession);
      return null;
    }

    final session = _parse(utf8.decode(plaintext, allowMalformed: true));
    plaintext.fillRange(0, plaintext.length, 0);

    if (session == null) {
      _log.log('The saved session was unreadable and has been discarded.',
          name: 'auth');
      await prefs.remove(_prefSession);
    }
    return session;
  }

  static PdsSession? _parse(String jsonText) {
    try {
      final decoded = json.decode(jsonText);
      if (decoded is! Map) return null;

      final pdsUrl = decoded['pdsUrl'];
      final accessJwt = decoded['accessJwt'];
      final refreshJwt = decoded['refreshJwt'];
      final did = decoded['did'];
      if (pdsUrl is! String ||
          accessJwt is! String ||
          refreshJwt is! String ||
          did is! String) {
        return null;
      }
      if (pdsUrl.isEmpty ||
          accessJwt.isEmpty ||
          refreshJwt.isEmpty ||
          did.isEmpty) {
        return null;
      }
      return (
        pdsUrl: pdsUrl,
        accessJwt: accessJwt,
        refreshJwt: refreshJwt,
        did: did,
      );
    } on FormatException {
      return null;
    }
  }

  /// Moves a session written in the clear by an older build into the encrypted
  /// key.
  ///
  /// The plaintext copies are deleted whether or not re-encrypting succeeded.
  /// Leaving them behind on a machine where DPAPI is unavailable would mean
  /// this upgrade silently kept storing credentials exactly as before, which is
  /// the one outcome worth avoiding; the session is still returned, so the
  /// current run carries on uninterrupted.
  Future<PdsSession?> _migrateLegacy(SharedPreferences prefs) async {
    final session = _parse(
      json.encode(<String, Object?>{
        'pdsUrl': prefs.getString(_legacyPdsUrl),
        'accessJwt': prefs.getString(_legacyAccessJwt),
        'refreshJwt': prefs.getString(_legacyRefreshJwt),
        'did': prefs.getString(_legacyDid),
      }),
    );

    if (session == null) {
      // No saved session, or a half-written one. Either way there is nothing
      // to keep, and stale keys should not sit around holding tokens.
      await _removeLegacy(prefs);
      return null;
    }

    await save(session);
    await _removeLegacy(prefs);
    _log.log('Existing session re-saved encrypted; the plaintext copy is gone.',
        name: 'auth');
    return session;
  }

  Future<void> _removeLegacy(SharedPreferences prefs) async {
    for (final key in _legacyKeys) {
      if (prefs.containsKey(key)) await prefs.remove(key);
    }
  }
}
