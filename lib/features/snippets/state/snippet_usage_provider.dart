import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/utils/logger.dart';

// ══════════════════════════════════════════════════════════════════
// Snippet usage - device-local run stats (run count + last-run stamp)
//
// The snippets Drift table has NO usage columns, and cloud sync only ever
// carries the snippet definition - never per-device telemetry. So the "N runs ·
// last run 3h ago" line on a snippet card is tracked LOCALLY here, persisted to
// SharedPreferences (one JSON map keyed by snippet id, under
// [_kSnippetUsageKey]). No schema, no migration, no sync.
//
// Follows the same StateNotifier + SharedPreferences persistence pattern as
// [savedTabGroupsProvider] / [monitorThresholdsProvider].
// ══════════════════════════════════════════════════════════════════

/// Per-snippet local usage: how many times the snippet has been run from this
/// device and when it was last run. Immutable; every edit replaces the value in
/// the notifier's map so widgets watching [snippetUsageProvider] rebuild.
@immutable
class SnippetUsage {
  /// Total number of runs recorded on this device.
  final int runCount;

  /// When the snippet was last run (local device clock).
  final DateTime lastRunAt;

  const SnippetUsage({required this.runCount, required this.lastRunAt});

  Map<String, dynamic> toJson() => {
        'runCount': runCount,
        // Millis-since-epoch: compact and locale/timezone stable on read.
        'lastRunAt': lastRunAt.millisecondsSinceEpoch,
      };

  /// Parse one persisted entry, or null when the shape is unusable so a single
  /// corrupt row can't take down the whole map.
  static SnippetUsage? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final count = raw['runCount'];
    final last = raw['lastRunAt'];
    if (count is! int || last is! int) return null;
    if (count <= 0) return null;
    return SnippetUsage(
      runCount: count,
      lastRunAt: DateTime.fromMillisecondsSinceEpoch(last),
    );
  }
}

/// The persisted key. `_v1` so the shape can evolve without misreading old data.
const String _kSnippetUsageKey = 'snippet_usage_v1';

/// Device-local snippet usage stats keyed by snippet id. Read a snippet's usage
/// with `ref.watch(snippetUsageProvider)[snippetId]`; record a run with
/// `ref.read(snippetUsageProvider.notifier).recordRun(snippetId)`.
final snippetUsageProvider =
    StateNotifierProvider<SnippetUsageNotifier, Map<String, SnippetUsage>>(
  (ref) => SnippetUsageNotifier(ref),
);

class SnippetUsageNotifier extends StateNotifier<Map<String, SnippetUsage>> {
  SnippetUsageNotifier(this._ref) : super(const {}) {
    _restore();
  }

  final Ref _ref;

  /// Load the persisted map on init. A corrupt blob starts fresh rather than
  /// throwing - usage stats are disposable telemetry, never the source of truth.
  void _restore() {
    try {
      final raw = _ref.read(sharedPreferencesProvider).getString(_kSnippetUsageKey);
      if (raw == null) return;
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      final restored = <String, SnippetUsage>{};
      decoded.forEach((id, value) {
        final usage = SnippetUsage.fromJson(value);
        if (usage != null) restored[id] = usage;
      });
      state = restored;
    } catch (e) {
      AppLogger.debug('SnippetUsage: failed to restore usage map: $e');
    }
  }

  void _persist() {
    try {
      _ref.read(sharedPreferencesProvider).setString(
            _kSnippetUsageKey,
            jsonEncode({
              for (final entry in state.entries) entry.key: entry.value.toJson(),
            }),
          );
    } catch (e) {
      AppLogger.debug('SnippetUsage: failed to persist usage map: $e');
    }
  }

  /// The recorded usage for [snippetId], or null when it has never been run on
  /// this device.
  SnippetUsage? usageFor(String snippetId) => state[snippetId];

  /// Record one run of [snippetId]: increment its run count and set the
  /// last-run stamp to now, then persist. Called from the snippet "Run on…"
  /// path once the run has been dispatched to a host.
  void recordRun(String snippetId) {
    final existing = state[snippetId];
    final next = SnippetUsage(
      runCount: (existing?.runCount ?? 0) + 1,
      lastRunAt: DateTime.now(),
    );
    state = {...state, snippetId: next};
    _persist();
  }
}
