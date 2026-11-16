import 'dart:async';
import 'dart:collection';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart' as hash;
import 'package:flutter/foundation.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_host.dart' show ShareRefusal, ShareWire;
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';

/// Where a live view stands, on the device that watches.
enum ShareViewPhase {
  /// Reaching ZestSSH Cloud's relay.
  connecting,

  /// Connected; the person sharing is not there right now.
  waitingForHost,

  /// Setting up the secure channel with their device.
  joining,

  /// Watching.
  watching,

  /// Over: see [ShareViewerController.end].
  ended,
}

/// Why a live view ended.
enum ShareViewEnd {
  /// The person sharing stopped.
  stopped,

  /// The session itself closed.
  sessionClosed,

  /// The person sharing removed this viewer.
  removed,

  /// The share ended at ZestSSH Cloud (its time ran out, or the person
  /// sharing went away for good).
  ended,

  /// There is no such share for this account any more.
  notFound,

  /// This device was signed out.
  signedOut,

  /// This account joined from another device.
  elsewhere,

  /// The share has as many people as it takes.
  full,

  /// The other device would not let this one in: it does not trust this
  /// account's keys, or this account cannot open the Crate any more.
  refused,

  /// This viewer left.
  left,

  /// No secure channel could be set up.
  failed,
}

/// One live view, on the device of someone invited to it. It connects to
/// the relay, sets up a secure channel with the device that shares (which
/// checks who this is, as this device checked the invitation before coming
/// here), and keeps [terminal] showing what that device's terminal shows.
/// When the person sharing hands over the keyboard, what is typed here goes
/// to their session; at any other time nothing typed here goes anywhere.
class ShareViewerController extends ChangeNotifier {
  ShareViewerController({
    required this.invitation,
    required AccountKeys keys,
    required ShareLink link,
    Terminal? terminal,
    Random? random,
    this.joinTimeout = const Duration(seconds: 20),
    this.heartbeat = const Duration(seconds: 10),
  })  : _keys = keys,
        _link = link,
        _random = random ?? Random.secure(),
        terminal = terminal ?? Terminal(maxLines: 2000) {
    // Only an invitation to a live view carries keys ([ShareInvitation]
    // takes no other kind with them, and no live view without).
    if (invitation.invitation.offer == null) {
      throw ArgumentError('not an invitation to a live view');
    }
    // The other terminal answers the program's queries; an answer from this
    // one would reach the program as if someone had typed it.
    this.terminal.respondToQueries = false;
    this.terminal.onOutput = _typed;
  }

  /// How many times in a row a channel is tried before giving up.
  static const int maxAttempts = 5;

  /// An ack goes back after this many frames, or this long after one.
  static const int ackEvery = 8;
  static const Duration ackWithin = Duration(milliseconds: 200);

  /// Keys typed here go out at most this fast, and at most this much waits
  /// (a paste larger than that into someone else's session is not sent).
  /// The relay holds every viewer to a rate of its own, above this one.
  static const int inputRate = 32 * 1024;
  static const int inputBurst = 128 * 1024;
  static const int inputQueueMax = 1024 * 1024;

  /// The invitation this view answers, already checked
  /// ([shareInvitationProblem]).
  final SignedShareInvitation invitation;

  /// What the shared terminal shows. Fed from the other device only.
  final Terminal terminal;

  final Duration joinTimeout;

  /// While the channel is up, an ack goes back this often even when nothing
  /// came. A frame lost on the way (which only a relay that is not playing
  /// by the rules loses) is found out by the next one, in either direction:
  /// this makes sure there is a next one, so a loss never lasts longer.
  final Duration heartbeat;

  final AccountKeys _keys;
  final ShareLink _link;
  final Random _random;

  StreamSubscription<ShareLineEvent>? _events;
  ShareViewPhase _phase = ShareViewPhase.connecting;
  ShareViewEnd? _end;
  ShareKeyboard _keyboard = ShareKeyboard.host;
  bool _asking = false;
  bool _started = false;

  ShareViewerKeys? _viewerKeys;
  Uint8List? _joinWire;
  ShareChannel? _channel;
  bool _hasScreen = false;
  int _attempts = 0;
  Timer? _joinTimer;
  int _unacked = 0;
  Timer? _ackTimer;
  Timer? _beat;
  Future<void> _inbound = Future.value();
  Future<void> _outbound = Future.value();

