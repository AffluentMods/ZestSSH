import 'dart:async';
import 'dart:collection';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// The first byte of what goes between a viewer and the host through the
/// relay, before and around the channel.
abstract final class ShareWire {
  /// Viewer to host: a signed join.
  static const join = 0x01;

  /// Host to viewer: the join is accepted. The host's 32-byte nonce
  /// follows, then the SHA-256 of the join it answers.
  static const accept = 0x02;

  /// Either way: a frame of the channel.
  static const frame = 0x03;

  /// Host to viewer: no. One byte follows, a [ShareRefusal].
  static const refuse = 0x04;
}

/// Why the host said no to a viewer, as it travels (one byte).
enum ShareRefusal {
  /// The join was not one, was not for this share, or was a repeat.
  notAccepted,

  /// The viewer cannot open the Crate any more, or their keys changed since
  /// the host compared them.
  notTrusted,

  /// The channel broke (a frame was changed, lost or out of order): join
  /// again for a new one.
  broken,
}

/// What the host controller needs of the session it shares.
abstract class ShareTerminal {
  /// The terminal as it is now: its size and the text that rebuilds it.
  ShareScreen snapshot();

  /// Types [bytes] into the session, as the session's own keyboard would.
  void type(Uint8List bytes);
}

/// Where someone invited stands, as the person sharing sees it.
enum ShareGuestState {
  /// Invited, not connected (yet, or any more).
  invited,

  /// Said no.
  declined,

  /// Connected. For a shared tmux session: attached. For a live view: its
  /// device is there and the secure channel is being set up.
  connected,

  /// Watching the live view.
  watching,

  /// Watching, with the keyboard.
  typing,
}

/// Someone invited, as the person sharing sees them.
@immutable
class ShareGuest {
  const ShareGuest({
    required this.uid,
    required this.state,
    required this.canType,
    required this.asksKeyboard,
    this.canEnd = false,
  });

  final String uid;
  final ShareGuestState state;

  /// Whether this person may be given the keyboard at all.
  final bool canType;

  /// Whether this person may end the session (session moderation). Then
  /// they are never given the keyboard.
  final bool canEnd;

  /// They asked for the keyboard and wait for an answer.
  final bool asksKeyboard;
}

/// What happened in a share, for the notice shown and for the team's
/// session log (who had the keyboard when is what tells whose input it was).
enum ShareNote {
  joined,
  left,
  declined,
  askedKeyboard,
  keyboardGiven,
  keyboardBack,

  /// The person sharing stopped, or the session closed.
  stopped,

  /// The share ended from the other side: ZestSSH Cloud ended it, this
  /// account lost its access, or this device was signed out.
  endedElsewhere,

  /// Someone invited to end the session said so (session moderation):
  /// whoever hears this closes the session.
  endAsked,
}

class _Guest {
  _Guest(this.party, this.invitation, this.keys, {required this.canType, required this.canEnd});

  final ShareParty party;
  final SignedShareInvitation invitation;

  /// The host's one-time keys for this person (live only).
  final ShareHostKeys? keys;
  final bool canType;
  final bool canEnd;

  bool declined = false;

  /// The lane of their connection; 0 while they have none.
  int lane = 0;
  ShareChannel? channel;

  /// Past "ready": gets the terminal's output.
  bool live = false;
  bool asks = false;

  /// Frames given to the channel, and how many of them they have taken.
  int queued = 0;
  int acked = 0;

  /// The sizes of the frames they have not taken yet, oldest first, and
  /// their sum: what is on its way to them.
  final unacked = ListQueue<int>();
  int inFlight = 0;

  /// The count their last ack carried.
  int lastAck = -1;

  /// Too far behind to be sent more output; gets the screen afresh once
  /// they have caught up.
  bool behind = false;
  double budget = ShareHostController.outputBurst.toDouble();
  DateTime budgetAt = DateTime.fromMillisecondsSinceEpoch(0);

