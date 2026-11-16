part of 'orchard_service.dart';

// Team session logs (3.0). A Crate setting in the Orchard's record
// (crate.set session_logs), owners only, off until turned on; every member
// who can open the Crate is told, and their app shows that a session is
// logged before and during it. While on, the device logging a session sends
// a header (who, which host, when) and then what the session shows, as text
// with the escape sequences taken out ([TerminalTextFilter]), redacted
// ([SessionLogRedactor]: known credentials and sensitive fields; terminal
// output may still contain sensitive information), in chunks sealed with the
// Crate's key and bound to the log and their place in it, in order. Owners
// and those who manage the Crate read them; the server cannot. A log whose
// device went away before it ended says so: it was never closed.
//
// What a device seals is kept in the Orchard's own database first and taken
// out once the server has it (3.0, the outage work): a session to a host of
// a Crate that logs is logged whether or not ZestSSH Cloud can be reached,
// and what could not be sent goes later, from the session itself or with a
// sync ([OrchardTeamSessionLogs.sessionLogRound]), in this run of the app or
// in a later one. It is kept sealed, as it goes to the server, so the
// database holds nothing of a session the server would not.

/// Who, where and when: a session log's header, sealed as its part 0.
class SessionLogHeader {
  const SessionLogHeader({
    required this.uid,
    required this.label,
    required this.host,
    required this.port,
    required this.startedAt,
    this.user,
    this.connectionId,
    this.kind,
  });

  /// The member whose session it is.
  final String uid;

  /// The host as the member's app named it, its address and port, and the
  /// user name signed in as.
  final String label;
  final String host;
  final int port;
  final String? user;

  /// The host item's key, when it is a saved host.
  final String? connectionId;

  /// When the session connected, by the member's device clock.
  final DateTime startedAt;

  /// What kind of session it is, where it is not a terminal: [kScreenLogKind]
  /// for a remote screen (4.0) and [kRdpScreenLogKind] for an RDP host's,
  /// whose logs hold their lifecycle lines alone
  /// ([ScreenSessionLogLines]). Null for a terminal, as every log before it.
  /// A version before it reads the header as it did and shows the lines.
  final String? kind;

  /// Whether this is a remote screen's log, VNC's or RDP's.
  bool get isScreen => kind == kScreenLogKind || kind == kRdpScreenLogKind;

  Map<String, Object?> toJson() => {
        'v': 1,
        'uid': uid,
        'label': label,
        'host': host,
        'port': port,
        'user': ?user,
        'connection': ?connectionId,
        'kind': ?kind,
        'at': startedAt.millisecondsSinceEpoch,
      };

  /// Read back from [toJson]'s JSON; null for anything else.
  static SessionLogHeader? fromJson(Object? json) {
    if (json is! Map || json['v'] != 1) return null;
    final uid = json['uid'], label = json['label'], host = json['host'], port = json['port'], at = json['at'];
    if (uid is! String || uid.isEmpty || label is! String || host is! String || port is! int || at is! int) return null;
    return SessionLogHeader(
      uid: uid,
      label: label,
      host: host,
      port: port,
      user: json['user'] is String ? json['user'] as String : null,
      connectionId: json['connection'] is String ? json['connection'] as String : null,
      kind: json['kind'] is String ? json['kind'] as String : null,
      startedAt: DateTime.fromMillisecondsSinceEpoch(at),
    );
  }
}

/// [SessionLogHeader.kind] of a remote screen's log (4.0).
const String kScreenLogKind = 'vnc';

/// [SessionLogHeader.kind] of an RDP host's log (4.0).
const String kRdpScreenLogKind = 'rdp';

/// The header's kind for a remote screen's log.
String screenLogKind({required bool rdp}) => rdp ? kRdpScreenLogKind : kScreenLogKind;

/// What a team's log of a remote screen session holds after its header (who,
/// which host, when): when it connected, when its clipboard was turned on or
/// off, and when it ended and how long it lasted. Never the picture, a key, a
/// pointer or what the clipboard held, and the first line says so. In English,
/// as the log's own markers are ([kSessionLogFull]), whatever the language of
/// whoever reads it.
abstract final class ScreenSessionLogLines {
  /// The first line: what the log holds, and what it never does.
  static const String notRecorded =
      '[remote screen (VNC): who, the host and when are logged; the picture, keys and clipboard are not]';

  /// The first line of an RDP host's log: the account that signed in is
  /// logged too where the app knows it ([signedIn]).
  static const String notRecordedRdp =
      '[remote screen (RDP): who, the host, the account and when are logged; the picture, keys and clipboard are not]';

  /// [notRecorded] for the kind of screen.
  static String notRecordedFor({required bool rdp}) => rdp ? notRecordedRdp : notRecorded;

  /// RDP with Network Level Authentication: the account the app signed in
  /// with, as its server was given it (DOMAIN\user, or the name alone), as
  /// [account] shows it. Never its password.
  static String signedIn(String account) => '[remote screen: signed in as ${ScreenSessionLogLines.account(account)}]';

  /// An account's name as a log shows it: on one line to every reader
  /// whatever was typed (a domain is free text). Control characters, the
  /// line and paragraph separators, the marks that turn text around or hide
  /// in it, and what is no character at all become spaces; square brackets,
  /// which frame a log's own lines, become round ones; cut at 256
  /// characters.
  static String account(String name) => String.fromCharCodes([
        for (final c in name.runes.take(256))
          if (c == 0x5b)
            0x28
          else if (c == 0x5d)
            0x29
          else if (_notShown(c))
            0x20
          else
            c,
      ]);

  static bool _notShown(int c) =>
      c < 0x20 ||
      (c >= 0x7f && c < 0xa0) ||
      c == 0xad ||
      c == 0x61c ||
      (c >= 0x200b && c <= 0x200f) ||
      (c >= 0x2028 && c <= 0x202e) ||
      (c >= 0x2060 && c <= 0x206f) ||
      c == 0xfeff ||
      (c >= 0xfff9 && c <= 0xfffb) ||
      (c >= 0xd800 && c <= 0xdfff) ||
      (c >= 0xe0000 && c <= 0xe007f);