  final _input = Queue<Uint8List>();
  int _inputWaiting = 0;
  double _inputBudget = inputBurst.toDouble();
  DateTime _inputAt = DateTime.now();
  Timer? _inputTimer;

  ShareViewPhase get phase => _phase;

  /// Why it ended; null while it has not.
  ShareViewEnd? get end => _end;

  /// Who has the keyboard.
  ShareKeyboard get keyboard => _keyboard;

  /// Whether what is typed here goes to the shared session now.
  bool get isTyping => _keyboard == ShareKeyboard.you && _phase == ShareViewPhase.watching;

  /// Whether this viewer may ask for the keyboard at all (the person
  /// sharing allowed it, for this viewer).
  bool get mayAsk => invitation.invitation.keyboard;

  /// Asked, and waiting for the person sharing to answer.
  bool get isAsking => _asking;

  /// Whether this viewer may end the session (the person sharing invited
  /// them to: session moderation).
  bool get mayEnd => invitation.invitation.mayEnd;

  /// Ends the shared session itself. The other device closes it, and this
  /// view ends with it. Nothing while this device is not watching.
  void endSession() {
    if (!mayEnd || _phase != ShareViewPhase.watching) return;
    _post(const ShareEndSession());
  }

  /// Connects and starts watching.
  void start() {
    if (_started) return;
    _started = true;
    _events = _link.events.listen(_heard);
    _link.start();
  }

  /// Asks the person sharing for the keyboard.
  void askKeyboard() {
    if (!mayAsk || _asking || _phase != ShareViewPhase.watching || _keyboard == ShareKeyboard.you) return;
    _asking = true;
    _post(const ShareAskKeyboard());
    notifyListeners();
  }

  /// Hands the keyboard back.
  void giveBack() {
    if (_keyboard != ShareKeyboard.you) return;
    // Nothing more is typed from here, whatever the answer.
    _keyboard = ShareKeyboard.host;
    _dropInput();
    _post(const ShareGiveBack());
    notifyListeners();
  }

  /// Stops watching.
  Future<void> leave() async {
    if (_phase == ShareViewPhase.ended) return;
    _post(const ShareLeave(), last: true);
    final sent = _outbound;
    _finish(ShareViewEnd.left, closeLine: false);
    await sent.timeout(const Duration(seconds: 1), onTimeout: () {});
    await _link.close();
  }

  @override
  void dispose() {
    _joinTimer?.cancel();
    _ackTimer?.cancel();
    _beat?.cancel();
    _inputTimer?.cancel();
    unawaited(_events?.cancel());
    if (_phase != ShareViewPhase.ended) unawaited(_link.close());
    terminal.onOutput = null;
    super.dispose();
  }

  // ── The line ────────────────────────────────────────────────────────

  /// Everything the line says is taken one at a time, in the order it came:
  /// a frame still being opened when the next thing arrives (the host said
  /// "stopped", then its line closed) is finished first.
  void _heard(ShareLineEvent event) {
    if (event is ShareLineBytes) {
      _inbound = _inbound.then((_) => _take(event.bytes)).catchError((Object _) {});
    } else {
      _inbound = _inbound.then((_) => _lineSaid(event)).catchError((Object _) {});
    }
  }

  void _lineSaid(ShareLineEvent event) {
    if (_phase == ShareViewPhase.ended) return;
    switch (event) {
      case ShareLineReady(:final hostOnline):
        _dropChannel();
        if (hostOnline) {
          unawaited(_join());
        } else {
          _setPhase(ShareViewPhase.waitingForHost);
        }
      case ShareLineHost(:final on):
        _dropChannel();
        if (on) {
          _attempts = 0;
          unawaited(_join());
        } else {
          _setPhase(ShareViewPhase.waitingForHost);
        }
      case ShareLineBytes():
        break; // taken in [_heard]
      case ShareLineDown():
        _dropChannel();
        _setPhase(ShareViewPhase.connecting);
      case ShareLineClosed(:final why):
        _finish(switch (why) {
          ShareLineEnd.ended => ShareViewEnd.ended,
          ShareLineEnd.notFound => ShareViewEnd.notFound,
          ShareLineEnd.signedOut => ShareViewEnd.signedOut,
          ShareLineEnd.replaced => ShareViewEnd.elsewhere,
          ShareLineEnd.full => ShareViewEnd.full,
          ShareLineEnd.refused => ShareViewEnd.refused,
        }, closeLine: false);
      case ShareLineViewer() || ShareLineDeclined():
        break; // said to the host only
    }
  }