  /// What they send is taken in order, and what they are sent goes in order.
  Future<void> inbound = Future.value();
  Future<void> outbound = Future.value();

  /// Joins already answered (their hashes): a repeat is refused.
  final joins = <String>{};

  void disconnect() {
    lane = 0;
    channel = null;
    live = false;
    asks = false;
    behind = false;
  }
}

/// One shared session, on the device that shares it. It invites people,
/// lets each of them in after checking who they are, sends each the
/// terminal's screen and then its output through a secure channel of their
/// own, and hands the keyboard to one of them when the person sharing says
/// so.
///
/// For a shared tmux session it only keeps the invitations and knows who is
/// attached: people connect to the host themselves.
class ShareHostController extends ChangeNotifier {
  ShareHostController._({
    required this.shareId,
    required this.mode,
    required this.orchardId,
    required this.crateId,
    required this.connectionId,
    required this.tmuxSession,
    required this.remoteUser,
    required this.keyboardRequests,
    required this.myUid,
    required AccountKeys keys,
    required ShareApi api,
    required ShareLink link,
    required Future<OrchardRecord?> Function() record,
    required Future<ShareParty?> Function(String uid) party,
    required ShareTerminal? terminal,
    required DateTime Function() now,
    required Random random,
    this.onNote,
  })  : _keys = keys,
        _api = api,
        _link = link,
        _record = record,
        _party = party,
        _terminal = terminal,
        _now = now,
        _random = random;

  /// How much may be on its way to one viewer before output stops going to
  /// them: this many bytes, or this many frames. What a slow phone has not
  /// taken yet waits on the relay, so this is also the most the relay ever
  /// holds for one viewer.
  static const int windowBytes = 1024 * 1024;
  static const int windowFrames = 2048;

  /// Bytes of output a second one viewer is sent, and what may be saved up.
  /// A terminal is text: more than this nobody reads, and the relay holds
  /// every device to a limit of its own.
  static const int outputRate = 256 * 1024;
  static const int outputBurst = 768 * 1024;

  /// Output that arrives within this long goes out as one frame.
  static const Duration gather = Duration(milliseconds: 16);

  /// How long someone's device is given to read its last word and go
  /// before ZestSSH Cloud is asked to cut its line.
  static const Duration goodbyeWait = Duration(seconds: 1);

  final String shareId;
  final ShareMode mode;
  final String orchardId;
  final String crateId;

  /// The host in the Crate the session is on.
  final String connectionId;
  final String tmuxSession;
  final String remoteUser;

  /// Whether viewers may ask for the keyboard.
  final bool keyboardRequests;
  final String myUid;

  /// Told what happens, as it happens.
  void Function(ShareNote note, String? uid)? onNote;

  final AccountKeys _keys;
  final ShareApi _api;
  final ShareLink _link;
  final Future<OrchardRecord?> Function() _record;
  final Future<ShareParty?> Function(String uid) _party;
  final ShareTerminal? _terminal;
  final DateTime Function() _now;
  final Random _random;

  final _guests = <String, _Guest>{};
  StreamSubscription<ShareLineEvent>? _events;
  String? _holder;
  bool _lineOpen = false;
  bool _ended = false;
  ShareLineEnd? _endedBy;

  /// Someone asked for the session to end: said once.
  bool _endAsked = false;

  /// What the terminal was sent and how it was resized since the last
  /// flush, in the order it happened: text (a [StringBuffer]) and sizes.
  /// The order matters: output written after a resize was made for the new
  /// size, and a viewer that took it at the old one would show it wrongly.
  final _gathered = <Object>[];
  Timer? _flush;
  Timer? _catchUp;

  /// Those told to go whose line has not closed yet, by lane.
  final _goodbyes = <int, Completer<void>>{};

