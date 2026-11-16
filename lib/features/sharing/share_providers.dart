import 'dart:async';
import 'dart:io';

import 'package:drift/drift.dart' show Variable;
import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/local_record.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sessionlogs/team_session_logs.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart' show CrateAuthor;
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_api.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/features/sharing/share_invitation.dart';
import 'package:zestssh/features/sharing/share_line.dart';
import 'package:zestssh/features/sharing/share_viewer.dart';
import 'package:zestssh/features/tmux/tmux_session_host.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/cloud/cloud_failure.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart' show isNoAnswer;
import 'package:zestssh/services/pinned_http_client.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

/// ZestSSH Cloud's routes for sharing a session.
final shareApiProvider = Provider<ShareApi>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return ShareApi(
    bearer: () async =>
        await AuthService.getIdToken(forceRefresh: false) ?? await AccountSecret.sessionToken.read(storage),
  );
});

/// Opens a line to the relay for one share, as its host or as someone
/// invited, over the same pinned TLS as every other request.
typedef ShareLinkFactory = ShareLink Function(String shareId, {required bool host});

final shareLinkFactoryProvider = Provider<ShareLinkFactory>((ref) {
  final storage = ref.watch(secureStorageProvider);
  return (shareId, {required host}) => ShareLine(
        url: ShareLine.urlFor(OrchardsApi.defaultBase),
        connect: (url) => WebSocket.connect(url.toString(), customClient: PinnedHttpClient.newHttpClient()),
        token: ({bool fresh = false}) async =>
            await AuthService.getIdToken(forceRefresh: fresh) ??
            await AccountSecret.sessionToken.readOnceOpen(storage),
        session: () => DeviceSessionHeader.current,
        shareId: shareId,
        host: host,
      );
});

/// Why a session cannot be shared at all.
enum ShareUnavailable {
  /// Its host is in the Tree: there is nobody ZestSSH knows to share it
  /// with.
  notInCrate,

  /// This device does not hold the account's keys yet, or the session or
  /// its Orchard is gone.
  notReady,
}

/// Why a share could not start.
enum ShareStartProblem {
  /// The session is gone, or this device does not hold the account's keys.
  notReady,

  /// Three sessions are shared already.
  tooMany,

  /// Someone picked cannot open the Crate any more.
  noAccess,

  /// ZestSSH Cloud could not be reached, or refused.
  failed,
}

class ShareStartFailed implements Exception, HasTypeName {
  const ShareStartFailed(this.problem, {this.cause});

  final ShareStartProblem problem;

  /// What was caught, where ZestSSH Cloud refused or could not be reached:
  /// for saying how it stands, where that was the reason
  /// ([shareStartFailureText]).
  final Object? cause;

  @override
  String toString() => 'ShareStartFailed: ${problem.name}';

  @override
  String get typeName => 'ShareStartFailed';
}

/// Why a session could not be shared, or more people not be asked into a
/// share, for whoever asked ([error]: a [ShareStartFailed], or whatever else
/// was caught). [notReady] is the screen's own sentence for a session or a
/// device that is not ready. Where ZestSSH Cloud or the way to it was what
/// stopped it, how the service stands is said, with its code, after the one
/// thing that matters here: that nothing was shared.
///
/// [answersNow]: the service was asked since and answered. What got no
/// answer was then this one request, and saying that the service does not
/// respond would be wrong: the sentence there always was is said.
String shareStartFailureText(AppLocalizations l10n, Object error,
    {required String notReady, bool answersNow = false}) {
  var cause = error;
  if (error is ShareStartFailed) {
    switch (error.problem) {
      case ShareStartProblem.tooMany:
        return l10n.shareFailedTooMany;
      case ShareStartProblem.noAccess:
        return l10n.shareFailedNoAccess;
      case ShareStartProblem.notReady:
        return notReady;
      case ShareStartProblem.failed:
        final caught = error.cause;
        if (caught == null) return l10n.shareFailedOffline;
        cause = caught;
    }
  }
  // Asking more people into a share that runs is answered as starting one.
  if (cause is ShareNoAccess) return l10n.shareFailedNoAccess;
  if (answersNow && isNoAnswer(cause)) return l10n.shareFailedOffline;
  return cloudStopped(l10n, cause, lead: l10n.shareNothingShared) ?? l10n.shareFailedOffline;
}

