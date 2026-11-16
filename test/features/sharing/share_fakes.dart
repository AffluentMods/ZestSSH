// What the session sharing tests share: a relay in memory that behaves as
// ZestSSH Cloud's does for one share (ZestSSH Cloud's lib/share_relay.js),
// an API that records what it was asked, and a terminal to share.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/terminal_snapshot.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Something passing through the relay: who sent it, on which lane, and the
/// bytes.
class Passing {
  Passing(this.fromHost, this.lane, this.bytes);

  final bool fromHost;
  final int lane;
  final Uint8List bytes;
}

/// The relay of one share, in memory. Lines attach when started, are told
/// who else is there, and get each other's bytes a moment later, as over a
/// network. Everything that passes is kept in [passed], and [tamper] may
/// change it or drop it on the way, as a relay that is not playing by the
/// rules could.
class FakeShareRelay {
  FakeShareRelay({this.mode = ShareMode.live});

  final ShareMode mode;
  FakeShareLink? _host;
  final _lanes = <int, FakeShareLink>{};
  int _nextLane = 0;

  /// Every message that crossed, as it was sent (before [tamper]).
  final passed = <Passing>[];

  /// Every message a line tried to send, also on a share that carries none
  /// (a shared tmux session): what would cross if the relay let it.
  final tried = <Passing>[];

  /// A relay that is slow to say someone went: while set, the host is not
  /// told that a viewer's line closed.
  bool quietWhenViewersGo = false;

  /// Returns what is delivered instead of [Passing.bytes]; null drops it;
  /// a list delivers each in turn.
  Object? Function(Passing p)? tamper;

  /// Bytes held back instead of delivered, while set: everything, or only
  /// what [holdWhere] picks (a phone on a slow line gets nothing for a
  /// while, and all of it later).
  bool hold = false;
  bool Function(Passing p)? holdWhere;
  final _held = <void Function()>[];

  FakeShareLink host() => FakeShareLink._(this, host: true, uid: 'host');

  FakeShareLink viewer(String uid) => FakeShareLink._(this, host: false, uid: uid);

  int? laneOf(String uid) {
    for (final e in _lanes.entries) {
      if (e.value.uid == uid) return e.key;
    }
    return null;
  }

  void _attach(FakeShareLink link) {
    if (link.host) {
      _host?._closed(ShareLineEnd.replaced);
      _host = link;
      link._open = true;
      link._emit(ShareLineReady(mode: mode, viewers: [for (final e in _lanes.entries) ShareLane(e.key, e.value.uid)]));
      for (final v in _lanes.values) {
        v._emit(const ShareLineHost(on: true));
      }
      return;
    }
    for (final e in _lanes.entries.toList()) {
      if (e.value.uid != link.uid) continue;
      _lanes.remove(e.key);
      _host?._emit(ShareLineViewer(e.key, link.uid, on: false));
      e.value._closed(ShareLineEnd.replaced);
    }
    final lane = ++_nextLane;
    _lanes[lane] = link;
    link._lane = lane;
    link._open = true;
    link._emit(ShareLineReady(mode: mode, hostOnline: _host != null));
    _host?._emit(ShareLineViewer(lane, link.uid, on: true));
  }

  void _detach(FakeShareLink link) {
    if (!link._open) return;
    link._open = false;
    if (link.host) {
      if (identical(_host, link)) {
        _host = null;
        for (final v in _lanes.values) {
          v._emit(const ShareLineHost(on: false));
        }
      }
    } else if (identical(_lanes[link._lane], link)) {
      _lanes.remove(link._lane);
      if (!quietWhenViewersGo) _host?._emit(ShareLineViewer(link._lane, link.uid, on: false));
    }
  }

  void _send(FakeShareLink from, Uint8List bytes, int lane) {
    if (!from._open) return;
    final p = Passing(from.host, from.host ? lane : from._lane, Uint8List.fromList(bytes));
    tried.add(p);
    if (mode != ShareMode.live) return;
    passed.add(p);
    final out = tamper == null ? p.bytes : tamper!(p);
    final deliveries = out == null
        ? const <Uint8List>[]
        : out is List<Uint8List>
            ? out
            : [out as Uint8List];
    for (final bytes in deliveries) {
      void deliver() {
        if (p.fromHost) {
          final to = _lanes[p.lane];
          if (to != null && to._open) to._emit(ShareLineBytes(0, bytes));
        } else {
          final to = _host;
          if (to != null && to._open && identical(_lanes[p.lane], from)) to._emit(ShareLineBytes(p.lane, bytes));
        }
      }

      if (hold || (holdWhere?.call(p) ?? false)) {
        _held.add(deliver);
      } else {
        deliver();
      }
    }
  }

