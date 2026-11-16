// What the live view tests share: one share with the person sharing, the
// relay in memory and the people invited (World), a device that speaks the
// protocol by hand to say what an honest viewer never would (Rogue), and one
// that plays the device that shares by hand, to see exactly what a viewer
// sends and to tell it what an honest host never would (HandHost).

import 'dart:async';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as hash;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

import 'share_fakes.dart';

const shareId = '11111111-1111-4111-8111-111111111111';
const orchardId = '22222222-2222-4222-8222-222222222222';
const crateId = '33333333-3333-4333-8333-333333333333';
const connectionId = '44444444-4444-4444-8444-444444444444';

late AccountKeys dana; // shares
late AccountKeys sam;
late AccountKeys kit;
late AccountKeys noa; // at level Connect: can watch only
late AccountKeys eve; // not in the Crate

/// One share: the person sharing, the relay, and what was said and done.
class World {
  World({this.mode = ShareMode.live});

  final ShareMode mode;
  late final relay = FakeShareRelay(mode: mode);
  final api = FakeShareApi();
  final terminal = SharedTerminal();
  final notes = <(ShareNote, String?)>[];
  DateTime clock = DateTime.utc(2026, 10, 1, 12);
  late OrchardRecord record = teamRecord(orchardId, crateId, {
    'uid-dana': dana,
    'uid-sam': sam,
    'uid-kit': kit,
    'uid-noa': noa,
  }, levels: {
    'uid-noa': CrateLevel.connect
  });

  /// The keys dana's device has pinned for each member.
  late final pinned = <String, ShareParty>{
    'uid-sam': partyOf('uid-sam', sam),
    'uid-kit': partyOf('uid-kit', kit),
    'uid-noa': partyOf('uid-noa', noa),
  };
  late ShareHostController host;
  final viewers = <ShareViewerController>[];

  Future<ShareHostController> share(
    List<String> people, {
    bool keyboardRequests = true,
    Set<String> watchOnly = const {'uid-noa'},
    Set<String> enders = const {},
  }) async =>
      host = await ShareHostController.start(
        shareId: shareId,
        mode: mode,
        orchardId: orchardId,
        crateId: crateId,
        connectionId: connectionId,
        people: [for (final uid in people) pinned[uid]!],
        watchOnly: watchOnly,
        enders: enders,
        myUid: 'uid-dana',
        keys: dana,
        api: api,
        link: relay.host(),
        record: () async => record,
        party: (uid) async => pinned[uid],
        terminal: mode == ShareMode.live ? terminal : null,
        tmuxSession: mode == ShareMode.tmux ? 'shared-k7q' : '',
        remoteUser: 'deploy',
        keyboardRequests: keyboardRequests,
        now: () => clock,
        onNote: (note, uid) => notes.add((note, uid)),
      );

  /// The invitation the server holds for [uid], opened with their keys.
  Future<SignedShareInvitation> invitationOf(String uid, AccountKeys keys) async {
    final sealed = [
      for (final c in api.created) c.invites[uid],
      for (final i in api.invited) i.invites[uid],
    ].whereType<Uint8List>().last;
    return SignedShareInvitation.open(sealed, keys.encryption, shareId: shareId);
  }

  /// [uid] joins on their device and watches.
  Future<ShareViewerController> watch(String uid, AccountKeys keys, {Duration? joinTimeout, Duration? heartbeat}) async {
    final v = ShareViewerController(
      invitation: await invitationOf(uid, keys),
      keys: keys,
      link: relay.viewer(uid),
      joinTimeout: joinTimeout ?? const Duration(seconds: 20),
      heartbeat: heartbeat ?? const Duration(seconds: 10),
    );
    viewers.add(v);
    v.start();
    return v;
  }

  /// The session shows [text]: the terminal is written, then the share is
  /// told, as the session does it. It goes out at once unless [gather].
  void show(String text, {bool gather = false}) {
    terminal.terminal.write(text);
    host.output(text);
    if (!gather) host.flush();
  }

  ShareGuest guest(String uid) => host.guests.firstWhere((g) => g.uid == uid);

  Future<void> dispose() async {
    for (final v in viewers) {
      v.dispose();
    }
    if (!host.isEnded) await host.stop();
    host.dispose();
  }
}

/// A device that speaks the protocol by hand, to say what an honest one
/// never would.
class Rogue {
  Rogue(this.world, this.uid) : link = world.relay.viewer(uid);

  final World world;
  final String uid;
  final FakeShareLink link;
  final heard = <Uint8List>[];
  ShareChannel? channel;

  Future<void> connect() async {
    link.events.listen((e) {
      if (e is ShareLineBytes) heard.add(e.bytes);
    });
    link.start();
    await settle();
  }

