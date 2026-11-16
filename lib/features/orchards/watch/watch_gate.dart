import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show OrchardAccessRefused;
import 'package:zestssh/features/orchards/orchard_providers.dart' show orchardAuthorProvider, orchardServiceProvider;
import 'package:zestssh/features/orchards/orchard_service.dart' show OrchardService, OrchardUnwatched;
import 'package:zestssh/features/orchards/watch/session_watch.dart';
import 'package:zestssh/features/orchards/watch/unwatched.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart' show ShareGuest, ShareGuestState;
import 'package:zestssh/features/sharing/share_invitation.dart' show ShareMode;
import 'package:zestssh/features/sharing/share_providers.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/type_name.dart';

// What stands between Connect and the connection for a host in a watched
// Crate (3.0): the person connecting is asked whom to ask, those
// people are invited to a live view of the session with the right to end
// it, and nothing is connected until the first of them is watching.
//
// A live view goes through ZestSSH Cloud. While the service cannot be
// reached nobody can be asked, and that must not be why a team cannot reach
// its machines (the outage work): then, and only then, an
// owner may connect after giving a reason, and so may anyone else where the
// owners allowed it for the Crate (unwatched.dart). What the device reports
// of the session is kept before anything is connected, and put into the
// Orchard's record once the device is back: where the session ran. One
// whose connection was not made after all is not reported.

/// What the app asks the person connecting.
@immutable
class WatchRequest {
  const WatchRequest({
    required this.sessionId,
    required this.host,
    required this.crateName,
    required this.hostLabel,
    required this.people,
    this.alreadyAsked = const {},
  });

  final String sessionId;
  final WatchedHost host;
  final String crateName;

  /// The host as the person named it.
  final String hostLabel;

  /// Everyone else who manages the Crate. Someone whose keys changed since
  /// they were compared is listed and cannot be asked.
  final List<ShareCandidate> people;

  /// Those asked already (when someone else is asked while waiting).
  final Set<String> alreadyAsked;
}

/// Asks the person connecting whom to ask to watch, and answers with their
/// account ids; null when they give up. Set by the app; with nobody to ask
/// (no screen), no session to a watched Crate's host starts.
Future<Set<String>?> Function(WatchRequest request)? watchAskHandler;

/// What the app asks someone who is about to go on with nobody watching.
@immutable
class UnwatchedRequest {
  const UnwatchedRequest({
    required this.sessionId,
    required this.host,
    required this.crateName,
    required this.hostLabel,
    this.held = false,
  });

  final String sessionId;
  final WatchedHost host;

  /// The Crate as this device calls it.
  final String crateName;

  /// The host as the person named it.
  final String hostLabel;

  /// The session is running and held (whoever watched is gone), and not
  /// about to connect.
  final bool held;
}

/// Asks the person why they go on with nobody watching, and answers with
/// their reason; null when they give up. Set by the app; with nobody to ask
/// (no screen), no session goes on unwatched.
Future<String?> Function(UnwatchedRequest request)? unwatchedAskHandler;

/// What happens to a watched session of this device, for the app to tell
/// the person (set by the app).
void Function(String sessionId, WatchNote note)? watchNoticeHandler;

/// The person connecting gave up before anyone watched.
class SessionWatchCancelled implements Exception, HasTypeName {
  const SessionWatchCancelled();

  @override
  String toString() => 'Not connected: nobody was asked to watch';

  @override
  String get typeName => 'SessionWatchCancelled';
}

class WatchGate {
  WatchGate(this._ref);

  final Ref _ref;

  /// How long a session waits for someone to join, how long it goes on
  /// with nobody watching, and how often the record is looked at again.
  /// (Tests shorten them.)
  @visibleForTesting
  static Duration joinWait = kWatchJoinWait;
  @visibleForTesting
  static Duration grace = kWatchGrace;
  @visibleForTesting
  static Duration recheck = const Duration(seconds: 15);

  /// Those of [people] who can be asked to watch: they manage the Crate,
  /// and this device has their keys, unchanged since they were compared.
  static List<ShareCandidate> askable(Iterable<ShareCandidate> people) => [
        for (final p in people)
          if (p.canManage && !p.keysChanged) p,
      ];