  static String connected({required bool viaCarrier}) =>
      '[remote screen: connected${viaCarrier ? ' through its SSH host' : ' directly over TLS'}]';

  static String clipboard({required bool on}) => '[remote screen: clipboard ${on ? 'on' : 'off'}]';

  /// The last line: how long the session lasted, in hours, minutes and
  /// seconds.
  static String ended(Duration lasted) {
    final d = lasted.isNegative ? Duration.zero : lasted;
    String two(int n) => n.toString().padLeft(2, '0');
    return '[remote screen: ended after ${d.inHours}h ${two(d.inMinutes % 60)}m ${two(d.inSeconds % 60)}s]';
  }
}

/// The longest plain text one chunk carries: sealed, it stays under the
/// server's 256 KB a chunk.
const int kSessionLogChunkBytes = 192 * 1024;

/// The most a log holds, sealed, as the server takes it (32 MB). A session
/// that shows more ends its log's text with [kSessionLogFull].
const int kSessionLogMaxBytes = 32 * 1024 * 1024;

/// What a log that reached [kSessionLogMaxBytes] ends with: the rest of the
/// session is not in it.
const String kSessionLogFull = '[session log full]';

/// Room kept, under [kSessionLogMaxBytes], for [kSessionLogFull] and the
/// chunk that ends the log.
const int _kSessionLogReserve = 4 * 1024;

/// What sealing adds to a chunk, at most (a version, the nonce and the tag).
const int _kSealOverhead = 64;

/// The most text held back after a private key's BEGIN line waiting for its
/// END line (keys are a few KB). Past it, what was held is left out as a key
/// and the log goes on, so output that never ends a key cannot pile up.
const int kSessionLogKeyHoldBytes = 64 * 1024;

/// Where an Orchard's database keeps what this device sealed of its session
/// logs and the server has not taken: this and a log's id for the log (its
/// Crate, the generation of the key, its sealed header, when its session
/// started and whether the server has taken its start), and that, a dot and
/// a chunk's number in eight digits for each chunk that waits.
const String kSessionLogState = 'sessionlog.';

/// Where the names that start with [kSessionLogState] end, as names sort:
/// the slash is the character after the dot.
const String _kSessionLogStateEnd = 'sessionlog/';

/// The most an Orchard's database keeps of session logs the server has not
/// taken, counted as it is kept (sealed, and written as text). With no room
/// left a log leaves out what its session shows, says so in its text
/// ([kSessionLogNotKept]) and goes on once there is room again.
const int kSessionLogKeepChars = 64 * 1024 * 1024;

/// What a log's text says where this device kept nothing of what its
/// session showed, for want of room ([kSessionLogKeepChars]).
const String kSessionLogNotKept =
    '[output missing: this device could not send its session logs and had no room to keep more]';

/// How long a session's own sending leaves the server alone once it did not
/// take what this device keeps: this, then twice as long after each further
/// try that fails, up to [kSessionLogLongestWait]. A sync asks whenever it
/// runs, whatever the wait.
const Duration kSessionLogFirstWait = Duration(seconds: 15);
const Duration kSessionLogLongestWait = Duration(minutes: 5);

/// How long what a session shows waits to be sealed while something sealed
/// before it still waits on this device (the server cannot be reached, or
/// takes it slowly): chunks are then fewer and larger, and what waits goes
/// in fewer requests.
const Duration kSessionLogSlowFlush = Duration(minutes: 1);

/// Session log requests are spaced, for a server that limits how many it
/// takes from one address in a minute: at most [kSessionLogBurst] in any
/// [kSessionLogBurstTime], from all of this device's logs together.
const int kSessionLogBurst = 20;
const Duration kSessionLogBurstTime = Duration(seconds: 40);

/// A log whose start reached the server this much after its session began
/// was kept on its device meanwhile ([TeamSessionLogEntry.receivedLater]).
/// Under it, clocks that differ a little say nothing.
const Duration kSessionLogLate = Duration(minutes: 10);

/// Where an Orchard's database notes that ZestSSH Cloud said the team's session
/// logs hold all its seats keep ('session-logs-team-full'), until the next sync
/// has told an owner ([takeSessionLogsFull]). The session goes on either way.
const String kSessionLogsFullState = 'orchards.session_logs_full';

/// Whether the server's answer [e] to a session log's start, or to a chunk
/// of it, holds for good: session logs are off for the Crate, the Crate or
/// the log is not there for this account, the log is closed or full, or the
/// server will not take what was sent. Not for good: signed out (401),
/// timed out (408), told to slow down (429), held back by the Orchard's
/// rules or its directory (which may end), and every fault of the server's
/// own (5xx).
bool sessionLogRefusedForGood(OrchardServerException e) =>
    e.status >= 400 &&
    e.status < 500 &&
    e.status != 401 &&
    e.status != 408 &&
    e.status != 429 &&
    !(e.status == 403 && (e.code == 'rules-unmet' || e.code == 'directory-removed'));

/// The writers of this run of the app whose session goes on, by their log's
/// id. More of such a log may come, so its place in the database stays when
/// nothing of it waits; a log no writer here holds (its session ended, or
/// the app was started again since) is taken out once the server has all
/// of it. The app's own and no service object's: the app makes its service
/// anew when its sign-in changes, while sessions go on, and a log one
/// service started must still count as going on for the next.
final _sessionLogWriters = <String, TeamSessionLogWriter>{};

/// Whether more of the log [logId] may still come in this run: its session
/// goes on, or its writer holds what the database could not take yet.
bool _sessionLogLive(String logId) {
  final writer = _sessionLogWriters[logId];
  return writer != null && (!writer._ended || writer._unkept.isNotEmpty);
}

/// The send under way for each log: one at a time, in the order asked,
/// whoever asks.
final _sessionLogSends = <String, Future<void>>{};

/// How each Orchard database that is open stands with its session logs in
/// this run of the app, by the database: the same for whichever service
/// object asks, and afresh for a database opened anew.
final _sessionLogStandings = Expando<_SessionLogStanding>('session logs of an Orchard database');