  /// Sends a join made from [invitation] with [signer]'s keys; returns what
  /// the host answered (accept or refuse), with the channel set up when it
  /// accepted.
  Future<Uint8List> join(
    SignedShareInvitation invitation,
    AccountKeys signer, {
    String? share,
    String? viewerUid,
    Uint8List? digest,
    ShareJoin? keys,
    Uint8List? rawWire,
  }) async {
    final viewerKeys = await ShareViewerKeys.generate(invitation.invitation.offer!);
    final join = await SignedShareJoin.sign(
      ShareJoinRequest(
        shareId: share ?? shareId,
        viewerUid: viewerUid ?? uid,
        viewerKeyVersion: signer.version,
        invitationDigest: digest ?? invitation.digest,
        join: keys ?? viewerKeys.join,
      ),
      signer,
    );
    final wire = rawWire ?? join.wire;
    final before = heard.length;
    link.send(Uint8List.fromList([ShareWire.join, ...wire]));
    await until(() => heard.length > before, what: 'an answer to the join');
    final answer = heard[before];
    if (answer[0] == ShareWire.accept) {
      channel = await viewerKeys.complete(
        shareId: shareId,
        transcript: shareTranscript(invitation.wire, join.wire),
        hostNonce: Uint8List.sublistView(answer, 1, 33),
      );
    }
    return answer;
  }

  Future<void> say(ShareMessage m) async {
    link.send(Uint8List.fromList([ShareWire.frame, ...await channel!.seal(m.encode())]));
    await settle();
  }
}

bool bytesContain(Uint8List haystack, List<int> needle) {
  outer:
  for (var i = 0; i + needle.length <= haystack.length; i++) {
    for (var j = 0; j < needle.length; j++) {
      if (haystack[i + j] != needle[j]) continue outer;
    }
    return true;
  }
  return false;
}

/// Makes the keys every World uses. Call from setUpAll.
Future<void> makeWorldKeys() async {
  dana = await AccountKeys.generate(version: 2);
  sam = await AccountKeys.generate();
  kit = await AccountKeys.generate();
  noa = await AccountKeys.generate();
  eve = await AccountKeys.generate();
}

/// The device that shares, played by hand: it invites one person with keys
/// of its own, answers their join as the real one does, and then says
/// whatever the test tells it to. What the viewer said is kept, opened.
class HandHost {
  HandHost(this.relay) : link = relay.host();

  final FakeShareRelay relay;
  final FakeShareLink link;
  late ShareHostKeys keys;
  late SignedShareInvitation invitation;
  ShareChannel? channel;
  int lane = 0;

  /// Every join that arrived, as it travelled; whether the next ones are
  /// answered.
  final joins = <Uint8List>[];
  bool answerJoins = true;

  /// What the viewer said through the channel, in order.
  final said = <ShareMessage>[];

  /// Frames from the viewer that did not open with the channel there is.
  int unreadable = 0;
  Future<void> _inbound = Future.value();

  /// An invitation to a live view for [uid], signed by dana.
  Future<SignedShareInvitation> invite(String uid, {bool keyboard = true, bool mayEnd = false}) async {
    keys = await ShareHostKeys.generate();
    return invitation = await SignedShareInvitation.sign(
      ShareInvitation(
        shareId: shareId,
        orchardId: orchardId,
        crateId: crateId,
        fromUid: 'uid-dana',
        fromKeyVersion: dana.version,
        toUid: uid,
        mode: ShareMode.live,
        connectionId: connectionId,
        remoteUser: 'deploy',
        keyboard: keyboard && !mayEnd,
        mayEnd: mayEnd,
        offer: keys.offer,
        expiresAt: 4000000000,
      ),
      dana,
    );
  }

  void start() {
    link.events.listen((e) {
      if (e is ShareLineBytes) _inbound = _inbound.then((_) => _take(e.lane, e.bytes));
    });
    link.start();
  }

  Future<void> _take(int from, Uint8List bytes) async {
    final body = Uint8List.sublistView(bytes, 1);
    if (bytes[0] == ShareWire.join) {
      joins.add(Uint8List.fromList(body));
      if (answerJoins) await accept(from, body);
    } else if (bytes[0] == ShareWire.frame) {
      try {
        said.add(ShareMessage.decode(await channel!.open(body), fromHost: false));
      } catch (_) {
        unreadable++;
      }
    }
  }

  /// Answers the join [wire] that came on [from], as the real host does.
  Future<void> accept(int from, Uint8List wire) async {
    final join = SignedShareJoin.decode(wire);
    final nonce = ShareHostKeys.newNonce();
    channel = await keys.accept(
      join.request.join,
      shareId: shareId,
      transcript: shareTranscript(invitation.wire, join.wire),
      hostNonce: nonce,
    );
    lane = from;
    link.send(Uint8List.fromList([ShareWire.accept, ...nonce, ...hash.sha256.convert(wire).bytes]), lane: from);
  }

  /// Says [m] to the viewer through the channel.
  Future<void> say(ShareMessage m) async {
    link.send(Uint8List.fromList([ShareWire.frame, ...await channel!.seal(m.encode())]), lane: lane);
    await settle();
  }

  /// The keys the viewer typed, as they arrived.
  List<int> get typed => [
        for (final m in said)
          if (m is ShareInput) ...m.bytes,
      ];
}

/// A viewer for [uid] watching a share that [hand] plays the host of.
Future<ShareViewerController> watchHand(
  HandHost hand,
  String uid,
  AccountKeys keys, {
  bool keyboard = true,
  bool mayEnd = false,
  Duration? heartbeat,
  Duration? joinTimeout,
}) async {
  final v = ShareViewerController(
    invitation: await hand.invite(uid, keyboard: keyboard, mayEnd: mayEnd),
    keys: keys,
    link: hand.relay.viewer(uid),
    heartbeat: heartbeat ?? const Duration(seconds: 10),
    joinTimeout: joinTimeout ?? const Duration(seconds: 20),
  );
  hand.start();
  v.start();
  return v;
}
