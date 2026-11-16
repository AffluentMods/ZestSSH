import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/crate_records_view.dart' show crateItemIcon, crateItemName;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

// The owners' activity page (3.0): while activity is
// on, what members did with the team's items (opened a key's secrets,
// copied one, exported, connected), newest first, each event checked on
// this device before it is shown. While it is off, the page says so and
// where an owner turns it on.

class TeamActivityView extends ConsumerStatefulWidget {
  const TeamActivityView({super.key, required this.orchard, this.onOpenRules});

  final OrchardSummary orchard;

  /// Opens the Rules page, where an owner turns activity on.
  final VoidCallback? onOpenRules;

  @override
  ConsumerState<TeamActivityView> createState() => _TeamActivityViewState();
}

class _TeamActivityViewState extends ConsumerState<TeamActivityView> {
  final _entries = <TeamActivityEntry>[];
  TeamActivityPage? _last;
  var _unreadable = 0;
  Object? _error;
  bool _loading = false;
  bool _started = false;

  Future<void> _more() async {
    setState(() => _loading = true);
    try {
      final page = await ref.read(orchardServiceProvider).teamActivity(widget.orchard.id, before: _last?.before);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _unreadable += page.unreadable;
        _last = page;
        _error = null;
      });
    } catch (e) {
      AppLogger.info('Orchard activity: not read ($e)');
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  String _text(TeamActivityEntry e, AppLocalizations l10n) {
    final emails = ref.watch(teamRecordProvider(widget.orchard.id)).valueOrNull?.emails ?? const <String, String?>{};
    final who = Redactable.account(emails[e.event.uid] ?? shortMemberId(e.event.uid)).displayIn(ref);
    final kind = e.event.itemKind ?? '';
    final name = e.event.name;
    final item = crateItemName(kind, name == null || name.isEmpty ? l10n.crateItemUnnamed : name).displayIn(ref);
    return teamActivityText(e.event.kind, l10n, who: who, item: item);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final tracking = ref.watch(teamTrackingProvider(widget.orchard.id)).valueOrNull;
    if (tracking == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    if (!tracking.activity) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(l10n.teamActivityOff,
              key: const ValueKey('team-activity-off'),
              style: TextStyle(fontSize: 13, height: 1.5, color: AppColors.v3TextSecondary)),
          if (widget.onOpenRules != null) ...[
            const SizedBox(height: 10),
            OutlinedButton.icon(
              key: const ValueKey('team-activity-open-rules'),
              onPressed: widget.onOpenRules,
              icon: const Icon(LucideIcons.scrollText, size: 15),
              label: Text(l10n.teamActivityOpenRules),
            ),
          ],
        ],
      );
    }
    if (!_started) {
      _started = true;
      unawaited(Future.microtask(_more));
    }
    final error = _error;
    if (error != null && _entries.isEmpty) {
      return Text(orchardChangeErrorMessage(error, l10n),
          key: const ValueKey('team-activity-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final last = _last;
    if (last == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    final when = DateFormat.yMMMd(l10n.localeName).add_jm();
    final crates = {for (final c in widget.orchard.crates) c.id: crateDisplayName(c, l10n)};
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (_entries.isEmpty)
          Text(l10n.teamActivityEmpty,
              key: const ValueKey('team-activity-empty'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary)),
        for (final e in _entries)
          Container(
            key: ValueKey('team-activity-${e.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.v3BorderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(
                  e.event.kind == ActivityKind.connect
                      ? LucideIcons.terminal
                      : e.event.kind == ActivityKind.export
                          ? LucideIcons.share
                          : crateItemIcon(e.event.itemKind ?? ''),
                  size: 15,
                  color: AppColors.v3TextSecondary,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(_text(e, l10n), style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary)),
                      const SizedBox(height: 2),
                      Text(
                        [
                          when.formatPlain(e.event.at.toLocal()),
                          if (crates[e.event.crateId] != null) crates[e.event.crateId]!,
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        if (_unreadable > 0)
          Text(l10n.activityUnreadable(_unreadable),
              key: const ValueKey('team-activity-unreadable'),
              style: TextStyle(fontSize: 11.5, color: AppColors.v3Warning)),
        if (last.more)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('team-activity-older'),
              onPressed: _loading ? null : _more,
              child: Text(l10n.crateChangesOlder),
            ),
          ),
      ],
    );
  }
}
