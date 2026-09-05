import 'dart:convert';

import 'package:encore_for_rocksky/services/pds_service.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

/// Covers [PdsService.deleteMatchingScrobbles], the only code in the app that
/// destroys user data. It issues `com.atproto.repo.applyWrites#delete` against
/// the user's own PDS and there is no undo, so the property that matters is
/// *selectivity*: it must delete records whose `createdAt` is in the requested
/// set and nothing else, and it must delete nothing at all when the scan fails.
///
/// `PdsService` calls the top-level `http.get`/`http.post` helpers, which
/// resolve their `Client` from the ambient zone, so `runWithClient` swaps in a
/// fake PDS without changing production code.

const _pdsUrl = 'https://pds.example.com';
const _did = 'did:plc:aaaaaaaaaaaaaaaaaaaaaaaa';

PdsService _service() => PdsService.fromSession(
  pdsUrl: _pdsUrl,
  accessJwt: 'access-token-not-a-jwt',
  refreshJwt: 'refresh-token-not-a-jwt',
  did: _did,
);

String _ts(int i) => '2026-01-01T00:00:00.${i.toString().padLeft(3, '0')}Z';

Map<String, dynamic> _record(String rkey, String? createdAt) => {
  'uri': 'at://$_did/app.rocksky.scrobble/$rkey',
  'cid': 'bafyreie$rkey',
  'value': {
    r'$type': 'app.rocksky.scrobble',
    'title': 'Track $rkey',
    'artist': 'Artist',
    'createdAt': ?createdAt,
  },
};

Map<String, dynamic> _page(
  List<Map<String, dynamic>> records, {
  String? cursor,
}) => {
  'records': records,
  'cursor': ?cursor,
};

/// A stand-in PDS that serves canned `listRecords` pages and records every
/// `applyWrites` payload it is handed.
class _FakePds {
  _FakePds(this.pages, {this.listStatus = 200, this.applyWritesStatusFor});

  /// `listRecords` bodies, served one per call in order.
  final List<Map<String, dynamic>> pages;
  final int listStatus;

  /// Status code for the nth `applyWrites` call (0-based). Defaults to 200.
  final int Function(int call)? applyWritesStatusFor;

  final List<Uri> listRequests = [];

  /// The `writes` array of each `applyWrites` request, in order.
  final List<List<Map<String, dynamic>>> writeBatches = [];

  /// Requests the service made that these tests did not anticipate. Asserted
  /// empty rather than thrown, because `deleteMatchingScrobbles` catches
  /// exceptions and would otherwise swallow the failure into a silent `break`.
  final List<Uri> unexpected = [];

  /// More `listRecords` calls than configured pages — a pagination bug.
  var pageOverruns = 0;

  http.Client build() => MockClient((req) async {
    final path = req.url.path;

    if (path.endsWith('com.atproto.repo.listRecords')) {
      listRequests.add(req.url);
      if (listStatus != 200) {
        return http.Response('{"error":"InternalServerError"}', listStatus);
      }
      final i = listRequests.length - 1;
      if (i >= pages.length) {
        pageOverruns++;
        return http.Response(jsonEncode(_page([])), 200);
      }
      return http.Response(jsonEncode(pages[i]), 200);
    }

    if (path.endsWith('com.atproto.repo.applyWrites')) {
      final body = jsonDecode(req.body) as Map<String, dynamic>;
      writeBatches.add((body['writes'] as List).cast<Map<String, dynamic>>());
      final status = applyWritesStatusFor?.call(writeBatches.length - 1) ?? 200;
      return http.Response('{}', status);
    }

    unexpected.add(req.url);
    return http.Response('{"error":"unexpected"}', 500);
  });

  /// Every rkey the service asked to delete, flattened in request order.
  List<String> get deletedRkeys =>
      writeBatches.expand((b) => b.map((w) => w['rkey'] as String)).toList();
}

Future<int> _run(_FakePds fake, Set<String> targets, {List<String>? status}) =>
    http.runWithClient(
      () => _service().deleteMatchingScrobbles(
        targets,
        onStatus: status?.add,
      ),
      fake.build,
    );