  /// Starts sharing: one invitation for each of [people] (who can open the
  /// Crate, with the keys this device has for them), the share at ZestSSH
  /// Cloud, and the line to the relay. [watchOnly] are those who are never
  /// given the keyboard; [enders] those who may end the session (and are
  /// never given the keyboard either). Throws what [ShareApi.create] throws;
  /// nothing is shared then.
  static Future<ShareHostController> start({
    required String shareId,
    required ShareMode mode,
    required String orchardId,
    required String crateId,
    required String connectionId,
    required List<ShareParty> people,
    required String myUid,
    required AccountKeys keys,
    required ShareApi api,
    required ShareLink link,
    required Future<OrchardRecord?> Function() record,
    required Future<ShareParty?> Function(String uid) party,
    ShareTerminal? terminal,
    Set<String> watchOnly = const {},
    Set<String> enders = const {},
    String tmuxSession = '',
    String remoteUser = '',
    bool keyboardRequests = false,
    DateTime Function()? now,
    Random? random,
    void Function(ShareNote note, String? uid)? onNote,
  }) async {
    if (mode == ShareMode.live && terminal == null) throw ArgumentError('a live view needs a terminal');
    final c = ShareHostController._(
      shareId: shareId,
      mode: mode,
      orchardId: orchardId,
      crateId: crateId,
      connectionId: connectionId,
      tmuxSession: tmuxSession,
      remoteUser: remoteUser,
      keyboardRequests: mode == ShareMode.live && keyboardRequests,
      myUid: myUid,
      keys: keys,
      api: api,
      link: link,
      record: record,
      party: party,
      terminal: terminal,
      now: now ?? DateTime.now,
      random: random ?? Random.secure(),
      onNote: onNote,
    );
    final (made, sealed) = await c._invitationsFor(people, watchOnly, enders);
    await api.create(id: shareId, crateId: crateId, mode: mode, invites: sealed);
    c._guests.addAll(made);
    c._events = link.events.listen(c._heard);
    link.start();
    return c;
  }

  /// An invitation for each of [people]: what this device keeps of each,
  /// and each sealed for its person, by account.
  Future<(Map<String, _Guest>, Map<String, Uint8List>)> _invitationsFor(
      List<ShareParty> people, Set<String> watchOnly, Set<String> enders) async {
    if (people.isEmpty) throw ArgumentError('nobody to share with');
    final expiresAt = _now().millisecondsSinceEpoch ~/ 1000 + kShareLifetimeSeconds;
    final made = <String, _Guest>{};
    final sealed = <String, Uint8List>{};
    for (final p in people) {
      if (p.uid == myUid || p.keysChanged) throw ArgumentError('not someone to share with');
      final canEnd = mode == ShareMode.live && enders.contains(p.uid);
      final canType = mode == ShareMode.live && !canEnd && !watchOnly.contains(p.uid);
      final hostKeys = mode == ShareMode.live ? await ShareHostKeys.generate(random: _random) : null;
      final signed = await SignedShareInvitation.sign(
        ShareInvitation(
          shareId: shareId,
          orchardId: orchardId,
          crateId: crateId,
          fromUid: myUid,
          fromKeyVersion: _keys.version,
          toUid: p.uid,
          mode: mode,
          connectionId: connectionId,
          tmuxSession: tmuxSession,
          remoteUser: remoteUser,
          keyboard: keyboardRequests && canType,
          mayEnd: canEnd,
          offer: hostKeys?.offer,
          expiresAt: expiresAt,
        ),
        _keys,
      );
      made[p.uid] = _Guest(p, signed, hostKeys, canType: canType, canEnd: canEnd);
      sealed[p.uid] = await signed.sealTo(p.encryptionKey);
    }
    if (_guests.length + made.keys.where((u) => !_guests.containsKey(u)).length > kShareMaxPeople) {
      throw ArgumentError('a session is shared with $kShareMaxPeople people at most');
    }
    return (made, sealed);
  }

  // ── What the person sharing sees ────────────────────────────────────