/// Sharing the sessions of this device: what it involves for one session,
/// and starting it.
class SessionSharing {
  SessionSharing(this._ref);

  final Ref _ref;

  int get _now => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// What sharing the session [sessionId] involves, or why it cannot be
  /// shared: its host is not in a Crate, or this device is not ready (no
  /// account keys here, the session gone, its Orchard closed).
  Future<(ShareContext?, ShareUnavailable?)> availabilityFor(String sessionId) async {
    final connectionId = _ref.read(activeSessionsProvider)[sessionId]?.connectionId;
    if (connectionId == null) return (null, ShareUnavailable.notReady);
    final db = _ref.read(activeSessionsProvider.notifier).sessionDatabaseOf(connectionId);
    if (db == null) return (null, ShareUnavailable.notReady);
    if (!db.isOrchard) return (null, ShareUnavailable.notInCrate);
    final me = await _ref.read(orchardAuthorProvider).call();
    if (me == null) return (null, ShareUnavailable.notReady);
    final context = await shareContextFor(db, connectionId, myUid: me.uid, nowSeconds: _now);
    return context == null ? (null, ShareUnavailable.notInCrate) : (context, null);
  }

  /// Shares the session [sessionId] with [people] (accounts out of
  /// [context]'s); [enders] are those of them who may end the session (a
  /// live view only). Throws [ShareStartFailed].
  Future<ShareHostController> start(
    String sessionId,
    ShareContext context, {
    required ShareMode mode,
    required Set<String> people,
    bool keyboardRequests = false,
    Set<String> enders = const {},
    String tmuxSession = '',
  }) async {
    final sessions = _ref.read(activeSessionsProvider.notifier);
    final session = _ref.read(activeSessionsProvider)[sessionId];
    final db = sessions.sessionDatabaseOf(context.connectionId);
    final me = await _ref.read(orchardAuthorProvider).call();
    final terminal = mode == ShareMode.live ? sessions.shareTerminalOf(sessionId) : null;
    if (session == null || db == null || me == null || (mode == ShareMode.live && terminal == null)) {
      throw const ShareStartFailed(ShareStartProblem.notReady);
    }
    final chosen = [
      for (final p in context.people)
        if (people.contains(p.uid) && !p.keysChanged) p,
    ];
    if (chosen.isEmpty) throw const ShareStartFailed(ShareStartProblem.notReady);
    final emails = {for (final p in context.people) p.uid: p.email ?? p.uid};
    final shareId = const Uuid().v4();
    try {
      final controller = await ShareHostController.start(
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
        enders: enders,
        myUid: me.uid,
        keys: me.keys,
        api: _ref.read(shareApiProvider),
        link: _ref.read(shareLinkFactoryProvider)(shareId, host: true),
        record: () => _recordOf(db, context.orchardId),
        party: (uid) => _partyOf(db, uid, me.uid),
        terminal: terminal,
        tmuxSession: tmuxSession,
        remoteUser: session.username ?? '',
        keyboardRequests: keyboardRequests,
        onNote: (note, uid) => _noted(sessionId, note, uid == null ? null : emails[uid] ?? uid),
      );
      SessionShares.add(sessionId, controller, names: emails);
      TeamSessionLogs.append(
          sessionId,
          _marker(mode == ShareMode.live
              ? gl10n.shareLogStartedLive(chosen.map((p) => p.email ?? p.uid).join(', '))
              : gl10n.shareLogStartedTmux(chosen.map((p) => p.email ?? p.uid).join(', '))));
      return controller;
    } on ShareNoAccess {
      throw const ShareStartFailed(ShareStartProblem.noAccess);
    } on OrchardServerException catch (e) {
      throw ShareStartFailed(e.code == 'too-many-shares' ? ShareStartProblem.tooMany : ShareStartProblem.failed,
          cause: e);
    } on ShareStartFailed {
      rethrow;
    } catch (e) {
      AppLogger.info('Session sharing: could not start ($e)');
      throw ShareStartFailed(ShareStartProblem.failed, cause: e);
    }
  }

