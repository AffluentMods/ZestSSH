// The invited side (share_providers.dart): the invitations this device
// shows, joining a live view, and joining a shared tmux session. sam's
// device is a provider container with the app's own providers; the Orchard
// is built the way the app builds one (the in-memory server the Orchard
// tests use), dana shares from a device of her own, and the relay and
// ZestSSH Cloud's share routes are the in-memory ones.
//
// The list is only asked for in a build with Orchards on: run with
//   flutter test --dart-define=ZEST_ORCHARDS=true

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';

import '../orchards/fake_crate_server.dart';
import 'share_fakes.dart';

const _dana = 'uid-dana';
const _sam = 'uid-sam';
const _kit = 'uid-kit';
const hostId = 'h-web1';

class _MemoryStorage implements OrchardDatabaseStorage {
  final dbs = <String, AppDatabase>{};

  /// Opens nothing (as when the Orchard's key cannot be had).
  bool refuse = false;

  @override
  Future<bool> exists(String orchardId) async => dbs.containsKey(orchardId);

  @override
  Future<AppDatabase> open(String orchardId, String keyHex) async {
    if (refuse) throw StateError('the Orchard cannot be opened');
    return dbs[orchardId] ??= AppDatabase.forTesting(NativeDatabase.memory(), isOrchard: true);
  }

  @override
  Future<void> delete(String orchardId) async => dbs.remove(orchardId);

  @override
  Future<List<String>> list() async => dbs.keys.toList();
}

/// Free or Squeezed, as the test sets it.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  void set(bool pro) => state = pro;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The tmux side of a tab: keeps what it was asked to attach to.
class _Tmux extends ChangeNotifier implements TmuxSessionHost {
  _Tmux(this.sessionId, this._log, this._alreadyActive);

  @override
  final String sessionId;
  final List<(String, String)> _log;
  final bool Function() _alreadyActive;

  @override
  bool get active => _alreadyActive();

  @override
  Future<void> createSession(String name) async => _log.add((sessionId, name));

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// One device with its own databases.
class _Device {
  _Device(FakeCrateServer shared, this.uid, AccountKeys keys, {OrchardDatabasesNotifier? databases}) {
    final dbs = databases ??
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    service = OrchardService(
      server: shared.as(uid),
      databases: dbs,
      author: () async => CrateAuthor(uid: uid, keys: keys),
    );
    coordinator = OrchardSyncCoordinator(service: service, server: shared.as(uid), databases: dbs);
  }

  final String uid;
  final storage = _MemoryStorage();
  late final OrchardService service;
  late final OrchardSyncCoordinator coordinator;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final keys = <String, AccountKeys>{};
  late FakeCrateServer server;
  late ServerSocket tcp;
  late _Device dana;
  late _Device sam;
  late String orchardId;
  late String crateId;
  late ProviderContainer container;
  late AppDatabase tree;
  late _MemoryStorage storage;
  late FakeShareApi samApi;
  late _Pro pro;
  CrateAuthor? me;
  final relays = <String, FakeShareRelay>{};
  final viewerLinks = <FakeShareLink>[];
  final hosts = <ShareHostController>[];
  final tmuxLog = <(String, String)>[];

  /// The sealed invitations of each share dana started, by account.
  final sealedFor = <String, Map<String, Uint8List>>{};
  var tmuxActive = false;
  var shares = 0;

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  setUpAll(() async {
    for (final uid in [_dana, _sam, _kit]) {
      keys[uid] = await AccountKeys.generate();
    }
  });

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    SessionShares.reset();
    ShareViews.reset();
    relays.clear();
    viewerLinks.clear();
    hosts.clear();
    tmuxLog.clear();
    tmuxActive = false;
    tcp = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    tcp.listen((socket) => socket.listen((_) {}, onError: (Object _) {}));
    server = FakeCrateServer(accountUid: _dana);
    for (final uid in [_dana, _sam, _kit]) {
      await server.publish(uid, keys[uid]!, email: '${uid.substring(4)}@example.com');
    }