  void _setPhase(ShareViewPhase phase) {
    if (_phase == phase || _phase == ShareViewPhase.ended) return;
    _phase = phase;
    notifyListeners();
  }

  void _finish(ShareViewEnd why, {bool closeLine = true}) {
    if (_phase == ShareViewPhase.ended) return;
    _dropChannel();
    _phase = ShareViewPhase.ended;
    _end = why;
    unawaited(_events?.cancel());
    if (closeLine) unawaited(_link.close());
    notifyListeners();
  }

  /// Whatever was agreed is over: no channel, no keyboard, nothing waiting.
  void _dropChannel() {
    _joinTimer?.cancel();
    _joinTimer = null;
    _ackTimer?.cancel();
    _ackTimer = null;
    _beat?.cancel();
    _beat = null;
    _unacked = 0;
    _channel = null;
    _viewerKeys = null;
    _joinWire = null;
    _hasScreen = false;
    _asking = false;
    _keyboard = ShareKeyboard.host;
    _dropInput();
    _outbound = Future.value();
  }

  // ── Joining ─────────────────────────────────────────────────────────

  Future<void> _join() async {
    if (_phase == ShareViewPhase.ended) return;
    if (_attempts >= maxAttempts) {
      _finish(ShareViewEnd.failed);
      return;
    }
    _attempts++;
    _dropChannel();
    _setPhase(ShareViewPhase.joining);
    final ShareViewerKeys viewerKeys;
    final SignedShareJoin join;
    try {
      viewerKeys = await ShareViewerKeys.generate(invitation.invitation.offer!, random: _random);
      join = await SignedShareJoin.sign(
        ShareJoinRequest(
          shareId: invitation.invitation.shareId,
          viewerUid: invitation.invitation.toUid,
          viewerKeyVersion: _keys.version,
          invitationDigest: invitation.digest,
          join: viewerKeys.join,
        ),
        _keys,
      );
    } on ArgumentError {
      // Keys in the invitation that no honest device would send, or this
      // device's own keys are not the ones invited.
      _finish(ShareViewEnd.refused);
      return;
    }
    if (_phase != ShareViewPhase.joining || !_link.isOpen) return;
    _viewerKeys = viewerKeys;
    _joinWire = join.wire;
    _link.send(Uint8List.fromList([ShareWire.join, ...join.wire]));
    // No answer: once more, with new keys.
    _joinTimer = Timer(joinTimeout, () {
      if (_phase == ShareViewPhase.joining) unawaited(_join());
    });
  }

  Future<void> _take(Uint8List bytes) async {
    if (_phase == ShareViewPhase.ended || bytes.isEmpty) return;
    final body = Uint8List.sublistView(bytes, 1);
    switch (bytes[0]) {
      case ShareWire.accept:
        final viewerKeys = _viewerKeys;
        final joinWire = _joinWire;
        if (viewerKeys == null || joinWire == null || _channel != null || body.length != kShareHostNonceLength + 32) {
          return;
        }
        // The answer names the join it answers: one to an earlier join of
        // this device (it joined twice in a row) is not this one's.
        final answered = Uint8List.sublistView(body, kShareHostNonceLength);
        if (!listEquals(answered, hash.sha256.convert(joinWire).bytes)) return;
        final channel = await viewerKeys.complete(
          shareId: invitation.invitation.shareId,
          transcript: shareTranscript(invitation.wire, joinWire),
          hostNonce: Uint8List.sublistView(body, 0, kShareHostNonceLength),
        );
        if (!identical(_viewerKeys, viewerKeys) || _phase != ShareViewPhase.joining) return;
        _joinTimer?.cancel();
        _joinTimer = null;
        _channel = channel;
        _viewerKeys = null;
        _post(const ShareReady());
        _beat = Timer.periodic(heartbeat, (_) {
          if (identical(_channel, channel)) _post(ShareAck(channel.received));
        });
      case ShareWire.refuse:
        if (body.length != 1) return;
        if (body[0] == ShareRefusal.broken.index) {
          unawaited(_join());
        } else {
          _finish(ShareViewEnd.refused);
        }
      case ShareWire.frame:
        final channel = _channel;
        if (channel == null) return;
        final ShareMessage message;
        try {
          message = ShareMessage.decode(await channel.open(body), fromHost: true);
        } on ShareChannelBroken {
          if (identical(_channel, channel)) unawaited(_join());
          return;
        } on FormatException {
          if (identical(_channel, channel)) unawaited(_join());
          return;
        }
        if (!identical(_channel, channel)) return;
        _said(message);
        _ackSoon();
    }
  }