  /// Delivers what was held back, in order, and stops holding.
  void release() {
    hold = false;
    holdWhere = null;
    final held = List.of(_held);
    _held.clear();
    for (final d in held) {
      d();
    }
  }

  /// The host's line drops (its network went) and comes back.
  void dropHostLine({bool comeBack = true}) {
    final host = _host;
    if (host == null) return;
    _host = null;
    host._open = false;
    for (final v in _lanes.values) {
      v._emit(const ShareLineHost(on: false));
    }
    host._emit(const ShareLineDown());
    if (comeBack) _attach(host);
  }

  /// [uid]'s line drops and comes back, on a new lane (or stays away, to
  /// see what the viewer makes of the time in between).
  void dropViewerLine(String uid, {bool comeBack = true}) {
    final lane = laneOf(uid);
    if (lane == null) return;
    final link = _lanes.remove(lane)!;
    link._open = false;
    _host?._emit(ShareLineViewer(lane, uid, on: false));
    link._emit(const ShareLineDown());
    if (comeBack) _attach(link);
  }

  /// What a relay that does not play by the rules could tell the host: that
  /// the line is ready once more though it never dropped, that someone is
  /// there or gone on a lane whatever is true, and bytes as if they had come
  /// on a lane (also on a share that carries none).
  void sayReadyAgain() => _host
      ?._emit(ShareLineReady(mode: mode, viewers: [for (final e in _lanes.entries) ShareLane(e.key, e.value.uid)]));

  void sayViewer(int lane, String uid, {required bool on}) => _host?._emit(ShareLineViewer(lane, uid, on: on));

  void pushToHost(int lane, Uint8List bytes) => _host?._emit(ShareLineBytes(lane, bytes));

  /// The relay closes [uid]'s line for good.
  void kick(String uid, ShareLineEnd why) {
    final lane = laneOf(uid);
    if (lane == null) return;
    final link = _lanes.remove(lane)!;
    _host?._emit(ShareLineViewer(lane, uid, on: false));
    link._closed(why);
  }

  /// Someone declined: the host is told.
  void declined(String uid) => _host?._emit(ShareLineDeclined(uid));

  /// The share ended at the server: every line is closed.
  void end([ShareLineEnd why = ShareLineEnd.ended]) {
    final host = _host;
    _host = null;
    final viewers = _lanes.values.toList();
    _lanes.clear();
    host?._closed(why);
    for (final v in viewers) {
      v._closed(why);
    }
  }
}

class FakeShareLink implements ShareLink {
  FakeShareLink._(this._relay, {required this.host, required this.uid});

  final FakeShareRelay _relay;
  final bool host;
  final String uid;
  final _events = StreamController<ShareLineEvent>.broadcast();
  bool _open = false;
  int _lane = 0;
  bool closedHere = false;

  @override
  Stream<ShareLineEvent> get events => _events.stream;

  @override
  bool get isOpen => _open;

  @override
  void start() => _relay._attach(this);

  @override
  void send(Uint8List bytes, {int lane = 0}) => _relay._send(this, bytes, lane);

  @override
  Future<void> close() async {
    closedHere = true;
    _relay._detach(this);
  }

  void _emit(ShareLineEvent event) {
    // A moment later, as over a network; never after this side closed it.
    scheduleMicrotask(() {
      if (!closedHere && !_events.isClosed) _events.add(event);
    });
  }

  void _closed(ShareLineEnd why) {
    _open = false;
    _emit(ShareLineClosed(why));
  }
}

/// An API that keeps what it was asked and reaches nothing.
class FakeShareApi extends ShareApi {
  FakeShareApi()
      : super(
          client: MockClient((_) async => http.Response('{}', 500)),
          baseUrl: 'http://127.0.0.1:1/v1',
          bearer: () async => 'token',
        );

  /// What each call carried: the sealed invitations, by account.
  final created = <({String id, String crateId, ShareMode mode, Map<String, Uint8List> invites})>[];
  final invited = <({String id, Map<String, Uint8List> invites})>[];
  final removed = <(String id, String uid)>[];
  final ended = <String>[];

  /// The invitations the server lists for this account.
  List<ShareInviteListing> waiting = [];

  /// Thrown by the next call, once.
  Object? failNext;

  /// Told of each call as it arrives ('create', 'invite', 'invitations',
  /// 'removeInvite', 'end'), before it is answered: what the world looked like when the
  /// server was asked.
  void Function(String call)? onCall;

  void _called(String call) {
    onCall?.call(call);
    final f = failNext;
    failNext = null;
    if (f != null) throw f;
  }

