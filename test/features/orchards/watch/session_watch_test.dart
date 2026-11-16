// The watch of one session to a watched Crate's host (3.0;
// session_watch.dart), with a real live view behind it: the device that
// shares, the devices that watch and a relay in memory between them (the
// live view tests' world). Someone counts as watching when they were
// invited to end the session, are watching now, and manage the Crate by the
// record as it is now. The session waits for the first such person, holds
// typing while there is none, and after a while of that says it is to be
// closed.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../../sharing/share_fakes.dart';
import '../../sharing/share_world.dart';

const _session = 's1';
const _host = WatchedHost(orchardId: orchardId, crateId: crateId, crateName: 'Production');

/// A shell that keeps what it was sent and what was asked of it.
class _Shell extends ShellService {
  final written = <int>[];
  final asked = <String>[];
  final _out = StreamController<Uint8List>.broadcast();
  final _state = StreamController<bool>.broadcast();

  @override
  Future<void> connect() async => asked.add('connect');
  @override
  Future<void> disconnect() async => asked.add('disconnect');
  @override
  late final Stream<Uint8List> stdout = _out.stream;
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) => written.addAll(data);
  @override
  void resize(int width, int height) => asked.add('resize:$width,$height');
  @override
  bool get isConnected => true;
  @override
  late final Stream<bool> connectionState = _state.stream;
  @override
  bool get exitedCleanly => true;
  @override
  bool get isEncryptedSsh => true;
}

/// A shell that says why its connection ended.
class _SayingShell extends _Shell implements ShellEndReason {
  final reason = Completer<String?>();

  @override
  Future<String?> get endReason => reason.future;
}