  /// Everyone invited, in the order they were invited.
  List<ShareGuest> get guests => [
        for (final g in _guests.values)
          ShareGuest(
            uid: g.party.uid,
            state: g.declined
                ? ShareGuestState.declined
                : g.lane == 0
                    ? ShareGuestState.invited
                    : mode == ShareMode.tmux || !g.live
                        ? ShareGuestState.connected
                        : _holder == g.party.uid
                            ? ShareGuestState.typing
                            : ShareGuestState.watching,
            canType: g.canType,
            asksKeyboard: g.asks,
            canEnd: g.canEnd,
          ),
      ];

  /// Those watching now who may end the session.
  Set<String> get endersWatching => {
        for (final g in _guests.values)
          if (g.canEnd && g.live) g.party.uid,
      };

  /// Who has the keyboard besides the person sharing; null for nobody.
  String? get keyboardHolder => _holder;

  /// Whether the line to the relay is open. While it is not, nobody is
  /// connected and it opens again by itself.
  bool get isLineOpen => _lineOpen;

  /// The share is over.
  bool get isEnded => _ended;

  /// Why, when it ended from the other side (the server ended it, the
  /// account lost its access, this device was signed out).
  ShareLineEnd? get endedBy => _endedBy;

  // ── What the session tells it ───────────────────────────────────────

  /// The terminal was just sent [text] (and has shown it).
  void output(String text) {
    if (_ended || mode != ShareMode.live || text.isEmpty) return;
    if (!_guests.values.any((g) => g.live)) return;
    final last = _gathered.isEmpty ? null : _gathered.last;
    if (last is StringBuffer) {
      last.write(text);
    } else {
      _gathered.add(StringBuffer(text));
    }
    _flush ??= Timer(gather, flush);
  }

  /// The terminal is now [columns] by [rows].
  void resized(int columns, int rows) {
    if (_ended || mode != ShareMode.live) return;
    if (columns < 1 || rows < 1 || columns > kShareMaxColumns || rows > kShareMaxRows) return;
    if (!_guests.values.any((g) => g.live)) return;
    // Two sizes in a row: only the last one is worth sending.
    if (_gathered.isNotEmpty && _gathered.last is (int, int)) _gathered.removeLast();
    _gathered.add((columns, rows));
    _flush ??= Timer(gather, flush);
  }

  /// Sends what was gathered, now.
  @visibleForTesting
  void flush() {
    _flush?.cancel();
    _flush = null;
    final gathered = List.of(_gathered);
    _gathered.clear();
    if (_ended) return;
    for (final g in _guests.values) {
      if (!g.live) continue;
      for (final item in gathered) {
        // Someone who fell behind gets the screen afresh later, size and all.
        if (g.behind) break;
        switch (item) {
          case StringBuffer():
            _sendOutput(g, item.toString());
          case (final int columns, final int rows):
            _post(g, ShareResize(columns: columns, rows: rows));
        }
      }
    }
  }

  void _sendOutput(_Guest g, String text) {
    for (final piece in shareOutputPieces(text)) {
      if (!_afford(g, piece.length)) {
        _fellBehind(g);
        return;
      }
      _post(g, ShareOutput(piece));
    }
  }

  /// Whether [g] can be sent [size] more now: within the window of what
  /// they have yet to take, and within the rate.
  bool _afford(_Guest g, int size) {
    if (g.inFlight + size > windowBytes || g.unacked.length >= windowFrames) return false;
    final now = _now();
    final gained = now.difference(g.budgetAt).inMicroseconds * outputRate / 1e6;
    g.budget = min(outputBurst.toDouble(), g.budget + (gained < 0 ? 0 : gained));
    g.budgetAt = now;
    if (g.budget < size) return false;
    g.budget -= size;
    return true;
  }

  void _fellBehind(_Guest g) {
    g.behind = true;
    _catchUp ??= Timer.periodic(const Duration(milliseconds: 250), (_) => _resync());
  }

