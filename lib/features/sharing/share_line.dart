import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:zestssh/features/sharing/share_invitation.dart';

/// Why a line to the relay ended for good.
enum ShareLineEnd {
  /// The share ended: it was stopped, its time ran out, or this person's
  /// invitation was taken back or declined.
  ended,

  /// There is no such share for this account: it ended before the line
  /// opened, or the account can no longer open the Crate.
  notFound,

  /// This device was signed out.
  signedOut,

  /// A newer connection of the same person took this one's place (they
  /// joined from another device).
  replaced,

  /// The share has as many people as it takes, or the account as many
  /// lines.
  full,

  /// The relay refused the sign-in, or what this app sent.
  refused,
}

/// Someone connected to the share, on the host's line.
class ShareLane {
  const ShareLane(this.lane, this.uid);

  /// Which of the host's lanes carries this viewer's bytes (1 to 255).
  final int lane;
  final String uid;
}

/// What the relay says, and what it passes on.
sealed class ShareLineEvent {
  const ShareLineEvent();
}

/// Signed in. For the host, [viewers] are the people already connected; for
/// a viewer, [hostOnline] says whether the host is.
class ShareLineReady extends ShareLineEvent {
  const ShareLineReady({required this.mode, this.hostOnline = false, this.viewers = const []});

  final ShareMode mode;
  final bool hostOnline;
  final List<ShareLane> viewers;
}

/// To the host: someone connected ([on]) or went.
class ShareLineViewer extends ShareLineEvent {
  const ShareLineViewer(this.lane, this.uid, {required this.on});

  final int lane;
  final String uid;
  final bool on;
}

/// To the host: someone declined their invitation.
class ShareLineDeclined extends ShareLineEvent {
  const ShareLineDeclined(this.uid);

  final String uid;
}

/// To a viewer: the host connected ([on]) or went. Whatever was agreed with
/// an earlier connection of the host is over: a viewer starts again with a
/// new join each time it is on.
class ShareLineHost extends ShareLineEvent {
  const ShareLineHost({required this.on});

  final bool on;
}

/// Bytes from the other side: for the host, from the viewer on [lane]; for
/// a viewer, from the host ([lane] 0).
class ShareLineBytes extends ShareLineEvent {
  const ShareLineBytes(this.lane, this.bytes);

  final int lane;
  final Uint8List bytes;
}

/// The line dropped and opens again by itself. Until it is ready again,
/// nothing sent goes anywhere.
class ShareLineDown extends ShareLineEvent {
  const ShareLineDown();
}

/// The line ended for good.
class ShareLineClosed extends ShareLineEvent {
  const ShareLineClosed(this.why);

  final ShareLineEnd why;
}

/// A line to the relay, as the host and viewer controllers see it. The real
/// one is [ShareLine]; tests join controllers with one in memory.
abstract class ShareLink {
  Stream<ShareLineEvent> get events;

  /// Whether the line is open and signed in.
  bool get isOpen;

  /// Opens the line and keeps it open until [close] or a [ShareLineClosed].
  void start();

  /// Sends [bytes] to the other side: the host to the viewer on [lane], a
  /// viewer to the host. Dropped when the line is not open.
  void send(Uint8List bytes, {int lane = 0});

  Future<void> close();
}

/// Opens a WebSocket to a URL.
typedef ShareConnector = Future<WebSocket> Function(Uri url);

/// The line to ZestSSH Cloud's relay for one share (ZestSSH Cloud's
/// lib/share_relay.js): a WebSocket this device signs in to with its first
/// message (a token never goes in the address), as the host of the share or
/// as someone invited. The relay passes bytes between the host and each
/// viewer and says who is connected. What it passes it cannot read: a join
/// signed by the viewer, the host's answer, and the frames of a channel
/// whose keys only the two devices have.
///
/// A line that drops opens again by itself. The sign-in is renewed in place
/// well before it runs out, so a long view is never cut for it.
class ShareLine implements ShareLink {
  ShareLine({
    required this.url,
    required this.connect,
    required this.token,
    required this.session,
    required this.shareId,
    required this.host,
    Duration Function(int attempt)? retryDelay,
    this.renewEvery = const Duration(minutes: 45),
  }) : _retryDelay = retryDelay ?? defaultRetryDelay;