/// What was noted of a database before this is noted again: a test's new
/// run of the app.
var _sessionLogRunNumber = 0;

_SessionLogStanding _sessionLogStanding(AppDatabase db) {
  final known = _sessionLogStandings[db];
  return known != null && known.run == _sessionLogRunNumber ? known : (_sessionLogStandings[db] = _SessionLogStanding());
}

/// What a service knows, while the app runs, of the session log requests
/// its device makes.
class _SessionLogRun {
  /// The most an Orchard's database keeps ([kSessionLogKeepChars]; a test
  /// sets less).
  var keepChars = kSessionLogKeepChars;

  /// When the last session log requests were made, oldest first, and the
  /// one whose turn it is next: requests are spaced ([kSessionLogBurst]).
  final asked = <DateTime>[];
  Future<void> turn = Future<void>.value();

  /// Waits [time] for a request's turn (a test moves its clock instead).
  Future<void> Function(Duration time) sleep = Future<void>.delayed;

  /// The round under way for each Orchard: one at a time.
  final rounds = <String, Future<int>>{};
}

/// How an Orchard's database stands with its session logs in this run.
class _SessionLogStanding {
  /// How much it keeps under [kSessionLogState], in characters: counted
  /// once ([counting]), then kept up with what is written and taken out.
  var chars = 0;
  Future<void>? counting;

  /// Until when a session's own sending leaves the Orchard's server alone,
  /// and how long that wait is; null while it need not.
  ({DateTime until, Duration wait})? leftAlone;

  /// Which run of the app noted it ([_sessionLogRunNumber]).
  final run = _sessionLogRunNumber;
}

/// A session log as an Orchard's database keeps it until the server has all
/// of it: what its start needs, and whether the server has taken that.
class _KeptSessionLog {
  const _KeptSessionLog({
    required this.crateId,
    required this.generation,
    required this.header,
    required this.at,
    required this.started,
  });

  final String crateId;
  final int generation;

  /// The header, sealed.
  final Uint8List header;

  /// When its session started, by this device's clock (milliseconds).
  final int at;

  /// The server has taken its start.
  final bool started;

  /// As text. ([started] is kept as 0 or 1: marking a log as started
  /// changes no length, so what the database keeps counts the same.)
  String write({bool? started}) => jsonEncode({
        'crate': crateId,
        'gen': generation,
        'header': base64Encode(header),
        'at': at,
        'started': (started ?? this.started) ? 1 : 0,
      });

  /// Read back from [write]'s text; null for anything else.
  static _KeptSessionLog? read(String? text) {
    if (text == null) return null;
    try {
      final json = jsonDecode(text);
      if (json is! Map) return null;
      final crate = json['crate'], gen = json['gen'], header = json['header'], at = json['at'];
      final started = json['started'];
      if (crate is! String || gen is! int || header is! String || at is! int || started is! int) return null;
      return _KeptSessionLog(
          crateId: crate, generation: gen, header: base64Decode(header), at: at, started: started == 1);
    } on FormatException {
      return null;
    }
  }
}

/// A chunk as it is kept: read back from what [_keptChunk] wrote, null for
/// anything else.
({Uint8List sealed, bool last})? _readKeptChunk(String? text) {
  if (text == null) return null;
  try {
    final json = jsonDecode(text);
    if (json is! Map) return null;
    final sealed = json['sealed'], last = json['last'];
    if (sealed is! String || last is! bool) return null;
    return (sealed: base64Decode(sealed), last: last);
  } on FormatException {
    return null;
  }
}

String _keptChunk(Uint8List sealed, {required bool last}) => jsonEncode({'last': last, 'sealed': base64Encode(sealed)});

/// Where the log [logId] is kept, and where its chunk [seq] is.
String _sessionLogKey(String logId) => '$kSessionLogState$logId';
String _sessionLogChunkKey(String logId, int seq) => '${_sessionLogKey(logId)}.${seq.toString().padLeft(8, '0')}';

/// The names [db] keeps that start with [prefix] (which ends in a dot), in
/// order, the first [limit] of them when given. The names alone: what is
/// kept under them, which may be large, is not read.
Future<List<String>> _sessionLogKeys(AppDatabase db, String prefix, {int? limit}) async {
  // Everything that starts with "a." sorts from "a." up to "a/": the slash
  // is the character after the dot.
  final end = '${prefix.substring(0, prefix.length - 1)}/';
  final rows = await db.customSelect(
    'SELECT "key" AS k FROM local_state WHERE "key" >= ? AND "key" < ? ORDER BY "key"'
    '${limit == null ? '' : ' LIMIT $limit'}',
    variables: [Variable(prefix), Variable(end)],
  ).get();
  return [for (final r in rows) r.read<String>('k')];
}

/// What became of a try to send what this device keeps of a log.
enum _LogSend {
  /// The server has all that was kept of it.
  sent,

  /// It cannot be sent now: it stays kept.
  later,

  /// The server refuses it for good: nothing of it is kept any more.
  refused,
}

/// A session being logged for its team: what it shows goes in through
/// [append], and is redacted, sealed, kept on this device and sent in
/// order, every [flushEvery] or once [flushAtBytes] wait; every
/// [slowFlushEvery] while something sealed before still waits to be sent.
/// Made by [OrchardTeamSessionLogs.startTeamSessionLog].
class TeamSessionLogWriter {
  TeamSessionLogWriter._(
    this._service, {
    required this.orchardId,
    required this.crateId,
    required this.logId,
    required this.keyGeneration,
    required Uint8List key,
    this.flushEvery = const Duration(seconds: 5),
    this.slowFlushEvery = kSessionLogSlowFlush,
    this.flushAtBytes = 64 * 1024,
    this.maxBytes = kSessionLogMaxBytes,
  }) : _key = key;

  final OrchardService _service;
  final String orchardId;
  final String crateId;
  final String logId;
  final int keyGeneration;
  final Uint8List _key;
  final Duration flushEvery;
  final Duration slowFlushEvery;
  final int flushAtBytes;

  /// The most the log holds, sealed ([kSessionLogMaxBytes]).
  final int maxBytes;

