import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:uuid/uuid.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/sync/orchard_stream.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/account_key_service.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/services/account/device_sessions.dart';

import 'share_fakes.dart' show SharedTerminal, sameScreen, until;

/// Session sharing against the REAL server (ZestSSH Cloud's routes/shares.js
/// and lib/share_relay.js, with the auth middleware and the Orchard routes)
/// on a real Postgres: three accounts in one Orchard, a host in a Crate, and
/// the app's own pieces on each side (ShareApi, ShareLine, the host and
/// viewer controllers). Who can be invited comes from the record; the server
/// hands each person their sealed invitation and nudges them; a live view
/// goes through the relay and shows what the terminal shows; the keyboard
/// goes where it was given; declining, taking back, stopping, a host that
/// stays away and someone who lost their access all end what they should.
/// Start the server first:
///
///   SHARE_HOST_GRACE_MS=1500 node test/helpers/app_contract_server.js   (in ZestSSH Cloud's server code)
///
/// Skips itself when it is not running. ZESTSSH_TEST_API overrides the base
/// URL (default http://127.0.0.1:39200/v1).

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

class _Device {
  _Device(this.me, this.storage, this.service, this.coordinator, this.shares);

  final CrateAuthor me;
  final _MemoryStorage storage;
  final OrchardService service;
  final OrchardSyncCoordinator coordinator;
  final ShareApi shares;

  String get uid => me.uid;
  String get email => '${me.uid}@example.com';

  Future<AppDatabase> db(String orchardId) => coordinator.databases.open(orchardId);
}

/// Three people in one Orchard: dana shares, sam and kit open the Crate.
class _Team {
  _Team(this.orchardId, this.crateId, this.dana, this.sam, this.kit);

  final String orchardId;
  final String crateId;
  final _Device dana;
  final _Device sam;
  final _Device kit;
}

const hostId = 'h-web1';