void main() {
  test('deletes only the records whose createdAt was asked for', () async {
    final fake = _FakePds([
      _page([
        _record('r1', _ts(1)),
        _record('r2', _ts(2)),
        _record('r3', _ts(3)),
        _record('r4', _ts(4)),
        _record('r5', _ts(5)),
      ]),
    ]);

    final statuses = <String>[];
    final deleted = await _run(fake, {_ts(2), _ts(4)}, status: statuses);

    expect(deleted, 2);
    expect(fake.deletedRkeys, ['r2', 'r4']);
    // The untargeted records must survive — this is the whole safety property.
    expect(fake.deletedRkeys, isNot(contains('r1')));
    expect(fake.deletedRkeys, isNot(contains('r3')));
    expect(fake.deletedRkeys, isNot(contains('r5')));
    expect(fake.unexpected, isEmpty);
    expect(statuses, contains('Scanning existing records...'));
    expect(statuses, contains('Deleting 2 existing records...'));
  });

  test('sends a well-formed applyWrites#delete for each match', () async {
    final fake = _FakePds([
      _page([_record('abc123', _ts(1))]),
    ]);

    await _run(fake, {_ts(1)});

    expect(fake.writeBatches.single.single, {
      r'$type': 'com.atproto.repo.applyWrites#delete',
      'collection': 'app.rocksky.scrobble',
      // rkey is the last segment of at://did/collection/rkey
      'rkey': 'abc123',
    });
  });

  test('issues no delete at all when nothing matches', () async {
    final fake = _FakePds([
      _page([_record('r1', _ts(1)), _record('r2', _ts(2))]),
    ]);

    final deleted = await _run(fake, {_ts(99)});

    expect(deleted, 0);
    expect(fake.writeBatches, isEmpty, reason: 'must not call applyWrites');
    expect(fake.unexpected, isEmpty);
  });

  test('deletes nothing when the scan fails', () async {
    // A failed listRecords must not be read as "no records exist".
    final fake = _FakePds([
      _page([_record('r1', _ts(1))]),
    ], listStatus: 500);

    final deleted = await _run(fake, {_ts(1)});

    expect(deleted, 0);
    expect(fake.writeBatches, isEmpty);
  });

  test('follows the cursor and accumulates matches across pages', () async {
    final fake = _FakePds([
      _page([_record('r1', _ts(1)), _record('r2', _ts(2))], cursor: 'c1'),
      _page([_record('r3', _ts(3))]),
    ]);

    final deleted = await _run(fake, {_ts(1), _ts(3)});

    expect(deleted, 2);
    expect(fake.deletedRkeys, ['r1', 'r3']);
    expect(fake.listRequests, hasLength(2));
    expect(fake.listRequests[1].query, contains('cursor=c1'));
    expect(fake.pageOverruns, 0);
  });

  test('stops scanning once every requested timestamp is found', () async {
    // Page one satisfies both targets, so the offered cursor is not followed.
    final fake = _FakePds([
      _page([_record('r1', _ts(1)), _record('r2', _ts(2))], cursor: 'c1'),
      _page([_record('r3', _ts(3))]),
    ]);

    final deleted = await _run(fake, {_ts(1), _ts(2)});

    expect(deleted, 2);
    expect(fake.listRequests, hasLength(1));
  });

  test('skips records with no createdAt instead of deleting them', () async {
    final fake = _FakePds([
      _page([_record('missing', null), _record('r1', _ts(1))]),
    ]);

    final deleted = await _run(fake, {_ts(1)});

    expect(deleted, 1);
    expect(fake.deletedRkeys, ['r1']);
    expect(fake.deletedRkeys, isNot(contains('missing')));
  });

  test('splits deletes into batches of 200', () async {
    final records = List.generate(250, (i) => _record('r$i', _ts(i)));
    final targets = List.generate(250, _ts).toSet();
    final fake = _FakePds([_page(records)]);

    final deleted = await _run(fake, targets);

    expect(deleted, 250);
    expect(fake.writeBatches.map((b) => b.length), [200, 50]);
    expect(fake.deletedRkeys, hasLength(250));
  });

  test('counts only the batches the PDS actually accepted', () async {
    final records = List.generate(250, (i) => _record('r$i', _ts(i)));
    final targets = List.generate(250, _ts).toSet();
    final fake = _FakePds([
      _page(records),
    ], applyWritesStatusFor: (call) => call == 1 ? 400 : 200);

    final deleted = await _run(fake, targets);

    expect(deleted, 200, reason: 'the rejected batch must not be counted');
    expect(fake.writeBatches, hasLength(2));
  });
}