  /// What the log leaves out; [addSecret] adds to it.
  final redactor = SessionLogRedactor();

  final _filter = TerminalTextFilter();
  final _pending = StringBuffer();
  var _seq = 0;
  var _sealedBytes = 0;
  var _waiting = 0;

  /// Chunks sealed that the Orchard's database has not taken (it is closed
  /// just now: the app is locked, or the Orchard is past its offline
  /// limit), lowest number first. Written, in that order, as soon as it is
  /// open again.
  final _unkept = <({int seq, Uint8List sealed, bool last})>[];
  Timer? _timer;

  /// The timer that runs was set while something waited to be sent.
  bool _timerSlow = false;

  /// Sealing runs one at a time, in the order asked, so chunks are numbered
  /// and kept in the order the session showed them.
  Future<void> _sealing = Future<void>.value();
  bool _closed = false;

  /// True once the log's last chunk is kept: nothing more of it comes.
  bool _ended = false;

  /// True once the log reached [kSessionLogMaxBytes]: what the session
  /// shows after that is not kept.
  bool get full => _full;
  bool _full = false;

  /// True while this device keeps nothing of what the session shows, for
  /// want of room ([kSessionLogKeepChars]). The log's text says so once
  /// where it is missing ([kSessionLogNotKept]).
  bool get notKept => _notKept;
  bool _notKept = false;

  /// True once the server stopped taking this log (session logs turned off
  /// for the Crate, the log is gone, full or refused): nothing more is kept
  /// or sent.
  bool get stopped => _stopped;
  bool _stopped = false;

  /// Chunks sealed, kept on this device, that the server has not taken.
  int get waiting => _waiting;

  /// Whether the last try to send what this device keeps of the log did
  /// not get through (ZestSSH Cloud away, no network, the server busy, the
  /// Orchard's database closed just now): the log waits on this device,
  /// sealed, and goes with the session's next try or the next sync. What
  /// the session's "logged" chip says of it (TeamSessionLogs.waiting).
  final onDevice = ValueNotifier<bool>(false);

  /// How long what the session shows waits before it is sealed:
  /// [flushEvery] while the server has all that was sealed before, and
  /// [slowFlushEvery] while some of it still waits on this device.
  @visibleForTesting
  Duration get flushDelay => _waiting > 0 && slowFlushEvery > flushEvery ? slowFlushEvery : flushEvery;

  /// The server has all that was sealed: what waits to be sealed need not
  /// wait as long as it was told to while something was still kept.
  void _nothingWaits() {
    if (_timer == null || !_timerSlow) return;
    _timer!.cancel();
    _timerSlow = false;
    _timer = Timer(flushEvery, () => unawaited(flush()));
  }

  /// Leaves [value] out of the log wherever it appears (a password,
  /// passphrase or masked snippet value used in this session).
  void addSecret(String value) => redactor.addSecret(value);

  /// Output as the session shows it, escape sequences and all.
  void append(String text) {
    if (_closed || _stopped || _full) return;
    _pending.write(_filter.feed(text));
    if (_pending.length >= flushAtBytes) {
      unawaited(flush());
    } else if (_timer == null) {
      final delay = flushDelay;
      _timerSlow = delay != flushEvery;
      _timer = Timer(delay, () => unawaited(flush()));
    }
  }

  /// Runs [step] after every sealing asked before it.
  Future<void> _inOrder(Future<void> Function() step) {
    final next = _sealing.then((_) => step());
    _sealing = next.catchError((Object _) {});
    return next;
  }

  /// Seals what waits, up to its last complete line (all of it when [all]),
  /// keeps it, and sends what is kept. A private key block still open is
  /// held back until its end arrives, or, at the end of the session, left
  /// out whole.
  Future<void> flush({bool all = false}) async {
    _timer?.cancel();
    _timer = null;
    if (_stopped) return;
    try {
      await _inOrder(() => _sealPending(all: all));
    } catch (e) {
      AppLogger.info('Orchards: part of a team session log was not sealed ($e)');
    }
    await _send();
  }

  Future<void> _sealPending({required bool all}) async {
    if (_stopped) return;
    var text = _pending.toString();
    var cut = all ? text.length : text.lastIndexOf('\n') + 1;
    // A line that never ends (a progress bar with no newline) goes anyway
    // once it is large.
    if (cut == 0 && text.length >= flushAtBytes) cut = text.length;
    final open = SessionLogRedactor.openPrivateKeyAt(text.substring(0, cut));
    if (open != null) {
      if (all || cut - open > kSessionLogKeyHoldBytes) {
        // The session ended in it, or it went on too long for a key: left
        // out whole, and the log goes on after it.
        text = '${text.substring(0, open)}$kRedactedPrivateKey\n${text.substring(cut)}';
        cut = open + kRedactedPrivateKey.length + 1;
      } else {
        cut = open;
      }
    }
    final take = text.substring(0, cut);
    _pending
      ..clear()
      ..write(text.substring(cut));
    // Once full, [append] keeps nothing more and [_seal] dropped what waited.
    if (take.isNotEmpty) await _seal(redactor.redact(take));
    // (Also what an earlier look could not write.)
    await _keep();
  }

  /// Seals [plain] into chunks of at most [kSessionLogChunkBytes] and keeps
  /// them. Past [kSessionLogMaxBytes] (less room for the end), what does
  /// not fit is left out and the log says so, once, and ends there. With no
  /// room on this device ([kSessionLogKeepChars]) it is left out as well,
  /// and the log says so once and goes on when there is room.
  Future<void> _seal(String plain, {bool last = false}) async {
    final bytes = utf8.encode(plain);
    var from = 0;
    do {
      final to = math.min(from + kSessionLogChunkBytes, bytes.length);
      if (!last && _sealedBytes + (to - from) + _kSealOverhead > maxBytes - _kSessionLogReserve) {
        _full = true;
        _pending.clear();
        await _sealPart(utf8.encode('\n$kSessionLogFull\n'), last: false);
        return;
      }
      if (!last && !await _service._sessionLogRoom(orchardId, to - from)) {
        if (!_notKept) {
          _notKept = true;
          await _sealPart(utf8.encode('\n$kSessionLogNotKept\n'), last: false);
        }
        return;
      }
      _notKept = false;
      await _sealPart(bytes.sublist(from, to), last: last && to == bytes.length);
      from = to;
    } while (from < bytes.length);
  }

