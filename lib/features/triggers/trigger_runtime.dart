import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/daos/terminal_triggers_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/notification_service.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// The rules of [rows] that run: each that is on and whose pattern compiles
/// and passes the checks (null, and left out, for a pattern that could hold
/// up the app: a team's alerts are written by whoever may add to its vaults;
/// the row says so), among the first [kMaxTriggerRules] that are on only
/// (found in a review). Rules past those are not even
/// compiled.
List<CompiledTrigger> compileTriggerRules(Iterable<TerminalTrigger> rows) {
  final compiled = <CompiledTrigger>[];
  var on = 0;
  var past = 0;
  for (final r in rows) {
    if (!r.enabled) continue;
    if (++on > kMaxTriggerRules) {
      past++;
      continue;
    }
    final c = CompiledTrigger.tryCompile(
      id: r.id,
      name: r.name,
      pattern: r.pattern,
      caseSensitive: r.caseSensitive,
      notify: r.notify,
      highlight: r.highlight,
      highlightColor: r.highlightColor,
      playSound: r.playSound,
      connectionId: r.connectionId,
    );
    if (c != null) compiled.add(c);
  }
  if (past > 0) AppLogger.warning('$past alert rule(s) past the first $kMaxTriggerRules that are on do not run');
  return compiled;
}

/// The live runtime for trigger / highlight rules.
///
/// It keeps the compiled rule set in sync with the (synced) DAO, scans every
/// session's output stream for NOTIFY matches, and fires coalesced alerts into
/// the notification center. The HIGHLIGHT half is applied in the terminal view
/// (which owns the [TerminalController]); the view reads [highlightRulesFor]
/// and re-runs its pass whenever [revision] changes.
class TriggerRuntime {
  TriggerRuntime(this._ref) {
    // Follows the rules' database: a new one after the app unlocks (the old
    // one closed), or another space's when you switch (3.0).
    // While locked there is none, and nothing is watched.
    _daoSub = _ref.listen<TerminalTriggersDao>(
      terminalTriggersDaoProvider,
      (_, dao) => _watch(dao),
      onError: (_, _) {
        _sub?.cancel();
        _sub = null;
      },
      fireImmediately: true,
    );
  }

  void _watch(TerminalTriggersDao dao) {
    _sub?.cancel();
    _sub = dao.watchAll().listen(_recompile, onError: (Object e) {
      AppLogger.error('Trigger rule stream error', e);
    });
  }

  /// A runtime with NO DAO subscription, for widget tests that only need the
  /// stats surface ([statsFor] / [statsRevision]) without a live database - a
  /// real DAO stream never settles under `pumpAndSettle`.
  @visibleForTesting
  TriggerRuntime.forTesting(this._ref);

  final Ref _ref;
  ProviderSubscription<TerminalTriggersDao>? _daoSub;
  StreamSubscription<List<TerminalTrigger>>? _sub;

  List<CompiledTrigger> _all = const [];
  final TriggerCoalescer _coalescer = TriggerCoalescer();
  final Map<String, TriggerLineScanner> _scanners = {};

  /// Bumped whenever the rule set changes so terminal views can re-apply their
  /// highlights against the new patterns.
  final ValueNotifier<int> revision = ValueNotifier<int>(0);

  /// Per-trigger match telemetry: how many output lines each rule has matched
  /// this app run, and when it last matched. In-memory only (resets on
  /// relaunch) - it is live activity, not synced state. Keyed by trigger id.
  final Map<String, ({int count, DateTime last})> _stats = {};

  /// Bumped whenever [_stats] changes so the Triggers view can re-read counts
  /// without the runtime knowing anything about the widget layer.
  final ValueNotifier<int> statsRevision = ValueNotifier<int>(0);

  /// The match telemetry for [triggerId], or null if it has never matched.
  ({int count, DateTime last})? statsFor(String triggerId) => _stats[triggerId];

  /// The enabled HIGHLIGHT rules that apply to a session on [connectionId].
  List<CompiledTrigger> highlightRulesFor(String? connectionId) => _all
      .where((t) => t.highlight && t.appliesTo(connectionId))
      .toList(growable: false);

  void _recompile(List<TerminalTrigger> rows) {
    _all = compileTriggerRules(rows);
    revision.value++;
  }

