import 'dart:convert';
import 'dart:typed_data';

import 'package:encore_for_rocksky/services/credential_store.dart';
import 'package:encore_for_rocksky/services/dpapi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// These run against the real DPAPI, not a fake. `flutter test` executes as the
/// signed-in Windows user, which is the same context the app runs in, so
/// `CryptProtectData` behaves here exactly as it does in production. Faking it
/// would leave the one thing worth checking — that what lands on disk is not
/// readable — untested.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const session = (
    pdsUrl: 'https://pds.example.com',
    accessJwt: 'eyJhbGciOiJIUzI1NiJ9.access-token-value.signature',
    refreshJwt: 'eyJhbGciOiJIUzI1NiJ9.refresh-token-value.signature',
    did: 'did:plc:abcdefghijklmnopqrstuvwx',
  );

  const storedKey = 'pds_session';
  const legacyKeys = <String>[
    'pds_url',
    'pds_access_jwt',
    'pds_refresh_jwt',
    'pds_did',
  ];

  group('Dpapi', () {
    test('round-trips a payload', () {
      final plaintext = Uint8List.fromList(utf8.encode('a secret'));
      final blob = Dpapi.protect(plaintext);

      expect(blob, isNotNull);
      expect(utf8.decode(Dpapi.unprotect(blob!)!), 'a secret');
    });

    test('produces ciphertext that does not contain the plaintext', () {
      final blob = Dpapi.protect(Uint8List.fromList(utf8.encode('hunter2')))!;

      expect(_containsBytes(blob, utf8.encode('hunter2')), isFalse);
    });

    test('rejects data it did not produce', () {
      // The integrity check fails rather than returning rubbish, which is what
      // lets the store treat "cannot decrypt" as "no session".
      expect(Dpapi.unprotect(Uint8List.fromList(List.filled(64, 7))), isNull);
    });

    test('refuses empty input rather than storing an empty blob', () {
      expect(Dpapi.protect(Uint8List(0)), isNull);
      expect(Dpapi.unprotect(Uint8List(0)), isNull);
    });
  });

  group('CredentialStore', () {
    setUp(() => SharedPreferences.setMockInitialValues({}));

    test('reports no session when nothing is stored', () async {
      expect(await CredentialStore.instance.load(), isNull);
    });

    test('round-trips a session', () async {
      expect(await CredentialStore.instance.save(session), isTrue);

      expect(await CredentialStore.instance.load(), session);
    });

    test('what reaches disk contains none of the tokens', () async {
      await CredentialStore.instance.save(session);
      final prefs = await SharedPreferences.getInstance();
      final stored = prefs.getString(storedKey)!;

      // This is the whole point of the class: someone reading
      // shared_preferences.json out of a backup or off a stick finds nothing
      // usable. Checked on the stored text and on its decoded bytes, so a
      // future change to the container cannot pass by accident.
      for (final secret in [session.accessJwt, session.refreshJwt, session.did]) {
        expect(stored, isNot(contains(secret)));
        expect(_containsBytes(base64Decode(stored), utf8.encode(secret)),
            isFalse);
      }
    });

    test('stores nothing under the old plaintext keys', () async {
      await CredentialStore.instance.save(session);
      final prefs = await SharedPreferences.getInstance();

      for (final key in legacyKeys) {
        expect(prefs.getString(key), isNull, reason: key);
      }
    });

    test('migrates a plaintext session from an older build', () async {
      SharedPreferences.setMockInitialValues({
        'pds_url': session.pdsUrl,
        'pds_access_jwt': session.accessJwt,
        'pds_refresh_jwt': session.refreshJwt,
        'pds_did': session.did,
      });

      // The user stays signed in across the upgrade...
      expect(await CredentialStore.instance.load(), session);

      final prefs = await SharedPreferences.getInstance();
      // ...and the plaintext they were signed in with is gone.
      for (final key in legacyKeys) {
        expect(prefs.getString(key), isNull, reason: key);
      }
      expect(prefs.getString(storedKey), isNotNull);
    });

    test('discards a half-written plaintext session instead of migrating it',
        () async {
      SharedPreferences.setMockInitialValues({
        'pds_url': session.pdsUrl,
        'pds_did': session.did,
      });

      expect(await CredentialStore.instance.load(), isNull);

      final prefs = await SharedPreferences.getInstance();
      for (final key in legacyKeys) {
        expect(prefs.getString(key), isNull, reason: key);
      }
    });

    test('drops a blob it cannot decrypt rather than retrying it forever',
        () async {
      // Stands in for a copy carried to another machine or Windows account.
      SharedPreferences.setMockInitialValues({
        storedKey: base64Encode(List.filled(64, 7)),
      });

      expect(await CredentialStore.instance.load(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(storedKey), isNull);
    });

    test('drops a blob that is not even base64', () async {
      SharedPreferences.setMockInitialValues({storedKey: 'not base64 !!!'});

      expect(await CredentialStore.instance.load(), isNull);
      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(storedKey), isNull);
    });

    test('signing out leaves nothing behind', () async {
      await CredentialStore.instance.save(session);
      await CredentialStore.instance.clear();

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString(storedKey), isNull);
      for (final key in legacyKeys) {
        expect(prefs.getString(key), isNull, reason: key);
      }
      expect(await CredentialStore.instance.load(), isNull);
    });
  });
}

/// Whether [haystack] contains [needle] as a contiguous run of bytes.
bool _containsBytes(List<int> haystack, List<int> needle) {
  if (needle.isEmpty || needle.length > haystack.length) return false;
  for (var start = 0; start <= haystack.length - needle.length; start++) {
    var matched = true;
    for (var i = 0; i < needle.length; i++) {
      if (haystack[start + i] != needle[i]) {
        matched = false;
        break;
      }
    }
    if (matched) return true;
  }
  return false;
}