  static Future<OrchardRecord?> _recordOf(AppDatabase db, String orchardId) async {
    try {
      return (await LocalRecord.load(db, orchardId)).latest;
    } catch (_) {
      // The Orchard closed (the app locked): nobody new is let in.
      return null;
    }
  }

  static Future<ShareParty?> _partyOf(AppDatabase db, String uid, String myUid) async {
    try {
      return await sharePartyOf(db, uid, myUid: myUid);
    } catch (_) {
      return null;
    }
  }

  static String _marker(String text) => '\r\n[ZestSSH] $text\r\n';

  /// What happens in a share goes into the team's log of the session (when
  /// the Crate logs sessions): who had the keyboard when is what tells whose
  /// input it was.
  void _noted(String sessionId, ShareNote note, String? who) {
    final l10n = gl10n;
    final text = switch (note) {
      ShareNote.joined => who == null ? null : l10n.shareLogJoined(who),
      ShareNote.left => who == null ? null : l10n.shareLogLeft(who),
      ShareNote.keyboardGiven => who == null ? null : l10n.shareLogKeyboardGiven(who),
      ShareNote.keyboardBack => l10n.shareLogKeyboardBack,
      ShareNote.stopped || ShareNote.endedElsewhere => l10n.shareLogStopped,
      ShareNote.endAsked => who == null ? null : l10n.shareLogEndedBy(who),
      ShareNote.declined || ShareNote.askedKeyboard => null,
    };
    if (text != null) TeamSessionLogs.append(sessionId, _marker(text));
    shareNoticeHandler?.call(sessionId, note, who);
    // Someone invited to end the session said so: it is closed here,
    // on the device it runs on, after the log has who ended it. Those
    // watching are told as for any session that closed.
    if (note == ShareNote.endAsked) {
      unawaited(_ref.read(activeSessionsProvider.notifier).endSession(sessionId, byThePerson: false));
    }
  }
}

final sessionSharingProvider = Provider<SessionSharing>((ref) => SessionSharing(ref));

/// Told what happens in the shares of this device, for the notices shown
/// (set by the app's shell, which knows how to show one).
void Function(String sessionId, ShareNote note, String? who)? shareNoticeHandler;

/// An invitation to a shared session, opened and checked.
@immutable
class IncomingShare {
  const IncomingShare({
    required this.listing,
    required this.invitation,
    required this.fromEmail,
    required this.crateName,
    required this.hostLabel,
    required this.keysChanged,
    this.watched = false,
  });

  final ShareInviteListing listing;
  final SignedShareInvitation invitation;

  /// Who shares, when this device knows their address.
  final String? fromEmail;
  final String crateName;

  /// The host's name in this device's copy of the Crate, when it has it.
  final String? hostLabel;

  /// The sender's keys changed since this device's person compared them (or
  /// it has none for them): it cannot be joined until they are compared.
  final bool keysChanged;

  /// The session's Crate is a watched one, by this device's record.
  final bool watched;

  /// The sender asks this account to watch a session of a watched Crate:
  /// invited to end it, in a Crate whose sessions run only while someone
  /// who manages it watches.
  bool get asksToWatch => mode == ShareMode.live && invitation.invitation.mayEnd && watched;

  String get shareId => listing.shareId;
  ShareMode get mode => listing.mode;
}

