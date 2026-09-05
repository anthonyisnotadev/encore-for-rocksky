import 'package:flutter/foundation.dart';

class LogBuffer {
  static final LogBuffer instance = LogBuffer._();
  LogBuffer._();

  final List<String> _entries = [];
  final maxEntries = 200;

  /// Identifiers that must never survive into an exported log.
  ///
  /// Redaction happens here, at the sink, rather than at each call site. The
  /// DID rarely arrives as a field we control: it comes back inside PDS
  /// response bodies (`createRecord` returns `at://did:plc:.../rkey`, so a
  /// *successful* scrobble carries it), and inside `http` exception strings,
  /// which embed the request URI and therefore the `repo=` query parameter.
  /// Scrubbing per call site would cover today's lines and quietly regress on
  /// the next one added.
  static final _redactions = <RegExp, String>{
    // AT Protocol DIDs, plain and percent-encoded (query strings may escape
    // the colons), plus the did:web form used by self-hosted PDSes.
    RegExp(r'did:plc:[a-zA-Z0-9]+'): 'did:plc:[redacted]',
    RegExp(r'did%3Aplc%3A[a-zA-Z0-9]+', caseSensitive: false):
        'did%3Aplc%3A[redacted]',
    RegExp(r'did:web:[a-zA-Z0-9._%:-]+'): 'did:web:[redacted]',
    // Session tokens. Not logged deliberately anywhere today, but an error
    // body from createSession/refreshSession could carry one.
    RegExp(r'eyJ[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]{4,}\.[A-Za-z0-9_-]*'):
        '[jwt redacted]',
  };

  /// Strips account identifiers from [message].
  ///
  /// Exposed for tests; callers should just use [log].
  @visibleForTesting
  static String redact(String message) {
    var out = message;
    for (final entry in _redactions.entries) {
      out = out.replaceAll(entry.key, entry.value);
    }
    return out;
  }

  List<String> get entries => List.unmodifiable(_entries);

  void log(String message, {String name = ''}) {
    final ts = DateTime.now().toIso8601String().substring(11, 23);
    final prefix = '[$ts] ${name.isNotEmpty ? '$name: ' : ''}';
    final line = '$prefix${redact(message)}';
    _entries.add(line);
    if (_entries.length > maxEntries) _entries.removeAt(0);
    // The buffer backs both the on-screen log dialog and its Copy button, so
    // it holds only redacted text. Local debug runs still get the full line —
    // that output goes to the attached console, not to anything shareable.
    debugPrint(kDebugMode ? '$prefix$message' : line);
  }

  String export() => _entries.join('\n');

  void clear() => _entries.clear();
}