  Future<void> _sealPart(List<int> bytes, {required bool last}) async {
    // Numbered once sealed: a part that failed leaves no gap.
    final seq = _seq + 1;
    final sealed = await sealSessionLogPart(bytes, _key,
        orchardId: orchardId, crateId: crateId, logId: logId, part: seq, generation: keyGeneration);
    // (A log the server stopped taking keeps nothing more.)
    if (_stopped) return;
    _seq = seq;
    _sealedBytes += sealed.length;
    _waiting++;
    _unkept.add((seq: seq, sealed: sealed, last: last));
    await _keep();
  }

  /// Writes what was sealed into the Orchard's database, lowest number
  /// first: on this device before anything is sent, so that what the server
  /// has not taken is still here when the session, or the app, has ended.
  /// Where the database is closed just now, what is sealed stays here, in
  /// order, for the next time. (Called with the sealing, one at a time.)
  Future<void> _keep() async {
    while (_unkept.isNotEmpty && !_stopped) {
      final chunk = _unkept.first;
      if (!await _service._keepSessionLogChunk(orchardId, logId, chunk.seq, chunk.sealed, last: chunk.last)) return;
      _unkept.removeAt(0);
    }
  }

  /// [_keep], after whatever sealing was asked before it: for a round that
  /// finds the database open again.
  Future<void> _keepNow() => _inOrder(_keep);

  /// Sends what this device keeps of the log, in order, one request at a
  /// time. What cannot go now (no network, the server busy) stays kept, for
  /// a later flush or the next sync; what the server refuses for good stops
  /// the log.
  Future<void> _send() => _service._sendSessionLog(orchardId, logId);

  /// Ends the log: what waits is sealed, the last chunk marked so readers
  /// know it ended properly, and what is kept is sent. What the server does
  /// not take now goes with a later sync; a log whose device goes away for
  /// good before that reads as not closed.
  Future<void> close() async {
    if (_closed) return;
    _closed = true;
    _timer?.cancel();
    _timer = null;
    if (!_full) _pending.write(_filter.finish());
    await flush(all: true);
    try {
      await _inOrder(() => _seal('', last: true));
    } catch (e) {
      AppLogger.info('Orchards: the end of a team session log was not sealed ($e)');
    }
    // Nothing more of it comes: once the server has what is kept, nothing
    // of the log stays on this device. And the writer is let go, with what
    // it knows of the session's secrets, whether or not its log has gone;
    // unless it still holds what the database could not take, which a
    // round writes once the database is open again.
    _ended = true;
    await _send();
    if (_unkept.isEmpty) _sessionLogWriters.remove(logId);
  }
}

/// A team session log as its readers see it: its header opened and checked
/// against who the server says sent it.
class TeamSessionLogEntry {
  const TeamSessionLogEntry({
    required this.id,
    required this.header,
    required this.chunks,
    required this.bytes,
    required this.closed,
    required this.receivedAt,
    required this.updatedAt,
    required this.keyGeneration,
  });

  final String id;
  final SessionLogHeader header;
  final int chunks;
  final int bytes;

  /// It ended properly: a log not closed was cut short (its device went
  /// away) or is still going.
  final bool closed;

  /// When the server took the log's start, by its own clock.
  final DateTime receivedAt;
  final DateTime updatedAt;
  final int keyGeneration;

  /// The server took this log's start well after its session began, by the
  /// clock of the device that wrote it ([kSessionLogLate]): the device kept
  /// the log meanwhile, as it does while ZestSSH Cloud cannot be reached.
  bool get receivedLater => receivedAt.difference(header.startedAt) > kSessionLogLate;
}

class TeamSessionLogPage {
  const TeamSessionLogPage({required this.entries, required this.more, this.before, this.unreadable = 0});

  final List<TeamSessionLogEntry> entries;
  final bool more;

  /// Pass to read the next page.
  final String? before;

  /// Logs that did not open, or named someone other than who sent them.
  final int unreadable;
}

/// A log's text, and whether all of it was there and opened.
class TeamSessionLogText {
  const TeamSessionLogText({required this.text, required this.complete});

  final String text;

  /// Every chunk opened, none missing, and the log ended properly.
  final bool complete;
}

extension OrchardTeamSessionLogs on OrchardService {
  /// Whether sessions to hosts in [crateId] of [orchardId] are logged, as
  /// this device's copy of the record says.
  Future<bool> sessionLogsOn(String orchardId, String crateId) async {
    final db = await databases.open(orchardId);
    return (await LocalRecord.load(db, orchardId)).latest.crates[crateId]?.sessionLogs ?? false;
  }

  /// Starts logging a session to a host in [crateId] for its team, when
  /// session logs are on there, as this device's record says: the writer to
  /// feed, or null when the session is not logged. The log's start is kept
  /// on this device before the server is asked, so the session is logged
  /// whether or not the server can be reached; a server that answers and
  /// says no (session logs are off there) ends it, and nothing is kept.
  Future<TeamSessionLogWriter?> startTeamSessionLog(
    String orchardId,
    String crateId, {
    required String label,
    required String host,
    required int port,
    String? user,
    String? connectionId,
    String? kind,
    Duration flushEvery = const Duration(seconds: 5),
    Duration slowFlushEvery = kSessionLogSlowFlush,
    int flushAtBytes = 64 * 1024,
    int maxBytes = kSessionLogMaxBytes,
  }) async {
    try {
      final me = await author();
      if (me == null) return null;
      final db = await databases.open(orchardId);
      final record = (await LocalRecord.load(db, orchardId)).latest;
      final crate = record.crates[crateId];
      if (crate == null || !crate.sessionLogs) return null;
      final generation = crate.generation;
      final key = await OrchardService._secret(db, orchardId, crateId, generation);
      if (key == null) return null;
      final logId = const Uuid().v4();
      final header = SessionLogHeader(
        uid: me.uid,
        label: label,
        host: host,
        port: port,
        user: user,
        connectionId: connectionId,
        kind: kind,
        startedAt: OrchardService.debugNow(),
      );
      final sealed = await sealSessionLogPart(utf8.encode(jsonEncode(header.toJson())), key,
          orchardId: orchardId, crateId: crateId, logId: logId, part: 0, generation: generation);
      final kept = await _sessionLogsKept(db);
      final start = _KeptSessionLog(
          crateId: crateId,
          generation: generation,
          header: sealed,
          at: header.startedAt.millisecondsSinceEpoch,
          started: false)
          .write();
      await LocalStateStore(db).write(_sessionLogKey(logId), start);
      kept.chars += start.length;
      final writer = TeamSessionLogWriter._(this,
          orchardId: orchardId,
          crateId: crateId,
          logId: logId,
          keyGeneration: generation,
          key: key,
          flushEvery: flushEvery,
          slowFlushEvery: slowFlushEvery,
          flushAtBytes: flushAtBytes,
          maxBytes: maxBytes);
      _sessionLogWriters[logId] = writer;
      if (await _sendSessionLog(orchardId, logId) == _LogSend.refused) return null;
      return writer;
    } catch (e) {
      AppLogger.info('Orchards: this session is not logged for its team ($e)');
      return null;
    }
  }