/// The invitations to shared sessions waiting for this account, each
/// opened with the account's key and checked against the Orchard's record
/// and the sender's pinned keys. One that does not check out is not shown
/// at all: nothing a server made up reaches the screen.
class ShareInvitations extends StateNotifier<List<IncomingShare>> {
  ShareInvitations(this._ref) : super(const []);

  final Ref _ref;
  Future<void>? _running;
  bool _again = false;
  final _told = <String>{};

  /// Called for each invitation seen for the first time.
  void Function(IncomingShare share)? onNew;

  /// Asks ZestSSH Cloud again. Calls made while one runs are one more run.
  Future<void> refresh() {
    final running = _running;
    if (running != null) {
      _again = true;
      return running;
    }
    return _running = _refresh().whenComplete(() {
      _running = null;
      if (_again) {
        _again = false;
        unawaited(refresh());
      }
    });
  }

  Future<void> _refresh() async {
    if (!kOrchardsEnabled) return;
    final CrateAuthor? me;
    final List<ShareInviteListing> listings;
    try {
      me = await _ref.read(orchardAuthorProvider).call();
      if (me == null) {
        if (mounted) state = const [];
        return;
      }
      listings = await _ref.read(shareApiProvider).invitations();
    } catch (_) {
      // Not reached: what is shown stays; a share that ended meanwhile is
      // found out when it is joined.
      return;
    }
    final open = _ref.read(orchardDatabasesProvider);
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final out = <IncomingShare>[];
    for (final l in listings) {
      final db = open[l.orchardId];
      if (db == null) continue; // the Orchard is closed on this device now
      try {
        final signed = await SignedShareInvitation.open(l.sealed, me.keys.encryption, shareId: l.shareId);
        final record = (await LocalRecord.load(db, l.orchardId)).latest;
        final problem = await shareInvitationProblem(
          signed,
          shareId: l.shareId,
          orchardId: l.orchardId,
          crateId: l.crateId,
          fromUid: l.fromUid,
          mode: l.mode,
          me: me.uid,
          record: record,
          host: await sharePartyOf(db, l.fromUid, myUid: me.uid),
          nowSeconds: now,
        );
        if (problem != null && problem != ShareProblem.keysChanged) {
          AppLogger.info('Session sharing: an invitation was not shown (${problem.name})');
          continue;
        }
        String? email;
        for (final v in await MemberDirectory(db).view(me.uid)) {
          if (v.uid == l.fromUid) email = v.email;
        }
        final crate = await db
            .customSelect('SELECT name FROM orchard_crates WHERE crate_id = ?', variables: [Variable(l.crateId)])
            .getSingleOrNull();
        final host = await db.connectionsDao.getById(signed.invitation.connectionId);
        out.add(IncomingShare(
          listing: l,
          invitation: signed,
          fromEmail: email,
          crateName: crate?.read<String?>('name') ?? '',
          hostLabel: host?.label,
          keysChanged: problem == ShareProblem.keysChanged,
          watched: record.crates[l.crateId]?.watched ?? false,
        ));
      } on FormatException {
        AppLogger.info('Session sharing: an invitation was not shown (it does not open)');
      } catch (e) {
        AppLogger.info('Session sharing: an invitation was not shown ($e)');
      }
    }
    if (!mounted) return;
    state = out;
    final ids = {for (final s in out) s.shareId};
    _told.removeWhere((id) => !ids.contains(id));
    for (final s in out) {
      if (_told.add(s.shareId)) onNew?.call(s);
    }
  }

  /// Declines [share]: the person sharing is told, and it is gone here.
  Future<void> decline(IncomingShare share) async {
    state = [
      for (final s in state)
        if (s.shareId != share.shareId) s,
    ];
    try {
      await _ref.read(shareApiProvider).removeInvite(share.shareId, share.invitation.invitation.toUid);
    } catch (_) {
      // It lapses with the share.
    }
  }

