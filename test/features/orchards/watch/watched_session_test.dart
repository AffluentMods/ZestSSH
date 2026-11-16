// A session to a host in a watched Crate (3.0, session
// moderation), as the app runs it: the app's own session of a host in an
// Orchard's Crate, started the way the app starts one, against a host on
// this machine (a TCP server, reached with the Telnet shell so no SSH
// server is needed), with the Orchard's record on a stand-in server and the
// live view's relay in memory. Nothing is connected before someone who
// manages the Crate is watching; typing is held while nobody is; the session
// is closed when that lasts; whoever watches can end it; and the other ways
// the app reaches a host stay shut for such a Crate.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' show Locale;

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/networks/engine/connection_resolver.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show OrchardServerException;
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/orchards/watch/watch_gate.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/ssh_connection_factory.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/utils/error_translator.dart' as translator show ConnectionError, ConnectionErrorType, saidByApp;

import '../../sharing/share_fakes.dart';
import '../fake_crate_server.dart';

const _dana = 'uid-dana'; // owns the Orchard, and connects
const _sam = 'uid-sam'; // an admin: manages the Crate
const _kit = 'uid-kit'; // an admin too
const _noa = 'uid-noa'; // a member: opens the Crate, does not manage it
const _lee = 'uid-lee'; // not in the Orchard at first

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

class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// No networks are set up in these tests: a host is reached as it is saved.
/// (The app's own resolver asks the system which network it is on, which a
/// test would wait five seconds for.)
class _AsSaved implements ConnectionResolver {
  @override
  Future<ResolvedConnection> resolve(String hostId) async => throw StateError('no networks here');

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

  void say(String text) => sockets.last.add(utf8.encode(text));

  Future<void> stop() async {
    for (final s in sockets) {
      s.destroy();
    }
    await _server.close();
  }
}

/// A shell that reaches nothing and can lose its connection on the way: not
/// a shell that ended, which is what a Telnet host closing looks like.
class _LostOnTheWay implements ShellService {
  final _state = StreamController<bool>.broadcast();
  final _out = StreamController<Uint8List>.broadcast();
  var _connected = false;

  void lose() {
    _connected = false;
    _state.add(false);
  }

  @override
  Future<void> connect() async {
    _connected = true;
    _state.add(true);
  }

  @override
  Future<void> disconnect() async => _connected = false;

  @override
  Stream<Uint8List> get stdout => _out.stream;

  @override
  Stream<Uint8List> get stderr => const Stream.empty();

  @override
  void write(Uint8List data) {}

  @override
  void resize(int width, int height) {}

  @override
  bool get isConnected => _connected;

  @override
  Stream<bool> get connectionState => _state.stream;

  @override
  bool get exitedCleanly => false;

  @override
  bool get isEncryptedSsh => false;
}

/// A shell whose connection is made when the test says so, or fails then.
class _WhenTold extends _LostOnTheWay {
  /// Completes when the app sets about connecting.
  final begun = Completer<void>();

  /// Completed by the test: the connection is made, or fails with what
  /// this is completed with.
  final made = Completer<void>();

  @override
  Future<void> connect() async {
    if (!begun.isCompleted) begun.complete();
    await made.future;
    await super.connect();
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

  final l10n = lookupAppLocalizations(const Locale('en'));
  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late _Host host;
  late FakeShareRelay relay;
  late FakeShareApi api;
  late OrchardService dana;
  late String orchardId;
  late String crateId;
  CrateAuthor? me;

  /// What the person connecting was asked, and what they answer.
  final asks = <WatchRequest>[];
  Set<String>? answer;
  final notices = <(String, WatchNote)>[];
  final viewers = <ShareViewerController>[];

  /// What ZestSSH Cloud answers when the app asks how it is (a status, or
  /// what is thrown): it answers, unless a test says otherwise.
  Object cloudAnswer = 200;

  /// How many times the app asked ZestSSH Cloud how it is.
  var cloudAsked = 0;

  /// What someone about to go on with nobody watching was asked, and the
  /// reason they give (null: they give up).
  final unwatchedAsks = <UnwatchedRequest>[];
  String? reason;

  /// The Orchard as other people's devices have it (closed at the end).
  final others = <_MemoryStorage>[];

  setUpAll(() async {
    for (final uid in [_dana, _sam, _kit, _noa, _lee]) {
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
    SessionWatches.reset();
    TeamSessionLogs.reset();
    asks.clear();
    notices.clear();
    answer = {_sam};
    watchAskHandler = (request) async {
      asks.add(request);
      return answer;
    };
    watchNoticeHandler = (sessionId, note) => notices.add((sessionId, note));
    cloudAnswer = 200;
    cloudAsked = 0;
    unwatchedAsks.clear();
    reason = 'restoring the database';
    unwatchedAskHandler = (request) async {
      unwatchedAsks.add(request);
      return reason;
    };
    WatchGate.joinWait = const Duration(seconds: 30);
    WatchGate.grace = const Duration(seconds: 30);
    WatchGate.recheck = const Duration(milliseconds: 25);
    host = _Host();
    await host.start();
    relay = FakeShareRelay();
    api = FakeShareApi();
    me = CrateAuthor(uid: _dana, keys: keys[_dana]!);
    server = FakeCrateServer(accountUid: _dana);
    for (final uid in [_dana, _sam, _kit, _noa, _lee]) {
      await server.publish(uid, keys[uid]!, email: '${uid.substring(4)}@example.com');
    }
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => _Pro()),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => me)),
      shareApiProvider.overrideWithValue(api),
      shareLinkFactoryProvider
          .overrideWithValue((shareId, {required host}) => host ? relay.host() : relay.viewer(_sam)),
      connectionResolverProvider.overrideWithValue(_AsSaved()),
      // What the app knows of how ZestSSH Cloud stands: asked when a test
      // says so, never by itself.
      cloudReachProvider.overrideWith((ref) {
        final reach = CloudReachService(
          check: () async {
            cloudAsked++;
            final a = cloudAnswer;
            if (a is int) return a;
            throw a;
          },
          timer: (wait, then) => Timer(const Duration(days: 1), () {}),
        );
        ref.onDispose(reach.dispose);
        return reach;
      }),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);