  // ── What this device keeps until the server has it ──

  /// As if the app had been started again: no log is being written, what
  /// the databases keep is counted anew, and no server is left alone.
  @visibleForTesting
  void debugSessionLogsNewRun() {
    _sessionLogWriters.clear();
    _sessionLogSends.clear();
    _sessionLogRunNumber++;
    _sessionLogRun
      ..asked.clear()
      ..rounds.clear()
      ..turn = Future<void>.value();
  }

  /// What waits for a request's turn, for a test that moves its own clock.
  @visibleForTesting
  set debugSessionLogSleep(Future<void> Function(Duration time) sleep) => _sessionLogRun.sleep = sleep;

  /// The round under way for [orchardId], when one is: a test waits for
  /// the one a sync started. Ends when the round does, however it ends.
  @visibleForTesting
  Future<void>? debugSessionLogRound(String orchardId) =>
      _sessionLogRun.rounds[orchardId]?.then<void>((_) {}, onError: (Object _) {});

  /// The most an Orchard's database keeps of session logs, for a test that
  /// cannot fill [kSessionLogKeepChars].
  @visibleForTesting
  set debugSessionLogKeepChars(int chars) => _sessionLogRun.keepChars = chars;

  /// How the Orchard database [db] stands, with how much it keeps of
  /// session logs counted: the first time it is asked in a run, then kept
  /// up by whoever writes.
  Future<_SessionLogStanding> _sessionLogsKept(AppDatabase db) async {
    final kept = _sessionLogStanding(db);
    try {
      await (kept.counting ??= () async {
        final row = await db.customSelect(
          'SELECT COALESCE(SUM(LENGTH(value)), 0) AS n FROM local_state WHERE "key" >= ? AND "key" < ?',
          variables: const [Variable(kSessionLogState), Variable(_kSessionLogStateEnd)],
        ).getSingle();
        kept.chars = row.read<int>('n');
      }());
    } catch (_) {
      // Counted again by whoever asks next.
      kept.counting = null;
      rethrow;
    }
    return kept;
  }

  /// Whether [orchardId]'s database has room for [bytes] more of a log. A
  /// database that is closed just now cannot say: what is sealed stays with
  /// its writer meanwhile, within what one log holds.
  Future<bool> _sessionLogRoom(String orchardId, int bytes) async {
    final db = databases.opened(orchardId);
    if (db == null) return true;
    final _SessionLogStanding kept;
    try {
      kept = await _sessionLogsKept(db);
    } catch (_) {
      // (Nor can one that fails under the question.)
      return true;
    }
    // As it is kept: sealed, in base64, inside a little JSON.
    return kept.chars + (bytes + _kSealOverhead) * 4 ~/ 3 + 48 <= _sessionLogRun.keepChars;
  }

  /// Keeps the chunk [seq] of the log [logId], sealed, until the server has
  /// it. True once it is written; false where the Orchard's database is
  /// closed just now (it is not opened for this) or does not take it.
  Future<bool> _keepSessionLogChunk(String orchardId, String logId, int seq, Uint8List sealed,
      {required bool last}) async {
    final db = databases.opened(orchardId);
    if (db == null) return false;
    try {
      final kept = await _sessionLogsKept(db);
      final text = _keptChunk(sealed, last: last);
      await LocalStateStore(db).write(_sessionLogChunkKey(logId, seq), text);
      kept.chars += text.length;
      return true;
    } catch (e) {
      AppLogger.info('Orchards: part of a session log is not written to this device yet ($e)');
      return false;
    }
  }

  /// Takes everything this device keeps of the log [logId] out, and stops
  /// whoever writes it.
  Future<void> _dropSessionLog(AppDatabase db, String logId) async {
    final writer = _sessionLogWriters.remove(logId);
    if (writer != null) {
      writer
        .._stopped = true
        .._waiting = 0;
    }
    final key = _sessionLogKey(logId);
    await db.customStatement(
        'DELETE FROM local_state WHERE "key" = ? OR ("key" >= ? AND "key" < ?)', [key, '$key.', '$key/']);
    // Counted anew by whoever asks next.
    _sessionLogStanding(db).counting = null;
  }

  /// Whether a session's own sending may ask the server of the Orchard in
  /// [db] now: not while the app knows that ZestSSH Cloud is not answering,
  /// nor shortly after the server did not take what this device keeps.
  bool _sessionLogsMayAsk(AppDatabase db) {
    if (cloudAway?.call() ?? false) return false;
    final wait = _sessionLogStanding(db).leftAlone;
    return wait == null || !OrchardService.debugNow().isBefore(wait.until);
  }

