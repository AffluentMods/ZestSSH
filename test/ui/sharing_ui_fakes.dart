// What the sharing screens are shown in tests: a share, a view, the tmux
// side of a tab and the app's sharing services, each as the test sets it,
// keeping what the screen asked of it. (The real ones are tested end to end
// in test/features/sharing.)

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_channel.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_messages.dart';
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/teams/crypto/account_keys.dart';
import 'package:zestssh/features/tmux/tmux_controller.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/ssh_service.dart';

/// A shared session as the person sharing sees it.
class FakeShare extends ChangeNotifier implements ShareHostController {
  FakeShare({
    this.mode = ShareMode.live,
    this.tmuxSession = '',
    this.keyboardRequests = true,
    this.shareId = '11111111-1111-4111-8111-111111111111',
    List<ShareGuest> guests = const [],
  }) : _guests = List.of(guests);

  @override
  final ShareMode mode;
  @override
  final String tmuxSession;
  @override
  final bool keyboardRequests;
  @override
  final String shareId;

  List<ShareGuest> _guests;
  String? _holder;
  bool lineOpen = true;
  bool ended = false;

  /// What the screen asked for, in order.
  final calls = <String>[];

  /// Thrown by the next [invite].
  Object? failInvite;

  @override
  List<ShareGuest> get guests => List.unmodifiable(_guests);

  @override
  String? get keyboardHolder => _holder;

  @override
  Set<String> get endersWatching => {
        for (final g in _guests)
          if (g.canEnd && (g.state == ShareGuestState.watching || g.state == ShareGuestState.typing)) g.uid,
      };

  @override
  bool get isLineOpen => lineOpen;

  @override
  bool get isEnded => ended;

  /// The test changes who is there, and the screen follows.
  void show(List<ShareGuest> guests, {String? holder, bool? lineOpen}) {
    _guests = List.of(guests);
    _holder = holder;
    if (lineOpen != null) this.lineOpen = lineOpen;
    notifyListeners();
  }

  ShareGuest _with(ShareGuest g, {ShareGuestState? state, bool? asks}) => ShareGuest(
        uid: g.uid,
        state: state ?? g.state,
        canType: g.canType,
        asksKeyboard: asks ?? g.asksKeyboard,
        canEnd: g.canEnd,
      );

  @override
  bool giveKeyboard(String uid) {
    calls.add('give:$uid');
    _holder = uid;
    _guests = [
      for (final g in _guests)
        g.uid == uid
            ? _with(g, state: ShareGuestState.typing, asks: false)
            : g.state == ShareGuestState.typing
                ? _with(g, state: ShareGuestState.watching)
                : g,
    ];
    notifyListeners();
    return true;
  }

  @override
  void takeBack() {
    calls.add('takeBack');
    _holder = null;
    _guests = [
      for (final g in _guests) g.state == ShareGuestState.typing ? _with(g, state: ShareGuestState.watching) : g,
    ];
    notifyListeners();
  }

  @override
  void denyKeyboard(String uid) {
    calls.add('deny:$uid');
    _guests = [for (final g in _guests) g.uid == uid ? _with(g, asks: false) : g];
    notifyListeners();
  }

  @override
  Future<void> remove(String uid) async {
    calls.add('remove:$uid');
    if (_holder == uid) _holder = null;
    _guests = [
      for (final g in _guests)
        if (g.uid != uid) g,
    ];
    notifyListeners();
  }

  @override
  Future<void> invite(
    List<ShareParty> people, {
    Set<String> watchOnly = const {},
    Set<String> enders = const {},
  }) async {
    calls.add('invite:${people.map((p) => p.uid).join(',')}|${watchOnly.join(',')}'
        '${enders.isEmpty ? '' : '|ends:${enders.join(',')}'}');
    final failure = failInvite;
    failInvite = null;
    if (failure != null) throw failure;
    _guests = [
      for (final g in _guests)
        if (!people.any((p) => p.uid == g.uid)) g,
      for (final p in people)
        ShareGuest(
          uid: p.uid,
          state: ShareGuestState.invited,
          canType: !watchOnly.contains(p.uid) && !enders.contains(p.uid),
          asksKeyboard: false,
          canEnd: enders.contains(p.uid),
        ),
    ];
    notifyListeners();
  }

