import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

/// What the live line to ZestSSH Cloud says (3.0).
sealed class OrchardStreamEvent {
  const OrchardStreamEvent();
}

/// Signed in. [reconnected] after the line was lost, when changes may have
/// been missed meanwhile.
class StreamConnected extends OrchardStreamEvent {
  const StreamConnected({required this.reconnected});

  final bool reconnected;
}

/// A Crate this account reads changed; [revision] is its newest revision.
class CrateChanged extends OrchardStreamEvent {
  const CrateChanged(this.crateId, this.revision);

  final String crateId;
  final int revision;
}

/// The account's Orchards changed: one was made, or a Crate was added,
/// renamed or taken away.
class OrchardsChanged extends OrchardStreamEvent {
  const OrchardsChanged();
}

/// A new-device approval of this account moved on (3.0):
/// request [id] was made, answered, revealed, sent or ended.
class DeviceApprovalMoved extends OrchardStreamEvent {
  const DeviceApprovalMoved(this.id);

  final String id;
}

/// An invitation to a shared session came or went (3.0, session sharing):
/// this device looks at the account's invitations again. Nothing more is
/// said on the line.
class ShareInvitesChanged extends OrchardStreamEvent {
  const ShareInvitesChanged();
}

/// A request for access was made, withdrawn or answered (3.0):
/// this device looks at the requests again. Nothing more is said on the
/// line.
class AccessRequestsChanged extends OrchardStreamEvent {
  const AccessRequestsChanged();
}

/// A device asked to be approved, was answered, or was approved or removed
/// (3.0): this device looks at the requests again. Nothing more is
/// said on the line.
class DeviceRequestsChanged extends OrchardStreamEvent {
  const DeviceRequestsChanged();
}

/// The account's security changed (3.3, the two-step contract, section
/// 6.5): this device reads its two-step sign-in again, where a waiting
/// lock-out recovery shows with "This wasn't me". Nothing more is said on
/// the line.
class SecurityChanged extends OrchardStreamEvent {
  const SecurityChanged();
}

/// ZestSSH Cloud signed this device out.
class StreamSignedOut extends OrchardStreamEvent {
  const StreamSignedOut();
}

/// Why the line opens again.
enum StreamRetry {
  /// The server asked for a fresh sign-in, as it does about hourly.
  renew,

  /// The sign-in was refused once: it is tried again with a fresh token.
  freshToken,

  /// The line dropped, or could not open.
  dropped,

  /// The sign-in was refused even with a fresh token.
  refused,

  /// The account has too many lines open.
  busy,
}

/// How long to wait before opening the line again, the [attempt]th time in
/// a row.
typedef StreamRetryDelay = Duration Function(StreamRetry why, int attempt);

/// Opens a WebSocket to a URL.
typedef StreamConnector = Future<WebSocket> Function(Uri url);

/// The live line to ZestSSH Cloud (3.0; ZestSSH Cloud's
/// lib/stream.js). While it is open, the server says when a Crate this
/// account reads changed, or its Orchards did, so an edit reaches the
/// account's other devices in seconds instead of at the next 15-minute
/// sync. It carries no data, a Crate id and a revision at most, and losing
/// it costs only speed: syncs still run on their own.
///
/// The sign-in token goes in the first message, never in the address, where
/// proxies and logs keep it.
class OrchardStream {
  OrchardStream({
    required this.url,
    required this.connect,
    required this.token,
    required this.session,
    StreamRetryDelay? retryDelay,
  }) : _retryDelay = retryDelay ?? defaultRetryDelay;

  /// The line's address for an API base such as https://api.zestssh.com/v1.
  static Uri urlFor(String apiBase) {
    final base = Uri.parse(apiBase);
    final path = base.path.endsWith('/') ? base.path.substring(0, base.path.length - 1) : base.path;
    return base.replace(scheme: base.scheme == 'http' ? 'ws' : 'wss', path: '$path/stream');
  }

  // How the server closes the line (lib/stream.js).
  static const closeRenew = 4000;
  static const closeNotSignedIn = 4401;
  static const closeSignedOut = 4403;
  static const closeBusy = 4429;