  /// The relay's address for an API base such as https://api.zestssh.com/v1.
  static Uri urlFor(String apiBase) {
    final base = Uri.parse(apiBase);
    final path = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(scheme: base.scheme == 'http' ? 'ws' : 'wss', path: '$path/share');
  }

  // How the relay closes a line (lib/share_relay.js).
  static const closeBad = 4400;
  static const closeNotSignedIn = 4401;
  static const closeSignedOut = 4403;
  static const closeNotFound = 4404;
  static const closeReplaced = 4409;
  static const closeEnded = 4410;
  static const closeFull = 4429;

  static const _signInTimeout = Duration(seconds: 15);
  static const _pingInterval = Duration(seconds: 45);
  static final _random = Random();

  /// Half a second, doubling to fifteen, with some spread.
  static Duration defaultRetryDelay(int attempt) =>
      Duration(milliseconds: min(15000, 500 << min(attempt, 5))) * (0.75 + _random.nextDouble() * 0.5);

  final Uri url;
  final ShareConnector connect;

  /// The account's sign-in; [fresh] asks for a newly issued one. Null when
  /// signed out.
  final Future<String?> Function({bool fresh}) token;

  /// This device's registration (the X-ZestSSH-Session header), or null.
  final String? Function() session;

  final String shareId;

  /// Whether this device shares the session (true) or was invited (false).
  final bool host;

  /// How often the sign-in is renewed on an open line. The relay lets one
  /// stand for 55 minutes.
  final Duration renewEvery;

  final Duration Function(int attempt) _retryDelay;

  final _events = StreamController<ShareLineEvent>.broadcast();

  @override
  Stream<ShareLineEvent> get events => _events.stream;

  bool _running = false;
  int _generation = 0;
  WebSocket? _socket;
  bool _ready = false;
  Completer<void>? _wake;

  @override
  bool get isOpen => _ready;