  /// Those who fell behind and have caught up get the screen as it is now.
  void _resync() {
    var waiting = false;
    for (final g in _guests.values) {
      if (!g.behind) continue;
      if (!g.live || g.channel == null) {
        g.behind = false;
        continue;
      }
      final now = _now();
      final gained = now.difference(g.budgetAt).inMicroseconds * outputRate / 1e6;
      g.budget = min(outputBurst.toDouble(), g.budget + (gained < 0 ? 0 : gained));
      g.budgetAt = now;
      // Caught up: most of what was on its way has been taken, by its size
      // and by its count, and the rate allows a screen.
      if (g.inFlight <= windowBytes ~/ 4 && g.unacked.length <= windowFrames ~/ 4 && g.budget >= outputBurst / 2) {
        _sendScreen(g);
      } else {
        waiting = true;
      }
    }
    if (!waiting) {
      _catchUp?.cancel();
      _catchUp = null;
    }
  }

  // ── The keyboard ────────────────────────────────────────────────────

  /// Hands the keyboard to [uid], who is watching and may type. The person
  /// sharing keeps their own keyboard throughout.
  bool giveKeyboard(String uid) {
    final g = _guests[uid];
    if (_ended || g == null || !g.live || !g.canType) return false;
    _setHolder(uid);
    return true;
  }

  /// Takes the keyboard back from whoever has it.
  void takeBack() => _setHolder(null);

  /// Says no to [uid]'s request for the keyboard.
  void denyKeyboard(String uid) {
    final g = _guests[uid];
    if (g == null || !g.asks) return;
    g.asks = false;
    // The state as it stands is the answer.
    if (g.live) _post(g, ShareKeyboardState(_keyboardFor(g)));
    notifyListeners();
  }

  ShareKeyboard _keyboardFor(_Guest g) => _holder == null
      ? ShareKeyboard.host
      : _holder == g.party.uid
          ? ShareKeyboard.you
          : ShareKeyboard.someoneElse;

  void _setHolder(String? uid) {
    if (_holder == uid) return;
    final before = _holder;
    _holder = uid;
    if (uid != null) _guests[uid]?.asks = false;
    for (final g in _guests.values) {
      if (g.live) _post(g, ShareKeyboardState(_keyboardFor(g)));
    }
    if (uid != null) {
      onNote?.call(ShareNote.keyboardGiven, uid);
    } else {
      onNote?.call(ShareNote.keyboardBack, before);
    }
    notifyListeners();
  }

  // ── People ──────────────────────────────────────────────────────────

  /// Invites [people] as well. Someone already invited keeps the invitation
  /// they have (their device may be watching with it); someone who said no
  /// is invited again. Throws what [ShareApi.invite] throws.
  Future<void> invite(
    List<ShareParty> people, {
    Set<String> watchOnly = const {},
    Set<String> enders = const {},
  }) async {
    if (_ended) return;
    final asked = [
      for (final p in people)
        if (_guests[p.uid]?.declined ?? true) p,
    ];
    if (asked.isEmpty) return;
    final (made, sealed) = await _invitationsFor(asked, watchOnly, enders);
    await _api.invite(shareId, sealed);
    if (_ended) return;
    _guests.addAll(made);
    notifyListeners();
  }

  /// Takes [uid]'s invitation back: they are dropped now and cannot come
  /// back.
  Future<void> remove(String uid) async {
    final g = _guests[uid];
    if (g == null) return;
    if (_holder == uid) _setHolder(null);
    final told = g.live ? _sayGoodbye(g, ShareEndReason.removed) : null;
    // Nothing follows the last word, and nothing of theirs is taken.
    _guests.remove(uid);
    notifyListeners();
    if (told != null) await told;
    try {
      await _api.removeInvite(shareId, uid);
    } catch (_) {
      // The share ends with the session at the latest; nothing they hold
      // opens anything once this device has forgotten their invitation.
    }
  }