  @override
  Future<void> create({
    required String id,
    required String crateId,
    required ShareMode mode,
    required Map<String, Uint8List> invites,
  }) async {
    _called('create');
    created.add((id: id, crateId: crateId, mode: mode, invites: Map.of(invites)));
  }

  @override
  Future<void> invite(String id, Map<String, Uint8List> invites) async {
    _called('invite');
    invited.add((id: id, invites: Map.of(invites)));
  }

  @override
  Future<List<ShareInviteListing>> invitations() async {
    _called('invitations');
    return List.of(waiting);
  }

  @override
  Future<void> removeInvite(String id, String uid) async {
    _called('removeInvite');
    removed.add((id, uid));
  }

  @override
  Future<void> end(String id) async {
    _called('end');
    ended.add(id);
  }
}

/// A real terminal to share: what the host's session shows, and what was
/// typed into it.
class SharedTerminal implements ShareTerminal {
  SharedTerminal({int columns = 60, int rows = 12}) : terminal = Terminal(maxLines: 2000) {
    terminal.resize(columns, rows);
  }

  final Terminal terminal;
  final typed = <int>[];
  int snapshots = 0;

  @override
  ShareScreen snapshot() {
    snapshots++;
    return ShareScreen(columns: terminal.viewWidth, rows: terminal.viewHeight, text: terminalSnapshot(terminal));
  }

  @override
  void type(Uint8List bytes) => typed.addAll(bytes);
}

/// Every visible cell of [b] is that of [a], the size and the cursor too.
void sameScreen(Terminal a, Terminal b) {
  expect((b.viewWidth, b.viewHeight), (a.viewWidth, a.viewHeight), reason: 'size');
  expect(b.isUsingAltBuffer, a.isUsingAltBuffer, reason: 'which screen');
  final ba = a.buffer;
  final bb = b.buffer;
  for (var y = 0; y < a.viewHeight; y++) {
    final la = ba.lines[ba.scrollBack + y];
    final lb = bb.lines[bb.scrollBack + y];
    for (var x = 0; x < a.viewWidth; x++) {
      final where = 'row $y col $x';
      expect(lb.getCodePoint(x), la.getCodePoint(x), reason: '$where text');
      if (la.getCodePoint(x) == 0 && la.getBackground(x) == 0) continue;
      expect(lb.getForeground(x), la.getForeground(x), reason: '$where fg');
      expect(lb.getBackground(x), la.getBackground(x), reason: '$where bg');
      expect(lb.getAttributes(x), la.getAttributes(x), reason: '$where attrs');
    }
  }
  expect((bb.cursorX, bb.cursorY), (ba.cursorX, ba.cursorY), reason: 'cursor');
}

/// Lets everything queued run: sealing, opening and delivery take several
/// turns of the event loop.
Future<void> settle([int turns = 40]) async {
  for (var i = 0; i < turns; i++) {
    await Future<void>.delayed(Duration.zero);
  }
}

/// Waits until [check] holds, letting things run meanwhile.
Future<void> until(bool Function() check, {String? what, int turns = 4000}) async {
  for (var i = 0; i < turns; i++) {
    if (check()) return;
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
  fail('timed out waiting${what == null ? '' : ' for $what'}');
}

/// An Orchard's record where each of [members] opens the Crate [crateId]
/// at [level] (Use unless [levels] says otherwise).
OrchardRecord teamRecord(
  String orchardId,
  String crateId,
  Map<String, AccountKeys> members, {
  Map<String, CrateLevel> levels = const {},
}) {
  final r = OrchardRecord(orchardId);
  r.crates[crateId] = RecordCrate(id: crateId, ownersOnly: false, allow: {'sftp', 'forward'});
  for (final level in CrateLevel.values) {
    r.roles['role-${level.name}'] = RecordRole(
        id: 'role-${level.name}', rank: 100, nameEnc: '', nameGeneration: 1, can: {}, crates: {crateId: levelSwitches(level)});
  }
  var seq = 1;
  for (final e in members.entries) {
    final k = e.value;
    r.members[e.key] = RecordMember(
      uid: e.key,
      role: 'role-${(levels[e.key] ?? CrateLevel.use).name}',
      keys: {
        k.version: RecordKeys(
          version: k.version,
          signingKey: k.signingPublicKey,
          encryptionKey: k.encryption.publicKey,
          createdAt: k.createdAt,
          selfSignature: Uint8List(64),
        ),
      },
      since: seq++,
    );
  }
  return r;
}

/// The keys a device has pinned for [uid].
ShareParty partyOf(String uid, AccountKeys k, {bool keysChanged = false}) => ShareParty(
      uid: uid,
      keyVersion: k.version,
      signingKey: k.signingPublicKey,
      encryptionKey: k.encryption.publicKey,
      keysChanged: keysChanged,
    );