  /// The server of the Orchard in [db] did not take what this device
  /// keeps: sessions leave it alone for a while, longer each time.
  void _sessionLogsNotNow(AppDatabase db) {
    final standing = _sessionLogStanding(db);
    final now = OrchardService.debugNow();
    final before = standing.leftAlone;
    // Tries that fail during a wait (they were on their way, or a sync
    // asked) do not make it longer.
    if (before != null && now.isBefore(before.until)) return;
    final wait = before == null
        ? kSessionLogFirstWait
        : (before.wait * 2 < kSessionLogLongestWait ? before.wait * 2 : kSessionLogLongestWait);
    standing.leftAlone = (until: now.add(wait), wait: wait);
  }

  /// A session log request's turn: at once while fewer than
  /// [kSessionLogBurst] were made in the last [kSessionLogBurstTime], and
  /// otherwise once the oldest of them is that long ago. One after another,
  /// in the order asked, for all of this device's logs together.
  Future<void> _sessionLogTurn() {
    final run = _sessionLogRun;
    final mine = run.turn.then((_) async {
      var now = OrchardService.debugNow();
      run.asked.removeWhere((at) => !now.isBefore(at.add(kSessionLogBurstTime)));
      if (run.asked.length >= kSessionLogBurst) {
        await run.sleep(run.asked.first.add(kSessionLogBurstTime).difference(now));
        now = OrchardService.debugNow();
      }
      run.asked.add(now);
    });
    run.turn = mine.catchError((Object _) {});
    return mine;
  }

  /// Sends what this device keeps of the log [logId] of [orchardId], after
  /// whatever send of that log was asked before. One a session asks for is
  /// not made while the server is left alone ([_sessionLogsMayAsk]); one a
  /// sync asks for ([always]) is.
  Future<_LogSend> _sendSessionLog(String orchardId, String logId, {bool always = false}) {
    final before = _sessionLogSends[logId] ?? Future<void>.value();
    final done = Completer<void>();
    _sessionLogSends[logId] = done.future;
    return before.then((_) async {
      var went = _LogSend.later;
      try {
        // A database that is closed just now is not opened for this: what
        // it keeps waits until it is open again.
        final db = databases.opened(orchardId);
        if (db == null || (!always && !_sessionLogsMayAsk(db))) return went;
        return went = await _sessionLogPass(db, logId);
      } finally {
        // Whether the log waits on this device, for whoever shows it.
        _sessionLogWriters[logId]?.onDevice.value = went == _LogSend.later;
        if (identical(_sessionLogSends[logId], done.future)) _sessionLogSends.remove(logId);
        done.complete();
      }
    });
  }

  /// One go at the log [logId]: its start when the server has not taken
  /// it, then its chunks, lowest number first, each taken out of the
  /// database once the server has it. A start or a chunk the server has
  /// already (its answer never arrived) is answered as taken. Never throws.
  Future<_LogSend> _sessionLogPass(AppDatabase db, String logId) async {
    try {
      final store = LocalStateStore(db);
      final kept = await _sessionLogsKept(db);
      final key = _sessionLogKey(logId);
      // Asked now: a log whose session ends while this runs is finished by
      // the send its ending asks for, which finds every chunk.
      final live = _sessionLogLive(logId);
      final text = await store.read(key);
      if (text == null) return _LogSend.sent;
      final log = _KeptSessionLog.read(text);
      if (log == null) {
        AppLogger.info('Orchards: what is kept of a session log does not read, and is dropped');
        await _dropSessionLog(db, logId);
        return _LogSend.refused;
      }
      // The server answered a request of this go: sessions need not leave
      // it alone any longer.
      var answered = false;
      try {
        if (!log.started) {
          await _sessionLogTurn();
          await server.startSessionLog(log.crateId, logId, keyGeneration: log.generation, header: log.header);
          answered = true;
          await store.write(key, log.write(started: true));
        }
        while (true) {
          final next = await _sessionLogKeys(db, '$key.', limit: 1);
          if (next.isEmpty) break;
          final chunkText = await store.read(next.single);
          final chunk = _readKeptChunk(chunkText);
          final seq = int.tryParse(next.single.substring(key.length + 1));
          // What does not read as a chunk goes: the server refuses what
          // follows it, which ends the log where it stands.
          if (chunk != null && seq != null) {
            await _sessionLogTurn();
            await server.sendSessionLogChunk(log.crateId, logId,
                seq: seq, keyGeneration: log.generation, sealed: chunk.sealed, last: chunk.last);
            answered = true;
          }
          await store.remove(next.single);
          kept.chars -= chunkText?.length ?? 0;
          final writer = _sessionLogWriters[logId];
          if (writer != null && writer._waiting > 0 && --writer._waiting == 0) writer._nothingWaits();
        }
        if (!live) {
          await store.remove(key);
          kept.chars -= text.length;
        }
      } on OrchardServerException catch (e) {
        if (!sessionLogRefusedForGood(e)) rethrow;
        AppLogger.info('Orchards: the server takes no more of a session log, which is dropped ($e)');
        if (e.code == 'session-logs-team-full') await store.write(kSessionLogsFullState, '1');
        _sessionLogStanding(db).leftAlone = null;
        await _dropSessionLog(db, logId);
        return _LogSend.refused;
      }
      if (answered) _sessionLogStanding(db).leftAlone = null;
      return _LogSend.sent;
    } catch (e) {
      _sessionLogsNotNow(db);
      AppLogger.info('Orchards: a session log stays on this device until it can be sent ($e)');
      return _LogSend.later;
    }
  }

  /// The logs [db] keeps something of, and those it keeps chunks of.
  Future<({Set<String> logs, Set<String> withChunks})> _sessionLogsHere(AppDatabase db) async {
    final logs = <String>{}, withChunks = <String>{};
    for (final key in await _sessionLogKeys(db, kSessionLogState)) {
      final rest = key.substring(kSessionLogState.length);
      final dot = rest.indexOf('.');
      if (dot < 0) {
        logs.add(rest);
      } else {
        withChunks.add(rest.substring(0, dot));
      }
    }
    return (logs: logs, withChunks: withChunks);
  }