  static const _signInTimeout = Duration(seconds: 15);

  /// Pings from this side too, so a line that died silently (a laptop that
  /// slept, a network that changed) is noticed within a minute and a half.
  static const _pingInterval = Duration(seconds: 45);

  static final _random = Random();

  /// Soon for a renewal, doubling from a second up to five minutes for a
  /// dropped line, and ten minutes when the account is refused or has too
  /// many lines; each with some spread, so devices do not all come back at
  /// once after an outage.
  static Duration defaultRetryDelay(StreamRetry why, int attempt) {
    final base = switch (why) {
      StreamRetry.renew || StreamRetry.freshToken => const Duration(milliseconds: 200),
      StreamRetry.dropped => Duration(seconds: min(300, 1 << min(attempt, 9))),
      StreamRetry.refused || StreamRetry.busy => const Duration(minutes: 10),
    };
    return base * (0.75 + _random.nextDouble() * 0.5);
  }

  final Uri url;
  final StreamConnector connect;

  /// The account's sign-in; [fresh] asks for a newly issued one. Null when
  /// signed out.
  final Future<String?> Function({bool fresh}) token;

  /// This device's registration (the X-ZestSSH-Session header), or null.
  final String? Function() session;

  final StreamRetryDelay _retryDelay;

  final _events = StreamController<OrchardStreamEvent>.broadcast();

  /// What the server says, while the line is open.
  Stream<OrchardStreamEvent> get events => _events.stream;

  bool _running = false;
  int _generation = 0;
  WebSocket? _socket;
  bool _signedIn = false;
  Completer<void>? _wake;
  StreamRetry? _waitingFor;
  bool _reopen = false;

  /// Whether the line is kept open.
  bool get isRunning => _running;

  /// Whether the line is open and signed in.
  bool get isConnected => _signedIn;

  /// Opens the line and keeps it open until [stop]. Does nothing when it is
  /// already running.
  void start() {
    if (_running) return;
    _running = true;
    unawaited(_loop(++_generation));
  }

  /// Opens a dropped line now instead of at the end of its wait: a sync just
  /// reached the server, so the network is back. A wait after a refusal is
  /// kept.
  void retryNow() {
    if (_waitingFor == StreamRetry.dropped) _wakeUp();
  }

  /// Opens the line afresh at once: the network changed, and a line that
  /// was open may be dead without knowing it yet. Coming back, it says it
  /// may have missed changes. A wait after a refusal is kept.
  void reconnectNow() {
    if (!_running) return;
    final socket = _socket;
    if (socket == null) {
      retryNow();
      return;
    }
    _reopen = true;
    unawaited(_close(socket));
  }

  /// Closes the line. Nothing opens it again until [start].
  Future<void> stop() async {
    _running = false;
    _reopen = false;
    _generation++;
    _wakeUp();
    final socket = _socket;
    _socket = null;
    _signedIn = false;
    if (socket != null) {
      try {
        await socket.close(WebSocketStatus.normalClosure);
      } catch (_) {/* already gone */}
    }
  }

  Future<void> dispose() async {
    await stop();
    await _events.close();
  }