void main() {
  setUpAll(makeWorldKeys);

  late World w;
  var shared = false;
  final notes = <WatchNote>[];
  final watches = <SessionWatch>[];

  setUp(() {
    SessionShares.reset();
    SessionWatches.reset();
    notes.clear();
    shared = false;
    w = World();
    // sam and kit manage the Crate; noa opens it at the lowest level. Its
    // sessions are watched, so it allows the terminal only.
    w.record = teamRecord(orchardId, crateId, {
      'uid-dana': dana,
      'uid-sam': sam,
      'uid-kit': kit,
      'uid-noa': noa,
    }, levels: {
      'uid-dana': CrateLevel.manage,
      'uid-sam': CrateLevel.manage,
      'uid-kit': CrateLevel.manage,
      'uid-noa': CrateLevel.connect,
    });
    w.record.crates[crateId]!
      ..watched = true
      ..allow.clear();
  });

  tearDown(() async {
    for (final watch in watches) {
      watch.over();
    }
    watches.clear();
    SessionWatches.reset();
    SessionShares.reset();
    if (shared) await w.dispose();
  });

  /// The watch of the session, with its waits shortened.
  SessionWatch watch({
    Duration joinWait = const Duration(seconds: 30),
    Duration grace = const Duration(seconds: 30),
    Future<OrchardRecord?> Function()? record,
  }) {
    final s = SessionWatch(
      sessionId: _session,
      host: _host,
      record: record ?? () async => w.record,
      joinWait: joinWait,
      grace: grace,
      recheck: const Duration(milliseconds: 25),
      onNote: notes.add,
    );
    watches.add(s);
    return s;
  }

  /// The session is shared as a live view with [people], [enders] of them
  /// invited to end it.
  Future<void> share(List<String> people, {required Set<String> enders}) async {
    await w.share(people, enders: enders, watchOnly: const {});
    shared = true;
    SessionShares.add(_session, w.host);
  }

  Future<ShareViewerController> watching(String uid) async {
    final keys = {'uid-sam': sam, 'uid-kit': kit, 'uid-noa': noa}[uid]!;
    final v = await w.watch(uid, keys);
    await until(() => v.phase == ShareViewPhase.watching, what: '$uid watching');
    return v;
  }

  test('who counts: someone invited to end the session, watching now, who manages the Crate by the record', () {
    expect(mayWatch(w.record, crateId, 'uid-sam', 1790000000), isTrue);
    expect(mayWatch(w.record, crateId, 'uid-noa', 1790000000), isFalse);
    expect(mayWatch(w.record, crateId, 'uid-eve', 1790000000), isFalse, reason: 'not in the Orchard');
    expect(mayWatch(w.record, 'another-crate', 'uid-sam', 1790000000), isFalse);
    w.record.members['uid-sam']!.status = MemberStatus.suspended;
    expect(mayWatch(w.record, crateId, 'uid-sam', 1790000000), isFalse);
    w.record.members['uid-sam']!.status = MemberStatus.active;
    // Someone whose time in the Orchard ended no longer does.
    w.record.members['uid-sam']!.endsAt = 1790000000;
    expect(mayWatch(w.record, crateId, 'uid-sam', 1789999999), isTrue);
    expect(mayWatch(w.record, crateId, 'uid-sam', 1790000000), isFalse);
  });

  test('it waits for the first of those asked: nobody yet, someone who does not manage the Crate, someone who '
      'manages it but was not asked, then someone who was', () async {
    final s = watch();
    expect((s.phase, s.holdsTyping, s.closesAt), (SessionWatchPhase.choosing, true, null));
    var first = 'not yet';
    unawaited(s.firstWatcher.then((gaveUp) => first = '$gaveUp'));

    // noa was asked (and may end it) but does not manage the Crate; kit
    // manages it and was invited as someone who may type.
    await share(['uid-noa', 'uid-kit', 'uid-sam'], enders: {'uid-noa', 'uid-sam'});
    s.askedPeople();
    expect(s.phase, SessionWatchPhase.waiting);
    expect(s.asked.map((g) => g.uid), ['uid-noa', 'uid-sam']);
    await settle();
    expect(first, 'not yet');

    await watching('uid-noa');
    await watching('uid-kit');
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect((s.phase, s.holdsTyping, first), (SessionWatchPhase.waiting, true, 'not yet'));
    expect(w.host.endersWatching, {'uid-noa'});

    await watching('uid-sam');
    await until(() => s.phase == SessionWatchPhase.watched, what: 'sam counted');
    await settle();
    expect((first, s.holdsTyping, s.closesAt), ('null', false, null));
    expect(notes, isEmpty, reason: 'nothing to tell before the connection is made');
  });

  test('nobody asked joins in time: it gives up, and says so once', () async {
    final s = watch(joinWait: const Duration(milliseconds: 150));
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    expect(await s.firstWatcher, WatchGivenUp.nobodyJoined);
    expect(s.phase, SessionWatchPhase.over);
    expect(s.holdsTyping, isTrue);
    // Too late: nothing changes any more.
    await watching('uid-sam');
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(s.phase, SessionWatchPhase.over);
    expect(notes, isEmpty);
  });

  test('asking someone else while it waits starts the wait over', () async {
    final s = watch(joinWait: const Duration(milliseconds: 300));
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    await w.host.invite([w.pinned['uid-kit']!], enders: {'uid-kit'});
    s.askedPeople();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(s.phase, SessionWatchPhase.waiting, reason: 'the first wait would be over by now');
    expect(s.asked.map((g) => g.uid), ['uid-sam', 'uid-kit']);
    await watching('uid-kit');
    expect(await s.firstWatcher, isNull);
  });

  test('the person gives up, or the session goes: the wait ends as cancelled, and the watch is over', () async {
    final s = watch();
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    s.cancel();
    expect(await s.firstWatcher, WatchGivenUp.cancelled);
    expect(s.phase, SessionWatchPhase.over);
    s.cancel();
    s.over();

    // Through the registry, as a session that closed does it; also before
    // anyone was asked.
    final other = watch();
    SessionWatches.add(other);
    expect(SessionWatches.of(_session), same(other));
    expect(SessionWatches.active.value.keys, [_session]);
    SessionWatches.end(_session);
    expect(await other.firstWatcher, WatchGivenUp.cancelled);
    expect(SessionWatches.of(_session), isNull);
    expect(SessionWatches.active.value, isEmpty);
    SessionWatches.end(_session);

    // A session watched a second time: the watch it had is over.
    final a = watch();
    final b = watch();
    SessionWatches.add(a);
    SessionWatches.add(b);
    expect(a.phase, SessionWatchPhase.over);
    expect(b.phase, SessionWatchPhase.choosing);
    expect(SessionWatches.of(_session), same(b));
  });

  test('connected: held when nobody watches, watched again when someone does, closed after a while of nobody',
      () async {
    final s = watch(grace: const Duration(milliseconds: 400));
    await share(['uid-sam', 'uid-kit'], enders: {'uid-sam', 'uid-kit'});
    s.askedPeople();
    final v = await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    expect((s.phase, s.holdsTyping), (SessionWatchPhase.watched, false));
    expect(notes, isEmpty);

    // sam leaves: held at once, with a time at which it closes.
    final before = DateTime.now();
    await v.leave();
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    expect(s.holdsTyping, isTrue);
    expect(notes, [WatchNote.held]);
    final closes = s.closesAt!;
    expect(closes.difference(before).inMilliseconds, inInclusiveRange(380, 900));

    // kit joins in time: watched again, and nothing closes.
    await watching('uid-kit');
    await until(() => s.phase == SessionWatchPhase.watched, what: 'watched again');
    expect((s.holdsTyping, s.closesAt), (false, null));
    expect(notes, [WatchNote.held, WatchNote.watchedAgain]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(notes, [WatchNote.held, WatchNote.watchedAgain], reason: 'the first hold ended with kit');

    // Nobody for longer than it allows: whoever listens is told to close
    // it, once.
    await w.host.remove('uid-kit');
    await until(() => notes.contains(WatchNote.closedUnwatched), what: 'the end of the grace');
    expect(notes, [WatchNote.held, WatchNote.watchedAgain, WatchNote.held, WatchNote.closedUnwatched]);
    expect(s.phase, SessionWatchPhase.held, reason: 'it is over when the session is closed, by whoever was told');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(notes.where((n) => n == WatchNote.closedUnwatched), hasLength(1));
    // The session closed: nothing is said after that.
    s.over();
    final said = notes.length;
    await Future<void>.delayed(const Duration(milliseconds: 100));
    expect(notes, hasLength(said));
  });

  // 3.0: while ZestSSH Cloud cannot be reached nobody can
  // be asked to watch, and a session may then be let go on with nobody
  // watching (who may, and what is kept of it, is the gate's to see to).
  test('let go on with nobody watching before it connects: the connection may be made, nothing is held, and it '
      'says so once there is a session to say it of', () async {
    final s = watch(grace: const Duration(milliseconds: 150));
    var first = 'not yet';
    unawaited(s.firstWatcher.then((gaveUp) => first = '$gaveUp'));
    var told = 0;
    s.addListener(() => told++);
    expect(s.goUnwatched(), isTrue);
    await settle();
    expect((s.phase, s.holdsTyping, s.closesAt, first), (SessionWatchPhase.unwatched, false, null, 'null'));
    expect(notes, isEmpty, reason: 'there is no session yet to say it of');
    expect((s.ranUnwatched, told), (false, 1), reason: 'let go on, and not running yet');
    s.connected();
    expect(notes, [WatchNote.unwatched]);
    expect((s.ranUnwatched, told), (true, 2), reason: 'whoever looks at it is told that it runs');
    // Nobody watching is what it is: not held, and not closed after a while.
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect((s.phase, s.holdsTyping, s.closesAt), (SessionWatchPhase.unwatched, false, null));
    expect(notes, [WatchNote.unwatched]);
    // Let go on twice is let go on once, and what is typed goes through.
    expect(s.goUnwatched(), isFalse);
    expect(notes, [WatchNote.unwatched]);
    final inner = _Shell();
    WatchedShell(inner, s).write(Uint8List.fromList([0x6c, 0x73]));
    expect(inner.written, [0x6c, 0x73]);
    expect(s.dropped, 0);
  });

  test('let go on while it waits for those asked: the wait gives up no more, and whoever joins afterwards watches',
      () async {
    final s = watch(joinWait: const Duration(milliseconds: 150));
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    expect(s.phase, SessionWatchPhase.waiting);
    expect(s.goUnwatched(), isTrue);
    expect(await s.firstWatcher, isNull);
    await Future<void>.delayed(const Duration(milliseconds: 350));
    expect(s.phase, SessionWatchPhase.unwatched, reason: 'the wait it was under gives up nothing any more');
    // sam joins after all, before the connection is made: watched, with
    // nothing to tell yet.
    await watching('uid-sam');
    await until(() => s.phase == SessionWatchPhase.watched, what: 'sam counted');
    expect(notes, isEmpty);
    s.connected();
    await settle();
    expect(notes, isEmpty, reason: 'it connects as a watched session');
    expect(s.ranUnwatched, isFalse, reason: 'it never ran with nobody watching');
  });

  test('a held session let go on: held no longer, the wait it was under closes nothing, and someone watching '
      'makes it a watched session again', () async {
    final s = watch(grace: const Duration(milliseconds: 300));
    await share(['uid-sam', 'uid-kit'], enders: {'uid-sam', 'uid-kit'});
    s.askedPeople();
    final v = await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    await v.leave();
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    expect(s.closesAt, isNotNull);
    final inner = _Shell();
    final shell = WatchedShell(inner, s);
    shell.write(Uint8List.fromList([0x61]));
    expect(inner.written, isEmpty);

    expect(s.ranUnwatched, isFalse);
    expect(s.goUnwatched(), isTrue);
    expect((s.phase, s.holdsTyping, s.closesAt, s.ranUnwatched), (SessionWatchPhase.unwatched, false, null, true));
    expect(notes, [WatchNote.held, WatchNote.unwatched]);
    shell.write(Uint8List.fromList([0x62]));
    expect(inner.written, [0x62]);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(notes, [WatchNote.held, WatchNote.unwatched], reason: 'the wait it was held under closes nothing');
    expect(s.phase, SessionWatchPhase.unwatched);

    // kit watches: a watched session again, by the rule as it always is.
    await watching('uid-kit');
    await until(() => s.phase == SessionWatchPhase.watched, what: 'watched again');
    expect(notes, [WatchNote.held, WatchNote.unwatched, WatchNote.watchedAgain]);
    // Someone is watching: there is nothing to go on from.
    expect(s.goUnwatched(), isFalse);
    expect(s.phase, SessionWatchPhase.watched);
    expect(notes, hasLength(3));
    await w.host.remove('uid-kit');
    await until(() => s.phase == SessionWatchPhase.held, what: 'held again');
    expect(s.holdsTyping, isTrue);
    expect(notes.last, WatchNote.held);
  });

  test('a watch that is over is let go on by nothing', () async {
    final s = watch();
    s.over();
    expect(s.goUnwatched(), isFalse);
    expect((s.phase, s.holdsTyping), (SessionWatchPhase.over, true));
    s.connected();
    expect(notes, isEmpty);
    expect(s.ranUnwatched, isFalse);
    // Nor is there anything of it to hold open, or to close.
    s.holdOpen();
    s.closeAfterGrace();
    expect((s.phase, s.closesAt), (SessionWatchPhase.over, null));
  });

  test('a held session is not closed while its person is asked whether it goes on: the wait starts over once they '
      'have answered, and where two are asked, once both have', () async {
    final s = watch(grace: const Duration(milliseconds: 250));
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    final v = await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    // Someone watches: nothing to hold open, and nothing to start.
    s.holdOpen();
    s.closeAfterGrace();
    expect((s.phase, s.closesAt), (SessionWatchPhase.watched, null));
    await v.leave();
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    expect(s.closesAt, isNotNull);
    var told = 0;
    s.addListener(() => told++);

    s.holdOpen();
    expect((s.closesAt, s.holdsTyping, told), (null, true, 1));
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(s.phase, SessionWatchPhase.held, reason: 'not closed while asked');
    expect(notes, [WatchNote.held]);
    // Asked a second time meanwhile: the first answer starts no wait, the
    // second does.
    s.holdOpen();
    expect(told, 1);
    s.closeAfterGrace();
    expect((s.closesAt, told), (null, 1));
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(notes, [WatchNote.held]);
    final before = DateTime.now();
    s.closeAfterGrace();
    expect(told, 2);
    expect(s.closesAt!.difference(before).inMilliseconds, inInclusiveRange(200, 300), reason: 'the whole wait, anew');
    // An answer nobody asked for changes nothing.
    final closes = s.closesAt;
    s.closeAfterGrace();
    expect((s.closesAt, told), (closes, 2));
    await until(() => notes.contains(WatchNote.closedUnwatched), what: 'closed after the wait');
    expect(notes, [WatchNote.held, WatchNote.closedUnwatched]);
  });

  test('held anew while its person is still being asked (whoever watched came back and left again): no wait runs '
      'until they have answered', () async {
    final s = watch(grace: const Duration(milliseconds: 250));
    await share(['uid-sam', 'uid-kit'], enders: {'uid-sam', 'uid-kit'});
    s.askedPeople();
    final v = await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    await v.leave();
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    s.holdOpen();
    await watching('uid-kit');
    await until(() => s.phase == SessionWatchPhase.watched, what: 'watched again');
    await w.host.remove('uid-kit');
    await until(() => s.phase == SessionWatchPhase.held, what: 'held again');
    expect(s.closesAt, isNull, reason: 'its person is still being asked');
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(notes, [WatchNote.held, WatchNote.watchedAgain, WatchNote.held]);
    s.closeAfterGrace();
    expect(s.closesAt, isNotNull);
    await until(() => notes.contains(WatchNote.closedUnwatched), what: 'closed after the wait');
  });

  test('someone who no longer manages the Crate stops counting, without the share saying anything', () async {
    final s = watch();
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    expect(s.phase, SessionWatchPhase.watched);

    // The record changes: sam's role now only opens the Crate.
    w.record.members['uid-sam']!.role = 'role-use';
    await until(() => s.phase == SessionWatchPhase.held, what: 'the record looked at again');
    expect(notes, [WatchNote.held]);
    expect(w.host.endersWatching, {'uid-sam'}, reason: 'still watching, and still able to end it');
    // Back among those who manage it.
    w.record.members['uid-sam']!.role = 'role-manage';
    await until(() => s.phase == SessionWatchPhase.watched, what: 'counted again');
    expect(notes, [WatchNote.held, WatchNote.watchedAgain]);
  });

  test('a record that cannot be read lets nobody count as watching', () async {
    var broken = false;
    final s = watch(record: () async {
      if (broken) throw StateError('closed');
      return w.record;
    });
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    broken = true;
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    broken = false;
    await until(() => s.phase == SessionWatchPhase.watched, what: 'read again');

    // Nor does a record that is not there.
    final none = SessionWatch(
        sessionId: 's2', host: _host, record: () async => null, recheck: const Duration(milliseconds: 25));
    watches.add(none);
    SessionShares.add('s2', w.host);
    none.askedPeople();
    await Future<void>.delayed(const Duration(milliseconds: 120));
    expect(none.phase, SessionWatchPhase.waiting);
  });

  test('the share stops while the session runs: nobody is watching', () async {
    final s = watch();
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    await SessionShares.stop(_session);
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    expect(notes, [WatchNote.held]);

    // Shared again with someone who manages the Crate, invited to end it:
    // watched again once they are there.
    final again = World()..record = w.record;
    addTearDown(again.dispose);
    await again.share(['uid-kit'], enders: {'uid-kit'}, watchOnly: const {});
    SessionShares.add(_session, again.host);
    final v = await again.watch('uid-kit', kit);
    await until(() => v.phase == ShareViewPhase.watching);
    await until(() => s.phase == SessionWatchPhase.watched, what: 'the new share counted');
    expect(notes, [WatchNote.held, WatchNote.watchedAgain]);
  });

  test('the shell of a watched session says why the connection under it ended, when that one can', () async {
    final s = watch();
    final saying = _SayingShell();
    final ShellService shell = WatchedShell(saying, s);
    expect(shell, isA<ShellEndReason>());
    saying.reason.complete('SSHSocketError(SocketException: Broken pipe)');
    expect(await (shell as ShellEndReason).endReason, 'SSHSocketError(SocketException: Broken pipe)');
    expect(await WatchedShell(_Shell(), s).endReason, isNull, reason: 'the one under it cannot say');
  });

  test('the shell of a watched session: what is typed is dropped unless someone is watching; the rest passes',
      () async {
    final s = watch();
    final inner = _Shell();
    final ShellService shell = WatchedShell(inner, s);
    expect(shell, isNot(isA<SshService>()), reason: 'what works beside the terminal asks for an SshService');

    // Before anyone watches, and while people are asked.
    shell.write(Uint8List.fromList([0x61]));
    await share(['uid-sam'], enders: {'uid-sam'});
    s.askedPeople();
    shell.write(Uint8List.fromList([0x62]));
    expect(inner.written, isEmpty);
    expect(s.dropped, 2);

    final v = await watching('uid-sam');
    expect(await s.firstWatcher, isNull);
    s.connected();
    await settle();
    shell.write(Uint8List.fromList([0x63, 0x0d]));
    expect(inner.written, [0x63, 0x0d]);
    expect(s.dropped, 2);

    await v.leave();
    await until(() => s.phase == SessionWatchPhase.held, what: 'held');
    shell.write(Uint8List.fromList([0x64]));
    expect(inner.written, [0x63, 0x0d]);
    expect(s.dropped, 3);

    // Over: nothing typed goes anywhere any more.
    s.over();
    shell.write(Uint8List.fromList([0x65]));
    expect(inner.written, [0x63, 0x0d]);

    // Everything else is the shell's own.
    await shell.connect();
    shell.resize(120, 40);
    await shell.disconnect();
    expect(inner.asked, ['connect', 'resize:120,40', 'disconnect']);
    expect((shell.isConnected, shell.exitedCleanly, shell.isEncryptedSsh), (true, true, true));
    expect(shell.stdout, same(inner.stdout));
    expect(shell.connectionState, same(inner.connectionState));
  });
}