  /// How many session logs of [orchardId] this device keeps something of
  /// that the server has not taken: a start, or chunks. None that can be
  /// told of while the Orchard's database is closed.
  Future<int> sessionLogsWaiting(String orchardId) async {
    final db = databases.opened(orchardId);
    if (db == null) return 0;
    final store = LocalStateStore(db);
    final here = await _sessionLogsHere(db);
    var waiting = 0;
    for (final id in here.logs) {
      final log = _KeptSessionLog.read(await store.read(_sessionLogKey(id)));
      if (log == null || !log.started || here.withChunks.contains(id)) waiting++;
    }
    return waiting;
  }

  /// Sends what this device keeps of [orchardId]'s session logs, the log
  /// whose session started first before the others, and returns how many
  /// logs it sent all that waited of. It asks whatever wait the sessions
  /// keep. What the server refuses for good is dropped; at the first log it
  /// cannot take now the round ends, and the rest waits for the next.
  /// Chunks of a log this device keeps no start of (it was dropped while
  /// one was being written) are cleared away. One round at a time for an
  /// Orchard: asked for while one runs, that one answers. Nothing while
  /// the Orchard's database is closed.
  Future<int> sessionLogRound(String orchardId) {
    final run = _sessionLogRun;
    return run.rounds[orchardId] ??= _sessionLogRoundNow(orchardId).whenComplete(() {
      run.rounds.remove(orchardId);
    });
  }

  /// [sessionLogRound] as a sync asks for it, once the server answered the
  /// sync itself: it never fails. A sync starts it and does not wait for
  /// it: much may be kept, and requests are spaced.
  Future<void> sessionLogCatchUp(String orchardId) =>
      sessionLogRound(orchardId).then<void>((_) {}, onError: (Object e) {
        AppLogger.info('Orchards: session logs kept on this device wait for the next sync ($e)');
      });

  Future<int> _sessionLogRoundNow(String orchardId) async {
    final db = databases.opened(orchardId);
    if (db == null) return 0;
    // What writers still hold of this Orchard's logs (the database was
    // closed when it was sealed) is written first; one whose session has
    // ended is let go once it holds nothing.
    for (final writer in _sessionLogWriters.values.toList()) {
      if (writer.orchardId != orchardId || writer._unkept.isEmpty) continue;
      await writer._keepNow();
      if (writer._ended && writer._unkept.isEmpty) _sessionLogWriters.remove(writer.logId);
    }
    final store = LocalStateStore(db);
    final here = await _sessionLogsHere(db);
    for (final id in here.withChunks.difference(here.logs)) {
      await _dropSessionLog(db, id);
    }
    final logs = <({String id, int at, bool waits})>[];
    for (final id in here.logs) {
      final log = _KeptSessionLog.read(await store.read(_sessionLogKey(id)));
      logs.add((id: id, at: log?.at ?? 0, waits: log == null || !log.started || here.withChunks.contains(id)));
    }
    logs.sort((a, b) {
      final byTime = a.at.compareTo(b.at);
      return byTime != 0 ? byTime : a.id.compareTo(b.id);
    });
    var sent = 0;
    for (final log in logs) {
      switch (await _sendSessionLog(orchardId, log.id, always: true)) {
        case _LogSend.sent:
          if (log.waits) sent++;
        case _LogSend.refused:
          break;
        case _LogSend.later:
          return sent;
      }
    }
    return sent;
  }

  // ── Reading (owners and those who manage the Crate) ──

  /// [crateId]'s session logs, newest first, older than [before] when given
  /// (owners and those who manage the Crate).
  Future<TeamSessionLogPage> teamSessionLogs(String orchardId, String crateId, {String? before}) async {
    final db = await databases.open(orchardId);
    final page = await server.sessionLogs(crateId, before: before);
    final out = <TeamSessionLogEntry>[];
    var unreadable = 0;
    for (final l in page.logs) {
      final key = await OrchardService._secret(db, orchardId, crateId, l.keyGeneration);
      SessionLogHeader? header;
      if (key != null) {
        try {
          header = SessionLogHeader.fromJson(jsonDecode(utf8.decode(await openSessionLogPart(l.header, key,
              orchardId: orchardId, crateId: crateId, logId: l.id, part: 0, generation: l.keyGeneration))));
        } catch (_) {
          header = null;
        }
      }
      if (header == null || header.uid != l.uid) {
        unreadable++;
        continue;
      }
      out.add(TeamSessionLogEntry(
        id: l.id,
        header: header,
        chunks: l.chunks,
        bytes: l.bytes,
        closed: l.closed,
        receivedAt: l.startedAt,
        updatedAt: l.updatedAt,
        keyGeneration: l.keyGeneration,
      ));
    }
    return TeamSessionLogPage(
      entries: out,
      more: page.more,
      before: page.logs.isEmpty ? null : page.logs.last.id,
      unreadable: unreadable,
    );
  }

  /// The text of the log [entry] of [crateId], every chunk opened in order.
  /// A chunk that does not open, or one missing, ends the text there, and
  /// the text is not [TeamSessionLogText.complete].
  Future<TeamSessionLogText> teamSessionLogText(String orchardId, String crateId, TeamSessionLogEntry entry) async {
    final db = await databases.open(orchardId);
    final out = BytesBuilder(copy: false);
    var next = 1;
    var intact = true;
    while (intact) {
      final page = await server.sessionLogChunks(crateId, entry.id, after: next - 1);
      for (final c in page.chunks) {
        final key = c.seq == next ? await OrchardService._secret(db, orchardId, crateId, c.keyGeneration) : null;
        if (key == null) {
          intact = false;
          break;
        }
        try {
          out.add(await openSessionLogPart(c.sealed, key,
              orchardId: orchardId, crateId: crateId, logId: entry.id, part: c.seq, generation: c.keyGeneration));
        } catch (_) {
          intact = false;
          break;
        }
        next++;
      }
      if (!page.more || page.chunks.isEmpty) break;
    }
    return TeamSessionLogText(
      text: utf8.decode(out.takeBytes(), allowMalformed: true),
      complete: intact && entry.closed && next - 1 == entry.chunks,
    );
  }

  /// Deletes the log [logId] of [crateId] (owners).
  Future<void> deleteTeamSessionLog(String crateId, String logId) => server.deleteSessionLog(crateId, logId);
}