  /// For a session about to connect to the host [connectionId] of [db] (the
  /// database its sessions work in; null once that space has closed): null
  /// when its sessions are not watched. When they are, asks whom to ask,
  /// invites them, and comes back with the session's watch once the first
  /// of them is watching. Throws [SessionWatchCancelled] when the person
  /// gives up, and [OrchardAccessRefused], with the reason in words, when
  /// the session cannot start.
  Future<SessionWatch?> open(
    String sessionId, {
    required String connectionId,
    required String hostLabel,
    required AppDatabase? db,
    required void Function(String line) log,
  }) async {
    // Its Orchard closed on this device: whether its Crate is watched
    // cannot be read, so nothing is connected.
    if (db == null) throw OrchardAccessRefused(gl10n.watchedOrchardClosed);
    final host = await watchedHostIn(db, connectionId);
    if (host == null) return null;
    log('watch: Sessions in this Crate are watched');

    // ZestSSH Cloud cannot be reached: nobody can be asked to watch.
    // Whoever may go on then is asked why, and their session reported.
    if (_cloudAway()) {
      final watch = _watchOf(sessionId, host, db);
      SessionWatches.add(watch);
      try {
        await _goUnwatched(watch, db: db, hostLabel: hostLabel, log: log);
        return watch;
      } catch (_) {
        SessionWatches.end(sessionId);
        rethrow;
      }
    }

    final sharing = _ref.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    if (context == null) throw OrchardAccessRefused(gl10n.watchedNotReady);
    final managers = [
      for (final p in context.people)
        if (p.canManage) p,
    ];
    if (askable(managers).isEmpty) throw OrchardAccessRefused(gl10n.watchedNobodyToAsk(context.crateName));

    final watch = _watchOf(sessionId, host, db);
    SessionWatches.add(watch);
    try {
      final ask = watchAskHandler;
      final picked = ask == null
          ? null
          : await ask(WatchRequest(
              sessionId: sessionId,
              host: host,
              crateName: context.crateName,
              hostLabel: hostLabel,
              people: managers,
            ));
      // Only people who can be asked, whatever came back.
      final asked = {
        for (final p in askable(managers))
          if (picked?.contains(p.uid) ?? false) p.uid,
      };
      if (asked.isEmpty || watch.phase == SessionWatchPhase.over) throw const SessionWatchCancelled();
      try {
        await sharing.start(sessionId, context, mode: ShareMode.live, people: asked, enders: asked);
      } on ShareStartFailed catch (e) {
        // The live view did not start because ZestSSH Cloud did not answer
        // (what the app knew of it was from before): the same as above.
        if (e.problem == ShareStartProblem.failed && await _awayNow()) {
          await _goUnwatched(watch, db: db, hostLabel: hostLabel, log: log);
          return watch;
        }
        // (Where the live view failed for no reason of its own, the service
        // was asked just now and answered.)
        throw OrchardAccessRefused(
            shareStartFailureText(gl10n, e, notReady: gl10n.watchedNotReady, answersNow: true));
      }
      watch.askedPeople();
      log('watch: Asked ${asked.length} to watch. The connection is made once one of them has joined');
      switch (await watch.firstWatcher) {
        case null:
          log('watch: Someone who manages the Crate is watching');
          return watch;
        case WatchGivenUp.cancelled:
          throw const SessionWatchCancelled();
        case WatchGivenUp.nobodyJoined:
          throw OrchardAccessRefused(gl10n.watchedNobodyJoined);
      }
    } catch (_) {
      // It never started: the watch is over, and whoever was asked is told
      // the session closed.
      SessionWatches.end(sessionId);
      SessionShares.sessionClosed(sessionId);
      rethrow;
    }
  }

  SessionWatch _watchOf(String sessionId, WatchedHost host, AppDatabase db) => SessionWatch(
        sessionId: sessionId,
        host: host,
        record: () => latestRecordIn(db),
        joinWait: joinWait,
        grace: grace,
        recheck: recheck,
      );

  /// Whether ZestSSH Cloud cannot be reached, as the app knows it.
  bool _cloudAway() => _ref.read(cloudReachProvider).state.value.inTheWay;

  /// The same, asked now: for the moment when something that goes through
  /// the service has just failed and what the app knew may be from before.
  Future<bool> _awayNow() async {
    if (_cloudAway()) return true;
    try {
      return (await _ref.read(cloudReachProvider).checkNow()).inTheWay;
    } catch (_) {
      return false;
    }
  }