  @override
  Future<void> stop([ShareEndReason reason = ShareEndReason.stopped]) async {
    calls.add('stop:${reason.name}');
    ended = true;
    notifyListeners();
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

ShareGuest guest(String uid, ShareGuestState state, {bool canType = true, bool asks = false, bool canEnd = false}) =>
    ShareGuest(uid: uid, state: state, canType: canType && !canEnd, asksKeyboard: asks, canEnd: canEnd);

/// A live view as the person watching sees it.
class FakeView extends ChangeNotifier implements ShareViewerController {
  FakeView({this.canAsk = true, this.canEnd = false}) : terminal = Terminal(maxLines: 500);

  @override
  final Terminal terminal;

  /// The part this viewer has, as the invitation would say it.
  bool canAsk;
  bool canEnd;

  ShareViewPhase _phase = ShareViewPhase.connecting;
  ShareViewEnd? _end;
  ShareKeyboard _keyboard = ShareKeyboard.host;
  bool _asking = false;
  final calls = <String>[];

  @override
  ShareViewPhase get phase => _phase;

  @override
  ShareViewEnd? get end => _end;

  @override
  ShareKeyboard get keyboard => _keyboard;

  @override
  bool get isTyping => _keyboard == ShareKeyboard.you && _phase == ShareViewPhase.watching;

  @override
  bool get mayAsk => canAsk;

  @override
  bool get isAsking => _asking;

  @override
  bool get mayEnd => canEnd;

  @override
  void endSession() => calls.add('end');

  void show(ShareViewPhase phase, {ShareViewEnd? end, ShareKeyboard keyboard = ShareKeyboard.host, bool asking = false}) {
    _phase = phase;
    _end = end;
    _keyboard = keyboard;
    _asking = asking;
    notifyListeners();
  }

  @override
  void askKeyboard() {
    calls.add('ask');
    _asking = true;
    notifyListeners();
  }

  @override
  void giveBack() {
    calls.add('giveBack');
    _keyboard = ShareKeyboard.host;
    notifyListeners();
  }

  @override
  Future<void> leave() async {
    calls.add('leave');
    _phase = ShareViewPhase.ended;
    _end = ShareViewEnd.left;
    notifyListeners();
  }

  @override
  // ignore: must_call_super
  void dispose() => calls.add('dispose');

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _FakeTmuxController implements TmuxController {
  _FakeTmuxController(this._host);

  final FakeTmux _host;

  @override
  String? get currentSessionName => _host.sessionName;

  @override
  Future<bool> detachOtherClients() async {
    _host.detachedOthers++;
    return true;
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The tmux side of a session's tab.
class FakeTmux extends ChangeNotifier implements TmuxSessionHost {
  @override
  String get sessionId => 's1';

  /// Attached to a session named [sessionName].
  bool attached = false;
  String? sessionName;

  /// tmux cannot be started on this host.
  bool cannotStart = false;
  TmuxHostStage _stage = TmuxHostStage.idle;
  final created = <String>[];
  int detachedOthers = 0;

  @override
  bool get live => attached;

  @override
  bool get active => _stage != TmuxHostStage.idle;

  @override
  TmuxHostStage get stage => _stage;

  @override
  TmuxController? get controller => attached ? _FakeTmuxController(this) : null;

  /// The tab asked for tmux and there is no connection to start it on.
  void noConnection() {
    _stage = TmuxHostStage.noLiveSession;
    notifyListeners();
  }

  /// The tab is in tmux, attached to the session [name].
  void attachedTo(String name) {
    attached = true;
    sessionName = name;
    _stage = TmuxHostStage.attached;
    notifyListeners();
  }

  /// The provider that holds it disposes it; the test keeps using it.
  @override
  // ignore: must_call_super
  void dispose() {}

  @override
  Future<void> createSession(String name) async {
    created.add(name);
    if (cannotStart) {
      _stage = TmuxHostStage.notInstalled;
      notifyListeners();
    } else {
      attachedTo(name);
    }
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's "share this session", answering as the test says.
class FakeSharing extends SessionSharing {
  FakeSharing(super.ref);

  (ShareContext?, ShareUnavailable?) availability = (null, ShareUnavailable.notReady);
  final started = <({
    String sessionId,
    ShareMode mode,
    Set<String> people,
    bool keyboardRequests,
    String tmuxSession,
    Set<String> enders
  })>[];

  /// Thrown by the next [start].
  Object? failStart;

  @override
  Future<(ShareContext?, ShareUnavailable?)> availabilityFor(String sessionId) async => availability;

  @override
  Future<ShareHostController> start(
    String sessionId,
    ShareContext context, {
    required ShareMode mode,
    required Set<String> people,
    bool keyboardRequests = false,
    Set<String> enders = const {},
    String tmuxSession = '',
  }) async {
    started.add((
      sessionId: sessionId,
      mode: mode,
      people: Set.of(people),
      keyboardRequests: keyboardRequests,
      tmuxSession: tmuxSession,
      enders: Set.of(enders),
    ));
    final failure = failStart;
    failStart = null;
    if (failure != null) throw failure;
    final share = FakeShare(
      mode: mode,
      tmuxSession: tmuxSession,
      keyboardRequests: mode == ShareMode.live && keyboardRequests,
      guests: [for (final uid in people) guest(uid, ShareGuestState.invited, canEnd: enders.contains(uid))],
    );
    SessionShares.add(sessionId, share, names: {for (final p in context.people) p.uid: p.email ?? p.uid});
    return share;
  }
}

/// The invitations waiting, as the test sets them.
class FakeInvitations extends ShareInvitations {
  FakeInvitations(super.ref);

  int refreshes = 0;
  final declined = <String>[];

  void show(List<IncomingShare> shares) => state = shares;

  @override
  Future<void> refresh() async => refreshes++;

  @override
  Future<void> decline(IncomingShare share) async {
    declined.add(share.shareId);
    state = [
      for (final s in state)
        if (s.shareId != share.shareId) s,
    ];
  }
}

/// Joining a live view: hands out the view the test prepared.
class FakeJoining extends ShareJoining {
  FakeJoining(super.ref);

  final asked = <String>[];

  /// The view each share is watched with; a share without one cannot be
  /// joined.
  final views = <String, FakeView>{};

  @override
  Future<ShareViewerController?> watch(IncomingShare share) async {
    asked.add(share.shareId);
    final view = views[share.shareId];
    if (view == null) return null;
    ShareViews.add(share, view);
    return view;
  }
}

/// Joining a shared tmux session: answers as the test says.
class FakeTmuxJoins implements ShareTmuxJoins {
  final asked = <String>[];
  (String?, ShareTmuxJoinProblem?) answer = (null, ShareTmuxJoinProblem.hostMissing);
  int left = 0;

  @override
  void Function(String shareId, ShareLineEnd why)? onEnded;

  @override
  Future<(String?, ShareTmuxJoinProblem?)> join(IncomingShare share) async {
    asked.add(share.shareId);
    return answer;
  }

  @override
  Future<void> leaveAll() async => left++;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The app's sessions, as the test sets them.
class FakeSessions extends ActiveSessionsNotifier {
  FakeSessions(super.ref);

  void show(Map<String, SessionState> sessions) => state = sessions;

  /// Whether a held session may go on with nobody watching, as the test
  /// says; each time that was asked; each session let go on; and what
  /// letting the next one go on throws.
  bool mayGoOn = false;
  final askedMayGoOn = <String>[];
  final wentOn = <String>[];
  Object? failGoOn;

  /// What letting a session go on waits for, when the test sets it (the
  /// question that asks why is open).
  Completer<void>? goOnWaits;

  @override
  Future<bool> mayGoOnUnwatched(String sessionId) async {
    askedMayGoOn.add(sessionId);
    return mayGoOn;
  }

  @override
  Future<void> goOnUnwatched(String sessionId) async {
    wentOn.add(sessionId);
    await goOnWaits?.future;
    final failure = failGoOn;
    failGoOn = null;
    if (failure != null) throw failure;
  }
}

class _Shell extends ShellService {
  @override
  Future<void> connect() async {}
  @override
  Future<void> disconnect() async {}
  @override
  Stream<Uint8List> get stdout => const Stream.empty();
  @override
  Stream<Uint8List> get stderr => const Stream.empty();
  @override
  void write(Uint8List data) {}
  @override
  void resize(int width, int height) {}
  @override
  bool get isConnected => true;
  @override
  Stream<bool> get connectionState => const Stream.empty();
  @override
  bool get exitedCleanly => false;
  @override
  bool get isEncryptedSsh => true;
}

/// A connected session of a host called [label].
SessionState connectedSession(String id, String label, {String host = '10.50.0.21'}) => SessionState(
      status: SessionStatus.connected,
      connectionId: 'c-$id',
      connectionLabel: label,
      host: host,
      port: 22,
      username: 'deploy',
      session: TerminalSession(
        id: id,
        connectionId: 'c-$id',
        terminal: Terminal(),
        shell: _Shell(),
        startedAt: DateTime(2026, 10, 1, 9),
      ),
    );

/// Someone who could be invited. Their keys are made up: the screens only
/// show whether this device has any and whether they changed.
ShareCandidate candidate(
  String uid,
  String? email, {
  CrateLevel level = CrateLevel.use,
  bool keysChanged = false,
  bool noKeys = false,
}) =>
    ShareCandidate(
      uid: uid,
      email: email,
      level: level,
      canManage: level == CrateLevel.manage,
      party: noKeys
          ? null
          : ShareParty(
              uid: uid,
              keyVersion: 1,
              signingKey: Uint8List(32),
              encryptionKey: Uint8List(32),
              keysChanged: keysChanged,
            ),
    );

ShareContext shareContext(
  List<ShareCandidate> people, {
  List<String> withoutAccess = const [],
  bool sessionLogs = false,
  bool synced = true,
  bool watched = false,
  String crateName = 'Production',
}) =>
    ShareContext(
      orchardId: '22222222-2222-4222-8222-222222222222',
      crateId: '33333333-3333-4333-8333-333333333333',
      crateName: crateName,
      connectionId: 'c-s1',
      myUid: 'uid-dana',
      people: people,
      withoutAccess: withoutAccess,
      sessionLogs: sessionLogs,
      synced: synced,
      watched: watched,
    );

/// An invitation from [fromEmail], signed and sealed for real (the screens
/// read what was signed).
Future<IncomingShare> incomingShare({
  required String shareId,
  required ShareMode mode,
  required AccountKeys from,
  required AccountKeys to,
  String? fromEmail = 'dana@example.com',
  String crateName = 'Production',
  String? hostLabel = 'Web 1',
  bool keysChanged = false,
  bool keyboard = true,
  bool mayEnd = false,
  bool watched = false,
}) async {
  final offer = mode == ShareMode.live ? (await ShareHostKeys.generate()).offer : null;
  final signed = await SignedShareInvitation.sign(
    ShareInvitation(
      shareId: shareId,
      orchardId: '22222222-2222-4222-8222-222222222222',
      crateId: '33333333-3333-4333-8333-333333333333',
      fromUid: 'uid-dana',
      fromKeyVersion: from.version,
      toUid: 'uid-sam',
      mode: mode,
      connectionId: 'c-s1',
      tmuxSession: mode == ShareMode.tmux ? 'shared-k7q' : '',
      remoteUser: 'deploy',
      keyboard: mode == ShareMode.live && keyboard && !mayEnd,
      mayEnd: mode == ShareMode.live && mayEnd,
      offer: offer,
      expiresAt: DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600,
    ),
    from,
  );
  return IncomingShare(
    listing: ShareInviteListing(
      shareId: shareId,
      orchardId: '22222222-2222-4222-8222-222222222222',
      crateId: '33333333-3333-4333-8333-333333333333',
      mode: mode,
      fromUid: 'uid-dana',
      sealed: await signed.sealTo(to.encryption.publicKey),
      expiresIn: const Duration(hours: 1),
    ),
    invitation: signed,
    fromEmail: fromEmail,
    crateName: crateName,
    hostLabel: hostLabel,
    keysChanged: keysChanged,
    watched: watched,
  );
}

/// The overrides every sharing screen needs.
List<Override> sharingOverrides({
  required FakeTmux tmux,
  FakeSharing Function(Ref ref)? sharing,
}) =>
    [
      activeSessionsProvider.overrideWith(FakeSessions.new),
      tmuxHostProvider.overrideWith((ref, sessionId) => tmux),
      if (sharing != null) sessionSharingProvider.overrideWith(sharing),
    ];