  /// Nothing waits any more (signing out).
  void clear() {
    _told.clear();
    state = const [];
  }
}

final shareInvitationsProvider =
    StateNotifierProvider<ShareInvitations, List<IncomingShare>>((ref) => ShareInvitations(ref));

/// The live views this device watches, by share: kept while they run, so a
/// view goes on while its screen is not the one in front.
abstract final class ShareViews {
  static final _views = <String, ShareViewerController>{};
  static final _shares = <String, IncomingShare>{};

  /// The views open now, for whoever shows them.
  static final active = ValueNotifier<Map<String, ShareViewerController>>(const {});

  static ShareViewerController? of(String shareId) => _views[shareId];

  /// The invitation the view of [shareId] answers.
  static IncomingShare? shareOf(String shareId) => _shares[shareId];

  static void add(IncomingShare share, ShareViewerController controller) {
    final before = _views[share.shareId];
    if (before != null && !identical(before, controller)) before.dispose();
    _views[share.shareId] = controller;
    _shares[share.shareId] = share;
    active.value = Map.unmodifiable(_views);
  }

  /// Leaves the view of [shareId] and forgets it.
  static Future<void> close(String shareId) async {
    final controller = _views.remove(shareId);
    _shares.remove(shareId);
    active.value = Map.unmodifiable(_views);
    if (controller == null) return;
    await controller.leave();
    controller.dispose();
  }

  static Future<void> closeAll() async {
    for (final id in _views.keys.toList()) {
      await close(id);
    }
  }

  @visibleForTesting
  static void reset() {
    _views.clear();
    _shares.clear();
    active.value = const {};
  }
}

/// Joining what this account was invited to.
class ShareJoining {
  ShareJoining(this._ref);

  final Ref _ref;

  /// Starts watching [share] (a live view); the view already open for it is
  /// returned as it is. Null when this device does not hold the account's
  /// keys, or the invitation cannot be joined.
  Future<ShareViewerController?> watch(IncomingShare share) async {
    if (share.mode != ShareMode.live || share.keysChanged) return null;
    final open = ShareViews.of(share.shareId);
    if (open != null && open.phase != ShareViewPhase.ended) return open;
    final me = await _ref.read(orchardAuthorProvider).call();
    if (me == null) return null;
    final controller = ShareViewerController(
      invitation: share.invitation,
      keys: me.keys,
      link: _ref.read(shareLinkFactoryProvider)(share.shareId, host: false),
    );
    ShareViews.add(share, controller);
    controller.start();
    return controller;
  }
}

final shareJoiningProvider = Provider<ShareJoining>((ref) => ShareJoining(ref));

/// Why a shared tmux session could not be joined.
enum ShareTmuxJoinProblem {
  /// This device does not have the host (yet), or has it in another Crate.
  hostMissing,

  /// The Orchard is closed on this device right now.
  orchardClosed,

  /// No new session could be opened (the session limit of the plan).
  noSession,
}

/// Joining shared tmux sessions: this person connects to the host with
/// their own access and attaches to the session by name. Nothing of the
/// terminal goes through ZestSSH; a line to the relay says they are there,
/// and tells them when sharing stops.
class ShareTmuxJoins {
  ShareTmuxJoins(this._ref) {
    _ref.listen(activeSessionsProvider, (_, sessions) {
      // A joined session that ended: its line goes with it.
      for (final e in _sessions.entries.toList()) {
        if (!sessions.containsKey(e.value)) unawaited(_leave(e.key));
      }
      // One whose own connection is up now attaches to the shared tmux
      // session by name. (One that never connects attaches to nothing.)
      for (final sessionId in _attach.keys.toList()) {
        final status = sessions[sessionId]?.status;
        if (status == null) {
          _attach.remove(sessionId);
        } else if (status == SessionStatus.connected) {
          final name = _attach.remove(sessionId)!;
          Timer(attachDelay, () => _attachTo(sessionId, name));
        }
      }
    });
  }