    // dana's Orchard, with a host in its Crate, from her own device.
    dana = _Device(server, _dana, keys[_dana]!);
    orchardId = await dana.service.createOrchard('Acme', firstCrateName: 'Production', memberRoleName: 'Member');
    final member = server.recordOf(orchardId).roles.values.single;
    crateId = member.crates.keys.single;
    for (final uid in [_sam, _kit]) {
      await dana.service.invite(orchardId, email: '${uid.substring(4)}@example.com', role: member.id);
      final invite = (await dana.service.invites(orchardId)).single;
      server.acceptAs(orchardId, invite.id, uid);
      await dana.service.confirmInvite(orchardId, (await dana.service.invites(orchardId)).single);
    }
    await dana.service.refresh();
    final danaDb = await dana.service.databases.open(orchardId);
    final at = DateTime(2026, 10, 1);
    await danaDb.into(danaDb.connections).insert(ConnectionsCompanion.insert(
          id: hostId,
          label: 'Web 1',
          host: '127.0.0.1',
          port: Value(tcp.port),
          protocol: const Value('telnet'),
          createdAt: at,
          updatedAt: at,
        ));
    await dana.coordinator.syncAll();

    // sam's device: the app's providers.
    samApi = FakeShareApi();
    pro = _Pro();
    me = CrateAuthor(uid: _sam, keys: keys[_sam]!);
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    storage = _MemoryStorage();
    container = ProviderContainer(overrides: [
      currentUserProvider.overrideWithValue(const UserProfile(uid: 'uid-me', email: 'me@example.com')),
      sharedPreferencesProvider.overrideWithValue(prefs),
      orchardDatabaseStorageProvider.overrideWithValue(storage),
      isProProvider.overrideWith((ref) => pro),
      orchardAuthorProvider.overrideWithValue(OrchardAuthorSource(() async => me)),
      shareApiProvider.overrideWithValue(samApi),
      tmuxHostProvider.overrideWith((ref, sessionId) => _Tmux(sessionId, tmuxLog, () => tmuxActive)),
      shareLinkFactoryProvider.overrideWithValue((shareId, {required host}) {
        final link = relays[shareId]!.viewer(_sam);
        viewerLinks.add(link);
        return link;
      }),
    ]);
    container.read(databaseSessionProvider.notifier).seed(tree);
    sam = _Device(server, _sam, keys[_sam]!, databases: container.read(orchardDatabasesProvider.notifier));
    await sam.coordinator.syncAll();
  });

  tearDown(() async {
    await ShareViews.closeAll();
    ShareViews.reset();
    for (final h in hosts) {
      if (!h.isEnded) await h.stop();
      h.dispose();
    }
    container.dispose();
    await tcp.close();
    for (final db in [...storage.dbs.values, ...dana.storage.dbs.values]) {
      await db.close();
    }
    await tree.close();
  });

  /// dana shares her session of the host with sam (and kit, when asked):
  /// the share on her device, and what ZestSSH Cloud lists for sam.
  Future<(ShareHostController, ShareInviteListing)> danaShares({
    ShareMode mode = ShareMode.live,
    bool withKit = false,
    String connection = hostId,
    DateTime Function()? clock,
    Set<String> enders = const {},
  }) async {
    final db = await dana.service.databases.open(orchardId);
    final context = (await shareContextFor(db, connection, myUid: _dana, nowSeconds: now()))!;
    final people = [
      for (final p in context.people)
        if (p.uid == _sam || (withKit && p.uid == _kit)) p.party!,
    ];
    final shareId = '11111111-1111-4111-8111-${(++shares).toString().padLeft(12, '0')}';
    final relay = relays[shareId] = FakeShareRelay(mode: mode);
    final api = FakeShareApi();
    final host = await ShareHostController.start(
      shareId: shareId,
      mode: mode,
      orchardId: orchardId,
      crateId: crateId,
      connectionId: connection,
      people: people,
      myUid: _dana,
      keys: keys[_dana]!,
      api: api,
      link: relay.host(),
      record: () async => server.recordOf(orchardId),
      party: (uid) => sharePartyOf(db, uid, myUid: _dana),
      terminal: mode == ShareMode.live ? SharedTerminal() : null,
      tmuxSession: mode == ShareMode.tmux ? 'shared-k7q' : '',
      remoteUser: 'deploy',
      keyboardRequests: true,
      enders: enders,
      now: clock,
    );
    hosts.add(host);
    sealedFor[shareId] = api.created.single.invites;
    return (
      host,
      ShareInviteListing(
        shareId: shareId,
        orchardId: orchardId,
        crateId: crateId,
        mode: mode,
        fromUid: _dana,
        sealed: api.created.single.invites[_sam]!,
        expiresIn: const Duration(hours: 12),
      ),
    );
  }

  ShareInviteListing relisted(
    ShareInviteListing l, {
    String? orchardId,
    String? crateId,
    ShareMode? mode,
    String? fromUid,
    Uint8List? sealed,
  }) =>
      ShareInviteListing(
        shareId: l.shareId,
        orchardId: orchardId ?? l.orchardId,
        crateId: crateId ?? l.crateId,
        mode: mode ?? l.mode,
        fromUid: fromUid ?? l.fromUid,
        sealed: sealed ?? l.sealed,
        expiresIn: l.expiresIn,
      );

  ShareInvitations invitations() => container.read(shareInvitationsProvider.notifier);
  List<IncomingShare> shown() => container.read(shareInvitationsProvider);
  String skip() => 'run with --dart-define=ZEST_ORCHARDS=true';

  group('the invitations this device shows', () {
    test('one that checks out: who shares, from which Crate, which host; told once', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, listing) = await danaShares();
      final told = <String>[];
      invitations().onNew = (s) => told.add(s.shareId);
      samApi.waiting = [listing];
      await invitations().refresh();

      final s = shown().single;
      expect((s.shareId, s.mode, s.fromEmail, s.crateName, s.hostLabel, s.keysChanged),
          (listing.shareId, ShareMode.live, 'dana@example.com', 'Production', 'Web 1', false));
      expect((s.invitation.invitation.fromUid, s.invitation.invitation.toUid, s.invitation.invitation.connectionId),
          (_dana, _sam, hostId));
      expect(told, [listing.shareId]);

      // Asked again: the same one is not announced again.
      await invitations().refresh();
      expect(shown().single.shareId, listing.shareId);
      expect(told, [listing.shareId]);
      // Another one is, and only that one.
      final (_, second) = await danaShares(mode: ShareMode.tmux);
      samApi.waiting = [listing, second];
      await invitations().refresh();
      expect(shown().map((x) => (x.shareId, x.mode)), [(listing.shareId, ShareMode.live), (second.shareId, ShareMode.tmux)]);
      expect(told, [listing.shareId, second.shareId]);
      // It ended, and is gone here. Shared again later: announced again.
      samApi.waiting = [second];
      await invitations().refresh();
      expect(shown().map((x) => x.shareId), [second.shareId]);
      samApi.waiting = [listing, second];
      await invitations().refresh();
      expect(told, [listing.shareId, second.shareId, listing.shareId]);
    });

    test('asked to watch: an invitation to end a session of a watched Crate, by this device\'s own record',
        () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      // The Crate is not watched: invited to end the session, and that is
      // all it is.
      final (_, plain) = await danaShares(enders: {_sam});
      samApi.waiting = [plain];
      await invitations().refresh();
      var s = shown().single;
      expect((s.invitation.invitation.mayEnd, s.watched, s.asksToWatch), (true, false, false));

      // The owners mark the Crate as watched, and sam's device reads it in
      // the record: someone invited to end a session there is asked to
      // watch; someone invited to look on is not.
      await dana.service.setCrateWatched(orchardId, crateId, true);
      await sam.coordinator.syncAll();
      final (_, toWatch) = await danaShares(enders: {_sam});
      final (_, toLook) = await danaShares();
      samApi.waiting = [toWatch, toLook];
      await invitations().refresh();
      expect([for (final x in shown()) (x.shareId, x.invitation.invitation.mayEnd, x.watched, x.asksToWatch)], [
        (toWatch.shareId, true, true, true),
        (toLook.shareId, false, true, false),
      ]);
      // A shared tmux session is never a request to watch.
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      samApi.waiting = [tmux];
      await invitations().refresh();
      s = shown().single;
      expect((s.mode, s.watched, s.asksToWatch), (ShareMode.tmux, true, false));
    });

    test('what does not check out is not shown at all: nothing a server made up reaches the screen', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, good) = await danaShares();
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      final (_, forBoth) = await danaShares(withKit: true);
      final told = <String>[];
      invitations().onNew = (s) => told.add(s.shareId);

      Future<List<String>> shownFor(List<ShareInviteListing> waiting) async {
        samApi.waiting = waiting;
        await invitations().refresh();
        return [for (final s in shown()) s.shareId];
      }

      // What the server says around the invitation is not what was signed.
      expect(await shownFor([relisted(good, crateId: '44444444-4444-4444-8444-444444444444')]), isEmpty);
      expect(await shownFor([relisted(good, fromUid: _kit)]), isEmpty);
      expect(await shownFor([relisted(good, mode: ShareMode.tmux)]), isEmpty);
      expect(await shownFor([relisted(tmux, mode: ShareMode.live)]), isEmpty);
      // An Orchard this device does not have open.
      expect(await shownFor([relisted(good, orchardId: '55555555-5555-4555-8555-555555555555')]), isEmpty);
      // Someone else's invitation handed to sam, bytes that are no
      // invitation, and one moved to another share.
      expect(await shownFor([relisted(forBoth, sealed: sealedFor[forBoth.shareId]![_kit]!)]), isEmpty);
      expect(await shownFor([relisted(good, sealed: Uint8List.fromList(List.filled(200, 7)))]), isEmpty);
      expect(await shownFor([relisted(tmux, sealed: good.sealed)]), isEmpty);
      // The good ones among them are still shown.
      expect(await shownFor([
        relisted(good, fromUid: _kit),
        good,
        relisted(tmux, sealed: Uint8List.fromList([1, 2, 3])),
        forBoth,
      ]), [good.shareId, forBoth.shareId]);
      expect(told, [good.shareId, forBoth.shareId]);
    });

    test('an invitation past its time, or from someone who can no longer open the Crate, is not shown', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      // Signed thirteen hours ago: its twelve hours are over.
      final (_, old) = await danaShares(clock: () => DateTime.now().subtract(const Duration(hours: 13)));
      samApi.waiting = [old];
      await invitations().refresh();
      expect(shown(), isEmpty);
      // One that claims to last longer than a share can.
      final (_, endless) = await danaShares(clock: () => DateTime.now().add(const Duration(days: 2)));
      samApi.waiting = [endless];
      await invitations().refresh();
      expect(shown(), isEmpty);

      // sam's device learns that kit left the Orchard: nothing from kit.
      final kitDevice = _Device(server, _kit, keys[_kit]!);
      await kitDevice.coordinator.syncAll();
      final kitDb = await kitDevice.service.databases.open(orchardId);
      final samParty = (await sharePartyOf(kitDb, _sam, myUid: _kit))!;
      const shareId = '11111111-1111-4111-8111-999999999999';
      final fromKit = await SignedShareInvitation.sign(
        ShareInvitation(
          shareId: shareId,
          orchardId: orchardId,
          crateId: crateId,
          fromUid: _kit,
          fromKeyVersion: keys[_kit]!.version,
          toUid: _sam,
          mode: ShareMode.tmux,
          connectionId: hostId,
          tmuxSession: 'shared-k7q',
          remoteUser: 'deploy',
          keyboard: false,
          offer: null,
          expiresAt: now() + 3600,
        ),
        keys[_kit]!,
      );
      final listing = ShareInviteListing(
        shareId: shareId,
        orchardId: orchardId,
        crateId: crateId,
        mode: ShareMode.tmux,
        fromUid: _kit,
        sealed: await fromKit.sealTo(samParty.encryptionKey),
        expiresIn: const Duration(hours: 1),
      );
      samApi.waiting = [listing];
      await invitations().refresh();
      expect(shown().single.fromEmail, 'kit@example.com', reason: 'while kit is in the Crate it is shown');
      await dana.service.removeMember(orchardId, _kit);
      await sam.service.refresh();
      await invitations().refresh();
      expect(shown(), isEmpty);
      for (final db in kitDevice.storage.dbs.values) {
        await db.close();
      }
    });

    test('the sender\'s keys changed since they were compared: shown, marked, and not joined', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, listing) = await danaShares();
      final db = container.read(orchardDatabasesProvider)[orchardId]!;
      await db.customStatement(
          "UPDATE member_keys SET replaced_since_compared = 1, verified_by_me = 0, verified_by = '[]' WHERE uid = ?",
          [_dana]);
      samApi.waiting = [listing];
      await invitations().refresh();
      expect(shown().single.keysChanged, isTrue);
      expect(await container.read(shareJoiningProvider).watch(shown().single), isNull);
      expect(await container.read(shareTmuxJoinsProvider).join(shown().single), (null, ShareTmuxJoinProblem.hostMissing));
      expect(viewerLinks, isEmpty, reason: 'no line to the relay was even opened');
    });

    test('ZestSSH Cloud not reached: what is shown stays; no account keys here: nothing is', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, listing) = await danaShares();
      samApi.waiting = [listing];
      await invitations().refresh();
      expect(shown(), hasLength(1));
      samApi
        ..waiting = []
        ..failNext = const SocketException('offline');
      await invitations().refresh();
      expect(shown(), hasLength(1));

      me = null;
      container.read(orchardAuthorProvider).forget();
      samApi.waiting = [listing];
      final asked = <String>[];
      samApi.onCall = asked.add;
      await invitations().refresh();
      expect(shown(), isEmpty);
      expect(asked, isEmpty, reason: 'nothing is asked for an account whose keys are not here');
    });

    test('declining: gone here at once, and the person sharing is told', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, first) = await danaShares();
      final (_, second) = await danaShares(mode: ShareMode.tmux);
      samApi.waiting = [first, second];
      await invitations().refresh();
      final declining = invitations().decline(shown().first);
      expect(shown().map((s) => s.shareId), [second.shareId], reason: 'before the server has answered');
      await declining;
      expect(samApi.removed, [(first.shareId, _sam)]);
      // The server not reached: still gone here (it lapses with the share).
      samApi.failNext = const SocketException('offline');
      await invitations().decline(shown().single);
      expect(shown(), isEmpty);
    });

    test('signing out forgets them, and what was announced', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, listing) = await danaShares();
      final told = <String>[];
      invitations().onNew = (s) => told.add(s.shareId);
      samApi.waiting = [listing];
      await invitations().refresh();
      invitations().clear();
      expect(shown(), isEmpty);
      await invitations().refresh();
      expect(told, [listing.shareId, listing.shareId], reason: 'a new sign-in is told again');
    });

    test('asked several times at once, the server is asked once more, not once for each', () async {
      if (!kOrchardsEnabled) return markTestSkipped(skip());
      final (_, listing) = await danaShares();
      samApi.waiting = [listing];
      var asked = 0;
      samApi.onCall = (call) => asked += call == 'invitations' ? 1 : 0;
      final all = [for (var i = 0; i < 5; i++) invitations().refresh()];
      await Future.wait(all);
      await until(() => asked == 2, what: 'the one further run');
      await settle();
      expect(asked, 2);
      expect(shown(), hasLength(1));
    });
  });

  group('joining a live view', () {
    Future<IncomingShare> incoming(ShareInviteListing listing) async {
      final db = container.read(orchardDatabasesProvider)[orchardId]!;
      final signed = await SignedShareInvitation.open(listing.sealed, keys[_sam]!.encryption, shareId: listing.shareId);
      final host = await db.connectionsDao.getById(signed.invitation.connectionId);
      return IncomingShare(
        listing: listing,
        invitation: signed,
        fromEmail: 'dana@example.com',
        crateName: 'Production',
        hostLabel: host?.label,
        keysChanged: false,
      );
    }

    test('watching starts once, is kept while it runs, and is left when closed', () async {
      final (host, listing) = await danaShares();
      final share = await incoming(listing);
      final announced = <List<String>>[];
      void listener() => announced.add(ShareViews.active.value.keys.toList());
      ShareViews.active.addListener(listener);
      addTearDown(() => ShareViews.active.removeListener(listener));

      final joining = container.read(shareJoiningProvider);
      final view = (await joining.watch(share))!;
      expect(ShareViews.of(share.shareId), same(view));
      expect(ShareViews.shareOf(share.shareId), same(share));
      expect(announced, [
        [share.shareId]
      ]);
      await until(() => view.phase == ShareViewPhase.watching, what: 'sam watching');
      expect(host.guests.single.state, ShareGuestState.watching);
      // Opened again (from the list, from the bell): the same view.
      expect(await joining.watch(share), same(view));
      expect(viewerLinks, hasLength(1));

      await ShareViews.close(share.shareId);
      expect(view.end, ShareViewEnd.left);
      expect(ShareViews.of(share.shareId), isNull);
      expect(ShareViews.shareOf(share.shareId), isNull);
      expect(announced.last, isEmpty);
      await until(() => host.guests.single.state == ShareGuestState.invited, what: 'dana sees sam leave');
      expect(viewerLinks.single.closedHere, isTrue);
      // Closing what is not open is nothing.
      await ShareViews.close(share.shareId);

      // Joined again afterwards: a new view, since the old one is over.
      final again = (await joining.watch(share))!;
      expect(again, isNot(same(view)));
      await until(() => again.phase == ShareViewPhase.watching, what: 'sam watching again');
      // dana stops: the view is over but still there to say why, and
      // opening the invitation again makes a new one.
      await host.stop();
      await until(() => again.phase == ShareViewPhase.ended);
      expect(again.end, ShareViewEnd.stopped);
      expect(ShareViews.of(share.shareId), same(again));
      final third = (await joining.watch(share))!;
      expect(third, isNot(same(again)));
      expect(ShareViews.of(share.shareId), same(third));
      // The one it replaced is done with: nothing can listen to it any more.
      expect(() => again.addListener(() {}), throwsFlutterError);
      // Registered once more, the same view is kept as it is.
      ShareViews.add(share, third);
      third.addListener(() {});
      expect(ShareViews.of(share.shareId), same(third));
    });

    test('a shared tmux session is not watched, and nothing is joined without the account\'s keys', () async {
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      final (_, live) = await danaShares();
      final joining = container.read(shareJoiningProvider);
      expect(await joining.watch(await incoming(tmux)), isNull);
      final share = await incoming(live);
      me = null;
      container.read(orchardAuthorProvider).forget();
      expect(await joining.watch(share), isNull);
      expect(ShareViews.active.value, isEmpty);
      expect(viewerLinks, isEmpty);
    });

    test('every view is left when asked (signing out)', () async {
      final (first, a) = await danaShares();
      final (second, b) = await danaShares();
      final joining = container.read(shareJoiningProvider);
      final one = (await joining.watch(await incoming(a)))!;
      final two = (await joining.watch(await incoming(b)))!;
      await until(() => one.phase == ShareViewPhase.watching && two.phase == ShareViewPhase.watching);
      await ShareViews.closeAll();
      expect((one.end, two.end), (ShareViewEnd.left, ShareViewEnd.left));
      expect(ShareViews.active.value, isEmpty);
      await until(() =>
          first.guests.single.state == ShareGuestState.invited && second.guests.single.state == ShareGuestState.invited);
    });
  });

  group('joining a shared tmux session', () {
    Future<IncomingShare> incoming(ShareInviteListing listing, {bool keysChanged = false}) async {
      final signed = await SignedShareInvitation.open(listing.sealed, keys[_sam]!.encryption, shareId: listing.shareId);
      return IncomingShare(
        listing: listing,
        invitation: signed,
        fromEmail: 'dana@example.com',
        crateName: 'Production',
        hostLabel: 'Web 1',
        keysChanged: keysChanged,
      );
    }

    /// Longer than a joined session waits before it attaches.
    Future<void> pastTheAttach() => Future<void>.delayed(ShareTmuxJoins.attachDelay * 2);

    test('sam connects to the host himself and attaches to the session the invitation names', () async {
      final (host, listing) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      final ended = <(String, ShareLineEnd)>[];
      joins.onEnded = (shareId, why) => ended.add((shareId, why));
      expect(container.read(activeSpaceProvider), isA<TreeSpace>());

      final (sessionId, problem) = await joins.join(await incoming(listing));
      expect(problem, isNull);
      expect(joins.sessionOf(listing.shareId), sessionId);
      expect(tmuxLog, isEmpty, reason: 'nothing is attached before his own connection is up');
      // The session is of the host as THIS device has it, in its Orchard.
      final session = container.read(activeSessionsProvider)[sessionId]!;
      expect((session.connectionId, session.connectionLabel), (hostId, 'Web 1'));
      expect(container.read(activeSpaceProvider), OrchardSpace(orchardId));
      expect(container.read(activeSessionsProvider.notifier).sessionDatabaseOf(hostId),
          same(container.read(orchardDatabasesProvider)[orchardId]));
      // Once it is connected, tmux attaches by the name dana signed.
      await until(() => tmuxLog.isNotEmpty, what: 'the attach', turns: 6000);
      expect(tmuxLog, [(sessionId, 'shared-k7q')]);
      expect(container.read(activeSessionsProvider)[sessionId]?.status, SessionStatus.connected);
      // dana sees him there.
      await until(() => host.guests.single.state == ShareGuestState.connected, what: 'sam attached');

      // Joined again (the invitation opened twice): the same session, and
      // nothing attached twice.
      expect(await joins.join(await incoming(listing)), (sessionId, null));
      await pastTheAttach();
      expect(container.read(activeSessionsProvider).length, 1);
      expect(viewerLinks, hasLength(1));
      expect(tmuxLog, hasLength(1));

      // dana stops sharing, and ZestSSH Cloud ends the share: sam's device
      // is told, and its line is gone. His own connection stays.
      await host.stop();
      relays[listing.shareId]!.end();
      await until(() => ended.isNotEmpty, what: 'the end');
      expect(ended, [(listing.shareId, ShareLineEnd.ended)]);
      expect(joins.sessionOf(listing.shareId), isNull);
      expect(viewerLinks.single.closedHere, isTrue);
      expect(container.read(activeSessionsProvider)[sessionId]?.status, SessionStatus.connected);
    });

    test('a tab that already shows tmux is left as it is, and one that never connects attaches to nothing', () async {
      final (_, listing) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      tmuxActive = true;
      final (first, _) = await joins.join(await incoming(listing));
      await until(() => container.read(activeSessionsProvider)[first]?.status == SessionStatus.connected);
      await pastTheAttach();
      expect(tmuxLog, isEmpty);

      // The host cannot be reached: the session never connects.
      tmuxActive = false;
      await tcp.close();
      final (_, again) = await danaShares(mode: ShareMode.tmux);
      final (second, problem) = await joins.join(await incoming(again));
      expect(problem, isNull);
      await until(() => container.read(activeSessionsProvider)[second]?.status != SessionStatus.connecting,
          what: 'the connection to fail', turns: 8000);
      expect(container.read(activeSessionsProvider)[second]?.status, isNot(SessionStatus.connected));
      await pastTheAttach();
      expect(tmuxLog, isEmpty);
    });

    test('when the session he joined with ends, sam is no longer shown as attached', () async {
      final (host, listing) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      final ended = <String>[];
      joins.onEnded = (shareId, _) => ended.add(shareId);
      final (sessionId, _) = await joins.join(await incoming(listing));
      await until(() => host.guests.single.state == ShareGuestState.connected, what: 'sam attached');

      // The session leaves the list a moment after it ends.
      final sessions = container.read(activeSessionsProvider.notifier);
      await sessions.endSession(sessionId!);
      await until(() => !container.read(activeSessionsProvider).containsKey(sessionId),
          what: 'the session gone', turns: 8000);
      await until(() => host.guests.single.state == ShareGuestState.invited, what: 'sam gone for dana');
      expect(joins.sessionOf(listing.shareId), isNull);
      expect(viewerLinks.single.closedHere, isTrue);
      expect(ended, isEmpty, reason: 'he left; nothing ended from the other side');
      expect(host.isEnded, isFalse);
    });

    test('a live view is not attached to, and keys that changed are compared first', () async {
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      final (_, live) = await danaShares();
      final joins = container.read(shareTmuxJoinsProvider);
      expect(await joins.join(await incoming(live)), (null, ShareTmuxJoinProblem.hostMissing));
      expect(await joins.join(await incoming(tmux, keysChanged: true)), (null, ShareTmuxJoinProblem.hostMissing));
      expect(container.read(activeSpaceProvider), isA<TreeSpace>(), reason: 'nothing moved');
      expect(container.read(activeSessionsProvider), isEmpty);
      expect(viewerLinks, isEmpty);
    });

    test('a host this device does not have, or has in another Crate, is not connected to', () async {
      final joins = container.read(shareTmuxJoinsProvider);
      // dana shares a host that has not reached sam's device.
      final danaDb = await dana.service.databases.open(orchardId);
      final at = DateTime(2026, 10, 1);
      await danaDb.into(danaDb.connections).insert(ConnectionsCompanion.insert(
            id: 'h-new',
            label: 'New',
            host: '127.0.0.1',
            port: Value(tcp.port),
            protocol: const Value('telnet'),
            createdAt: at,
            updatedAt: at,
          ));
      final (_, unknown) = await danaShares(mode: ShareMode.tmux, connection: 'h-new');
      expect(await joins.join(await incoming(unknown)), (null, ShareTmuxJoinProblem.hostMissing));

      // The invitation names Production; by the time sam opens it the host
      // is in Staging on his device. Where to connect never comes from the
      // invitation, and a host in another Crate is another matter.
      final (_, moved) = await danaShares(mode: ShareMode.tmux);
      final staging = await dana.service.createCrate(orchardId, 'Staging');
      await dana.service.setMemberGrants(orchardId, _sam, {staging: levelSwitches(CrateLevel.use)});
      await (await dana.coordinator.engineFor(orchardId, author: CrateAuthor(uid: _dana, keys: keys[_dana]!)))
          .moveItem('host', hostId, staging);
      await dana.coordinator.syncAll();
      await sam.coordinator.syncAll();
      final samDb = container.read(orchardDatabasesProvider)[orchardId]!;
      expect(await samDb.connectionsDao.getById(hostId), isNotNull, reason: 'sam still has the host');
      expect(await joins.join(await incoming(moved)), (null, ShareTmuxJoinProblem.hostMissing));

      expect(container.read(activeSessionsProvider), isEmpty);
      expect(viewerLinks, isEmpty);
      expect(tmuxLog, isEmpty);
    });

    test('the plan\'s session limit: no session, no line, nothing attached later', () async {
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      pro.set(false);
      await container.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
      final db = container.read(orchardDatabasesProvider)[orchardId]!;
      final connection = (await db.connectionsDao.getById(hostId))!;
      final sessions = container.read(activeSessionsProvider.notifier);
      while (sessions.startSession(connection, allowDuplicate: true) != null) {}
      final open = container.read(activeSessionsProvider).length;
      expect(open, greaterThan(0));

      expect(await joins.join(await incoming(tmux)), (null, ShareTmuxJoinProblem.noSession));
      expect(container.read(activeSessionsProvider).length, open);
      expect(joins.sessionOf(tmux.shareId), isNull);
      expect(viewerLinks, isEmpty);
      await pastTheAttach();
      expect(tmuxLog, isEmpty);
    });

    test('an Orchard that is closed on this device and cannot be opened: nothing is joined', () async {
      final (_, tmux) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      final share = await incoming(tmux);
      await container.read(orchardDatabasesProvider.notifier).close(orchardId);
      storage.refuse = true;
      expect(await joins.join(share), (null, ShareTmuxJoinProblem.orchardClosed));
      expect(container.read(activeSessionsProvider), isEmpty);
      expect(viewerLinks, isEmpty);
    });

    test('leaving them all closes every line', () async {
      final (first, a) = await danaShares(mode: ShareMode.tmux);
      final (second, b) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      await joins.join(await incoming(a));
      await joins.join(await incoming(b));
      await until(() =>
          first.guests.single.state == ShareGuestState.connected &&
          second.guests.single.state == ShareGuestState.connected);
      await joins.leaveAll();
      expect(viewerLinks.every((l) => l.closedHere), isTrue);
      expect((joins.sessionOf(a.shareId), joins.sessionOf(b.shareId)), (null, null));
      await until(() =>
          first.guests.single.state == ShareGuestState.invited && second.guests.single.state == ShareGuestState.invited);
    });

    test('when the joins themselves go (signing out), lines close and nothing is attached afterwards', () async {
      final (host, listing) = await danaShares(mode: ShareMode.tmux);
      final joins = container.read(shareTmuxJoinsProvider);
      final (sessionId, _) = await joins.join(await incoming(listing));
      expect(sessionId, isNotNull);
      container.invalidate(shareTmuxJoinsProvider);
      await until(() => viewerLinks.single.closedHere, what: 'the line closed');
      await until(() => container.read(activeSessionsProvider)[sessionId]?.status == SessionStatus.connected);
      await pastTheAttach();
      expect(tmuxLog, isEmpty);
      expect(host.guests.single.state, ShareGuestState.invited);
    });
  });
}