  void _said(ShareMessage message) {
    switch (message) {
      case ShareScreen(:final columns, :final rows, :final text):
        terminal.resize(columns, rows);
        terminal.write(text);
        _hasScreen = true;
        _attempts = 0;
        _setPhase(ShareViewPhase.watching);
      case ShareOutput(:final text):
        if (_hasScreen) terminal.write(text);
      case ShareResize(:final columns, :final rows):
        if (_hasScreen) terminal.resize(columns, rows);
      case ShareKeyboardState(:final holder):
        final before = _keyboard;
        // Invited to end the session, this device never types into it,
        // whatever the other one says (session moderation).
        _keyboard = holder == ShareKeyboard.you && mayEnd ? ShareKeyboard.host : holder;
        _asking = false;
        if (before == ShareKeyboard.you && holder != ShareKeyboard.you) _dropInput();
        notifyListeners();
      case ShareEnd(:final reason):
        _finish(switch (reason) {
          ShareEndReason.stopped => ShareViewEnd.stopped,
          ShareEndReason.sessionClosed => ShareViewEnd.sessionClosed,
          ShareEndReason.removed => ShareViewEnd.removed,
        });
      case ShareReady() ||
            ShareInput() ||
            ShareAskKeyboard() ||
            ShareGiveBack() ||
            ShareLeave() ||
            ShareAck() ||
            ShareEndSession():
        break; // only a viewer says these; decode refuses them from the host
    }
  }

  // ── Acks ────────────────────────────────────────────────────────────

  void _ackSoon() {
    if (_channel == null) return;
    _unacked++;
    if (_unacked >= ackEvery) {
      _ack();
    } else {
      _ackTimer ??= Timer(ackWithin, _ack);
    }
  }

  void _ack() {
    _ackTimer?.cancel();
    _ackTimer = null;
    final channel = _channel;
    if (channel == null || _unacked == 0) return;
    _unacked = 0;
    _post(ShareAck(channel.received));
  }

  // ── Typing ──────────────────────────────────────────────────────────

  /// What this device's keyboard produced. It goes to the shared session
  /// only while this viewer holds the keyboard; otherwise nowhere
  /// ([_drainInput] is the one gate: it drops what it is handed at any
  /// other time).
  void _typed(String data) {
    if (data.isEmpty) return;
    final bytes = utf8.encode(data);
    if (_inputWaiting + bytes.length > inputQueueMax) return;
    for (var i = 0; i < bytes.length; i += kShareInputMax) {
      _input.add(Uint8List.sublistView(bytes, i, min(bytes.length, i + kShareInputMax)));
    }
    _inputWaiting += bytes.length;
    _drainInput();
  }

  void _drainInput() {
    _inputTimer?.cancel();
    _inputTimer = null;
    // (While this viewer types there is a channel: the keyboard is only
    // ever given through one, and goes when it does.)
    if (!isTyping) {
      _dropInput();
      return;
    }
    final now = DateTime.now();
    final gained = now.difference(_inputAt).inMicroseconds * inputRate / 1e6;
    _inputBudget = min(inputBurst.toDouble(), _inputBudget + (gained < 0 ? 0 : gained));
    _inputAt = now;
    while (_input.isNotEmpty && _inputBudget >= _input.first.length) {
      final chunk = _input.removeFirst();
      _inputBudget -= chunk.length;
      _inputWaiting -= chunk.length;
      _post(ShareInput(chunk));
    }
    if (_input.isNotEmpty) _inputTimer = Timer(const Duration(milliseconds: 250), _drainInput);
  }

  void _dropInput() {
    _inputTimer?.cancel();
    _inputTimer = null;
    _input.clear();
    _inputWaiting = 0;
  }

  /// Queues [message] for the host, in order, sealed in the channel. What
  /// still waits when the channel is replaced is dropped, except the [last]
  /// word of a viewer who leaves.
  void _post(ShareMessage message, {bool last = false}) {
    final channel = _channel;
    if (channel == null) return;
    _outbound = _outbound.then((_) async {
      if (!last && !identical(_channel, channel)) return;
      try {
        final frame = await channel.seal(message.encode());
        final out = Uint8List(frame.length + 1);
        out[0] = ShareWire.frame;
        out.setRange(1, out.length, frame);
        _link.send(out);
      } catch (_) {
        // A channel that cannot seal any more is finished.
      }
    });
  }
}
