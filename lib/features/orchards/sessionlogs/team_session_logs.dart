import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/sync/crate_placement.dart';
import 'package:zestssh/utils/logger.dart';

/// Starts logging [sessionId] for its team when [db] (the database the
/// session works in) is an Orchard's and the host [connectionId]'s Crate
/// logs sessions, as this device's record says: its output waits from now
/// on, and goes in once the log has started (in the background: a slow
/// server never holds the session up). Never throws. [kind]: the header's
/// SessionLogHeader.kind, kScreenLogKind for a remote screen (4.0), whose
/// log takes ScreenSessionLogLines alone.
Future<void> startTeamSessionLogFor(
  OrchardService service,
  AppDatabase db,
  String sessionId, {
  required String connectionId,
  required String label,
  required String host,
  required int port,
  String? user,
  String? kind,
}) async {
  if (!db.isOrchard) return;
  try {
    final info = await db.customSelect('SELECT orchard_id FROM orchard_info WHERE id = 1').getSingleOrNull();
    final orchardId = info?.read<String>('orchard_id');
    final crateId = await CratePlacement(db).crateOf('host', connectionId);
    if (orchardId == null || crateId == null || !await service.sessionLogsOn(orchardId, crateId)) return;
    TeamSessionLogs.expect(sessionId);
    unawaited(service
        .startTeamSessionLog(orchardId, crateId,
            label: label, host: host, port: port, user: user, connectionId: connectionId, kind: kind)
        .then((writer) => TeamSessionLogs.started(sessionId, writer)));
  } catch (e) {
    AppLogger.info('Orchards: this session is not logged for its team ($e)');
  }
}

/// The team session logs open in this run (3.0), by session id:
/// what the terminal, its tmux panes and snippets feed. A session to a host
/// whose Crate logs sessions is [expect]ed as it connects, and what it shows
/// waits here (up to [kEarlyOutputMax]) until its log has [started]; a log
/// that does not start (the server says session logs are off) keeps
/// nothing. [logged] is what the session header's "logged" chip shows, and
/// [waiting] which of those logs have not reached ZestSSH Cloud yet.
abstract final class TeamSessionLogs {
  static final _writers = <String, TeamSessionLogWriter>{};
  static final _early = <String, StringBuffer>{};
  static final _secrets = <String>{};

  /// Sessions that ended while their log was still starting: once it has
  /// started, what they showed goes in, and it is closed. (A session, or a
  /// run on a host, quicker than its log's start was not logged: its log
  /// was closed with nothing in it.)
  static final _endedStarting = <String>{};

  /// Output kept at most while a session's log is starting.
  static const int kEarlyOutputMax = 1 << 20;

  /// The sessions being logged for their team, or about to be.
  static final logged = ValueNotifier<Set<String>>(const {});

  static bool isLogged(String sessionId) => logged.value.contains(sessionId);

  /// Of the [logged] sessions, those whose log has not reached ZestSSH
  /// Cloud yet: it is kept on this device, sealed, and sent later
  /// ([TeamSessionLogWriter.onDevice]). The chip says so.
  static final waiting = ValueNotifier<Set<String>>(const {});

  /// What follows each session's writer, to stop following it by.
  static final _following = <String, (TeamSessionLogWriter, void Function())>{};

  static void _mark(String sessionId, bool on) {
    final now = {...logged.value};
    on ? now.add(sessionId) : now.remove(sessionId);
    logged.value = now;
    // A session that is not logged has no log that waits.
    if (!on) _unfollow(sessionId);
  }

  static void _markWaiting(String sessionId, bool on) {
    if (waiting.value.contains(sessionId) == on) return;
    final now = {...waiting.value};
    on ? now.add(sessionId) : now.remove(sessionId);
    waiting.value = now;
  }