  /// Lets [watch]'s session go on with nobody watching, ZestSSH Cloud being
  /// away: where this account may ([mayGoUnwatched], by this device's copy
  /// of the record), after the person gave a reason, and once what is
  /// reported of it is kept on the device. Throws [OrchardAccessRefused],
  /// with the reason in words, where it may not, and
  /// [SessionWatchCancelled] when the person gives up.
  ///
  /// What was kept is let go once the session runs with nobody watching: a
  /// held one ([held]) at once, one that is still to connect when it has
  /// connected, and never where it does not. A held session is not closed
  /// while its person is asked.
  Future<void> _goUnwatched(
    SessionWatch watch, {
    required AppDatabase db,
    required String hostLabel,
    required void Function(String line) log,
    bool held = false,
  }) async {
    final l10n = gl10n;
    final host = watch.host;
    final me = await _ref.read(orchardAuthorProvider).call();
    final record = await latestRecordIn(db);
    if (me == null || record == null) throw OrchardAccessRefused(l10n.watchedNotReady);
    final crateName = host.crateName.isEmpty ? l10n.crateUnnamed : host.crateName;
    log('watch: ZestSSH Cloud cannot be reached, so nobody can be asked to watch');
    if (!mayGoUnwatched(record, host.crateId, me.uid)) {
      throw OrchardAccessRefused(
          ErrorCodes.withCode(l10n.watchedAwayNotAllowed(crateName), ErrorCodes.watchedNobodyToAsk));
    }
    final ask = unwatchedAskHandler;
    final asking = held && ask != null;
    if (asking) watch.holdOpen();
    try {
      final given = ask == null
          ? null
          : await ask(UnwatchedRequest(
              sessionId: watch.sessionId,
              host: host,
              crateName: crateName,
              hostLabel: hostLabel,
              held: held,
            ));
      final reason = given == null ? null : unwatchedReason(given);
      if (reason == null || watch.phase == SessionWatchPhase.over) throw const SessionWatchCancelled();
      // A held session someone is watching again needs none of this.
      if (held && watch.phase != SessionWatchPhase.held) return;
      // The service answers again meanwhile: someone can be asked after all.
      if (!_cloudAway()) throw OrchardAccessRefused(l10n.watchedAwayBack);
      final service = _ref.read(orchardServiceProvider);
      final String kept;
      try {
        kept = await service.keepUnwatchedReport(
          host.orchardId,
          crateId: host.crateId,
          hostLabel: hostLabel,
          reason: reason,
          reach: unwatchedReach(_ref.read(cloudReachProvider).state.value),
        );
      } catch (e) {
        AppLogger.warning('Watched sessions: nothing goes on with nobody watching, its report was not kept ($e)');
        throw OrchardAccessRefused(l10n.watchedAwayNotKept);
      }
      if (!watch.goUnwatched()) {
        // In the moment it took to keep it the session ended, someone
        // watches it again, or it was let go on already: nothing goes on
        // with nobody watching from this, and nothing is reported.
        await _takeBack(service, host.orchardId, kept);
        if (watch.phase == SessionWatchPhase.over) throw const SessionWatchCancelled();
        return;
      }
      log('watch: Goes on with nobody watching. The owners are told once this device is back online');
      _reportOnceItRuns(watch, service, kept);
    } finally {
      if (asking) watch.closeAfterGrace();
    }
  }

  /// What was kept under [kept] may go once its session runs with nobody
  /// watching: at once for one that is connected, and for one that is still
  /// to connect when it has. Where it never does (the connection is not
  /// made, its tab is closed on the way, or someone watches it before it
  /// connects) what was kept is taken back: what the owners read is a
  /// session that ran with nobody watching.
  void _reportOnceItRuns(SessionWatch watch, OrchardService service, String kept) {
    void look() {
      if (watch.ranUnwatched) {
        watch.removeListener(look);
        service.unwatchedRan(kept);
      } else if (watch.phase != SessionWatchPhase.unwatched) {
        watch.removeListener(look);
        unawaited(_takeBack(service, watch.host.orchardId, kept));
      }
    }

    watch.addListener(look);
    look();
  }