    // dana's Orchard on this device. sam and kit are admins, so they manage
    // its Crate; noa is a member, who opens it and does not.
    dana = OrchardService(
      server: server.as(_dana),
      databases: container.read(orchardDatabasesProvider.notifier),
      author: () async => CrateAuthor(uid: _dana, keys: keys[_dana]!),
    );
    orchardId = await dana.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    crateId = server.recordOf(orchardId).crates.keys.single;
    final member = server.recordOf(orchardId).roles.values.single.id;
    await join(_sam, FixedRoles.admin);
    await join(_kit, FixedRoles.admin);
    await join(_noa, member);
    await dana.setCrateWatched(orchardId, crateId, true);
    await dana.refresh();
    await container.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
  });

  tearDown(() async {
    watchAskHandler = null;
    watchNoticeHandler = null;
    unwatchedAskHandler = null;
    for (final s in others) {
      for (final db in s.dbs.values) {
        await db.close();
      }
    }
    others.clear();
    WatchGate.joinWait = kWatchJoinWait;
    WatchGate.grace = kWatchGrace;
    WatchGate.recheck = const Duration(seconds: 15);
    for (final v in viewers) {
      v.dispose();
    }
    viewers.clear();
    await SessionShares.stopAll();
    SessionShares.reset();
    SessionWatches.reset();
    TeamSessionLogs.reset();
    container.dispose();
    await host.stop();
    for (final db in storage.dbs.values) {
      await db.close();
    }
    await tree.close();
  });

  AppDatabase orchardDb() => container.read(orchardDatabasesProvider)[orchardId]!;
  ActiveSessionsNotifier sessions() => container.read(activeSessionsProvider.notifier);
  SessionState? stateOf(String sessionId) => container.read(activeSessionsProvider)[sessionId];

  /// A host on this machine, saved in [db] (in [crate] of the Orchard, or
  /// in the Crate new items go into).
  Future<Connection> addHost(
    AppDatabase db,
    String id, {
    String? crate,
    String label = 'Web 1',
    String protocol = 'telnet',
    String? key,
    String? via,
  }) async {
    final at = DateTime(2026, 10, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: label,
          host: '127.0.0.1',
          port: Value(host.port),
          protocol: Value(protocol),
          identityId: Value(key),
          connectViaId: Value(via),
          createdAt: at,
          updatedAt: at,
        ));
    if (crate != null) await CratePlacement(db).place('host', id, crate);
    return (await db.connectionsDao.getById(id))!;
  }

  /// Connect is pressed for the host in the watched Crate.
  Future<String> connect({String id = 'h-web1'}) async {
    final existing = await orchardDb().connectionsDao.getById(id);
    return sessions().startSession(existing ?? await addHost(orchardDb(), id))!;
  }

  /// [uid]'s device joins the live view of [share].
  Future<ShareViewerController> watches(ShareHostController share, String uid) async {
    final sealed = [
      for (final c in api.created)
        if (c.id == share.shareId) c.invites[uid],
      for (final i in api.invited)
        if (i.id == share.shareId) i.invites[uid],
    ].whereType<Uint8List>().last;
    final invitation = await SignedShareInvitation.open(sealed, keys[uid]!.encryption, shareId: share.shareId);
    final v = ShareViewerController(invitation: invitation, keys: keys[uid]!, link: relay.viewer(uid));
    viewers.add(v);
    v.start();
    await until(() => v.phase == ShareViewPhase.watching, what: '$uid watching');
    return v;
  }

  /// The session's share, once the people asked have their invitations.
  Future<ShareHostController> shared(String sessionId) async {
    await until(() => SessionShares.of(sessionId) != null, what: 'the invitation to watch');
    return SessionShares.of(sessionId)!;
  }

  /// Connected, with [uid] watching.
  Future<(String, ShareHostController, ShareViewerController)> watched({String uid = _sam}) async {
    final sessionId = await connect();
    final share = await shared(sessionId);
    final viewer = await watches(share, uid);
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    await until(() => host.sockets.isNotEmpty, what: 'the host\'s side of it');
    await until(() => SessionWatches.of(sessionId)?.phase == SessionWatchPhase.watched, what: 'the watch');
    return (sessionId, share, viewer);
  }

  Terminal terminalOf(String sessionId) => stateOf(sessionId)!.session!.terminal;

  test('nothing is connected until someone who manages the Crate is watching; then it starts, and they see it from '
      'the first byte', () async {
    final sessionId = await connect();
    final share = await shared(sessionId);

    // Whom to ask: the others who manage the Crate, named with the Crate and
    // the host.
    final request = asks.single;
    expect((request.sessionId, request.crateName, request.hostLabel), (sessionId, 'Production', 'Web 1'));
    expect((request.host.orchardId, request.host.crateId), (orchardId, crateId));
    expect(request.people.map((p) => (p.uid, p.email, p.canManage)),
        [(_kit, 'kit@example.com', true), (_sam, 'sam@example.com', true)]);
    expect(request.alreadyAsked, isEmpty);

    // A live view with sam invited to end it, and nobody a keyboard.
    expect((share.mode, share.keyboardRequests), (ShareMode.live, false));
    expect(api.created.single.invites.keys, [_sam]);
    expect(share.guests.map((g) => (g.uid, g.canType, g.canEnd)), [(_sam, false, true)]);
    final invitation =
        (await SignedShareInvitation.open(api.created.single.invites[_sam]!, keys[_sam]!.encryption, shareId: share.shareId))
            .invitation;
    expect((invitation.crateId, invitation.connectionId, invitation.mayEnd, invitation.keyboard),
        (crateId, 'h-web1', true, false));

    // What sharing this session involves says its Crate is watched, and
    // who manages it.
    final (context, _) = await container.read(sessionSharingProvider).availabilityFor(sessionId);
    expect(context!.watched, isTrue);
    expect({for (final p in context.people) p.uid: p.canManage}, {_kit: true, _noa: false, _sam: true});

    // Waiting: no connection of any kind, and it says so.
    final watch = SessionWatches.of(sessionId)!;
    expect((watch.phase, watch.holdsTyping), (SessionWatchPhase.waiting, true));
    expect(watch.asked.map((g) => g.uid), [_sam]);
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(host.sockets, isEmpty);
    expect(stateOf(sessionId)!.status, SessionStatus.connecting);
    expect(stateOf(sessionId)!.connectionLog.where((l) => l.startsWith('watch:')), hasLength(2));

    // sam joins: the connection is made.
    final viewer = await watches(share, _sam);
    expect((viewer.mayEnd, viewer.mayAsk), (true, false));
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    await until(() => host.sockets.isNotEmpty, what: 'the host\'s side of it');
    expect(host.sockets, hasLength(1));
    expect(watch.phase, SessionWatchPhase.watched);
    host.say('Debian GNU/Linux 12\r\nweb1 login: ');
    await until(() => _shown(viewer.terminal).contains('web1 login'), what: 'the first output on sam\'s screen');
    sameScreen(terminalOf(sessionId), viewer.terminal);

    // What dana types reaches the host; sam types nothing.
    terminalOf(sessionId).textInput('deploy\r');
    await until(() => host.text.contains('deploy\r'), what: 'dana\'s keys');
    expect(share.giveKeyboard(_sam), isFalse);
    viewer.terminal.textInput('never-typed');
    await settle();
    expect(host.text, isNot(contains('never-typed')));

    // The session's shell keeps the connection to itself: nothing that
    // works beside the terminal gets at it.
    final shell = stateOf(sessionId)!.session!.shell;
    expect(shell, isA<WatchedShell>());
    expect(shell, isNot(isA<SshService>()));
    expect(notices, isEmpty);
    await sessions().endSession(sessionId);
    expect(SessionWatches.of(sessionId), isNull);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    expect(viewer.end, ShareViewEnd.sessionClosed);
  });

  test('a session to a host of a Crate that is not watched starts as ever', () async {
    final open = await dana.createCrate(orchardId, 'Staging');
    await dana.refresh();
    final connection = await addHost(orchardDb(), 'h-staging', crate: open, label: 'Staging 1');
    final sessionId = sessions().startSession(connection)!;
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    expect(asks, isEmpty);
    expect(SessionWatches.of(sessionId), isNull);
    expect(SessionShares.of(sessionId), isNull);
    expect(stateOf(sessionId)!.session!.shell, isNot(isA<WatchedShell>()));
    expect(await watchedHostIn(orchardDb(), 'h-staging'), isNull);
    final (context, _) = await container.read(sessionSharingProvider).availabilityFor(sessionId);
    expect(context!.watched, isFalse);
    // And one in the Tree, where there is no record at all.
    await container.read(spaceControllerProvider).switchTo(const TreeSpace());
    final mine = sessions().startSession(await addHost(tree, 'h-mine'))!;
    await until(() => stateOf(mine)?.status == SessionStatus.connected, what: 'the Tree session');
    expect(asks, isEmpty);
    expect(await watchedHostIn(tree, 'h-mine'), isNull);
  });

  test('held while nobody watches: nothing typed reaches the host, whoever typed it; watched again, it does',
      () async {
    final (sessionId, share, viewer) = await watched();
    final watch = SessionWatches.of(sessionId)!;
    terminalOf(sessionId).textInput('before\r');
    await until(() => host.text.contains('before\r'), what: 'typing while watched');

    await viewer.leave();
    await until(() => watch.phase == SessionWatchPhase.held, what: 'held');
    expect(notices, [(sessionId, WatchNote.held)]);
    expect(watch.closesAt, isNotNull);
    // The keyboard, a paste, a snippet or a broadcast from another tab (all
    // of which write to the session's shell), and someone handed the
    // keyboard: nothing goes.
    terminalOf(sessionId).textInput('rm -rf /\r');
    terminalOf(sessionId).paste('pasted\r');
    stateOf(sessionId)!.session!.shell.write(utf8.encode('from-a-snippet\r'));
    sessions().shareTerminalOf(sessionId)!.type(utf8.encode('from-a-viewer\r'));
    await settle();
    await Future<void>.delayed(const Duration(milliseconds: 80));
    for (final typed in ['rm -rf', 'pasted', 'from-a-snippet', 'from-a-viewer']) {
      expect(host.text, isNot(contains(typed)), reason: typed);
    }
    expect(watch.dropped, greaterThanOrEqualTo(4));
    // What the host says is still shown: only typing is held.
    host.say('still running\r\n');
    await until(() => _shown(terminalOf(sessionId)).contains('still running'), what: 'output while held');

    // kit was not asked, so kit joining a share of some other kind would
    // not count; sam comes back, and typing goes through again.
    final back = await watches(share, _sam);
    await until(() => watch.phase == SessionWatchPhase.watched, what: 'watched again');
    expect(notices, [(sessionId, WatchNote.held), (sessionId, WatchNote.watchedAgain)]);
    expect(watch.closesAt, isNull);
    terminalOf(sessionId).textInput('after\r');
    await until(() => host.text.contains('after\r'), what: 'typing when watched again');
    expect(host.text, isNot(contains('rm -rf')), reason: 'what was dropped is not sent later');
    expect(back.phase, ShareViewPhase.watching);
    await sessions().endSession(sessionId);
  });

  test('the live view itself ends while the session runs: held, and asking again starts a new one', () async {
    final (sessionId, share, viewer) = await watched();
    final watch = SessionWatches.of(sessionId)!;
    await SessionShares.stop(sessionId);
    await until(() => watch.phase == SessionWatchPhase.held, what: 'held');
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    terminalOf(sessionId).textInput('while-unshared\r');
    await settle();
    expect(host.text, isNot(contains('while-unshared')));

    // kit is asked: a new live view, with kit invited to end it.
    await container.read(watchGateProvider).askMore(sessionId, {_kit});
    final again = SessionShares.of(sessionId)!;
    expect(again.shareId, isNot(share.shareId));
    expect(again.guests.map((g) => (g.uid, g.canEnd)), [(_kit, true)]);
    expect(api.created, hasLength(2));
    final kit = await watches(again, _kit);
    await until(() => watch.phase == SessionWatchPhase.watched, what: 'watched again');
    host.say('still here\r\n');
    await until(() => _shown(kit.terminal).contains('still here'), what: 'the output on kit\'s screen');
    terminalOf(sessionId).textInput('after\r');
    await until(() => host.text.contains('after\r'), what: 'typing when watched again');
    await sessions().endSession(sessionId);
  });

  test('nobody watches for too long: the session is closed, its team\'s log says why, and the person is told',
      () async {
    WatchGate.grace = const Duration(milliseconds: 500);
    await dana.setCrateSessionLogs(orchardId, crateId, true);
    final (sessionId, _, viewer) = await watched();
    // The team's log of this session, opened by hand on the server this
    // test reads. (The app's own goes through ZestSSH Cloud, which the app
    // is not signed in to here: it is kept on the device, and ended, so
    // that the one opened by hand is fed.)
    expect(TeamSessionLogs.isLogged(sessionId), isTrue, reason: 'logged, though ZestSSH Cloud took nothing');
    await TeamSessionLogs.end(sessionId);
    // (And the Orchard's server, which the app could not ask, is not left
    // alone on that account by the service this test asks through.)
    dana.debugSessionLogsNewRun();
    TeamSessionLogs.expect(sessionId);
    TeamSessionLogs.started(
        sessionId,
        await dana.startTeamSessionLog(orchardId, crateId,
            label: 'Web 1', host: '127.0.0.1', port: host.port, connectionId: 'h-web1'));

    await viewer.leave();
    await until(() => stateOf(sessionId)?.status != SessionStatus.connected, what: 'the session closed');
    expect(notices, [(sessionId, WatchNote.held), (sessionId, WatchNote.closedUnwatched)]);
    expect(SessionWatches.of(sessionId), isNull);
    expect(SessionShares.of(sessionId), isNull);
    await until(() => api.ended.isNotEmpty, what: 'the share ended at ZestSSH Cloud');
    sessions().shareTerminalOf(sessionId)?.type(utf8.encode('after-the-end'));
    await settle();
    expect(host.text, isNot(contains('after-the-end')));

    var logged = '';
    for (var i = 0; i < 200 && !logged.contains(l10n.watchLogClosed); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      final entries = (await dana.teamSessionLogs(orchardId, crateId)).entries;
      if (entries.isNotEmpty) logged = (await dana.teamSessionLogText(orchardId, crateId, entries.single)).text;
    }
    expect(logged, contains('[ZestSSH] ${l10n.watchLogHeld}'));
    expect(logged, contains('[ZestSSH] ${l10n.watchLogClosed}'));
    expect(logged.indexOf(l10n.watchLogHeld), lessThan(logged.indexOf(l10n.watchLogClosed)));
  });

  test('the connection cannot be made after someone joined: it says why, the watch is over and they are told',
      () async {
    // A host that is not there: the port is one nothing listens on.
    final nothing = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final port = nothing.port;
    await nothing.close();
    final at = DateTime(2026, 10, 1);
    final db = orchardDb();
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
        id: 'h-gone',
        label: 'Gone',
        host: '127.0.0.1',
        port: Value(port),
        protocol: const Value('telnet'),
        createdAt: at,
        updatedAt: at));
    final sessionId = sessions().startSession((await db.connectionsDao.getById('h-gone'))!)!;
    final share = await shared(sessionId);
    final viewer = await watches(share, _sam);
    await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the failure');
    expect(container.read(connectionErrorProvider), isNotNull);
    expect(SessionWatches.of(sessionId), isNull);
    expect(SessionShares.of(sessionId), isNull);
    expect(share.isEnded, isTrue);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    expect(viewer.end, ShareViewEnd.sessionClosed);
    expect(notices, isEmpty);
  });

  test('tmux control mode is not entered in a watched session: its tab stays the terminal that is watched',
      () async {
    final (sessionId, _, viewer) = await watched();
    // The host answers as tmux -CC would. In a session that is not watched
    // the tab would show the tmux workspace and this channel would carry
    // tmux commands; here the bytes are just shown.
    final before = host.received.length;
    host.say('\x1bP1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
    await until(() => _shown(viewer.terminal).contains('%begin'), what: 'the marker shown as text');
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(container.read(tmuxHostProvider(sessionId)).active, isFalse);
    expect(host.received.length, before, reason: 'nothing was sent to tmux');
    // What is typed is typed, as it is.
    terminalOf(sessionId).textInput('plain\r');
    await until(() => host.text.contains('plain\r'), what: 'typing after the marker');
    await sessions().endSession(sessionId);

    // In a session that is not watched, the same bytes do enter it.
    final open = await dana.createCrate(orchardId, 'Staging');
    await dana.refresh();
    final connection = await addHost(orchardDb(), 'h-staging', crate: open, label: 'Staging 1');
    final other = sessions().startSession(connection)!;
    await until(() => stateOf(other)?.status == SessionStatus.connected, what: 'the session');
    await until(() => host.sockets.length == 2, what: 'the host\'s side of it');
    terminalOf(other).textInput('tmux -CC\r');
    await until(() => host.text.contains('tmux -CC'), what: 'what was typed');
    host.say('\x1bP1000p%begin 1 1 0\r\n%end 1 1 0\r\n');
    await until(() => container.read(tmuxHostProvider(other)).active, what: 'tmux mode');
    await sessions().endSession(other);
  });

  test('whoever watches ends it: the session closes, and there is no reconnecting by itself', () async {
    final (sessionId, share, viewer) = await watched();
    viewer.endSession();
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the end');
    expect(viewer.end, ShareViewEnd.sessionClosed);
    expect(share.isEnded, isTrue);
    expect(stateOf(sessionId)?.status, isNot(SessionStatus.connected));
    expect(SessionWatches.of(sessionId), isNull);
    expect(notices, isEmpty, reason: 'ended by someone watching, not for want of one');
    expect(asks, hasLength(1));
  });

  test('the connection drops: a watched session does not come back by itself', () async {
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    final (sessionId, _, viewer) = await watched();
    host.sockets.single.destroy();
    await until(() => stateOf(sessionId)?.status == SessionStatus.disconnected, what: 'the drop');
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    expect(SessionWatches.of(sessionId), isNull);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(stateOf(sessionId)?.isReconnecting ?? false, isFalse);
    expect(asks, hasLength(1), reason: 'nobody is asked again by a timer');
    expect(host.sockets, hasLength(1));
  });

  test('a connection lost on the way: the watch is over at once, and nothing connects it again by itself, as it '
      'would a session nobody has to watch', () async {
    container.read(autoReconnectEnabledProvider.notifier).state = true;
    final shells = <String, _LostOnTheWay>{};
    sessions().debugShellFor = (connection) => shells[connection.id] = _LostOnTheWay();
    final sessionId = await connect();
    final viewer = await watches(await shared(sessionId), _sam);
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    await until(() => SessionWatches.of(sessionId)?.phase == SessionWatchPhase.watched, what: 'the watch');
    shells['h-web1']!.lose();
    await until(() => stateOf(sessionId)?.status == SessionStatus.disconnected, what: 'the loss');
    expect(SessionWatches.of(sessionId), isNull, reason: 'what comes back, if anything, is watched anew');
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam told');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(stateOf(sessionId)!.status, SessionStatus.disconnected, reason: 'the tab stays, for its person to decide');
    expect(stateOf(sessionId)!.isReconnecting, isFalse);
    expect(asks, hasLength(1), reason: 'nobody is asked again by a timer');
    expect(shells, hasLength(1), reason: 'no second connection was made');

    // The same loss in a session of a Crate that is not watched: the app
    // sets about connecting it again.
    final open = await dana.createCrate(orchardId, 'Staging');
    await dana.refresh();
    final other = sessions().startSession(await addHost(orchardDb(), 'h-staging', crate: open, label: 'Staging 1'))!;
    await until(() => stateOf(other)?.status == SessionStatus.connected, what: 'the other session');
    shells['h-staging']!.lose();
    await until(() => stateOf(other)?.isReconnecting ?? false, what: 'connecting again');
    await sessions().endSession(other);
    await sessions().endSession(sessionId);
  });

  test('someone who came to manage the Crate after the asking began can be asked too, and is known by their '
      'address', () async {
    final sessionId = await connect();
    final share = await shared(sessionId);
    final gate = container.read(watchGateProvider);
    await join(_lee, FixedRoles.admin);
    await dana.refresh();
    expect((await gate.requestFor(sessionId, hostLabel: 'Web 1'))!.people.map((p) => p.uid), contains(_lee));
    expect(SessionShares.nameOf(sessionId, _lee), _lee, reason: 'nobody the live view knew of when it started');
    await gate.askMore(sessionId, {_lee});
    expect(share.guests.map((g) => (g.uid, g.canEnd)), [(_sam, true), (_lee, true)]);
    expect(SessionShares.nameOf(sessionId, _lee), 'lee@example.com');
    await sessions().endSession(sessionId);
  });

  test('giving up: asking nobody starts nothing; closing the tab while waiting ends the invitation', () async {
    // Nobody picked (the question was closed).
    answer = null;
    final dropped = await connect();
    await until(() => stateOf(dropped) == null, what: 'the session gone');
    expect(api.created, isEmpty);
    expect(SessionWatches.of(dropped), isNull);
    expect(container.read(connectionErrorProvider), isNull, reason: 'giving up is not an error');

    // Someone who cannot be asked comes back from the question: the same.
    answer = {_noa, _dana, 'uid-stranger'};
    final none = await connect();
    await until(() => stateOf(none) == null, what: 'the session gone');
    expect(api.created, isEmpty);

    // Asked, then the tab is closed while it waits.
    answer = {_sam, _kit};
    final sessionId = await connect();
    final share = await shared(sessionId);
    expect(share.guests.map((g) => (g.uid, g.canEnd)), [(_kit, true), (_sam, true)]);
    await sessions().endSession(sessionId);
    await until(() => stateOf(sessionId) == null, what: 'the session gone');
    expect(share.isEnded, isTrue);
    expect(SessionShares.of(sessionId), isNull);
    expect(SessionWatches.of(sessionId), isNull);
    await until(() => api.ended.contains(share.shareId), what: 'the share ended at ZestSSH Cloud');
    expect(host.sockets, isEmpty);
    expect(container.read(connectionErrorProvider), isNull);

    // The wait itself is given up (the Cancel on the tab).
    final again = await connect();
    await shared(again);
    SessionWatches.of(again)!.cancel();
    await until(() => stateOf(again) == null, what: 'the session gone');
    expect(SessionShares.of(again), isNull);
    expect(host.sockets, isEmpty);
  });

  test('nobody joins in time: it says so, and nothing was connected', () async {
    WatchGate.joinWait = const Duration(milliseconds: 250);
    final sessionId = await connect();
    final share = await shared(sessionId);
    await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal');
    // Kept as the app's own words, so that the screens show the sentence
    // itself (they took the bare sentence for a library's error, and said
    // "An unexpected error occurred").
    expect(stateOf(sessionId)!.errorMessage, translator.saidByApp(l10n.watchedNobodyJoined));
    expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(l10n.watchedNobodyJoined));
    final shown = translator.ConnectionError.translate(container.read(connectionErrorProvider)!.errorMessage,
        host: '127.0.0.1', port: host.port);
    expect((shown.type, shown.description), (translator.ConnectionErrorType.saidByApp, l10n.watchedNobodyJoined));
    expect(shown.tip, isNull);
    expect(share.isEnded, isTrue);
    expect(SessionWatches.of(sessionId), isNull);
    expect(host.sockets, isEmpty);
  });

  test('nobody who can be asked: it says so before anyone is asked', () async {
    Future<String> refusal(String hostId) async {
      container.read(connectionErrorProvider.notifier).state = null;
      final sessionId = await connect(id: hostId);
      await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal');
      expect(SessionWatches.of(sessionId), isNull);
      expect(SessionShares.of(sessionId), isNull);
      return container.read(connectionErrorProvider)!.errorMessage;
    }

    // A Crate only its owners open, and dana is the only owner.
    final vault = await dana.createCrate(orchardId, 'Vault', ownersOnly: true);
    await dana.setCrateWatched(orchardId, vault, true);
    await dana.refresh();
    await addHost(orchardDb(), 'h-vault', crate: vault, label: 'Vault 1');
    expect(await refusal('h-vault'), translator.saidByApp(l10n.watchedNobodyToAsk('Vault')));

    // Those who manage the Crate have keys this device no longer trusts.
    await orchardDb().customStatement(
        "UPDATE member_keys SET replaced_since_compared = 1, verified_by_me = 0, verified_by = '[]' WHERE uid IN (?, ?)",
        [_sam, _kit]);
    expect(await refusal('h-web1'), translator.saidByApp(l10n.watchedNobodyToAsk('Production')));

    // This device does not hold the account's keys.
    me = null;
    container.read(orchardAuthorProvider).forget();
    expect(await refusal('h-web1'), translator.saidByApp(l10n.watchedNotReady));
    expect(asks, isEmpty);
    expect(api.created, isEmpty);
    expect(host.sockets, isEmpty);
  });

  test('the live view cannot start: it says why, and nothing is connected', () async {
    api.failNext = const OrchardServerException(429, 'too-many-shares');
    final sessionId = await connect();
    await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal');
    expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(l10n.shareFailedTooMany));
    expect(SessionWatches.of(sessionId), isNull);
    expect(host.sockets, isEmpty);
  });

  test('no app to ask the person (nothing on screen): nothing starts', () async {
    watchAskHandler = null;
    final sessionId = await connect();
    await until(() => stateOf(sessionId) == null, what: 'the session gone');
    expect(api.created, isEmpty);
    expect(host.sockets, isEmpty);
  });

  test('the other ways the app reaches a host stay shut: no monitoring, no hop through it, and its keys sign in '
      'to its own hosts only', () async {
    final db = orchardDb();
    final at = DateTime(2026, 10, 1);
    final open = await dana.createCrate(orchardId, 'Staging');
    await dana.refresh();

    // Monitoring connects by itself: not to a watched Crate's host.
    final watchedHost = await addHost(db, 'h-ssh', protocol: 'ssh', label: 'Web 2');
    final polled = await sessions().openExecClient(watchedHost);
    expect((polled.outcome, polled.detail), (MonitorExecOutcome.notEligible, 'sessions in its Crate are watched'));
    expect(host.sockets, isEmpty);
    // A host of a Crate that is not watched is monitored as any other: this
    // one has no key to sign in with, which is all that stands in the way.
    final plainHost = await addHost(db, 'h-open-ssh', crate: open, protocol: 'ssh', label: 'Staging 2');
    expect((await sessions().openExecClient(plainHost)).outcome, MonitorExecOutcome.needsCredentials);
    // Nor do the checks of whether hosts can be reached connect to a
    // watched Crate's host, where its person has them on; to the other
    // they do, where a connect would.
    final checks = container.read(Provider((ref) => ReachabilityTargets(ref)));
    expect(await checks.of(watchedHost), isNull);
    expect(await checks.of(plainHost), (host: plainHost.host, port: plainHost.port));

    // A key in the watched Crate, and what it may sign in to.
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-prod', label: 'deploy', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await CratePlacement(db).place('key', 'k-prod', crateId);
    await addHost(db, 'h-prod', key: 'k-prod', label: 'Web 3');
    await addHost(db, 'h-elsewhere', crate: open, key: 'k-prod', protocol: 'ssh', label: 'Staging 1');
    // (Its password is kept, so that nothing but the rule stands in the
    // way of using it.)
    await IdentitySecretStore.forDatabase(db, container.read(secureStorageProvider))
        .write('k-prod', IdentitySecret.password, 'made-up for this test');
    await requireWatchedKeyHostIn(db, 'k-prod', 'h-prod');
    await expectLater(
      requireWatchedKeyHostIn(db, 'k-prod', 'h-elsewhere'),
      throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', l10n.watchedKeyOtherHost)),
    );
    await expectLater(
      requireWatchedKeyHostIn(db, 'k-prod', 'quick_1790000000'),
      completes,
      reason: 'an address typed here counts as a host of the Crate new items go into, which is the watched one',
    );
    expect(await container.read(sshConnectionFactoryProvider).resolveCredentialsSilently(
        (await db.connectionsDao.getById('h-prod'))!), isNotNull,
        reason: 'the key itself is usable: for its own Crate\'s host it resolves');
    // A session to the host in the other Crate, with that key: refused
    // before anything is connected.
    final elsewhere = sessions().startSession((await db.connectionsDao.getById('h-elsewhere'))!)!;
    await until(() => stateOf(elsewhere)?.status == SessionStatus.error, what: 'the refusal');
    expect(container.read(connectionErrorProvider)!.errorMessage, translator.saidByApp(l10n.watchedKeyOtherHost));
    // Nor silently, for monitoring.
    expect(await container.read(sshConnectionFactoryProvider).resolveCredentialsSilently(
        (await db.connectionsDao.getById('h-elsewhere'))!), isNull);

    // A host of the watched Crate as a hop on the way to another host:
    // refused before the hop is dialled.
    container.read(connectionErrorProvider.notifier).state = null;
    await db.into(db.identities).insert(IdentitiesCompanion.insert(
        id: 'k-staging', label: 'staging', username: 'deploy', authMethod: 'password', createdAt: at, updatedAt: Value(at)));
    await CratePlacement(db).place('key', 'k-staging', open);
    // A key of a Crate that is not watched signs in wherever its Crate's
    // other rules let it, a watched Crate's host included.
    await requireWatchedKeyHostIn(db, 'k-staging', 'h-prod');
    await requireWatchedKeyHostIn(db, 'k-staging', 'h-elsewhere');
    // (Its password is kept, so nothing asks for one before the hop.)
    await IdentitySecretStore.forDatabase(db, container.read(secureStorageProvider))
        .write('k-staging', IdentitySecret.password, 'made-up for this test');
    await addHost(db, 'h-behind', crate: open, key: 'k-staging', protocol: 'ssh', via: 'h-ssh', label: 'Behind');
    final behind = sessions().startSession((await db.connectionsDao.getById('h-behind'))!)!;
    await until(() => stateOf(behind)?.status == SessionStatus.error, what: 'the hop refused');
    expect(container.read(connectionErrorProvider)!.errorMessage,
        translator.saidByApp(l10n.watchedHostNoJump('Web 2')));
    expect(asks, isEmpty);
    expect(host.sockets, isEmpty);

    // A test connection from the host editor: neither to a host of the
    // watched Crate nor with one of its keys.
    expect(await testWouldGoUnwatchedIn(db, hostId: 'h-prod'), isTrue);
    expect(await testWouldGoUnwatchedIn(db, hostId: 'h-elsewhere'), isFalse);
    expect(await testWouldGoUnwatchedIn(db, hostId: 'h-elsewhere', keyId: 'k-prod'), isTrue);
    expect(await testWouldGoUnwatchedIn(db, hostId: 'h-elsewhere', keyId: 'k-staging'), isFalse);
    expect(await testWouldGoUnwatchedIn(tree, hostId: 'anything', keyId: 'k-prod'), isFalse);
  });

  test('what a device reads of the record: which hosts are watched, read again only when the record has grown',
      () async {
    final db = orchardDb();
    await addHost(db, 'h-web1');
    final watchedHost = (await watchedHostIn(db, 'h-web1'))!;
    expect((watchedHost.orchardId, watchedHost.crateId, watchedHost.crateName), (orchardId, crateId, 'Production'));
    expect(await hostIsWatchedIn(db, 'h-web1'), isTrue);
    // The same record object until an entry is added.
    final first = await latestRecordIn(db);
    expect(identical(await latestRecordIn(db), first), isTrue);
    expect(first!.crates[crateId]!.watched, isTrue);
    expect(first.crates[crateId]!.allow, isEmpty, reason: 'turned on, a Crate allows the terminal only');

    // Turned off: the next look says so. What it allows stays as it was.
    await dana.setCrateWatched(orchardId, crateId, false);
    final next = await latestRecordIn(db);
    expect(identical(next, first), isFalse);
    expect(next!.crates[crateId]!.watched, isFalse);
    expect(next.crates[crateId]!.allow, isEmpty);
    expect(await watchedHostIn(db, 'h-web1'), isNull);
    expect(await hostIsWatchedIn(db, 'h-web1'), isFalse);
    final sessionId = await connect();
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    expect(asks, isEmpty);

    // Said to be off where it is off: what the Crate allows is left as it
    // is (only turning it on takes anything away).
    await dana.setCrateAllow(orchardId, crateId, {CrateSwitches.sftp});
    await dana.setCrateWatched(orchardId, crateId, false);
    expect((await latestRecordIn(db))!.crates[crateId]!.allow, {CrateSwitches.sftp});

    // Your Tree has no record, and a host nobody saved is one of the Crate
    // new items go into.
    expect(await latestRecordIn(tree), isNull);
    await dana.setCrateWatched(orchardId, crateId, true);
    expect((await latestRecordIn(db))!.crates[crateId]!.allow, isEmpty);
    expect(await hostIsWatchedIn(db, 'quick_1790000000'), isTrue);
  });

  test('the Orchard closed on this device: nothing is connected, since what its record says cannot be read',
      () async {
    final gate = container.read(watchGateProvider);
    await expectLater(
      gate.open('s-closed', connectionId: 'h-web1', hostLabel: 'Web 1', db: null, log: (_) {}),
      throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', l10n.watchedOrchardClosed)),
    );
    expect(await gate.open('s-tree', connectionId: 'h-mine', hostLabel: 'Mine', db: tree, log: (_) {}), isNull);
  });

  // 3.0: a live view goes through
  // ZestSSH Cloud, so while the service cannot be reached nobody can be
  // asked to watch, and that must not be why a team cannot reach its
  // machines. Then, and only then, an owner may connect after giving a
  // reason, and so may anyone else where the owners allowed it for the
  // Crate. What the device reports of it is kept before anything is
  // connected, and put into the record once the device is back.
  group('while ZestSSH Cloud cannot be reached', () {
    const refusedConnection = SocketException('Connection refused');

    /// ZestSSH Cloud stops answering, or answers again, and the app knows.
    Future<CloudReachState> cloudIs(Object answer) {
      cloudAnswer = answer;
      return container.read(cloudReachProvider).checkNow();
    }

    /// This device is [uid]'s for what follows. (The app asks who is signed
    /// in once in a while: it is told to ask again.)
    void signedInAs(String uid) {
      me = CrateAuthor(uid: uid, keys: keys[uid]!);
      container.read(orchardAuthorProvider).forget();
    }

    /// [uid]'s way to the Orchard on this device: the same database, their
    /// own account at the server.
    OrchardService here(String uid) => OrchardService(
          server: server.as(uid),
          databases: container.read(orchardDatabasesProvider.notifier),
          author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
        );

    /// The Orchard on a device of [uid]'s own.
    Future<OrchardService> deviceOf(String uid) async {
      final storage = _MemoryStorage();
      others.add(storage);
      final service = OrchardService(
        server: server.as(uid),
        databases: OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage),
        author: () async => CrateAuthor(uid: uid, keys: keys[uid]!),
      );
      await service.refresh();
      return service;
    }

    /// The reports in the record as the server has it.
    List<RecordEntry> reported() => [
          for (final e in server.entriesOf(orchardId))
            if (e.type == RecordTypes.sessionUnwatched) e,
        ];

    /// Waits until this device keeps [n] reports.
    Future<void> keeps(int n, String what) async {
      for (var i = 0; i < 300 && await dana.unwatchedWaiting(orchardId) != n; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 10));
      }
      expect(await dana.unwatchedWaiting(orchardId), n, reason: what);
    }

    String refusal() => container.read(connectionErrorProvider)!.errorMessage;
    String notAllowed([String crate = 'Production']) => translator.saidByApp(
        ErrorCodes.withCode(l10n.watchedAwayNotAllowed(crate), ErrorCodes.watchedNobodyToAsk));

    test('an owner connects after giving a reason: nobody is asked to watch, what is reported is kept before the '
        'host is reached, and the session goes on as what it is', () async {
      final state = await cloudIs(refusedConnection);
      expect(state.inTheWay, isTrue);
      reason = '  restoring   the database\n';
      var hostReachedWhenAsked = true;
      unwatchedAskHandler = (request) async {
        unwatchedAsks.add(request);
        hostReachedWhenAsked = host.sockets.isNotEmpty;
        return reason;
      };
      final before = server.asked;
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
      await until(() => host.sockets.isNotEmpty, what: "the host's side of it");

      // Nobody was asked to watch, and no live view was started: asked for
      // the reason instead, with what it is for, before anything connected.
      expect(asks, isEmpty);
      expect(api.created, isEmpty);
      expect(SessionShares.of(sessionId), isNull);
      final asked = unwatchedAsks.single;
      expect((asked.sessionId, asked.crateName, asked.hostLabel, asked.held), (sessionId, 'Production', 'Web 1', false));
      expect((asked.host.orchardId, asked.host.crateId), (orchardId, crateId));
      expect(hostReachedWhenAsked, isFalse);
      expect(server.asked, before, reason: 'nothing is asked of a server that cannot be reached');

      // The session: not held, and still one that keeps its connection to
      // itself (nothing beside the terminal).
      final watch = SessionWatches.of(sessionId)!;
      expect((watch.phase, watch.holdsTyping, watch.closesAt), (SessionWatchPhase.unwatched, false, null));
      terminalOf(sessionId).textInput('uptime\r');
      await until(() => host.text.contains('uptime\r'), what: 'typing with nobody watching');
      final shell = stateOf(sessionId)!.session!.shell;
      expect(shell, isA<WatchedShell>());
      expect(shell, isNot(isA<SshService>()));
      // It says what it is: in the connection's log, and to the person.
      expect(stateOf(sessionId)!.connectionLog.where((l) => l.startsWith('watch:')), [
        'watch: Sessions in this Crate are watched',
        'watch: ZestSSH Cloud cannot be reached, so nobody can be asked to watch',
        'watch: Goes on with nobody watching. The owners are told once this device is back online',
      ]);
      expect(notices, [(sessionId, WatchNote.unwatched)]);

      // What is reported is kept on the device, and goes into the record
      // when the server is reached: dana's own entry, about this Crate.
      expect(await dana.unwatchedWaiting(orchardId), 1);
      expect(reported(), isEmpty);
      expect(await dana.unwatchedRound(orchardId), 1);
      final entry = reported().single;
      expect((entry.by, entry.body['crate'], entry.body['gen']), (_dana, crateId, 1));
      // sam manages the Crate: on sam's device it reads as what was said.
      final sam = await deviceOf(_sam);
      final read = (await sam.unwatchedSessionOf(orchardId, entry))!;
      expect(read.by, _dana);
      expect(read.report, UnwatchedReport(host: 'Web 1', reason: 'restoring the database', reach: state.reach.name));
      await sessions().endSession(sessionId);
      expect(SessionWatches.of(sessionId), isNull);
    });

    test('no reason, no session: someone who gives none, or gives up, connects nothing and reports nothing; with '
        'no app to ask, the same', () async {
      await cloudIs(refusedConnection);
      Future<void> nothingStarts(String what) async {
        final sessionId = await connect();
        await until(() => stateOf(sessionId) == null, what: 'the session gone ($what)');
        expect(SessionWatches.of(sessionId), isNull, reason: what);
        expect(host.sockets, isEmpty, reason: what);
        expect(await dana.unwatchedWaiting(orchardId), 0, reason: what);
        expect(container.read(connectionErrorProvider), isNull, reason: 'given up, which is no failure ($what)');
      }

      reason = '  \n ';
      await nothingStarts('a reason of blanks');
      reason = null;
      await nothingStarts('gave up');
      expect(unwatchedAsks, hasLength(2));
      unwatchedAskHandler = null;
      await nothingStarts('no app to ask');
      expect(unwatchedAsks, hasLength(2));
      // The tab is closed while the person is asked: whatever they then
      // answer, nothing is kept and nothing connects.
      unwatchedAskHandler = (request) async {
        await sessions().endSession(request.sessionId);
        return 'a reason given too late';
      };
      await nothingStarts('the tab closed meanwhile');
      await settle();
      expect(await dana.unwatchedWaiting(orchardId), 0);
      expect(notices, isEmpty);
    });

    test('someone who is no owner is refused, in words that say why and with a code, unless the owners allowed it '
        'for the Crate', () async {
      await cloudIs(refusedConnection);
      // sam manages the Crate and noa opens it: neither owns the Orchard.
      for (final uid in [_sam, _noa]) {
        signedInAs(uid);
        final sessionId = await connect();
        await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal ($uid)');
        expect(refusal(), notAllowed(), reason: uid);
        expect(refusal(), contains('ZS-1401'));
        expect(unwatchedAsks, isEmpty, reason: 'not asked for a reason they could not use');
        expect(SessionWatches.of(sessionId), isNull);
        expect(host.sockets, isEmpty);
        await sessions().endSession(sessionId);
      }
      expect(await dana.unwatchedWaiting(orchardId), 0);

      // The owners allowed it for this Crate: noa is asked why, connects,
      // and it is noa's own entry that reports it.
      await dana.setCrateUnwatchedAway(orchardId, crateId, true);
      signedInAs(_noa);
      reason = 'the deploy is stuck';
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: "noa's session");
      expect(unwatchedAsks.single.crateName, 'Production');
      expect(SessionWatches.of(sessionId)!.phase, SessionWatchPhase.unwatched);
      expect(await here(_noa).unwatchedRound(orchardId), 1);
      final entry = reported().single;
      expect(entry.by, _noa);
      final read = (await dana.unwatchedSessionOf(orchardId, entry))!;
      expect((read.by, read.report!.reason, read.report!.host), (_noa, 'the deploy is stuck', 'Web 1'));
      await sessions().endSession(sessionId);

      // Taken back: noa is refused again.
      await dana.setCrateUnwatchedAway(orchardId, crateId, false);
      final again = await connect();
      await until(() => stateOf(again)?.status == SessionStatus.error, what: 'the refusal, again');
      expect(refusal(), notAllowed());
    });

    test('what is reported cannot be kept: nothing starts, and it says so', () async {
      await cloudIs(refusedConnection);
      // The key of the Crate is not on this device: nothing could be sealed.
      await orchardDb().customStatement("DELETE FROM space_keys WHERE scope = 'crate'");
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal');
      expect(refusal(), translator.saidByApp(l10n.watchedAwayNotKept));
      expect(unwatchedAsks, hasLength(1), reason: 'the reason was asked for, and then could not be kept');
      expect(SessionWatches.of(sessionId), isNull);
      expect(host.sockets, isEmpty);
      expect(notices, isEmpty);

      // No account ready on this device (its keys are not there yet):
      // nothing goes on, nobody is asked why, and it says that.
      await sessions().endSession(sessionId);
      me = null;
      container.read(orchardAuthorProvider).forget();
      final other = await connect();
      await until(() => stateOf(other)?.status == SessionStatus.error, what: 'the other refusal');
      expect(refusal(), translator.saidByApp(l10n.watchedNotReady));
      expect(unwatchedAsks, hasLength(1));
      expect(SessionWatches.of(other), isNull);
      expect(host.sockets, isEmpty);
    });

    test('the service answers again while the person says why: someone can be asked after all, and nothing goes on '
        'with nobody watching', () async {
      await cloudIs(refusedConnection);
      unwatchedAskHandler = (request) async {
        unwatchedAsks.add(request);
        await cloudIs(200);
        return 'a reason';
      };
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.error, what: 'the refusal');
      expect(refusal(), translator.saidByApp(l10n.watchedAwayBack));
      expect(SessionWatches.of(sessionId), isNull);
      expect(host.sockets, isEmpty);
      expect(await dana.unwatchedWaiting(orchardId), 0);
      // Connecting again asks someone to watch, as ever.
      await sessions().endSession(sessionId);
      final again = await connect();
      await shared(again);
      expect(asks, hasLength(1));
      expect(unwatchedAsks, hasLength(1));
      await sessions().endSession(again);
    });

    test('what the app knew was from before: the live view does not start, the service is asked how it is, and '
        'where it is away the session goes on as above', () async {
      // Nothing was asked of the service yet in this run, and it is away.
      cloudAnswer = refusedConnection;
      expect(container.read(cloudReachProvider).state.value.inTheWay, isFalse);
      api.failNext = refusedConnection;
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
      expect(asks, hasLength(1), reason: 'someone was to be asked, as far as the app knew');
      expect(unwatchedAsks.single.sessionId, sessionId);
      expect(container.read(cloudReachProvider).state.value.inTheWay, isTrue);
      expect(SessionWatches.of(sessionId)!.phase, SessionWatchPhase.unwatched);
      expect(SessionShares.of(sessionId), isNull);
      expect(await dana.unwatchedWaiting(orchardId), 1);
      await sessions().endSession(sessionId);

      // A live view that does not start while the service answers is what
      // it always was: refused, with nobody asked why.
      await cloudIs(200);
      api.failNext = refusedConnection;
      final other = await connect();
      await until(() => stateOf(other)?.status == SessionStatus.error, what: 'the refusal');
      expect(refusal(), translator.saidByApp(l10n.shareFailedOffline));
      expect(unwatchedAsks, hasLength(1));
      expect(await dana.unwatchedWaiting(orchardId), 1);
      // And one refused for another reason is not turned into this.
      cloudAnswer = refusedConnection;
      api.failNext = const OrchardServerException(429, 'too-many-shares');
      await sessions().endSession(other);
      final third = await connect();
      await until(() => stateOf(third)?.status == SessionStatus.error, what: 'the other refusal');
      expect(refusal(), translator.saidByApp(l10n.shareFailedTooMany));
      expect(unwatchedAsks, hasLength(1));
    });

    test('a held session goes on with nobody watching: asked why, typing goes through again, its team\'s log says '
        'so, it is reported, and nothing closes it; someone watching makes it a watched session again', () async {
      WatchGate.grace = const Duration(seconds: 2);
      await dana.setCrateSessionLogs(orchardId, crateId, true);
      final (sessionId, share, viewer) = await watched();
      // (As above: the app's own log of it is kept on the device, and
      // ended for the one opened by hand.)
      await TeamSessionLogs.end(sessionId);
      dana.debugSessionLogsNewRun();
      TeamSessionLogs.expect(sessionId);
      TeamSessionLogs.started(
          sessionId,
          await dana.startTeamSessionLog(orchardId, crateId,
              label: 'Web 1', host: '127.0.0.1', port: host.port, connectionId: 'h-web1'));
      final watch = SessionWatches.of(sessionId)!;
      final gate = sessions();

      // Watched: there is nothing to go on from, and nothing to ask the
      // service for.
      expect(await gate.mayGoOnUnwatched(sessionId), isFalse);
      await gate.goOnUnwatched(sessionId);
      expect(unwatchedAsks, isEmpty);
      expect(cloudAsked, 0);

      // The watcher is gone. Someone who may not go on anyway is not offered
      // it, and the service is not asked for them.
      await viewer.leave();
      await until(() => watch.phase == SessionWatchPhase.held, what: 'held');
      signedInAs(_noa);
      expect(await gate.mayGoOnUnwatched(sessionId), isFalse);
      expect(cloudAsked, 0);
      signedInAs(_dana);
      // For someone who may, the service is asked how it is. It answers:
      // someone can be asked to watch.
      expect(await gate.mayGoOnUnwatched(sessionId), isFalse);
      expect(cloudAsked, 1);
      await expectLater(
          gate.goOnUnwatched(sessionId),
          throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message', l10n.watchedAwayBack)));
      // The service stops answering, and the app has not heard of it:
      // nothing it asked has failed, and a live view's link is not something
      // it hears the failure of. Asked now, it is found away.
      cloudAnswer = refusedConnection;
      expect(container.read(cloudReachProvider).state.value.inTheWay, isFalse);
      expect(await gate.mayGoOnUnwatched(sessionId), isTrue);
      expect(container.read(cloudReachProvider).state.value.inTheWay, isTrue);
      // Someone who may not: told why, and it stays held.
      signedInAs(_noa);
      expect(await gate.mayGoOnUnwatched(sessionId), isFalse);
      await expectLater(
          gate.goOnUnwatched(sessionId),
          throwsA(isA<OrchardAccessRefused>().having((e) => e.message, 'message',
              ErrorCodes.withCode(l10n.watchedAwayNotAllowed('Production'), ErrorCodes.watchedNobodyToAsk))));
      signedInAs(_dana);
      // Giving up leaves it held, with nothing kept.
      reason = null;
      await expectLater(gate.goOnUnwatched(sessionId), throwsA(isA<SessionWatchCancelled>()));
      expect((watch.phase, await dana.unwatchedWaiting(orchardId)), (SessionWatchPhase.held, 0));
      expect(unwatchedAsks.single.held, isTrue);
      terminalOf(sessionId).textInput('while-held\r');
      await settle();
      expect(host.text, isNot(contains('while-held')));
      // Slow to answer, longer than a held session waits: it is not closed
      // under their hands, and the wait starts over when they give up.
      DateTime? closesWhileAsked = DateTime(2026);
      unwatchedAskHandler = (request) async {
        closesWhileAsked = watch.closesAt;
        await Future<void>.delayed(WatchGate.grace + const Duration(milliseconds: 500));
        return null;
      };
      await expectLater(gate.goOnUnwatched(sessionId), throwsA(isA<SessionWatchCancelled>()));
      expect(closesWhileAsked, isNull, reason: 'no wait runs while they are asked');
      expect(stateOf(sessionId)!.status, SessionStatus.connected);
      expect(watch.phase, SessionWatchPhase.held);
      expect(watch.closesAt, isNotNull, reason: 'the wait starts over');
      expect(notices, [(sessionId, WatchNote.held)]);
      unwatchedAskHandler = (request) async {
        unwatchedAsks.add(request);
        return reason;
      };

      // With a reason: it goes on.
      reason = 'the migration is half done';
      await gate.goOnUnwatched(sessionId);
      expect((watch.phase, watch.holdsTyping, watch.closesAt), (SessionWatchPhase.unwatched, false, null));
      expect(notices, [(sessionId, WatchNote.held), (sessionId, WatchNote.unwatched)]);
      expect(stateOf(sessionId)!.connectionLog.last,
          'watch: Goes on with nobody watching. The owners are told once this device is back online');
      expect(cloudAsked, 3, reason: 'once the app knows the service is away, a press does not ask it again');
      terminalOf(sessionId).textInput('finish\r');
      await until(() => host.text.contains('finish\r'), what: 'typing with nobody watching');
      expect(await dana.unwatchedWaiting(orchardId), 1);
      expect(await gate.mayGoOnUnwatched(sessionId), isFalse, reason: 'it is not held any more');
      // The wait it was held under closes nothing.
      await Future<void>.delayed(WatchGate.grace + const Duration(milliseconds: 500));
      expect(stateOf(sessionId)!.status, SessionStatus.connected);
      expect(notices, hasLength(2));

      // sam is back: a watched session again.
      final back = await watches(share, _sam);
      await until(() => watch.phase == SessionWatchPhase.watched, what: 'watched again');
      expect(notices.last, (sessionId, WatchNote.watchedAgain));
      expect(back.phase, ShareViewPhase.watching);
      await sessions().endSession(sessionId);

      // Its team's log has both lines, in that order; and the report reads
      // as what was said.
      var logged = '';
      for (var i = 0; i < 200 && !logged.contains(l10n.watchLogUnwatched); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        final entries = (await dana.teamSessionLogs(orchardId, crateId)).entries;
        if (entries.isNotEmpty) logged = (await dana.teamSessionLogText(orchardId, crateId, entries.single)).text;
      }
      expect(logged, contains('[ZestSSH] ${l10n.watchLogHeld}'));
      expect(logged, contains('[ZestSSH] ${l10n.watchLogUnwatched}'));
      expect(logged.indexOf(l10n.watchLogHeld), lessThan(logged.indexOf(l10n.watchLogUnwatched)));
      expect(await dana.unwatchedRound(orchardId), 1);
      final read = (await dana.unwatchedSessionOf(orchardId, reported().single))!;
      expect((read.report!.reason, read.report!.host), ('the migration is half done', 'Web 1'));
    });

    test('whoever watched is back while the person is asked why: it is a watched session again, and nothing is '
        'reported', () async {
      final (sessionId, share, viewer) = await watched();
      final watch = SessionWatches.of(sessionId)!;
      await viewer.leave();
      await until(() => watch.phase == SessionWatchPhase.held, what: 'held');
      // (The service is away and the app has not heard: it asks.)
      cloudAnswer = refusedConnection;
      unwatchedAskHandler = (request) async {
        unwatchedAsks.add(request);
        await watches(share, _sam);
        await until(() => watch.phase == SessionWatchPhase.watched, what: 'watched again');
        return 'it took a while to write this';
      };
      await sessions().goOnUnwatched(sessionId);
      expect(container.read(cloudReachProvider).state.value.inTheWay, isTrue);
      expect(unwatchedAsks, hasLength(1));
      expect(watch.phase, SessionWatchPhase.watched);
      expect(notices, [(sessionId, WatchNote.held), (sessionId, WatchNote.watchedAgain)]);
      expect(await dana.unwatchedWaiting(orchardId), 0);
      await sessions().endSession(sessionId);
    });

    test('pressed twice at once: asked twice, let go on once, and reported once', () async {
      final (sessionId, _, viewer) = await watched();
      final watch = SessionWatches.of(sessionId)!;
      await viewer.leave();
      await until(() => watch.phase == SessionWatchPhase.held, what: 'held');
      cloudAnswer = refusedConnection;
      await Future.wait([sessions().goOnUnwatched(sessionId), sessions().goOnUnwatched(sessionId)]);
      expect(unwatchedAsks, hasLength(2));
      expect(cloudAsked, 1, reason: 'the two share the one question');
      expect((watch.phase, watch.ranUnwatched), (SessionWatchPhase.unwatched, true));
      expect(notices, [(sessionId, WatchNote.held), (sessionId, WatchNote.unwatched)]);
      expect(await dana.unwatchedWaiting(orchardId), 1);
      expect(await dana.unwatchedRound(orchardId), 1);
      expect(reported(), hasLength(1));
      await sessions().endSession(sessionId);
    });

    test('kept before the connection is made, and not sent before the session runs: a connection that is not made '
        'after all, or a tab closed on the way, reports nothing', () async {
      await cloudIs(refusedConnection);
      final shells = <_WhenTold>[];
      sessions().debugShellFor = (connection) {
        final shell = _WhenTold();
        shells.add(shell);
        return shell;
      };

      // On its way: kept, and not something a sync sends yet.
      final first = await connect();
      await until(() => shells.length == 1, what: 'the connection begun');
      await shells[0].begun.future;
      final watch = SessionWatches.of(first)!;
      expect((watch.phase, watch.ranUnwatched), (SessionWatchPhase.unwatched, false));
      expect(await dana.unwatchedWaiting(orchardId), 1, reason: 'kept before the host is reached');
      expect(await dana.unwatchedRound(orchardId), 0, reason: 'not sent before the session runs');
      expect(notices, isEmpty);
      // It connects: the session runs with nobody watching, and is reported.
      shells[0].made.complete();
      await until(() => stateOf(first)?.status == SessionStatus.connected, what: 'the session');
      expect(watch.ranUnwatched, isTrue);
      expect(notices, [(first, WatchNote.unwatched)]);
      expect(await dana.unwatchedRound(orchardId), 1);
      expect(reported(), hasLength(1));
      await sessions().endSession(first);
      await keeps(0, 'sent, and nothing else kept');

      // The connection is not made after all: nothing ran with nobody
      // watching, and nothing is reported.
      final second = await connect();
      await until(() => shells.length == 2, what: 'the second connection begun');
      await shells[1].begun.future;
      expect(await dana.unwatchedWaiting(orchardId), 1);
      shells[1].made.completeError(const SocketException('Connection refused'));
      await until(() => stateOf(second)?.status == SessionStatus.error, what: 'the failure');
      await keeps(0, 'the connection was not made');
      expect(await dana.unwatchedRound(orchardId), 0);
      await sessions().endSession(second);

      // The tab is closed on the way: the same.
      final third = await connect();
      await until(() => shells.length == 3, what: 'the third connection begun');
      await shells[2].begun.future;
      expect(await dana.unwatchedWaiting(orchardId), 1);
      await sessions().endSession(third);
      await keeps(0, 'the tab was closed on the way');
      expect(reported(), hasLength(1));
      expect(unwatchedAsks, hasLength(3));
      expect(notices, hasLength(1));
    });

    test('the tab is closed in the moment it takes to keep what is reported: nothing connects, and what was kept is '
        'taken back', () async {
      await cloudIs(refusedConnection);
      String? closing;
      unwatchedAskHandler = (request) async {
        unwatchedAsks.add(request);
        closing = request.sessionId;
        return reason;
      };
      addTearDown(() => OrchardService.debugNow = DateTime.now);
      // The service reads its clock once while it keeps a report: the tab
      // is closed right then.
      var closedThen = 0;
      OrchardService.debugNow = () {
        final id = closing;
        closing = null;
        if (id != null) {
          closedThen++;
          SessionWatches.end(id);
        }
        return DateTime.now();
      };
      final sessionId = await connect();
      await until(() => stateOf(sessionId) == null, what: 'the session gone');
      expect(closedThen, 1);
      await keeps(0, 'nothing is reported of a session that never was');
      expect(unwatchedAsks, hasLength(1));
      expect(host.sockets, isEmpty);
      expect(notices, isEmpty);
    });

    test('how the service stood goes into the report as the app found it: a fault of its own, with its status',
        () async {
      final state = await cloudIs(503);
      expect((state.reach, state.status, state.inTheWay), (CloudReach.fault, 503, true));
      final sessionId = await connect();
      await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
      expect(await dana.unwatchedRound(orchardId), 1);
      final read = (await dana.unwatchedSessionOf(orchardId, reported().single))!;
      expect(read.report!.reach, 'fault 503');
      expect(unwatchedReachRead(read.report!.reach)!.status, 503);
      await sessions().endSession(sessionId);
    });

    test('the words for it, in every language: the Crate is named where it is refused, and each says its own thing',
        () {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        expect(t.watchedAwayNotAllowed('Production'), contains('Production'), reason: '$locale');
        expect(t.watchedAwayNotAllowed('Production'), contains('ZestSSH Cloud'), reason: '$locale');
        expect({
          t.watchedAwayNotAllowed('Production'),
          t.watchedAwayBack,
          t.watchedAwayNotKept,
          t.watchLogUnwatched,
          t.watchLogHeld,
          t.watchedNobodyToAsk('Production'),
        }, hasLength(6), reason: '$locale');
        expect(t.watchLogUnwatched, isNot(endsWith('.')), reason: '$locale: a line of a log, as its like');
      }
      expect(ErrorCodes.all, contains(ErrorCodes.watchedNobodyToAsk));
      expect(ErrorCodes.watchedNobodyToAsk.code, 'ZS-1401');
    });
  });

  test('asking someone else while it waits, and who could be asked', () async {
    WatchGate.joinWait = const Duration(milliseconds: 800);
    final sessionId = await connect();
    final share = await shared(sessionId);
    final gate = container.read(watchGateProvider);
    await Future<void>.delayed(const Duration(milliseconds: 500));
    final request = (await gate.requestFor(sessionId, hostLabel: 'Web 1'))!;
    expect(request.people.map((p) => p.uid), [_kit, _sam]);
    expect(request.alreadyAsked, {_sam});

    // noa does not manage the Crate, and is not asked whatever is picked.
    await gate.askMore(sessionId, {_noa, _kit});
    expect(share.guests.map((g) => (g.uid, g.canEnd)), [(_sam, true), (_kit, true)]);
    expect(api.invited.single.invites.keys, [_kit]);
    expect(SessionShares.nameOf(sessionId, _kit), 'kit@example.com');
    expect((await gate.requestFor(sessionId, hostLabel: 'Web 1'))!.alreadyAsked, {_sam, _kit});

    // Asking someone started the wait over: the first one is over by now,
    // and the session still waits.
    await Future<void>.delayed(const Duration(milliseconds: 500));
    expect(stateOf(sessionId)!.status, SessionStatus.connecting);
    expect(SessionWatches.of(sessionId)!.phase, SessionWatchPhase.waiting);

    // kit joins: that is someone watching.
    await watches(share, _kit);
    await until(() => stateOf(sessionId)?.status == SessionStatus.connected, what: 'the session');
    expect(SessionWatches.of(sessionId)!.phase, SessionWatchPhase.watched);
    await sessions().endSession(sessionId);
    expect(await gate.requestFor(sessionId, hostLabel: 'Web 1'), isNull);
    await gate.askMore(sessionId, {_sam});
  });
}