  /// Stops sharing: everyone watching is told why, the share ends at ZestSSH
  /// Cloud, and the line closes.
  Future<void> stop([ShareEndReason reason = ShareEndReason.stopped]) async {
    if (_ended) return;
    flush();
    _ended = true;
    _holder = null;
    _catchUp?.cancel();
    _catchUp = null;
    // After everything shown so far, which is already on its way.
    final told = [
      for (final g in _guests.values)
        if (g.live) _sayGoodbye(g, reason),
    ];
    notifyListeners();
    onNote?.call(ShareNote.stopped, null);
    await Future.wait(told);
    for (final g in _guests.values) {
      g.disconnect();
    }
    await _events?.cancel();
    try {
      await _api.end(shareId);
    } catch (_) {
      // It lapses by itself once this device is gone from the relay.
    }
    await _link.close();
  }

  /// Tells [g], who is watching, that it is over and why, and waits until
  /// their device has gone ([goodbyeWait] at most). A device closes its line
  /// when it reads this. Only after that is ZestSSH Cloud asked to cut the
  /// line: asked earlier, it could cut it before the last word got through,
  /// and they would see the view end without being told why.
  Future<void> _sayGoodbye(_Guest g, ShareEndReason reason) {
    final lane = g.lane;
    _post(g, ShareEnd(reason));
    final gone = _goodbyes[lane] = Completer<void>();
    return gone.future.timeout(goodbyeWait, onTimeout: () {});
  }

  @override
  void dispose() {
    _flush?.cancel();
    _catchUp?.cancel();
    unawaited(_events?.cancel());
    super.dispose();
  }

  // ── The line ────────────────────────────────────────────────────────

  void _heard(ShareLineEvent event) {
    // Someone told to go has gone (or the line itself did, and they with it).
    switch (event) {
      case ShareLineViewer(:final lane, on: false):
        _goodbyes.remove(lane)?.complete();
      case ShareLineReady() || ShareLineDown() || ShareLineClosed():
        for (final gone in _goodbyes.values) {
          gone.complete();
        }
        _goodbyes.clear();
      default:
        break;
    }
    if (_ended) return;
    switch (event) {
      case ShareLineReady(:final viewers):
        // A new line: whatever was agreed over the old one is over.
        _dropEveryone();
        _lineOpen = true;
        for (final v in viewers) {
          _guests[v.uid]?.lane = v.lane;
        }
        notifyListeners();
      case ShareLineViewer(:final lane, :final uid, :final on):
        final g = _guests[uid];
        if (g == null) return;
        if (on) {
          if (_holder == uid) _setHolder(null);
          g.disconnect();
          g.lane = lane;
          g.declined = false;
          if (mode == ShareMode.tmux) onNote?.call(ShareNote.joined, uid);
        } else if (g.lane == lane) {
          final was = g.live || mode == ShareMode.tmux;
          if (_holder == uid) _setHolder(null);
          g.disconnect();
          if (was) onNote?.call(ShareNote.left, uid);
        }
        notifyListeners();
      case ShareLineDeclined(:final uid):
        final g = _guests[uid];
        if (g == null) return;
        if (_holder == uid) _setHolder(null);
        g.disconnect();
        g.declined = true;
        onNote?.call(ShareNote.declined, uid);
        notifyListeners();
      case ShareLineBytes(:final lane, :final bytes):
        final g = _onLane(lane);
        if (g == null || mode != ShareMode.live) return;
        // One at a time, in the order they came.
        g.inbound = g.inbound.then((_) => _take(g, lane, bytes)).catchError((Object _) {});
      case ShareLineDown():
        _dropEveryone();
        _lineOpen = false;
        notifyListeners();
      case ShareLineClosed(:final why):
        _dropEveryone();
        _lineOpen = false;
        _ended = true;
        _endedBy = why;
        _catchUp?.cancel();
        _catchUp = null;
        notifyListeners();
        onNote?.call(ShareNote.endedElsewhere, null);
      case ShareLineHost():
        break; // said to viewers only
    }
  }

