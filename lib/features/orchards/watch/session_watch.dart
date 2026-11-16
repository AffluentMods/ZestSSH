import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/watch/watched_crates.dart';
import 'package:zestssh/features/sharing/session_shares.dart';
import 'package:zestssh/features/sharing/share_host.dart';
import 'package:zestssh/services/ssh_service.dart';

// A session to a host in a watched Crate (3.0, session
// moderation), on the device it runs on. It is shared as a live view with
// people who manage the Crate, each invited to end it. The connection is
// made once the first of them is watching. While nobody who manages the
// Crate is watching, nothing anyone types reaches the host, and after two
// minutes of that the session is closed. Whoever watches can end it at any
// time (share_host.dart).
//
// It is the app that keeps this rule: ZestSSH has no machine of its own
// between a member and a host. What it rests on that is signed: the record
// says which Crates are watched and who manages them, and the invitation
// says who may end the session.

/// How long a session to a watched Crate's host waits for someone to join
/// before it gives up.
const Duration kWatchJoinWait = Duration(minutes: 10);

/// How long a watched session goes on with nobody watching before it is
/// closed.
const Duration kWatchGrace = Duration(minutes: 2);

/// Where a watched session stands.
enum SessionWatchPhase {
  /// The person connecting is choosing whom to ask.
  choosing,

  /// People were asked; none of them is watching yet. No connection is
  /// made.
  waiting,

  /// Someone who manages the Crate is watching.
  watched,

  /// Connected, and nobody who manages the Crate is watching: typing is
  /// held, and the session closes at [SessionWatch.closesAt].
  held,

  /// Nobody is watching, and the session goes on all the same: ZestSSH
  /// Cloud could not be reached, so nobody could be asked, and this account
  /// may go on then (unwatched.dart). Typing is not held; the session is
  /// reported to the owners.
  unwatched,

  /// Over: the session ended, or it never started.
  over,
}

/// Why a session to a watched Crate's host never started.
enum WatchGivenUp {
  /// The person connecting gave up, or closed the tab.
  cancelled,

  /// Nobody asked joined in time.
  nobodyJoined,
}

/// What happens to a watched session after it started, for whoever keeps
/// its log and tells the person.
enum WatchNote {
  /// Nobody who manages the Crate is watching: typing is held.
  held,

  /// Someone is watching again.
  watchedAgain,

  /// Nobody watched for too long: the session is closed.
  closedUnwatched,

  /// The session goes on with nobody watching, because ZestSSH Cloud could
  /// not be reached: it is reported to the owners.
  unwatched,
}

/// The watch of one session.
class SessionWatch extends ChangeNotifier {
  SessionWatch({
    required this.sessionId,
    required this.host,
    required Future<OrchardRecord?> Function() record,
    DateTime Function()? now,
    this.joinWait = kWatchJoinWait,
    this.grace = kWatchGrace,
    Duration recheck = const Duration(seconds: 15),
    this.onNote,
  })  : _record = record,
        _now = now ?? DateTime.now {
    SessionShares.active.addListener(_sharesChanged);
    _sharesChanged();
    // The record changes without the share saying so (someone no longer
    // manages the Crate): looked at again every little while.
    _recheck = Timer.periodic(recheck, (_) => unawaited(_evaluate()));
  }

  final String sessionId;

  /// The watched Crate the session's host is in.
  final WatchedHost host;
  final Duration joinWait;
  final Duration grace;

  /// Told what happens once the session runs. Never called after [over].
  void Function(WatchNote note)? onNote;

  final Future<OrchardRecord?> Function() _record;
  final DateTime Function() _now;

  SessionWatchPhase _phase = SessionWatchPhase.choosing;
  final _first = Completer<WatchGivenUp?>();
  ShareHostController? _share;
  Timer? _recheck;
  Timer? _joinTimer;
  Timer? _graceTimer;
  DateTime? _closesAt;
  bool _connected = false;
  bool _ranUnwatched = false;
  int _asking = 0;
  bool _evaluating = false;
  bool _again = false;
  int _dropped = 0;

  SessionWatchPhase get phase => _phase;

  /// When a held session closes; null while it is not held.
  DateTime? get closesAt => _closesAt;

  /// Whether what is typed into the session is dropped now: always, except
  /// while someone who manages the Crate is watching, or the session was
  /// let go on with nobody watching.
  bool get holdsTyping => _phase != SessionWatchPhase.watched && _phase != SessionWatchPhase.unwatched;

  /// Whether the session ever ran with nobody watching, let go on
  /// ([goUnwatched]). One that was let go on and never connected, or that
  /// someone watched from the start of its connection, never did.
  bool get ranUnwatched => _ranUnwatched;

  /// How many times something typed was dropped because nobody who manages
  /// the Crate was watching.
  int get dropped => _dropped;

  /// Completes with null once someone who manages the Crate is watching
  /// (or the session was let go on with nobody watching), or with why the
  /// session never started.
  Future<WatchGivenUp?> get firstWatcher => _first.future;

