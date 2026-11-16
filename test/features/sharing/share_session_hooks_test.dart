// Sharing a real session (share_providers.dart with terminal_providers.dart):
// the app's own session of a host in a Crate, started the way the app
// starts one, against a host on this machine (a TCP server, reached with
// the Telnet shell so no SSH server is needed). What the session's terminal
// shows is what a viewer sees; a viewer's keys reach the host only while
// they hold the keyboard and the app is unlocked; the share ends with the
// session. The relay and ZestSSH Cloud are the in-memory ones.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

import '../orchards/fake_crate_server.dart';
import 'share_fakes.dart';

const _dana = 'uid-dana';
const _sam = 'uid-sam';
const _kit = 'uid-kit';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async =>
      dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// A Squeezed account, without RevenueCat or the backend.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app lock, as the test sets it.
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  void set(bool locked) => state = locked;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The host: a TCP server on this machine that keeps what it was sent.
class _Host {
  late final ServerSocket _server;
  final sockets = <Socket>[];
  final received = <int>[];

  Future<void> start() async {
    _server = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    _server.listen((socket) {
      sockets.add(socket);
      socket.listen(received.addAll, onError: (Object _) {});
    });
  }

  int get port => _server.port;

  /// What the host was sent, as text (Telnet's own bytes are not text).
  String get text => latin1.decode(received);

  void say(String text) {
    sockets.last.add(utf8.encode(text));
  }

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

String _shown(Terminal terminal) {
  final b = StringBuffer();
  for (var y = 0; y < terminal.buffer.lines.length; y++) {
    b.writeln(terminal.buffer.lines[y].getText());
  }
  return b.toString();
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late _Host host;
  late FakeShareRelay relay;
  late FakeShareApi api;
  late _Lock lock;
  late OrchardService dana;
  late String orchardId;
  CrateAuthor? me;
  final notices = <(String, ShareNote, String?)>[];
  final viewers = <ShareViewerController>[];

  setUpAll(() async {
    for (final uid in [_dana, _sam, _kit]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  Future<void> join(String uid, String role) async {
    await dana.invite(orchardId, email: '${uid.substring(4)}@example.com', role: role);
    final invite = (await dana.invites(orchardId)).single;
    server.acceptAs(orchardId, invite.id, uid);
    await dana.confirmInvite(orchardId, (await dana.invites(orchardId)).single);
  }

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    notices.clear();
    shareNoticeHandler = (sessionId, note, who) => notices.add((sessionId, note, who));
    host = _Host();
    await host.start();
    relay = FakeShareRelay();
    api = FakeShareApi();
    lock = _Lock();
    me = CrateAuthor(uid: _dana, keys: keys[_dana]!);
    server = FakeCrateServer(accountUid: _dana);
    for (final uid in [_dana, _sam, _kit]) {
      await server.publish(uid, keys[uid]!, email: '${uid.substring(4)}@example.com');
    }
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => lock),
      orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => me)),
      shareApiProvider.overrideWithValue(api),
      shareLinkFactoryProvider
          .overrideWithValue((shareId, {required host}) => host ? relay.host() : relay.viewer(_sam)),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);