  void _dropEveryone() {
    if (_holder != null) _setHolder(null);
    for (final g in _guests.values) {
      g.disconnect();
    }
  }

  _Guest? _onLane(int lane) {
    if (lane == 0) return null;
    for (final g in _guests.values) {
      if (g.lane == lane) return g;
    }
    return null;
  }

  Future<void> _take(_Guest g, int lane, Uint8List bytes) async {
    if (_ended || g.lane != lane || bytes.isEmpty) return;
    final body = Uint8List.sublistView(bytes, 1);
    switch (bytes[0]) {
      case ShareWire.join:
        await _join(g, lane, body);
      case ShareWire.frame:
        final channel = g.channel;
        if (channel == null) return;
        final ShareMessage message;
        try {
          message = ShareMessage.decode(await channel.open(body), fromHost: false);
        } on ShareChannelBroken {
          _broke(g, lane, channel);
          return;
        } on FormatException {
          _broke(g, lane, channel);
          return;
        }
        if (!identical(g.channel, channel) || g.lane != lane) return;
        _said(g, message);
    }
  }

  /// The channel with [g] cannot go on: they are told to join again.
  void _broke(_Guest g, int lane, ShareChannel channel) {
    if (!identical(g.channel, channel) || g.lane != lane) return;
    if (_holder == g.party.uid) _setHolder(null);
    g.channel = null;
    g.live = false;
    g.asks = false;
    g.behind = false;
    _refuse(lane, ShareRefusal.broken);
    notifyListeners();
  }

  void _refuse(int lane, ShareRefusal why) =>
      _link.send(Uint8List.fromList([ShareWire.refuse, why.index]), lane: lane);

  Future<void> _join(_Guest g, int lane, Uint8List wire) async {
    final SignedShareJoin join;
    try {
      join = SignedShareJoin.decode(wire);
    } on FormatException {
      _refuse(lane, ShareRefusal.notAccepted);
      return;
    }
    final digest = hash.sha256.convert(wire);
    final id = digest.toString();
    final hostKeys = g.keys;
    if (hostKeys == null || g.joins.contains(id)) {
      _refuse(lane, ShareRefusal.notAccepted);
      return;
    }
    // Who they are, by the keys this device has for them, and whether they
    // can still open the Crate, by the record as it is now.
    final record = await _record();
    final viewer = await _party(g.party.uid);
    if (_ended || g.lane != lane) return;
    final problem = record == null
        ? ShareProblem.senderNoAccess
        : await shareJoinProblem(
            join,
            invitation: g.invitation,
            record: record,
            viewer: viewer,
            nowSeconds: _now().millisecondsSinceEpoch ~/ 1000,
          );
    if (_ended || g.lane != lane) return;
    if (problem != null) {
      _refuse(
          lane,
          problem == ShareProblem.mismatch || problem == ShareProblem.expired
              ? ShareRefusal.notAccepted
              : ShareRefusal.notTrusted);
      return;
    }
    final nonce = ShareHostKeys.newNonce(random: _random);
    final ShareChannel channel;
    try {
      channel = await hostKeys.accept(
        join.request.join,
        shareId: shareId,
        transcript: shareTranscript(g.invitation.wire, join.wire),
        hostNonce: nonce,
      );
    } on ArgumentError {
      _refuse(lane, ShareRefusal.notAccepted);
      return;
    }
    if (_ended || g.lane != lane) return;
    g.joins.add(id);
    if (_holder == g.party.uid) _setHolder(null);
    g
      ..channel = channel
      ..live = false
      ..asks = false
      ..behind = false
      ..queued = 0
      ..acked = 0
      ..inFlight = 0
      ..lastAck = -1
      ..outbound = Future.value();
    g.unacked.clear();
    _link.send(Uint8List.fromList([ShareWire.accept, ...nonce, ...digest.bytes]), lane: lane);
    notifyListeners();
  }