  /// The people asked, as the share has them: those invited to end the
  /// session.
  List<ShareGuest> get asked => [
        for (final g in _share?.guests ?? const <ShareGuest>[])
          if (g.canEnd) g,
      ];

  /// People were asked to watch: now it waits for the first of them, for
  /// [joinWait] at most.
  /// Asked again while it still waits (someone else was asked), the wait
  /// starts over.
  void askedPeople() {
    if (_phase == SessionWatchPhase.choosing) _set(SessionWatchPhase.waiting);
    if (_phase != SessionWatchPhase.waiting) return;
    _joinTimer?.cancel();
    _joinTimer = Timer(joinWait, () => _giveUp(WatchGivenUp.nobodyJoined));
    unawaited(_evaluate());
  }

  /// The person connecting gives up waiting.
  void cancel() => _giveUp(WatchGivenUp.cancelled);

  /// The connection is made: from here on, nobody watching means held, and
  /// held for [grace] means closed.
  void connected() {
    if (_phase == SessionWatchPhase.over) return;
    _connected = true;
    // One that was let go on before it connected says so now that there is
    // a session to say it of.
    if (_phase == SessionWatchPhase.unwatched) {
      _ranUnwatched = true;
      onNote?.call(WatchNote.unwatched);
      notifyListeners();
    }
    unawaited(_evaluate());
  }

  /// The session goes on with nobody watching: ZestSSH Cloud cannot be
  /// reached, and this account may go on then. (Whoever calls this has
  /// checked both, and kept what is reported of it: watch_gate.dart.)
  /// Before the connection is made, it may be made now; a held session is
  /// held no longer. Someone who manages the Crate watching it later makes
  /// it a watched one again.
  ///
  /// Answers whether it goes on so from here. It does not where the watch
  /// is over, where it was let go on already, or where someone is watching:
  /// there is nothing to go on from.
  bool goUnwatched() {
    if (_phase == SessionWatchPhase.over ||
        _phase == SessionWatchPhase.unwatched ||
        _phase == SessionWatchPhase.watched) {
      return false;
    }
    _joinTimer?.cancel();
    _joinTimer = null;
    _graceTimer?.cancel();
    _graceTimer = null;
    _closesAt = null;
    if (!_first.isCompleted) _first.complete(null);
    if (_connected) _ranUnwatched = true;
    _set(SessionWatchPhase.unwatched);
    if (_connected) onNote?.call(WatchNote.unwatched);
    return true;
  }

  /// The person is being asked whether the held session goes on with nobody
  /// watching (watch_gate.dart): it is not closed under their hands while
  /// they answer. Typing stays held. Each call is followed by one of
  /// [closeAfterGrace], whatever they answered.
  void holdOpen() {
    _asking++;
    if (_phase != SessionWatchPhase.held || _graceTimer == null) return;
    _graceTimer?.cancel();
    _graceTimer = null;
    _closesAt = null;
    notifyListeners();
  }

  /// They answered. Where the session is still held and nobody else is
  /// being asked, the wait it closes after starts over.
  void closeAfterGrace() {
    if (_asking > 0) _asking--;
    if (_asking > 0 || _phase != SessionWatchPhase.held || _graceTimer != null) return;
    _startGrace();
    notifyListeners();
  }

  /// Something typed was dropped because the session is held.
  void typedWhileHeld() => _dropped++;

  /// The session ended, or never started: nothing more happens here.
  void over() {
    if (_phase == SessionWatchPhase.over) return;
    _phase = SessionWatchPhase.over;
    _closesAt = null;
    _recheck?.cancel();
    _joinTimer?.cancel();
    _graceTimer?.cancel();
    SessionShares.active.removeListener(_sharesChanged);
    _share?.removeListener(_shareChanged);
    _share = null;
    if (!_first.isCompleted) _first.complete(WatchGivenUp.cancelled);
    notifyListeners();
  }

  void _giveUp(WatchGivenUp why) {
    if (_first.isCompleted || _phase == SessionWatchPhase.over) return;
    _first.complete(why);
    over();
  }

  void _set(SessionWatchPhase phase) {
    if (_phase == phase) return;
    _phase = phase;
    notifyListeners();
  }

  void _sharesChanged() {
    final share = SessionShares.of(sessionId);
    if (!identical(share, _share)) {
      _share?.removeListener(_shareChanged);
      _share = share;
      share?.addListener(_shareChanged);
    }
    _shareChanged();
  }

  void _shareChanged() {
    // Who is asked and where they stand is on screen while waiting.
    if (_phase == SessionWatchPhase.waiting) notifyListeners();
    unawaited(_evaluate());
  }

  /// Whether someone who manages the Crate is watching now, by the share
  /// and this device's copy of the record.
  Future<bool> _watchedNow() async {
    final share = _share;
    if (share == null || share.isEnded) return false;
    final there = share.endersWatching;
    if (there.isEmpty) return false;
    final record = await _readRecord();
    if (record == null) return false;
    final at = _now().millisecondsSinceEpoch ~/ 1000;
    return there.any((uid) => mayWatch(record, host.crateId, uid, at));
  }