    // dana's Orchard on this device: sam and kit can open its Crate.
    dana = OrchardService(
      server: server.as(_dana),
      databases: container.read(orchardDatabasesProvider.notifier),
      author: () async => CrateAuthor(uid: _dana, keys: keys[_dana]!),
    );
    orchardId = await dana.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(orchardId).roles.values.single.id;
    await join(_sam, member);
    await join(_kit, member);
    await dana.refresh();
  });

  tearDown(() async {
    shareNoticeHandler = null;
    for (final v in viewers) {
      v.dispose();
    }
    viewers.clear();
    await SessionShares.stopAll();
    SessionShares.reset();
    container.dispose();
    await host.stop();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  Future<Connection> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 10, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: 'Web 1',
          host: '127.0.0.1',
          port: Value(host.port),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
    return (await db.connectionsDao.getById(id))!;
  }

  /// A session of a host in the Orchard's Crate, connected ([tcp]: to the
  /// host on this machine; false for a test with a shell of its own).
  Future<String> teamSession({bool tcp = true}) async {
    await container.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
    final connection = await addHost(container.read(orchardDatabasesProvider)[orchardId]!, 'h-web1');
    final id = container.read(activeSessionsProvider.notifier).startSession(connection)!;
    await until(() => container.read(activeSessionsProvider)[id]?.status == SessionStatus.connected,
        what: 'the session');
    if (tcp) await until(() => host.sockets.isNotEmpty, what: 'the host\'s side of it');
    return id;
  }

  Terminal terminalOf(String sessionId) => container.read(activeSessionsProvider)[sessionId]!.session!.terminal;

  /// sam's device joins the live view of [share].
  Future<ShareViewerController> watch(ShareHostController share) async {
    final sealed = [
      for (final c in api.created) c.invites[_sam],
      for (final i in api.invited) i.invites[_sam],
    ].whereType<Uint8List>().last;
    final invitation = await SignedShareInvitation.open(sealed, keys[_sam]!.encryption, shareId: share.shareId);
    final v = ShareViewerController(invitation: invitation, keys: keys[_sam]!, link: relay.viewer(_sam));
    viewers.add(v);
    v.start();
    await until(() => v.phase == ShareViewPhase.watching, what: 'sam watching');
    return v;
  }

  test('what can be shared: a session of a host in a Crate, on a device that holds the account\'s keys', () async {
    final sharing = container.read(sessionSharingProvider);
    expect(await sharing.availabilityFor('no-such-session'), (null, ShareUnavailable.notReady));

    // A host in the Tree: ZestSSH knows nobody to share it with.
    final mine = await addHost(tree, 'h-mine');
    final treeSession = container.read(activeSessionsProvider.notifier).startSession(mine)!;
    await until(() => container.read(activeSessionsProvider)[treeSession]?.status == SessionStatus.connected);
    expect(await sharing.availabilityFor(treeSession), (null, ShareUnavailable.notInCrate));
    expect(container.read(activeSessionsProvider.notifier).sessionDatabaseOf('h-mine'), same(tree));

    final sessionId = await teamSession();
    final (context, why) = await sharing.availabilityFor(sessionId);
    expect(why, isNull);
    expect((context!.orchardId, context.connectionId, context.crateName, context.myUid),
        (orchardId, 'h-web1', 'Production', _dana));
    expect(context.people.map((p) => (p.uid, p.email)), [(_kit, 'kit@example.com'), (_sam, 'sam@example.com')]);
    expect(container.read(activeSessionsProvider.notifier).sessionDatabaseOf('h-web1'),
        same(container.read(orchardDatabasesProvider)[orchardId]));

    // The account's keys are not on this device (yet).
    me = null;
    container.read(orchardAuthorProvider).forget();
    expect(await sharing.availabilityFor(sessionId), (null, ShareUnavailable.notReady));
    // A host in the Tree is said to be just that, keys or no keys: bringing
    // the keys here would not make it one to share.
    expect(await sharing.availabilityFor(treeSession), (null, ShareUnavailable.notInCrate));
    await expectLater(
      sharing.start(sessionId, context, mode: ShareMode.live, people: {_sam}),
      throwsA(isA<ShareStartFailed>().having((e) => e.problem, 'problem', ShareStartProblem.notReady)),
    );
    expect(api.created, isEmpty);
  });

  test('a live view of a real session: shown as the terminal shows it, typed into only by who holds the keyboard',
      () async {
    final sessionId = await teamSession();
    final sessions = container.read(activeSessionsProvider.notifier);
    final sharing = container.read(sessionSharingProvider);
    host.say('Debian GNU/Linux 12\r\nweb1 login: ');
    await until(() => _shown(terminalOf(sessionId)).contains('web1 login'), what: 'the session\'s own screen');

    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam}, keyboardRequests: true);
    expect(SessionShares.of(sessionId), same(share));
    expect((share.mode, share.connectionId, share.orchardId, share.keyboardRequests),
        (ShareMode.live, 'h-web1', orchardId, true));
    expect(api.created.single.invites.keys, [_sam]);
    expect(SessionShares.nameOf(sessionId, _sam), 'sam@example.com');
    expect(SessionShares.nameOf(sessionId, _kit), 'kit@example.com', reason: 'everyone who could be invited later');

    // sam joins and sees what is already there, then what the host says.
    final viewer = await watch(share);
    sameScreen(terminalOf(sessionId), viewer.terminal);
    expect(notices, contains((sessionId, ShareNote.joined, 'sam@example.com')),
        reason: 'named by address, not by account id');
    host.say('\x1b[1;32mdeploy\x1b[0m\r\nPassword: ');
    await until(() => _shown(viewer.terminal).contains('Password:'), what: 'the output on sam\'s screen');
    sameScreen(terminalOf(sessionId), viewer.terminal);

    // The window is resized: sam's view follows.
    terminalOf(sessionId).resize(100, 30);
    host.say('\r\nresized\r\n');
    await until(() => _shown(viewer.terminal).contains('resized'), what: 'the output after the resize');
    expect((viewer.terminal.viewWidth, viewer.terminal.viewHeight), (100, 30));
    sameScreen(terminalOf(sessionId), viewer.terminal);

    // Before the keyboard is his, nothing sam types reaches the host.
    viewer.terminal.textInput('too-early');
    // dana hands it over: now it does, exactly as typed.
    expect(share.giveKeyboard(_sam), isTrue);
    await until(() => viewer.isTyping, what: 'the keyboard');
    viewer.terminal.textInput('uname -a\r');
    await until(() => host.text.contains('uname -a\r'), what: 'sam\'s keys at the host');
    expect(host.text.contains('too-early'), isFalse);

    // The app locks while sam still believes the keyboard is his (the word
    // that it was taken back is on its way): nothing of his is typed.
    lock.set(true);
    sessions.shareTerminalOf(sessionId)!.type(utf8.encode('typed-while-locked'));
    viewer.terminal.textInput('also-while-locked');
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(host.text.contains('while-locked'), isFalse);
    lock.set(false);
    viewer.terminal.textInput('after-unlock\r');
    await until(() => host.text.contains('after-unlock\r'), what: 'sam\'s keys after the unlock');
    expect(host.text.contains('while-locked'), isFalse);

    // The session ends: the share ends with it, and sam is told it closed.
    await sessions.endSession(sessionId);
    expect(SessionShares.of(sessionId), isNull);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the end');
    expect(viewer.end, ShareViewEnd.sessionClosed);
    await until(() => api.ended.isNotEmpty);
    expect(api.ended, [share.shareId]);
    // Nothing typed after that goes anywhere: there is nowhere for it to go.
    sessions.shareTerminalOf(sessionId)?.type(utf8.encode('after-the-end'));
    await settle();
    expect(host.text.contains('after-the-end'), isFalse);
  });

  test('someone invited to end the session ends it: it closes on the device it runs on, the team\'s log has who '
      'ended it, and the person sharing is told', () async {
    TeamSessionLogs.reset();
    addTearDown(TeamSessionLogs.reset);
    final sessionId = await teamSession();
    final sessions = container.read(activeSessionsProvider.notifier);
    final sharing = container.read(sessionSharingProvider);
    // The Crate logs its sessions from here on, and this one's log is open
    // (by hand: the app's own would go through ZestSSH Cloud).
    final crateId = server.recordOf(orchardId).crates.keys.single;
    await dana.setCrateSessionLogs(orchardId, crateId, true);
    TeamSessionLogs.expect(sessionId);
    TeamSessionLogs.started(
        sessionId,
        await dana.startTeamSessionLog(orchardId, crateId,
            label: 'Web 1', host: '127.0.0.1', port: host.port, connectionId: 'h-web1'));
    expect(TeamSessionLogs.isLogged(sessionId), isTrue);

    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!,
        mode: ShareMode.live, people: {_sam}, keyboardRequests: true, enders: {_sam});
    expect((share.guests.single.canType, share.guests.single.canEnd), (false, true));
    final viewer = await watch(share);
    expect((viewer.mayEnd, viewer.mayAsk), (true, false));
    expect(share.endersWatching, {_sam});
    host.say('deploy@web1:~\$ ');
    await until(() => _shown(viewer.terminal).contains('deploy@web1'), what: 'the output on sam\'s screen');
    // Whoever may end the session never types into it.
    expect(share.giveKeyboard(_sam), isFalse);
    viewer.terminal.textInput('never-typed');
    await settle();

    notices.clear();
    viewer.endSession();
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the end');
    expect(viewer.end, ShareViewEnd.sessionClosed, reason: 'told as for any session that closed');
    expect(notices.first, (sessionId, ShareNote.endAsked, 'sam@example.com'), reason: 'named by address');
    expect(notices.where((n) => n.$2 == ShareNote.endAsked), hasLength(1));
    expect(SessionShares.of(sessionId), isNull);
    expect(share.isEnded, isTrue);
    expect(container.read(activeSessionsProvider)[sessionId]?.status, isNot(SessionStatus.connected));
    await until(() => api.ended.isNotEmpty, what: 'the share ended at ZestSSH Cloud');
    expect(api.ended, [share.shareId]);
    expect(TeamSessionLogs.isLogged(sessionId), isFalse);
    // Nothing reaches the host any more, and nothing sam typed ever did.
    sessions.shareTerminalOf(sessionId)?.type(utf8.encode('after-the-end'));
    await settle();
    expect(host.text, isNot(contains('after-the-end')));
    expect(host.text, isNot(contains('never-typed')));

    // The team's log of the session says who ended it, after who joined.
    var logged = '';
    for (var i = 0; i < 200 && !logged.contains('ended the session'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entries = (await dana.teamSessionLogs(orchardId, crateId)).entries;
      if (entries.isNotEmpty) logged = (await dana.teamSessionLogText(orchardId, crateId, entries.single)).text;
    }
    expect(logged, contains('[ZestSSH] sam@example.com joined'));
    expect(logged, contains('[ZestSSH] sam@example.com ended the session'));
    expect(logged.indexOf('joined'), lessThan(logged.indexOf('ended the session')));
  });

  test('a session with no terminal is not shown to anyone, and its screen is read when asked, not before', () async {
    final sessions = container.read(activeSessionsProvider.notifier);
    expect(sessions.shareTerminalOf('no-such-session'), isNull);
    final sessionId = await teamSession();
    final shared = sessions.shareTerminalOf(sessionId)!;
    host.say('one\r\n');
    await until(() => _shown(terminalOf(sessionId)).contains('one'));
    final first = shared.snapshot();
    expect((first.columns, first.rows), (terminalOf(sessionId).viewWidth, terminalOf(sessionId).viewHeight));
    expect(first.text, contains('one'));
    host.say('two\r\n');
    await until(() => _shown(terminalOf(sessionId)).contains('two'));
    expect(shared.snapshot().text, contains('two'));
  });

  test('a share that cannot start says why, and leaves nothing behind', () async {
    final sessionId = await teamSession();
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);

    Future<ShareStartProblem> refused(Object failure) async {
      api.failNext = failure;
      try {
        await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam});
      } on ShareStartFailed catch (e) {
        expect(SessionShares.of(sessionId), isNull);
        expect(SessionShares.active.value, isEmpty);
        return e.problem;
      }
      fail('it started');
    }

    expect(await refused(const ShareNoAccess([_sam])), ShareStartProblem.noAccess);
    expect(await refused(const OrchardServerException(429, 'too-many-shares')), ShareStartProblem.tooMany);
    expect(await refused(const OrchardServerException(429, 'rate-limited')), ShareStartProblem.failed);
    expect(await refused(const OrchardServerException(500, null)), ShareStartProblem.failed);
    expect(await refused(const SocketException('offline')), ShareStartProblem.failed);
    expect(api.created, isEmpty);

    // What was caught is carried, for whoever says how ZestSSH Cloud stands.
    Future<Object?> stoppedBy(Object failure) async {
      api.failNext = failure;
      try {
        await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam});
      } on ShareStartFailed catch (e) {
        return e.cause;
      }
      fail('it started');
    }

    const fault = OrchardServerException(503, null);
    expect(await stoppedBy(fault), same(fault));
    const dead = SocketException('offline');
    expect(await stoppedBy(dead), same(dead));
    const tooMany = OrchardServerException(429, 'too-many-shares');
    expect(await stoppedBy(tooMany), same(tooMany));

    // Nobody picked, someone who is not among the Crate's people, or the
    // session gone: there is nothing to start.
    for (final people in [<String>{}, {'uid-stranger'}]) {
      await expectLater(
        sharing.start(sessionId, context!, mode: ShareMode.live, people: people),
        throwsA(isA<ShareStartFailed>().having((e) => e.problem, 'problem', ShareStartProblem.notReady)),
      );
    }
    await expectLater(
      sharing.start('no-such-session', context!, mode: ShareMode.live, people: {_sam}),
      throwsA(isA<ShareStartFailed>().having((e) => e.problem, 'problem', ShareStartProblem.notReady)),
    );
    expect(api.created, isEmpty);
    expect(notices, isEmpty);

    // Someone whose keys changed since they were compared is left out, even
    // when picked; with nobody else picked, nothing starts.
    final db = container.read(orchardDatabasesProvider)[orchardId]!;
    await db.customStatement(
        "UPDATE member_keys SET replaced_since_compared = 1, verified_by_me = 0, verified_by = '[]' WHERE uid = ?",
        [_sam]);
    final (changed, _) = await sharing.availabilityFor(sessionId);
    await expectLater(
      sharing.start(sessionId, changed!, mode: ShareMode.live, people: {_sam}),
      throwsA(isA<ShareStartFailed>().having((e) => e.problem, 'problem', ShareStartProblem.notReady)),
    );
    final share = await sharing.start(sessionId, changed, mode: ShareMode.live, people: {_sam, _kit});
    expect(api.created.single.invites.keys, [_kit]);
    expect(share.guests.map((g) => g.uid), [_kit]);
  });

  test('a shared tmux session needs no terminal, names the session, and nobody is ever handed a keyboard', () async {
    final sessionId = await teamSession();
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!,
        mode: ShareMode.tmux, people: {_sam, _kit}, tmuxSession: 'shared-k7q', keyboardRequests: true);
    expect((share.mode, share.tmuxSession, share.keyboardRequests), (ShareMode.tmux, 'shared-k7q', false));
    expect(api.created.single.mode, ShareMode.tmux);
    final invitation = (await SignedShareInvitation.open(api.created.single.invites[_sam]!, keys[_sam]!.encryption,
            shareId: share.shareId))
        .invitation;
    expect((invitation.connectionId, invitation.tmuxSession, invitation.offer), ('h-web1', 'shared-k7q', null));
    // What the terminal shows goes nowhere.
    host.say('nothing of this is relayed\r\n');
    await until(() => _shown(terminalOf(sessionId)).contains('nothing of this'));
    await Future<void>.delayed(ShareHostController.gather * 3);
    expect(relay.passed, isEmpty);
    await SessionShares.stop(sessionId);
    expect(api.ended, [share.shareId]);
    expect(notices.last, (sessionId, ShareNote.stopped, null));
  });

  test('the last thing the host says before it hangs up still reaches whoever watches, then the view ends', () async {
    final sessionId = await teamSession();
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam});
    final viewer = await watch(share);

    // The remote shell says goodbye and closes at once (someone typed exit).
    host.say('logout\r\nConnection to web1 closed.\r\n');
    await host.sockets.last.flush();
    await host.sockets.last.close();

    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the end');
    expect(viewer.end, ShareViewEnd.sessionClosed);
    expect(_shown(viewer.terminal), contains('Connection to web1 closed.'));
    expect(SessionShares.of(sessionId), isNull);
  });

  test('output still waiting to be drawn when the stream closes reaches whoever watches', () async {
    final shells = <_DroppingShell>[];
    final sessions = container.read(activeSessionsProvider.notifier);
    sessions.debugShellFor = (connection) {
      final shell = _DroppingShell();
      shells.add(shell);
      return shell;
    };
    final sessionId = await teamSession(tcp: false);
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam});
    final viewer = await watch(share);

    // The output ends (the stream is done) with something not drawn yet.
    shells.single.say('the very last line\r\n');
    await shells.single.endOutput();
    await until(() => _shown(viewer.terminal).contains('the very last line'), what: 'the last line');
    sameScreen(terminalOf(sessionId), viewer.terminal);
    expect(share.isEnded, isFalse, reason: 'the connection itself is still there');
    await sessions.endSession(sessionId);
  });

  test('a connection that drops without a word ends the share there and then; what comes back is not shared', () async {
    final shells = <_DroppingShell>[];
    final sessions = container.read(activeSessionsProvider.notifier);
    sessions.debugShellFor = (connection) {
      final shell = _DroppingShell();
      shells.add(shell);
      return shell;
    };
    final sessionId = await teamSession(tcp: false);
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam}, keyboardRequests: true);
    final viewer = await watch(share);
    shells.single.say('before the drop\r\n');
    await until(() => _shown(viewer.terminal).contains('before the drop'), what: 'the output');
    expect(share.giveKeyboard(_sam), isTrue);
    await until(() => viewer.isTyping, what: 'the keyboard');
    viewer.terminal.textInput('ok');
    await until(() => utf8.decode(shells.single.written) == 'ok', what: 'sam\'s keys');

    // What the share types through, as it holds it from when it started.
    final typesInto = sessions.shareTerminalOf(sessionId)!;

    // The network goes (no exit, no word): the tab stays, disconnected. The
    // share ends there and then, not when (or if) a reconnect is tried.
    shells.single.drop();
    await settle();
    expect(SessionShares.of(sessionId), isNull);
    expect(share.isEnded, isTrue);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    expect(viewer.end, ShareViewEnd.sessionClosed);
    expect(container.read(activeSessionsProvider)[sessionId]?.status, isNot(SessionStatus.connected));

    // Whatever sam's device still sends, and whatever shell the session
    // gets when it reconnects, nothing of his is typed: not through what the
    // share held, and not through what the session hands out now.
    typesInto.type(utf8.encode('after-the-drop'));
    sessions.shareTerminalOf(sessionId)?.type(utf8.encode('after-the-drop'));
    await settle();
    for (final shell in shells) {
      expect(utf8.decode(shell.written), isNot(contains('after-the-drop')));
    }
    await sessions.endSession(sessionId);
  });

  test('while the tab is in tmux control mode, nothing a viewer types is sent: that channel carries tmux commands',
      () async {
    final sessionId = await teamSession();
    final sessions = container.read(activeSessionsProvider.notifier);
    final sharing = container.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    final share = await sharing.start(sessionId, context!, mode: ShareMode.live, people: {_sam}, keyboardRequests: true);
    final viewer = await watch(share);
    expect(share.giveKeyboard(_sam), isTrue);
    await until(() => viewer.isTyping, what: 'the keyboard');
    viewer.terminal.textInput('before-tmux');
    await until(() => host.text.contains('before-tmux'), what: 'sam\'s keys');

    // dana types tmux -CC: the host answers with the control mode marker,
    // and tmux gets its first commands on this very channel.
    terminalOf(sessionId).textInput('tmux -CC\r');
    await until(() => host.text.contains('tmux -CC'), what: 'what dana typed');
    final before = host.received.length;
    host.say('\x1bP1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
    await until(() => host.received.length > before, what: 'tmux control mode (its first command)');
    viewer.terminal.textInput('in-tmux\r');
    sessions.shareTerminalOf(sessionId)!.type(utf8.encode('also-in-tmux\r'));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    expect(host.text, isNot(contains('in-tmux')));

    // tmux exits: the channel is a terminal's again, and what sam types
    // (he still holds the keyboard) is typed.
    host.say('%exit\r\n\x1b\\');
    await until(() => !container.read(tmuxHostProvider(sessionId)).active, what: 'control mode over');
    viewer.terminal.textInput('after-tmux\r');
    await until(() => host.text.contains('after-tmux'), what: 'sam\'s keys after tmux');
    expect(host.text, isNot(contains('in-tmux')));
  });
}

/// A shell the test drives: what it says, what it was sent, and a
/// connection that goes without a clean exit.
class _DroppingShell extends ShellService {
  final _stdout = StreamController<Uint8List>.broadcast();
  final _state = StreamController<bool>.broadcast();
  final written = <int>[];
  bool _connected = false;

  void say(String text) => _stdout.add(Uint8List.fromList(utf8.encode(text)));

  /// Nothing more will be said (the stream is done); the connection stays.
  Future<void> endOutput() => _stdout.close();

  /// The connection is lost.
  void drop() {
    _connected = false;
    _state.add(false);
  }

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async {
    if (!_connected) return;
    _connected = false;
    _state.add(false);
  }

  @override
  Stream<Uint8List> get stdout => _stdout.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) => written.addAll(data);

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;

  @override
  bool get isEncryptedSsh => true;
}