  void _said(_Guest g, ShareMessage message) {
    switch (message) {
      case ShareReady():
        final first = !g.live;
        _sendScreen(g);
        if (first) onNote?.call(ShareNote.joined, g.party.uid);
        notifyListeners();
      case ShareInput(:final bytes):
        // Only from the one who has the keyboard; anyone else's is dropped.
        if (_holder == g.party.uid && g.live) _terminal?.type(bytes);
      case ShareAskKeyboard():
        if (!keyboardRequests || !g.canType || !g.live || _holder == g.party.uid || g.asks) return;
        g.asks = true;
        onNote?.call(ShareNote.askedKeyboard, g.party.uid);
        notifyListeners();
      case ShareGiveBack():
        if (_holder == g.party.uid) _setHolder(null);
      case ShareEndSession():
        // Only from someone invited to end it, who is watching; said once.
        if (!g.canEnd || !g.live || _endAsked) return;
        _endAsked = true;
        onNote?.call(ShareNote.endAsked, g.party.uid);
      case ShareLeave():
        final was = g.live;
        if (_holder == g.party.uid) _setHolder(null);
        g.channel = null;
        g.live = false;
        g.asks = false;
        g.behind = false;
        if (was) onNote?.call(ShareNote.left, g.party.uid);
        notifyListeners();
      case ShareAck(:final received):
        // The same count twice while frames are out: what was sent is not
        // arriving (only a relay that is not playing by the rules loses a
        // frame). One more frame shows the viewer the gap, and it joins
        // again; if the frames were only slow, it costs nothing.
        final stuck = received == g.lastAck && received < g.queued;
        g.lastAck = received;
        while (g.acked < received && g.unacked.isNotEmpty) {
          g.inFlight -= g.unacked.removeFirst();
          g.acked++;
        }
        if (g.behind) _resync();
        if (stuck && g.live) _post(g, ShareKeyboardState(_keyboardFor(g)));
      case ShareScreen() || ShareOutput() || ShareResize() || ShareKeyboardState() || ShareEnd():
        break; // only the host says these; decode refuses them from a viewer
    }
  }

  /// The terminal as it is now, to [g], who gets its output from here on.
  void _sendScreen(_Guest g) {
    final terminal = _terminal;
    if (terminal == null) return;
    // What the others have not been sent yet is in the terminal already:
    // it goes to them first, and is not sent to [g] on top of the screen.
    flush();
    final screen = terminal.snapshot();
    final pieces = shareOutputPieces(screen.text).toList();
    g
      ..live = true
      ..behind = false;
    _afford(g, 0);
    g.budget -= screen.text.length;
    _post(g, ShareScreen(columns: screen.columns, rows: screen.rows, text: pieces.isEmpty ? '' : pieces.first));
    for (final piece in pieces.skip(1)) {
      _post(g, ShareOutput(piece));
    }
    _post(g, ShareKeyboardState(_keyboardFor(g)));
  }

  /// Queues [message] for [g], in order, sealed in their channel.
  void _post(_Guest g, ShareMessage message) {
    final channel = g.channel;
    final lane = g.lane;
    if (channel == null || lane == 0) return;
    final plain = message.encode();
    g.queued++;
    g.unacked.add(plain.length);
    g.inFlight += plain.length;
    g.outbound = g.outbound.then((_) async {
      // A channel that was replaced meanwhile takes nothing more.
      if (!identical(g.channel, channel)) return;
      try {
        final frame = await channel.seal(plain);
        final out = Uint8List(frame.length + 1);
        out[0] = ShareWire.frame;
        out.setRange(1, out.length, frame);
        _link.send(out, lane: lane);
      } catch (_) {
        // A channel that cannot seal any more is finished; they join again.
      }
    });
  }
}
