import 'package:encore_for_rocksky/services/log_buffer.dart';
import 'package:flutter_test/flutter_test.dart';

/// Covers redaction in [LogBuffer]. The debug log is copied to the clipboard
/// and pasted into bug reports, so it must not carry the account's DID.
///
/// The messages below reproduce the shapes the DID actually arrives in — PDS
/// response bodies and `http` exception text — rather than a bare `did:plc:`
/// literal, because those embedded paths are the ones a per-call-site scrub
/// would miss. The identifier itself is a placeholder, not a real account.
const _did = 'did:plc:aaaaaaaaaaaaaaaaaaaaaaaa';

void main() {
  group('redact', () {
    test('strips the DID from a successful createRecord body', () {
      // The 200 body from a scrobble write — this is the every-track leak.
      final line = LogBuffer.redact(
        'Direct PDS scrobble → 200: {"uri":"at://$_did/app.rocksky.scrobble/3kx7","cid":"bafyrei"}',
      );

      expect(line, isNot(contains(_did)));
      expect(line, contains('at://did:plc:[redacted]/app.rocksky.scrobble/'));
      // Non-identifying detail survives, or the log stops being useful.
      expect(line, contains('200'));
      expect(line, contains('bafyrei'));
    });

    test('strips the DID from an http exception carrying the request URI', () {
      final line = LogBuffer.redact(
        'listRecords error: ClientException with SocketException, '
        'uri=https://bsky.social/xrpc/com.atproto.repo.listRecords'
        '?repo=$_did&collection=app.rocksky.scrobble&limit=100',
      );

      expect(line, isNot(contains(_did)));
      expect(line, contains('repo=did:plc:[redacted]'));
      expect(line, contains('collection=app.rocksky.scrobble'));
    });

    test('strips percent-encoded DIDs', () {
      final line = LogBuffer.redact(
        'listRecords failed: repo=did%3Aplc%3Aaaaaaaaaaaaaaaaaaaaaaaaa',
      );

      expect(line, isNot(contains('aaaaaaaaaaaaaaaaaaaaaaaa')));
      expect(line, contains('did%3Aplc%3A[redacted]'));
    });

    test('strips did:web identifiers used by self-hosted PDSes', () {
      final line = LogBuffer.redact('Restored PDS session: did=did:web:pds.example.com');

      expect(line, isNot(contains('pds.example.com')));
      expect(line, contains('did:web:[redacted]'));
    });

    test('strips session tokens', () {
      const jwt = 'eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiJhYmMifQ.7Hk2Qm1nO4pR';
      final line = LogBuffer.redact('PDS auth failed: 400 {"accessJwt":"$jwt"}');

      expect(line, isNot(contains(jwt)));
      expect(line, contains('[jwt redacted]'));
    });

    test('leaves ordinary track metadata alone', () {
      // Guards against an over-broad pattern eating real log content: track and
      // artist names reach the log on every scrobble.
      const line = 'Created: Steely Dan — Did It Again';

      expect(LogBuffer.redact(line), line);
    });
  });

  group('log', () {
    setUp(() => LogBuffer.instance.clear());

    test('stores redacted text, so the buffer itself never holds the DID', () {
      LogBuffer.instance.log('About to write live PDS scrobble: did=$_did', name: 'pds');

      // export() backs both the log dialog and its Copy button.
      expect(LogBuffer.instance.export(), isNot(contains(_did)));
      expect(LogBuffer.instance.export(), contains('did:plc:[redacted]'));
      expect(LogBuffer.instance.entries.single, contains('pds: '));
    });

    test('keeps the buffer capped while redacting', () {
      for (var i = 0; i < LogBuffer.instance.maxEntries + 10; i++) {
        LogBuffer.instance.log('scrobble $i for $_did');
      }

      expect(LogBuffer.instance.entries, hasLength(LogBuffer.instance.maxEntries));
      expect(LogBuffer.instance.export(), isNot(contains(_did)));
    });
  });
}