  /// Feed a session's raw output chunk. Cheap no-op when the user has NO rules
  /// at all (the common case). When rules exist we scan even for a highlight-
  /// only set, so match telemetry (count + last-match) is accurate; the notify
  /// path still gates on [CompiledTrigger.notify] before firing an alert.
  void processOutput(String sessionId, String? connectionId, String rawChunk) {
    if (_all.isEmpty) return;
    final scanner = _scanners.putIfAbsent(sessionId, TriggerLineScanner.new);
    final lines = scanner.addChunk(rawChunk);
    if (lines.isEmpty) return;
    final now = DateTime.now();
    var statsChanged = false;
    // Each rule a share of time for this burst (TriggerWorkBudget): a pattern
    // that takes too long on these lines sits out the rest of them.
    final budget = TriggerWorkBudget();
    for (final line in lines) {
      for (final hit in matchLine(line, _all, connectionId, budget: budget)) {
        // Telemetry counts one match per matched LINE as it streams. This is
        // the per-event path; the highlight view re-runs its pass per render,
        // so it must NOT count or every repaint would inflate the total.
        final prev = _stats[hit.trigger.id];
        _stats[hit.trigger.id] = (count: (prev?.count ?? 0) + 1, last: now);
        statsChanged = true;
        if (!hit.trigger.notify) continue; // highlight-only: counted, not fired
        if (!_coalescer.shouldNotify(hit.trigger.id, hit.line, now)) continue;
        _fire(hit);
      }
    }
    if (statsChanged) statsRevision.value++;
    if ((budget.overBudget.isNotEmpty || budget.spent) && _slowSaid.add(sessionId)) {
      AppLogger.warning(budget.spent
          ? 'The alert rules together took too long on a burst of output and sat out the rest of it'
          : '${budget.overBudget.length} alert rule(s) took too long on a burst of output and sat out the rest of it');
    }
  }

  /// Sessions whose log already says a rule sat out (once each).
  final Set<String> _slowSaid = {};

  void _fire(TriggerHit hit) {
    final match = hit.match.length > 120
        ? '${hit.match.substring(0, 120)}…'
        : hit.match;
    _ref.read(notificationCenterProvider.notifier).warning(
          hit.trigger.name,
          // In the person's language (it said "Matched:" in English).
          body: gl10n.trgMatchedBody(match),
          dismissAfter: const Duration(seconds: 8),
        );
    if (hit.trigger.playSound) {
      if (triggerSoundIsComputers) {
        // The system's alert sound, which Flutter plays on computers alone,
        // and, where its person turned that on and the window is not in
        // front, the system's notification, silent: the sound is played
        // (4.0).
        SystemSound.play(SystemSoundType.alert);
        unawaited(NotificationService.onComputer(
            () => NotificationService.showTriggerSound(triggerName: hit.trigger.name, silent: true)));
      } else {
        // A phone or a tablet has no alert sound to play (the switch played
        // nothing there): a notification of the system, with the sound the
        // person's settings give it.
        unawaited(NotificationService.showTriggerSound(triggerName: hit.trigger.name));
      }
    }
    AppLogger.info('Trigger "${hit.trigger.name}" fired');
  }

  /// Drop a closed session's partial-line buffer.
  void endSession(String sessionId) => _scanners.remove(sessionId);

  void dispose() {
    _daoSub?.close();
    _sub?.cancel();
    revision.dispose();
    statsRevision.dispose();
  }
}

/// Whether a trigger plays its sound as a computer does (the system's
/// alert sound) or as a phone or a tablet does (a notification of the
/// system): what the runtime does, and what the phone's editor says of it.
bool get triggerSoundIsComputers => debugTriggerSoundOnComputer ?? isDesktopPlatform;

/// [triggerSoundIsComputers] for tests. Null in the app, where the platform
/// says.
@visibleForTesting
bool? debugTriggerSoundOnComputer;

/// The app-wide trigger runtime. Lazily created on first output; keeps a live
/// subscription to the synced rule set for its lifetime.
final triggerRuntimeProvider = Provider<TriggerRuntime>((ref) {
  final runtime = TriggerRuntime(ref);
  ref.onDispose(runtime.dispose);
  return runtime;
});