  @override
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop(++_generation));
  }

  @override
  void send(Uint8List bytes, {int lane = 0}) {
    final socket = _socket;
    if (!_ready || socket == null) return;
    try {
      if (host) {
        final out = Uint8List(bytes.length + 1);
        out[0] = lane;
        out.setRange(1, out.length, bytes);
        socket.add(out);
      } else {
        socket.add(bytes);
      }
    } catch (_) {
      // Closing: what could not go is lost, like anything sent while down.
    }
  }

  @override
  Future<void> close() async {
    _running = false;
    _generation++;
    final wake = _wake;
    _wake = null;
    if (wake != null && !wake.isCompleted) wake.complete();
    final socket = _socket;
    _socket = null;
    _ready = false;
    if (socket != null) await _shut(socket);
    if (!_events.isClosed) await _events.close();
  }

  Future<void> _loop(int generation) async {
    bool live() => _running && generation == _generation;
    var attempt = 0;
    var fresh = false;
    var refusedOnce = false;
    while (live()) {
      String? bearer;
      try {
        bearer = await token(fresh: fresh);
      } catch (_) {
        // The sign-in could not be fetched now (renewing it needs the
        // network, which may not be back yet): that is not a sign-out, only
        // null is. Tried again, as a line that could not open.
        if (!live()) return;
        await _wait(_retryDelay(attempt++));
        continue;
      }
      fresh = false;
      if (!live()) return;
      if (bearer == null) {
        _finish(generation, ShareLineEnd.signedOut);
        return;
      }
      WebSocket? socket;
      final connecting = connect(url);
      try {
        socket = await connecting.timeout(_signInTimeout);
      } catch (_) {
        socket = null;
        // One that opens after all is closed, not left hanging.
        unawaited(connecting.then(_shut, onError: (Object _) {}));
      }
      if (socket != null) {
        final open = socket;
        if (!live()) {
          await _shut(open);
          return;
        }
        _socket = open;
        open.pingInterval = _pingInterval;
        final device = session();
        open.add(jsonEncode({
          'type': 'auth',
          'token': bearer,
          'share': shareId,
          'role': host ? 'host' : 'viewer',
          'session': ?device,
        }));
        DateTime? readyAt;
        // A relay that never answers the sign-in is not waited on forever.
        final unanswered = Timer(_signInTimeout, () {
          if (readyAt == null) unawaited(_shut(open));
        });
        Timer? renew;
        try {
          await for (final message in open) {
            if (message is String) {
              final event = _parse(message);
              if (event is ShareLineReady) {
                if (readyAt != null) continue;
                readyAt = DateTime.now();
                _ready = true;
                refusedOnce = false;
                renew = Timer.periodic(renewEvery, (_) => unawaited(_renew(open)));
                _emit(event);
              } else if (event != null && readyAt != null) {
                _emit(event);
              }
            } else if (message is List<int> && readyAt != null) {
              final bytes = message is Uint8List ? message : Uint8List.fromList(message);
              if (host) {
                if (bytes.length >= 2) _emit(ShareLineBytes(bytes[0], Uint8List.sublistView(bytes, 1)));
              } else if (bytes.isNotEmpty) {
                _emit(ShareLineBytes(0, bytes));
              }
            }
          }
        } catch (_) {
          // Dropped: the close code below says what happened, if anything.
        }
        unanswered.cancel();
        renew?.cancel();
        final wasReady = readyAt != null;
        if (identical(_socket, open)) {
          _socket = null;
          _ready = false;
        }
        if (!live()) return;
        if (readyAt != null && DateTime.now().difference(readyAt) > const Duration(seconds: 30)) {
          attempt = 0;
        }
        final end = switch (open.closeCode) {
          closeEnded => ShareLineEnd.ended,
          closeNotFound => ShareLineEnd.notFound,
          closeSignedOut => ShareLineEnd.signedOut,
          closeReplaced => ShareLineEnd.replaced,
          closeFull => ShareLineEnd.full,
          closeBad => ShareLineEnd.refused,
          closeNotSignedIn when refusedOnce => ShareLineEnd.refused,
          _ => null,
        };
        if (end != null) {
          _finish(generation, end);
          return;
        }
        if (open.closeCode == closeNotSignedIn) {
          // Once more, with a newly issued token.
          refusedOnce = true;
          fresh = true;
        }
        if (wasReady) _emit(const ShareLineDown());
      }
      await _wait(_retryDelay(attempt++));
    }
  }

  /// The line is over: says why, and nothing opens it again.
  void _finish(int generation, ShareLineEnd why) {
    if (generation != _generation) return;
    _running = false;
    _emit(ShareLineClosed(why));
  }

  Future<void> _renew(WebSocket socket) async {
    String? bearer;
    try {
      bearer = await token(fresh: true);
    } catch (_) {
      bearer = null;
    }
    if (bearer == null || !identical(_socket, socket)) return;
    try {
      socket.add(jsonEncode({'type': 'renew', 'token': bearer}));
    } catch (_) {/* closing */}
  }

  Future<void> _wait(Duration delay) async {
    if (delay <= Duration.zero) return;
    final wake = _wake = Completer<void>();
    final timer = Timer(delay, () {
      if (!wake.isCompleted) wake.complete();
    });
    await wake.future;
    timer.cancel();
    if (identical(_wake, wake)) _wake = null;
  }

  void _emit(ShareLineEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static Future<void> _shut(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.normalClosure);
    } catch (_) {/* already gone */}
  }

  /// A message from the relay, or null for anything this version does not
  /// know (skipped, so the relay can add kinds of message).
  static ShareLineEvent? _parse(String message) {
    if (message.length > 4096) return null;
    final Object? json;
    try {
      json = jsonDecode(message);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    switch (json['type']) {
      case 'ready':
        final mode = switch (json['mode']) {
          'live' => ShareMode.live,
          'tmux' => ShareMode.tmux,
          _ => null,
        };
        if (mode == null) return null;
        final viewers = json['viewers'];
        return ShareLineReady(
          mode: mode,
          hostOnline: json['host'] == true,
          viewers: [
            if (viewers is List)
              for (final v in viewers) ?_lane(v),
          ],
        );
      case 'viewer':
        final lane = _lane(json);
        final on = json['on'];
        if (lane == null || on is! bool) return null;
        return ShareLineViewer(lane.lane, lane.uid, on: on);
      case 'host':
        final on = json['on'];
        return on is bool ? ShareLineHost(on: on) : null;
      case 'declined':
        final uid = json['uid'];
        return uid is String && uid.isNotEmpty && uid.length <= 128 ? ShareLineDeclined(uid) : null;
    }
    return null;
  }

  static ShareLane? _lane(Object? raw) {
    if (raw is! Map<String, dynamic>) return null;
    final lane = raw['lane'];
    final uid = raw['uid'];
    if (lane is! int || lane < 1 || lane > 255 || uid is! String || uid.isEmpty || uid.length > 128) return null;
    return ShareLane(lane, uid);
  }
}