  /// [sessionId]'s log is [writer]'s: whether it waits is followed from now.
  static void _follow(String sessionId, TeamSessionLogWriter writer) {
    void follow() => _markWaiting(sessionId, writer.onDevice.value);
    _following[sessionId] = (writer, follow);
    writer.onDevice.addListener(follow);
    follow();
  }

  static void _unfollow(String sessionId) {
    final was = _following.remove(sessionId);
    if (was != null) was.$1.onDevice.removeListener(was.$2);
    _markWaiting(sessionId, false);
  }

  /// [sessionId] is to be logged: its output waits here from now on. Where
  /// a log of it is still starting (it ended, and connects again under the
  /// same id before that log has started), it goes on in that log.
  static void expect(String sessionId) {
    if (_writers.containsKey(sessionId)) return;
    _endedStarting.remove(sessionId);
    _early.putIfAbsent(sessionId, StringBuffer.new);
    _mark(sessionId, true);
  }

  /// [sessionId]'s log started as [writer] (null: it did not, and the
  /// session is not logged). What waited goes in first.
  static void started(String sessionId, TeamSessionLogWriter? writer) {
    final early = _early.remove(sessionId);
    final ended = _endedStarting.remove(sessionId);
    if (writer == null || early == null) {
      if (writer != null) unawaited(writer.close());
      _mark(sessionId, false);
      _forgetIfIdle();
      return;
    }
    for (final s in _secrets) {
      writer.addSecret(s);
    }
    // The session ended meanwhile: what it showed, and the log is over.
    if (ended) {
      if (early.isNotEmpty) writer.append(early.toString());
      unawaited(writer.close());
      _forgetIfIdle();
      return;
    }
    _writers[sessionId] = writer;
    _follow(sessionId, writer);
    if (early.isNotEmpty) writer.append(early.toString());
  }

  /// What [sessionId] shows, escape sequences and all.
  static void append(String sessionId, String text) {
    final writer = _writers[sessionId];
    if (writer != null) {
      writer.append(text);
      if (writer.stopped) {
        _writers.remove(sessionId);
        _mark(sessionId, false);
        _forgetIfIdle();
      }
      return;
    }
    final early = _early[sessionId];
    if (early != null && early.length < kEarlyOutputMax) early.write(text);
  }

  /// A value typed into a session that must not reach any team log (a
  /// masked snippet variable's): every open log leaves it out, and so does
  /// one still starting. Kept only while a log is open or starting, and
  /// forgotten when the last one ends: with none, there is nothing to keep
  /// it from.
  static void addSecret(String value) {
    if (value.isEmpty || (_writers.isEmpty && _early.isEmpty)) return;
    _secrets.add(value);
    for (final w in _writers.values) {
      w.addSecret(value);
    }
  }

  /// [sessionId] ended: its log is closed. One still starting is closed
  /// once it has started, with what the session showed ([started]).
  static Future<void> end(String sessionId) async {
    final writer = _writers.remove(sessionId);
    if (writer == null && _early.containsKey(sessionId)) {
      _endedStarting.add(sessionId);
      _mark(sessionId, false);
      return;
    }
    _early.remove(sessionId);
    _mark(sessionId, false);
    _forgetIfIdle();
    await writer?.close();
  }

  /// With no log open or starting, no secret is kept.
  static void _forgetIfIdle() {
    if (_writers.isEmpty && _early.isEmpty) _secrets.clear();
  }

  /// How many secret values are kept now (tests).
  @visibleForTesting
  static int get secretsKept => _secrets.length;

  /// What waits for [sessionId]'s log to start (tests).
  @visibleForTesting
  static String? debugWaiting(String sessionId) => _early[sessionId]?.toString();

  /// Forgets everything (tests; signing out).
  static void reset() {
    for (final sessionId in _following.keys.toList()) {
      _unfollow(sessionId);
    }
    _writers.clear();
    _early.clear();
    _endedStarting.clear();
    _secrets.clear();
    logged.value = const {};
    waiting.value = const {};
  }
}