  Future<void> _takeBack(OrchardService service, String orchardId, String kept) async {
    try {
      await service.forgetUnwatchedReport(orchardId, kept);
    } catch (e) {
      AppLogger.warning('Watched sessions: what was kept of a session that never went on with nobody watching '
          'could not be taken back ($e)');
    }
  }

  /// Whether the held session [sessionId], whose sessions work in [db],
  /// could go on with nobody watching now: this account may go on by this
  /// device's copy of the record, and ZestSSH Cloud cannot be reached. The
  /// service is asked how it is where the app knows of nothing in the way:
  /// whoever watched may be gone because it is, and a live view's link is
  /// not something the app hears the failure of. For whatever shows the
  /// session.
  Future<bool> mayGoOnUnwatched(String sessionId, {required AppDatabase? db}) async {
    final watch = SessionWatches.of(sessionId);
    if (watch == null || watch.phase != SessionWatchPhase.held || db == null) return false;
    final me = await _ref.read(orchardAuthorProvider).call();
    final record = await latestRecordIn(db);
    if (me == null || record == null || !mayGoUnwatched(record, watch.host.crateId, me.uid)) return false;
    return _awayNow();
  }

  /// Lets the held session [sessionId] go on with nobody watching, where
  /// ZestSSH Cloud cannot be reached and this account may go on then: the
  /// person is asked for the reason, and what is reported is kept, first.
  /// Nothing happens for a session that is not held. Throws
  /// [SessionWatchCancelled] when the person gives up (it stays held) and
  /// [OrchardAccessRefused], with the reason in words, where it may not.
  Future<void> goOnUnwatched(
    String sessionId, {
    required String hostLabel,
    required AppDatabase? db,
    required void Function(String line) log,
  }) async {
    final watch = SessionWatches.of(sessionId);
    if (watch == null || watch.phase != SessionWatchPhase.held) return;
    if (db == null) throw OrchardAccessRefused(gl10n.watchedOrchardClosed);
    if (!await _awayNow()) throw OrchardAccessRefused(gl10n.watchedAwayBack);
    await _goUnwatched(watch, db: db, hostLabel: hostLabel, log: log, held: true);
  }

  /// Asks more people to watch the session [sessionId] while it waits or is
  /// held: [uids] out of those who manage its Crate. Where its live view
  /// has ended meanwhile (stopped, or run out after its hours), a new one
  /// is started with them. Throws what inviting or sharing throws.
  Future<void> askMore(String sessionId, Set<String> uids) async {
    final watch = SessionWatches.of(sessionId);
    if (watch == null || uids.isEmpty) return;
    final sharing = _ref.read(sessionSharingProvider);
    final (context, _) = await sharing.availabilityFor(sessionId);
    if (context == null) return;
    final people = [
      for (final p in askable(context.people))
        if (uids.contains(p.uid)) p,
    ];
    if (people.isEmpty) return;
    final asked = {for (final p in people) p.uid};
    final share = SessionShares.of(sessionId);
    if (share == null || share.isEnded) {
      await sharing.start(sessionId, context, mode: ShareMode.live, people: asked, enders: asked);
    } else {
      SessionShares.addNames(sessionId, {for (final p in people) p.uid: p.email ?? p.uid});
      await share.invite([for (final p in people) p.party!], enders: asked);
    }
    watch.askedPeople();
  }

  /// Who could be asked to watch the session [sessionId] now, for asking
  /// someone else while it waits or is held; null when that cannot be
  /// worked out any more (the session or its Orchard is gone).
  Future<WatchRequest?> requestFor(String sessionId, {required String hostLabel}) async {
    final watch = SessionWatches.of(sessionId);
    if (watch == null) return null;
    final (context, _) = await _ref.read(sessionSharingProvider).availabilityFor(sessionId);
    if (context == null) return null;
    return WatchRequest(
      sessionId: sessionId,
      host: watch.host,
      crateName: context.crateName,
      hostLabel: hostLabel,
      people: [
        for (final p in context.people)
          if (p.canManage) p,
      ],
      alreadyAsked: {
        for (final g in SessionShares.of(sessionId)?.guests ?? const <ShareGuest>[])
          if (g.state != ShareGuestState.declined) g.uid,
      },
    );
  }
}

final watchGateProvider = Provider<WatchGate>((ref) => WatchGate(ref));