  Future<void> _loop(int generation) async {
    bool live() => _running && generation == _generation;
    var attempt = 0;
    var fresh = false;
    var refusedOnce = false;
    var signedInBefore = false;
    while (live()) {
      StreamRetry retry;
      String? bearer;
      try {
        bearer = await token(fresh: fresh);
      } catch (_) {
        bearer = null;
      }
      fresh = false;
      if (!live()) return;
      if (bearer == null) {
        // Signed out: nothing to open until the app starts the line again.
        if (generation == _generation) _running = false;
        return;
      }
      WebSocket? socket;
      final connecting = connect(url);
      try {
        socket = await connecting.timeout(_signInTimeout);
      } catch (_) {
        socket = null;
        // One that opens after all is closed, not left hanging.
        unawaited(connecting.then(_close, onError: (Object _) {}));
      }
      if (socket == null) {
        retry = StreamRetry.dropped;
      } else {
        final open = socket;
        if (!live()) {
          await _close(open);
          return;
        }
        _socket = open;
        open.pingInterval = _pingInterval;
        final device = session();
        open.add(jsonEncode({
          'type': 'auth',
          'token': bearer,
          'session': ?device,
        }));
        DateTime? readyAt;
        // A server that never answers the sign-in is not waited on forever.
        final unanswered = Timer(_signInTimeout, () {
          if (readyAt == null) unawaited(_close(open));
        });
        try {
          await for (final message in open) {
            final event = _parse(message);
            if (event == null) continue;
            if (event is _Ready) {
              if (readyAt != null) continue;
              readyAt = DateTime.now();
              _signedIn = true;
              refusedOnce = false;
              _emit(StreamConnected(reconnected: signedInBefore));
              signedInBefore = true;
            } else if (readyAt != null) {
              _emit(event as OrchardStreamEvent);
            }
          }
        } catch (_) {
          // Dropped: the close code below says what happened, if anything.
        }
        unanswered.cancel();
        if (identical(_socket, open)) {
          _socket = null;
          _signedIn = false;
        }
        if (!live()) return;
        if (_reopen) {
          // Closed here to open afresh: no wait, and no refusal to count.
          _reopen = false;
          continue;
        }
        if (readyAt != null && DateTime.now().difference(readyAt) > const Duration(minutes: 1)) {
          attempt = 0;
        }
        switch (open.closeCode) {
          case closeRenew:
            retry = StreamRetry.renew;
            fresh = true;
          case closeNotSignedIn when !refusedOnce:
            retry = StreamRetry.freshToken;
            fresh = true;
            refusedOnce = true;
          case closeNotSignedIn:
            retry = StreamRetry.refused;
          case closeSignedOut:
            _running = false;
            _emit(const StreamSignedOut());
            return;
          case closeBusy:
            retry = StreamRetry.busy;
          default:
            retry = StreamRetry.dropped;
        }
      }
      await _wait(retry, _retryDelay(retry, attempt++));
    }
  }

  Future<void> _wait(StreamRetry why, Duration delay) async {
    if (delay <= Duration.zero) return;
    final wake = _wake = Completer<void>();
    _waitingFor = why;
    final timer = Timer(delay, _wakeUp);
    await wake.future;
    timer.cancel();
    if (identical(_wake, wake)) {
      _wake = null;
      _waitingFor = null;
    }
  }

  void _wakeUp() {
    final wake = _wake;
    _wake = null;
    _waitingFor = null;
    if (wake != null && !wake.isCompleted) wake.complete();
  }

  void _emit(OrchardStreamEvent event) {
    if (!_events.isClosed) _events.add(event);
  }

  static Future<void> _close(WebSocket socket) async {
    try {
      await socket.close(WebSocketStatus.normalClosure);
    } catch (_) {/* already gone */}
  }

  /// A message from the server, or null for anything this version does not
  /// know (skipped, so the server can add kinds of message).
  static Object? _parse(Object? message) {
    if (message is! String || message.length > 4096) return null;
    final Object? json;
    try {
      json = jsonDecode(message);
    } on FormatException {
      return null;
    }
    if (json is! Map<String, dynamic>) return null;
    switch (json['type']) {
      case 'ready':
        return const _Ready();
      case 'crate':
        final crateId = json['crate_id'];
        final revision = json['revision'];
        if (crateId is! String || revision is! int) return null;
        return CrateChanged(crateId, revision);
      case 'orchards':
        return const OrchardsChanged();
      case 'device-approval':
        final id = json['id'];
        if (id is! String || id.isEmpty || id.length > 64) return null;
        return DeviceApprovalMoved(id);
      case 'share':
        return const ShareInvitesChanged();
      case 'access':
        return const AccessRequestsChanged();
      case 'device':
        return const DeviceRequestsChanged();
      case 'security':
        return const SecurityChanged();
    }
    return null;
  }
}

/// The server's answer to a good sign-in.
class _Ready {
  const _Ready();
}