  /// How long after its connection is up a joined session attaches: the
  /// tab's tmux side is ready by then.
  static const Duration attachDelay = Duration(milliseconds: 300);

  final Ref _ref;
  final _lines = <String, ShareLink>{};
  final _subscriptions = <String, StreamSubscription<ShareLineEvent>>{};
  final _sessions = <String, String>{};

  /// The tmux session each joined session attaches to once it is connected.
  final _attach = <String, String>{};
  bool _disposed = false;

  void _attachTo(String sessionId, String name) {
    if (_disposed || !_ref.read(activeSessionsProvider).containsKey(sessionId)) return;
    final tmux = _ref.read(tmuxHostProvider(sessionId));
    if (!tmux.active) unawaited(tmux.createSession(name));
  }

  /// Told when a share this device joined ended from the other side.
  void Function(String shareId, ShareLineEnd why)? onEnded;

  /// The session this device joined [shareId] with, if it has.
  String? sessionOf(String shareId) => _sessions[shareId];

  /// Connects to the host of [share] and attaches to its tmux session.
  /// Returns the new session's id, or why there is none.
  Future<(String?, ShareTmuxJoinProblem?)> join(IncomingShare share) async {
    final invitation = share.invitation.invitation;
    if (share.keysChanged || invitation.mode != ShareMode.tmux) {
      return (null, ShareTmuxJoinProblem.hostMissing);
    }
    final already = _sessions[share.shareId];
    if (already != null && _ref.read(activeSessionsProvider).containsKey(already)) return (already, null);
    final orchardId = share.listing.orchardId;
    try {
      await _ref.read(spaceControllerProvider).switchTo(OrchardSpace(orchardId));
    } catch (_) {
      return (null, ShareTmuxJoinProblem.orchardClosed);
    }
    final db = _ref.read(orchardDatabasesProvider)[orchardId];
    if (db == null) return (null, ShareTmuxJoinProblem.orchardClosed);
    final connection = await db.connectionsDao.getById(invitation.connectionId);
    // The host as THIS device has it, in the Crate the invitation names:
    // nothing about where to connect comes from the invitation.
    final crate = connection == null ? null : await CratePlacement(db).crateOf('host', connection.id);
    if (connection == null || crate != invitation.crateId) return (null, ShareTmuxJoinProblem.hostMissing);
    final sessionId = _ref.read(activeSessionsProvider.notifier).startSession(connection, allowDuplicate: true);
    if (sessionId == null) return (null, ShareTmuxJoinProblem.noSession);
    _attach[sessionId] = invitation.tmuxSession;
    await _leave(share.shareId);
    final line = _ref.read(shareLinkFactoryProvider)(share.shareId, host: false);
    _lines[share.shareId] = line;
    _sessions[share.shareId] = sessionId;
    _subscriptions[share.shareId] = line.events.listen((event) {
      if (event is ShareLineClosed) {
        final ended = onEnded;
        unawaited(_leave(share.shareId));
        ended?.call(share.shareId, event.why);
      }
    });
    line.start();
    return (sessionId, null);
  }

  Future<void> _leave(String shareId) async {
    _sessions.remove(shareId);
    await _subscriptions.remove(shareId)?.cancel();
    await _lines.remove(shareId)?.close();
  }

  Future<void> leaveAll() async {
    for (final id in _lines.keys.toList()) {
      await _leave(id);
    }
  }

  /// Every line closes and nothing more is attached (the provider goes).
  void dispose() {
    _disposed = true;
    _attach.clear();
    unawaited(leaveAll());
  }
}

final shareTmuxJoinsProvider = Provider<ShareTmuxJoins>((ref) {
  final joins = ShareTmuxJoins(ref);
  ref.onDispose(joins.dispose);
  return joins;
});