void main() {
  // No TestWidgetsFlutterBinding: its HTTP mock would block the real server.
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  final base = Platform.environment['ZESTSSH_TEST_API'] ?? 'http://127.0.0.1:39200/v1';
  final root = base.substring(0, base.length - '/v1'.length);
  final client = http.Client();
  var serverUp = false;
  final devices = <_Device>[];
  final hosts = <ShareHostController>[];
  final viewers = <ShareViewerController>[];
  final lines = <ShareLine>[];
  final streams = <OrchardStream>[];

  int now() => DateTime.now().millisecondsSinceEpoch ~/ 1000;
  String token(String uid) => 'fb:$uid:${now()}:${now()}';

  setUpAll(() async {
    try {
      final r = await client.get(Uri.parse('$base/shares/invites')).timeout(const Duration(seconds: 2));
      serverUp = r.statusCode == 401;
    } catch (_) {
      serverUp = false;
    }
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({});
    DeviceSessionHeader.current = null;
  });

  tearDown(() async {
    for (final v in viewers) {
      v.dispose();
    }
    viewers.clear();
    for (final h in hosts) {
      if (!h.isEnded) await h.stop();
      h.dispose();
    }
    hosts.clear();
    for (final l in lines) {
      await l.close();
    }
    lines.clear();
    for (final s in streams) {
      await s.dispose();
    }
    streams.clear();
    for (final d in devices) {
      for (final db in d.storage.dbs.values) {
        await db.close();
      }
    }
    devices.clear();
  });

  String skip() => 'app contract server not running at $base';

  var accounts = 0;

  Future<CrateAuthor> account(String name) async {
    final uid = 'share-$name-${now()}-${accounts++}';
    final keys = await AccountKeys.generate();
    await AccountKeysApi(client: client, baseUrl: base, bearer: () async => token(uid))
        .publish(await keys.publish(uid));
    return CrateAuthor(uid: uid, keys: keys);
  }

  /// A device of [me]: its own databases, as a second computer has.
  _Device device(CrateAuthor me) {
    final storage = _MemoryStorage();
    final databases =
        OrchardDatabasesNotifier(OrchardDatabaseKeys(const FlutterSecureStorage()), storage: storage);
    final server = OrchardsApi(client: client, baseUrl: base, bearer: () async => token(me.uid));
    final service = OrchardService(server: server, databases: databases, author: () async => me);
    final d = _Device(
      me,
      storage,
      service,
      OrchardSyncCoordinator(service: service, server: server, databases: databases),
      ShareApi(client: client, baseUrl: base, bearer: () async => token(me.uid)),
    );
    devices.add(d);
    return d;
  }

  Future<void> join(_Device owner, _Device person, String orchardId, String role) async {
    await owner.service.invite(orchardId, email: person.email, role: role);
    await person.service.acceptInvite((await person.service.myInvites()).single.id);
    await owner.service.confirmInvite(orchardId, (await owner.service.invites(orchardId)).single);
  }

  Future<void> addHost(AppDatabase db, String id) async {
    final at = DateTime(2026, 10, 1);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(
          id: id,
          label: 'Web 1',
          host: 'web1.example.com',
          port: const Value(22),
          createdAt: at,
          updatedAt: at,
        ));
  }

  /// dana's Orchard with sam and kit in it and one host in its Crate, on
  /// everyone's device.
  Future<_Team> team() async {
    final dana = device(await account('dana'));
    final sam = device(await account('sam'));
    final kit = device(await account('kit'));
    final id = await dana.service.createOrchard('Sharing', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await dana.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final role = (await dana.service.roles(id)).single.id;
    await join(dana, sam, id, role);
    await join(dana, kit, id, role);
    await addHost(await dana.db(id), hostId);
    await dana.coordinator.syncAll();
    await sam.coordinator.syncAll();
    await kit.coordinator.syncAll();
    return _Team(id, crate, dana, sam, kit);
  }

  /// A line to the real relay for [d]; the sockets it opens go to [sockets].
  ShareLine line(_Device d, String shareId, {required bool host, List<WebSocket>? sockets}) {
    final l = ShareLine(
      url: ShareLine.urlFor(base),
      connect: (url) async {
        final socket = await WebSocket.connect(url.toString());
        sockets?.add(socket);
        return socket;
      },
      token: ({bool fresh = false}) async => token(d.uid),
      session: () => null,
      shareId: shareId,
      host: host,
      retryDelay: (_) => const Duration(milliseconds: 100),
    );
    lines.add(l);
    return l;
  }

  Future<OrchardRecord> recordOf(_Device d, String orchardId) async =>
      (await LocalRecord.load(await d.db(orchardId), orchardId)).latest;

  Future<ShareContext> contextOf(_Team t) async =>
      (await shareContextFor(await t.dana.db(t.orchardId), hostId, myUid: t.dana.uid, nowSeconds: now()))!;

  /// dana shares her session of the host with [people], as the app does it.
  Future<ShareHostController> share(
    _Team t,
    List<_Device> people, {
    ShareMode mode = ShareMode.live,
    SharedTerminal? terminal,
    List<(ShareNote, String?)>? notes,
    List<WebSocket>? sockets,
    bool keyboardRequests = true,
  }) async {
    final context = await contextOf(t);
    final db = await t.dana.db(t.orchardId);
    final shareId = const Uuid().v4();
    final chosen = [
      for (final p in context.people)
        if (people.any((d) => d.uid == p.uid)) p,
    ];
    expect(chosen.length, people.length, reason: 'everyone picked can open the Crate');
    final h = await ShareHostController.start(
      shareId: shareId,
      mode: mode,
      orchardId: context.orchardId,
      crateId: context.crateId,
      connectionId: context.connectionId,
      people: [for (final p in chosen) p.party!],
      watchOnly: {
        for (final p in chosen)
          if (p.watchOnly) p.uid,
      },
      myUid: t.dana.uid,
      keys: t.dana.me.keys,
      api: t.dana.shares,
      link: line(t.dana, shareId, host: true, sockets: sockets),
      record: () => recordOf(t.dana, t.orchardId),
      party: (uid) => sharePartyOf(db, uid, myUid: t.dana.uid),
      terminal: mode == ShareMode.live ? (terminal ?? SharedTerminal()) : null,
      tmuxSession: mode == ShareMode.tmux ? 'shared-k7q' : '',
      remoteUser: 'deploy',
      keyboardRequests: keyboardRequests,
      onNote: (note, uid) => notes?.add((note, uid)),
    );
    hosts.add(h);
    return h;
  }

  /// The invitation waiting for [d], opened with their key and checked the
  /// way the app checks one before showing it.
  Future<(ShareInviteListing, SignedShareInvitation)> invitationOf(_Team t, _Device d, String shareId) async {
    final listing = (await d.shares.invitations()).firstWhere((l) => l.shareId == shareId);
    final signed = await SignedShareInvitation.open(listing.sealed, d.me.keys.encryption, shareId: listing.shareId);
    final problem = await shareInvitationProblem(
      signed,
      shareId: listing.shareId,
      orchardId: listing.orchardId,
      crateId: listing.crateId,
      fromUid: listing.fromUid,
      mode: listing.mode,
      me: d.uid,
      record: await recordOf(d, t.orchardId),
      host: await sharePartyOf(await d.db(t.orchardId), listing.fromUid, myUid: d.uid),
      nowSeconds: now(),
    );
    expect(problem, isNull, reason: 'the invitation checks out on the device of the person invited');
    return (listing, signed);
  }

  /// [d] joins the live view [shareId] and watches.
  Future<ShareViewerController> watch(_Team t, _Device d, String shareId, {List<WebSocket>? sockets}) async {
    final (_, signed) = await invitationOf(t, d, shareId);
    final v = ShareViewerController(
      invitation: signed,
      keys: d.me.keys,
      link: line(d, shareId, host: false, sockets: sockets),
    );
    viewers.add(v);
    v.start();
    return v;
  }

  Future<void> sweep() async {
    final r = await client.post(Uri.parse('$root/test/shares/sweep'));
    expect(r.statusCode, 200);
  }

  ShareGuest guest(ShareHostController h, _Device d) => h.guests.firstWhere((g) => g.uid == d.uid);

  /// The session shows [text]: the terminal is written, then the share is
  /// told, as the session does it.
  void show(ShareHostController h, SharedTerminal terminal, String text) {
    terminal.terminal.write(text);
    h.output(text);
  }

  /// Waits until [v] shows what [terminal] shows.
  Future<void> shows(ShareViewerController v, SharedTerminal terminal, String marker) async {
    await until(() => _text(v.terminal).contains(marker), what: '"$marker" on the viewer\'s screen');
    sameScreen(terminal.terminal, v.terminal);
  }

  test('who a session can be shared with comes from the record and the keys this device has', () async {
    if (!serverUp) return markTestSkipped(skip());
    final dana = device(await account('dana'));
    final sam = device(await account('sam'));
    final eve = device(await account('eve'));
    final id = await dana.service.createOrchard('Sharing', firstCrateName: 'Production', memberRoleName: 'Member');
    final crate = (await dana.service.server.orchards()).firstWhere((x) => x.id == id).crates.single.id;
    final member = (await dana.service.roles(id)).single.id;
    // eve is in the Orchard and opens another Crate only.
    final staging = await dana.service.createCrate(id, 'Staging');
    final ops = await dana.service.saveRole(id, name: 'Ops', can: {}, crates: {staging: levelSwitches(CrateLevel.use)});
    await join(dana, sam, id, member);
    await join(dana, eve, id, ops);
    final db = await dana.db(id);
    await addHost(db, hostId);

    // Before the host reached ZestSSH Cloud, the others do not have it.
    var context = (await shareContextFor(db, hostId, myUid: dana.uid, nowSeconds: now()))!;
    expect(context.synced, isFalse);
    await dana.coordinator.syncAll();
    context = (await shareContextFor(db, hostId, myUid: dana.uid, nowSeconds: now()))!;
    expect(context.synced, isTrue);
    expect((context.orchardId, context.crateId, context.crateName, context.connectionId), (id, crate, 'Production', hostId));
    expect(context.people.map((p) => (p.uid, p.email, p.keysChanged)), [(sam.uid, sam.email, false)]);
    expect(context.people.single.level, CrateLevel.use);
    expect(context.people.single.watchOnly, isFalse);
    expect(context.withoutAccess, [eve.email]);
    expect(context.sessionLogs, isFalse);

    // The server holds the same line: someone who cannot open the Crate is
    // refused by name, and nothing is shared.
    final shareId = const Uuid().v4();
    final evesKeys = (await sharePartyOf(db, eve.uid, myUid: dana.uid))!;
    final invitation = await SignedShareInvitation.sign(
      ShareInvitation(
        shareId: shareId,
        orchardId: id,
        crateId: crate,
        fromUid: dana.uid,
        fromKeyVersion: dana.me.keys.version,
        toUid: eve.uid,
        mode: ShareMode.tmux,
        connectionId: hostId,
        tmuxSession: 'shared-k7q',
        remoteUser: 'deploy',
        keyboard: false,
        offer: null,
        expiresAt: now() + kShareLifetimeSeconds,
      ),
      dana.me.keys,
    );
    await expectLater(
      dana.shares.create(
        id: shareId,
        crateId: crate,
        mode: ShareMode.tmux,
        invites: {eve.uid: await invitation.sealTo(evesKeys.encryptionKey)},
      ),
      throwsA(isA<ShareNoAccess>().having((e) => e.uids, 'uids', [eve.uid])),
    );
    expect(await eve.shares.invitations(), isEmpty);
    // And a share in a Crate that is not the caller's to open does not exist.
    await expectLater(
      eve.shares.create(id: shareId, crateId: crate, mode: ShareMode.tmux, invites: {
        sam.uid: Uint8List.fromList(List.filled(64, 7)),
      }),
      throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'notFound', isTrue)),
    );
  });

  test('a live view through the real relay: invited, nudged, joined, watched, typed into, left', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();

    // sam's device is on the live line, as a running app is.
    final heard = <OrchardStreamEvent>[];
    final stream = OrchardStream(
      url: OrchardStream.urlFor(base),
      connect: (url) => WebSocket.connect(url.toString()),
      token: ({bool fresh = false}) async => token(t.sam.uid),
      session: () => null,
      retryDelay: (_, _) => const Duration(seconds: 1),
    );
    stream.events.listen(heard.add);
    streams.add(stream);
    stream.start();
    await until(() => heard.whereType<StreamConnected>().isNotEmpty, what: 'the live line');

    final terminal = SharedTerminal();
    terminal.terminal.write('deploy@web1:~\$ tail -f /var/log/app.log\r\n\x1b[32mready\x1b[0m on :8080\r\n');
    final notes = <(ShareNote, String?)>[];
    final host = await share(t, [t.sam], terminal: terminal, notes: notes);
    expect(host.mode, ShareMode.live);
    await until(() => host.isLineOpen, what: 'the host\'s line');
    expect(guest(host, t.sam).state, ShareGuestState.invited);

    // The nudge, and the invitation: sealed to sam, naming nothing in clear.
    await until(() => heard.whereType<ShareInvitesChanged>().isNotEmpty, what: 'the nudge');
    final (listing, signed) = await invitationOf(t, t.sam, host.shareId);
    expect((listing.orchardId, listing.crateId, listing.mode, listing.fromUid),
        (t.orchardId, t.crateId, ShareMode.live, t.dana.uid));
    expect(listing.expiresIn.inSeconds, inInclusiveRange(kShareLifetimeSeconds - 60, kShareLifetimeSeconds));
    final sealedText = latin1.decode(listing.sealed);
    expect(sealedText.contains(hostId), isFalse, reason: 'the server never learns which host');
    expect(sealedText.contains('deploy'), isFalse);
    expect(signed.invitation.connectionId, hostId);
    expect(signed.invitation.remoteUser, 'deploy');
    expect(signed.invitation.keyboard, isTrue);
    // kit was not invited: nothing waits for them, and the relay has no
    // such share for them.
    expect(await t.kit.shares.invitations(), isEmpty);
    final strangerEvents = <ShareLineEvent>[];
    final stranger = line(t.kit, host.shareId, host: false)..events.listen(strangerEvents.add);
    stranger.start();
    await until(() => strangerEvents.isNotEmpty);
    expect((strangerEvents.single as ShareLineClosed).why, ShareLineEnd.notFound);

    // sam joins: the screen as it is, then what comes after.
    final viewer = await watch(t, t.sam, host.shareId);
    await until(() => viewer.phase == ShareViewPhase.watching, what: 'sam watching');
    await shows(viewer, terminal, 'ready');
    expect(guest(host, t.sam).state, ShareGuestState.watching);
    expect(notes, contains((ShareNote.joined, t.sam.uid)));
    show(host, terminal, 'GET /health 200 \x1b[1m3ms\x1b[0m\r\n');
    await shows(viewer, terminal, '3ms');
    terminal.terminal.resize(72, 16);
    host.resized(72, 16);
    show(host, terminal, 'after the resize\r\n');
    await shows(viewer, terminal, 'after the resize');
    expect((viewer.terminal.viewWidth, viewer.terminal.viewHeight), (72, 16));

    // Typing before the keyboard is given goes nowhere.
    viewer.terminal.textInput('whoami\r');
    expect(viewer.isTyping, isFalse);
    // sam asks, dana gives it, and what sam types reaches the session.
    viewer.askKeyboard();
    await until(() => guest(host, t.sam).asksKeyboard, what: 'the request');
    expect(host.giveKeyboard(t.sam.uid), isTrue);
    await until(() => viewer.isTyping, what: 'the keyboard');
    expect(guest(host, t.sam).state, ShareGuestState.typing);
    viewer.terminal.textInput('ls -la\r');
    await until(() => terminal.typed.length == 7, what: 'what sam typed');
    expect(utf8.decode(terminal.typed), 'ls -la\r');
    // Taken back: nothing more of sam's reaches it.
    host.takeBack();
    await until(() => !viewer.isTyping, what: 'the keyboard back');
    viewer.terminal.textInput('rm -rf /\r');
    show(host, terminal, 'still watching\r\n');
    await shows(viewer, terminal, 'still watching');
    expect(utf8.decode(terminal.typed), 'ls -la\r');
    expect(notes.map((n) => n.$1),
        containsAllInOrder([ShareNote.joined, ShareNote.askedKeyboard, ShareNote.keyboardGiven, ShareNote.keyboardBack]));

    // sam leaves: dana sees it, and the invitation still stands.
    await viewer.leave();
    expect(viewer.end, ShareViewEnd.left);
    await until(() => guest(host, t.sam).state == ShareGuestState.invited, what: 'sam gone');
    expect(notes, contains((ShareNote.left, t.sam.uid)));
    expect((await t.sam.shares.invitations()).map((l) => l.shareId), [host.shareId]);
  });

  test('inviting later, declining, taking an invitation back, and stopping', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final terminal = SharedTerminal();
    terminal.terminal.write('one\r\n');
    final notes = <(ShareNote, String?)>[];
    final host = await share(t, [t.sam], terminal: terminal, notes: notes);
    final viewer = await watch(t, t.sam, host.shareId);
    await until(() => viewer.phase == ShareViewPhase.watching, what: 'sam watching');

    // kit is invited while it runs, and says no: dana is told.
    final context = await contextOf(t);
    await host.invite([context.people.firstWhere((p) => p.uid == t.kit.uid).party!]);
    final (kitListing, _) = await invitationOf(t, t.kit, host.shareId);
    expect(kitListing.fromUid, t.dana.uid);
    await t.kit.shares.removeInvite(host.shareId, t.kit.uid);
    await until(() => guest(host, t.kit).state == ShareGuestState.declined, what: 'kit declined');
    expect(notes, contains((ShareNote.declined, t.kit.uid)));
    expect(await t.kit.shares.invitations(), isEmpty);
    // Nobody declines for someone else, and nobody but dana takes one back.
    await expectLater(t.kit.shares.removeInvite(host.shareId, t.sam.uid),
        throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'notFound', isTrue)));
    await expectLater(t.kit.shares.end(host.shareId),
        throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'notFound', isTrue)));
    expect((await t.sam.shares.invitations()).map((l) => l.shareId), [host.shareId]);

    // kit again, who now joins: two people watch the same screen.
    await host.invite([context.people.firstWhere((p) => p.uid == t.kit.uid).party!]);
    final second = await watch(t, t.kit, host.shareId);
    await until(() => second.phase == ShareViewPhase.watching, what: 'kit watching');
    show(host, terminal, 'two\r\n');
    await shows(viewer, terminal, 'two');
    await shows(second, terminal, 'two');

    // dana takes sam's invitation back: sam is told, and cannot come back.
    await host.remove(t.sam.uid);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam removed');
    expect(viewer.end, ShareViewEnd.removed);
    expect(host.guests.map((g) => g.uid), [t.kit.uid]);
    expect(await t.sam.shares.invitations(), isEmpty);
    final again = <ShareLineEvent>[];
    final back = line(t.sam, host.shareId, host: false)..events.listen(again.add);
    back.start();
    await until(() => again.isNotEmpty);
    expect((again.single as ShareLineClosed).why, ShareLineEnd.notFound);
    show(host, terminal, 'three\r\n');
    await shows(second, terminal, 'three');
    expect(_text(viewer.terminal).contains('three'), isFalse);

    // dana stops: kit sees the last of it and is told why; nothing is left.
    show(host, terminal, 'the last line\r\n');
    await host.stop();
    await until(() => second.phase == ShareViewPhase.ended, what: 'the end');
    expect(second.end, ShareViewEnd.stopped);
    expect(_text(second.terminal).contains('the last line'), isTrue);
    expect(await t.kit.shares.invitations(), isEmpty);
    expect(notes.last, (ShareNote.stopped, null));
    await expectLater(t.dana.shares.end(host.shareId),
        throwsA(isA<OrchardServerException>().having((e) => e.notFound, 'notFound', isTrue)));
  });

  test('a line that drops comes back by itself, on either side, and the view goes on', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final terminal = SharedTerminal();
    terminal.terminal.write('before\r\n');
    final hostSockets = <WebSocket>[];
    final viewerSockets = <WebSocket>[];
    final host = await share(t, [t.sam], terminal: terminal, sockets: hostSockets);
    final viewer = await watch(t, t.sam, host.shareId, sockets: viewerSockets);
    await until(() => viewer.phase == ShareViewPhase.watching, what: 'sam watching');
    expect(host.giveKeyboard(t.sam.uid), isTrue);
    await until(() => viewer.isTyping);

    // dana's network goes for a moment. What was agreed is over (nobody
    // types into her session after it), and sam joins again by himself.
    await hostSockets.last.close(WebSocketStatus.goingAway);
    await until(() => viewer.phase == ShareViewPhase.waitingForHost, what: 'sam told that dana went');
    expect(viewer.isTyping, isFalse);
    await until(
        () =>
            hostSockets.length == 2 &&
            viewer.phase == ShareViewPhase.watching &&
            guest(host, t.sam).state == ShareGuestState.watching,
        what: 'the host back, and sam watching again');
    expect(viewer.isTyping, isFalse);
    expect(host.keyboardHolder, isNull);
    show(host, terminal, 'after the host came back\r\n');
    await shows(viewer, terminal, 'after the host came back');

    // sam's network goes: the same.
    await viewerSockets.last.close(WebSocketStatus.goingAway);
    await until(() => viewer.phase == ShareViewPhase.connecting, what: 'sam\'s line down');
    await until(
        () =>
            viewerSockets.length == 2 &&
            viewer.phase == ShareViewPhase.watching &&
            guest(host, t.sam).state == ShareGuestState.watching,
        what: 'sam back');
    show(host, terminal, 'after sam came back\r\n');
    await shows(viewer, terminal, 'after sam came back');

    // sam joins from another device of his: the first one is told.
    final elsewhere = await watch(t, t.sam, host.shareId);
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the first device replaced');
    expect(viewer.end, ShareViewEnd.elsewhere);
    await until(() => elsewhere.phase == ShareViewPhase.watching, what: 'the second device watching');
    await shows(elsewhere, terminal, 'after sam came back');
    expect(host.guests.single.state, ShareGuestState.watching);
  });

  test('a host that stays away: the share ends at ZestSSH Cloud, and those invited are told', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final hostSockets = <WebSocket>[];
    final host = await share(t, [t.sam], sockets: hostSockets);
    final viewer = await watch(t, t.sam, host.shareId);
    await until(() => viewer.phase == ShareViewPhase.watching, what: 'sam watching');

    // dana's device is gone without a word (the app was killed).
    final hostLine = lines.firstWhere((l) => l.host);
    await hostLine.close();
    await until(() => viewer.phase == ShareViewPhase.waitingForHost, what: 'sam waiting');
    // Within the grace nothing ends.
    await sweep();
    expect(viewer.phase, ShareViewPhase.waitingForHost);
    expect((await t.sam.shares.invitations()).map((l) => l.shareId), [host.shareId]);
    // Past it (1.5 seconds on this server, three minutes in production).
    await Future<void>.delayed(const Duration(milliseconds: 1700));
    await sweep();
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'the end');
    expect(viewer.end, ShareViewEnd.ended);
    expect(await t.sam.shares.invitations(), isEmpty);
  });

  test('someone who lost their access is dropped at the next sweep and cannot come back', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final terminal = SharedTerminal();
    terminal.terminal.write('before\r\n');
    final host = await share(t, [t.sam, t.kit], terminal: terminal);
    final viewer = await watch(t, t.sam, host.shareId);
    final other = await watch(t, t.kit, host.shareId);
    await until(() => viewer.phase == ShareViewPhase.watching && other.phase == ShareViewPhase.watching,
        what: 'both watching');

    // dana removes sam from the Orchard.
    await t.dana.service.removeMember(t.orchardId, t.sam.uid);
    expect((await contextOf(t)).people.map((p) => p.uid), [t.kit.uid]);
    expect(await t.sam.shares.invitations(), isEmpty, reason: 'not listed for someone who cannot open the Crate');
    await sweep();
    await until(() => viewer.phase == ShareViewPhase.ended, what: 'sam dropped');
    expect(viewer.end, ShareViewEnd.notFound);
    await until(() => guest(host, t.sam).state == ShareGuestState.invited, what: 'sam gone for dana');
    final again = <ShareLineEvent>[];
    final back = line(t.sam, host.shareId, host: false)..events.listen(again.add);
    back.start();
    await until(() => again.isNotEmpty);
    expect((again.single as ShareLineClosed).why, ShareLineEnd.notFound);
    // kit is not touched.
    show(host, terminal, 'after sam went\r\n');
    await shows(other, terminal, 'after sam went');
    expect(_text(viewer.terminal).contains('after sam went'), isFalse);
  });

  test('a shared tmux session: nothing is relayed, the line says who is attached and when sharing stops', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final notes = <(ShareNote, String?)>[];
    final host = await share(t, [t.sam], mode: ShareMode.tmux, notes: notes);
    await until(() => host.isLineOpen, what: 'the host\'s line');
    final (listing, signed) = await invitationOf(t, t.sam, host.shareId);
    expect(listing.mode, ShareMode.tmux);
    expect((signed.invitation.connectionId, signed.invitation.tmuxSession, signed.invitation.remoteUser),
        (hostId, 'shared-k7q', 'deploy'));
    expect(signed.invitation.offer, isNull, reason: 'no channel: people connect to the host themselves');

    // sam attached (his own connection to the host is his own business):
    // the line says he is there.
    final events = <ShareLineEvent>[];
    final attached = line(t.sam, host.shareId, host: false)..events.listen(events.add);
    attached.start();
    await until(() => events.isNotEmpty);
    final ready = events.single as ShareLineReady;
    expect((ready.mode, ready.hostOnline), (ShareMode.tmux, true));
    await until(() => guest(host, t.sam).state == ShareGuestState.connected, what: 'sam attached');
    expect(notes, contains((ShareNote.joined, t.sam.uid)));

    // Bytes have no business on this line: whoever sends some is cut off.
    attached.send(Uint8List.fromList([1, 2, 3]));
    await until(() => events.length == 2);
    expect((events.last as ShareLineClosed).why, ShareLineEnd.refused);
    await until(() => guest(host, t.sam).state == ShareGuestState.invited, what: 'sam gone');
    expect(notes, contains((ShareNote.left, t.sam.uid)));

    // Attached again; dana stops sharing: sam's device is told.
    final later = <ShareLineEvent>[];
    final again = line(t.sam, host.shareId, host: false)..events.listen(later.add);
    again.start();
    await until(() => guest(host, t.sam).state == ShareGuestState.connected, what: 'sam attached again');
    await host.stop();
    await until(() => later.any((e) => e is ShareLineClosed), what: 'the end');
    expect((later.last as ShareLineClosed).why, ShareLineEnd.ended);
    expect(await t.sam.shares.invitations(), isEmpty);
  });

  test('three sessions shared at once at most, and a stopped one makes room', () async {
    if (!serverUp) return markTestSkipped(skip());
    final t = await team();
    final first = await share(t, [t.sam], mode: ShareMode.tmux);
    await share(t, [t.sam], mode: ShareMode.tmux);
    await share(t, [t.kit]);
    expect((await t.sam.shares.invitations()).length, 2);
    await expectLater(
      share(t, [t.sam]),
      throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'too-many-shares')),
    );
    expect((await t.sam.shares.invitations()).length, 2, reason: 'nothing of the refused one was kept');
    await first.stop();
    final fourth = await share(t, [t.sam]);
    expect((await t.sam.shares.invitations()).map((l) => l.shareId).toSet().contains(fourth.shareId), isTrue);
  });
}

/// What [terminal] shows, as text.
String _text(Terminal terminal) {
  final b = StringBuffer();
  final buffer = terminal.buffer;
  for (var y = 0; y < buffer.lines.length; y++) {
    b.writeln(buffer.lines[y].getText());
  }
  return b.toString();
}