  /// A record that cannot be read lets nobody count as watching.
  Future<OrchardRecord?> _readRecord() async {
    try {
      return await _record();
    } catch (_) {
      return null;
    }
  }

  Future<void> _evaluate() async {
    if (_phase == SessionWatchPhase.over || _phase == SessionWatchPhase.choosing) return;
    if (_evaluating) {
      _again = true;
      return;
    }
    _evaluating = true;
    try {
      do {
        _again = false;
        final watched = await _watchedNow();
        if (_phase == SessionWatchPhase.over) return;
        _apply(watched);
      } while (_again);
    } finally {
      _evaluating = false;
    }
  }

  void _apply(bool watched) {
    if (watched) {
      _joinTimer?.cancel();
      _joinTimer = null;
      _graceTimer?.cancel();
      _graceTimer = null;
      _closesAt = null;
      final was = _phase;
      if (!_first.isCompleted) _first.complete(null);
      _set(SessionWatchPhase.watched);
      if (was == SessionWatchPhase.held || (was == SessionWatchPhase.unwatched && _connected)) {
        onNote?.call(WatchNote.watchedAgain);
      }
      return;
    }
    // Not watched. Before the connection is made that is only waiting; and
    // a session that was let go on with nobody watching is not held.
    if (!_connected || _phase == SessionWatchPhase.held || _phase == SessionWatchPhase.unwatched) return;
    // (Held while its person is being asked whether it goes on: the wait
    // starts when they have answered, closeAfterGrace.)
    if (_asking == 0) _startGrace();
    _set(SessionWatchPhase.held);
    onNote?.call(WatchNote.held);
  }

  /// A held session closes once nobody has watched for [grace].
  void _startGrace() {
    _closesAt = _now().add(grace);
    _graceTimer = Timer(grace, () {
      if (_phase != SessionWatchPhase.held) return;
      final told = onNote;
      // Whoever is told closes the session, which ends this watch.
      told?.call(WatchNote.closedUnwatched);
    });
  }

  @override
  void dispose() {
    over();
    super.dispose();
  }
}

/// The watched sessions of this run, by session id: what the session's
/// shell asks before it sends anything typed, and what the screens show.
abstract final class SessionWatches {
  static final _watches = <String, SessionWatch>{};

  /// The watched sessions, for whoever shows them.
  static final active = ValueNotifier<Map<String, SessionWatch>>(const {});

  static SessionWatch? of(String sessionId) => _watches[sessionId];

  static void _publish() => active.value = Map.unmodifiable(_watches);

  /// [watch]'s session is one that is watched. A watch the session had
  /// before is over.
  static void add(SessionWatch watch) {
    _watches.remove(watch.sessionId)?.over();
    _watches[watch.sessionId] = watch;
    _publish();
  }

  /// [sessionId] ended, lost its connection, or never started: its watch is
  /// over.
  static void end(String sessionId) {
    final watch = _watches.remove(sessionId);
    if (watch == null) return;
    watch.over();
    _publish();
  }

  /// Forgets everything (tests; signing out).
  static void reset() {
    for (final w in _watches.values.toList()) {
      w.over();
    }
    _watches.clear();
    _publish();
  }
}

/// The shell of a watched session. Everything typed into a session goes
/// through its shell's [write], whoever typed it (the person connected,
/// someone handed the keyboard, a snippet, a broadcast from another tab):
/// here it is dropped while nobody who manages the Crate is watching.
///
/// It is on purpose not an [SshService]. What the app does with a session
/// beside its terminal needs the SSH connection itself and asks for it by
/// that type: SFTP, port forwarding, tmux's control channel, the commands
/// run for live stats and for a snippet's list of choices. None of that
/// shows in the terminal, so none of it is there for a watched session.
class WatchedShell implements ShellService, ShellEndReason {
  WatchedShell(this.inner, this.watch);

  final ShellService inner;
  final SessionWatch watch;

  @override
  void write(Uint8List data) {
    if (watch.holdsTyping) {
      watch.typedWhileHeld();
      return;
    }
    inner.write(data);
  }

  @override
  Future<void> connect() => inner.connect();

  @override
  Future<void> disconnect() => inner.disconnect();

  @override
  Stream<Uint8List> get stdout => inner.stdout;

  @override
  Stream<Uint8List> get stderr => inner.stderr;

  @override
  void resize(int width, int height) => inner.resize(width, height);

  @override
  bool get isConnected => inner.isConnected;

  @override
  Stream<bool> get connectionState => inner.connectionState;

  @override
  bool get exitedCleanly => inner.exitedCleanly;

  /// Why the connection under it ended, when that one can say.
  @override
  Future<String?> get endReason {
    final inner = this.inner;
    return inner is ShellEndReason ? (inner as ShellEndReason).endReason : Future.value(null);
  }

  @override
  bool get isEncryptedSsh => inner.isEncryptedSsh;
}
