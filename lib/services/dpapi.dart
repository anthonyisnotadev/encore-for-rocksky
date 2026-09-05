import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';

/// Windows Data Protection API — encryption whose key is held by the operating
/// system rather than by this app.
///
/// `CryptProtectData` derives a key from the signed-in user's credentials, so
/// the ciphertext can normally only be decrypted by the same Windows account on
/// the same machine. Nothing has to be stored alongside the data, which is the
/// point: an app with no key management has no key to leak.
///
/// What this defends against is a copied file — someone reading the settings
/// out of a backup, a shared PC, or a USB stick. It cannot defend against code
/// already running as the user, which can call `CryptUnprotectData` exactly as
/// this app does. Only a passphrase the user types would, and that is a
/// different trade — see `docs/authentication.md`.
class Dpapi {
  Dpapi._();

  /// Additional entropy mixed into the key.
  ///
  /// Not a secret — it ships inside the binary and anyone can read it out. It
  /// scopes the ciphertext to this app, so another program running as the same
  /// user cannot decrypt these blobs without at least having gone looking for
  /// it, and so blobs from a future unrelated use here cannot be confused with
  /// these. Changing it makes every existing saved session undecryptable.
  static final Uint8List _entropy =
      Uint8List.fromList(utf8.encode('encore-for-rocksky/pds-session/v1'));

  /// Never show a prompt. This is a tray app that starts with Windows and often
  /// has no window on screen; a modal from a background process would be both
  /// baffling and, from the user's point of view, unattributable.
  static const _uiForbidden = 0x1;

  /// Encrypts [plaintext], or returns null if Windows refused.
  static Uint8List? protect(Uint8List plaintext) =>
      _call(plaintext, encrypt: true);

  /// Decrypts [ciphertext], or returns null if it was not produced by this app
  /// under the current Windows account on this machine — the expected outcome
  /// for a copy carried to another PC, and for a corrupted or truncated blob,
  /// which the integrity check also rejects.
  static Uint8List? unprotect(Uint8List ciphertext) =>
      _call(ciphertext, encrypt: false);

  static Uint8List? _call(Uint8List input, {required bool encrypt}) {
    if (input.isEmpty) return null;

    return using((Arena arena) {
      final inputBytes = arena<Uint8>(input.length);
      inputBytes.asTypedList(input.length).setAll(0, input);
      final inputBlob = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = input.length
        ..ref.pbData = inputBytes;

      final entropyBytes = arena<Uint8>(_entropy.length);
      entropyBytes.asTypedList(_entropy.length).setAll(0, _entropy);
      final entropyBlob = arena<CRYPT_INTEGER_BLOB>()
        ..ref.cbData = _entropy.length
        ..ref.pbData = entropyBytes;

      final outputBlob = arena<CRYPT_INTEGER_BLOB>();
      final succeeded = encrypt
          ? CryptProtectData(inputBlob, nullptr, entropyBlob, nullptr, nullptr,
              _uiForbidden, outputBlob)
          : CryptUnprotectData(inputBlob, nullptr, entropyBlob, nullptr,
              nullptr, _uiForbidden, outputBlob);

      // The input buffer held either the tokens themselves or their ciphertext.
      // The arena will free it either way; overwriting first keeps the
      // plaintext from lingering in a freed page. Hygiene rather than a
      // guarantee — Dart's own copy of the same bytes is beyond reach.
      inputBytes.asTypedList(input.length).fillRange(0, input.length, 0);

      if (succeeded == 0) return null;

      final length = outputBlob.ref.cbData;
      final output =
          Uint8List.fromList(outputBlob.ref.pbData.asTypedList(length));
      // DPAPI allocates the output with LocalAlloc and hands over ownership.
      outputBlob.ref.pbData.asTypedList(length).fillRange(0, length, 0);
      LocalFree(outputBlob.ref.pbData);
      return output;
    });
  }
}
