import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_sync_engine.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_text.dart';

/// The items a new device shows no copy of ([CrateSyncEngine.heldBack]): each
/// copy's vault, who wrote it and when, and for an owner or admin who holds the
/// rights, Keep this one and Remove. Opened from Needs attention.
Future<void> showHeldBackItems(BuildContext context, WidgetRef ref, OrchardSummary orchard) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.copy,
    title: l10n.heldBackTitle,
    subtitle: l10n.heldBackBody,
    body: HeldBackList(orchard: orchard),
  );
}

/// The list of [showHeldBackItems].
class HeldBackList extends ConsumerStatefulWidget {
  const HeldBackList({super.key, required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<HeldBackList> createState() => _HeldBackListState();
}

class _HeldBackListState extends ConsumerState<HeldBackList> {
  bool _busy = false;
  Object? _problem;
  StackTrace? _problemStack;

  String get _id => widget.orchard.id;

  String _vault(String crateId, AppLocalizations l10n) {
    final crate = widget.orchard.crates.where((c) => c.id == crateId).firstOrNull;
    return Redactable.group(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)).displayIn(ref);
  }

  /// Runs what was asked, and reads the list again. What fails waits for the next
  /// sync, so it is said and nothing is undone.
  Future<void> _act(Future<bool> Function() action) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _problem = null;
      _problemStack = null;
    });
    try {
      await action();
    } catch (e, stack) {
      if (mounted) {
        setState(() {
          _problem = e;
          _problemStack = stack;
        });
      }
    }
    if (!mounted) return;
    ref.invalidate(teamHeldBackProvider(_id));
    setState(() => _busy = false);
  }

  Future<void> _keep(HeldBackItem item, HeldBackCopy copy, AppLocalizations l10n) async {
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.heldBackKeepTitle,
      body: l10n.heldBackKeepBody(_vault(copy.crateId, l10n)),
      confirmLabel: l10n.heldBackKeep,
    );
    if (go != true || !mounted) return;
    await _act(() => ref.read(orchardSyncProvider).keepHeldBack(_id, item.kind, item.key, copy.crateId));
  }

  Future<void> _remove(HeldBackItem item, HeldBackCopy copy, AppLocalizations l10n) async {
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.heldBackRemoveTitle,
      body: l10n.heldBackRemoveBody(_vault(copy.crateId, l10n)),
      confirmLabel: l10n.heldBackRemove,
    );
    if (go != true || !mounted) return;
    await _act(() => ref.read(orchardSyncProvider).removeHeldBack(_id, item.kind, item.key, copy.crateId));
  }

  String _names(HeldBackItem item, AppLocalizations l10n) {
    final names = {
      for (final copy in item.copies)
        if (copy.name != null) Redactable.host(copy.name!).displayIn(ref),
    };
    return names.isEmpty ? l10n.heldBackUnnamed : names.join(' / ');
  }

  String? _wroteIt(HeldBackCopy copy, AppLocalizations l10n) {
    final author = copy.author;
    final editedAt = copy.editedAt;
    if (author == null || editedAt == null) return null;
    final emails = ref.watch(teamRecordProvider(_id)).valueOrNull?.emails;
    final person = Redactable.account(emails?[author] ?? shortMemberId(author)).displayIn(ref);
    final when = DateFormat.yMMMd(l10n.localeName).add_jm().formatPlain(DateTime.fromMillisecondsSinceEpoch(editedAt));
    return l10n.heldBackCopyBy(person, when);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final items = [
      for (final item in ref.watch(teamHeldBackProvider(_id)).valueOrNull ?? const <HeldBackItem>[])
        if (item.mayAct) item,
    ];
    return Column(
      key: const ValueKey('held-back-list'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_problem != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: TeamLoadProblem(
              title: l10n.heldBackFailed,
              error: _problem!,
              stack: _problemStack,
              where: 'Team overview: settling an item held back',
            ),
          ),
        if (items.isEmpty)
          Text(l10n.teamAttentionNone, style: TextStyle(fontSize: 13, color: ZestColors.textSecondary)),
        for (final item in items) ...[
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Text(
              _names(item, l10n),
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
            ),
          ),
          for (final copy in item.copies) _copyRow(item, copy, l10n),
          const SizedBox(height: 10),
        ],
      ],
    );
  }

  Widget _copyRow(HeldBackItem item, HeldBackCopy copy, AppLocalizations l10n) {
    final wrote = _wroteIt(copy, l10n);
    return Padding(
      key: ValueKey('held-back-copy-${copy.crateId}'),
      padding: const EdgeInsets.only(bottom: 8),
      child: Wrap(
        alignment: WrapAlignment.spaceBetween,
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 12,
        runSpacing: 6,
        children: [
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 180, maxWidth: 300),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(_vault(copy.crateId, l10n), style: TextStyle(fontSize: 13, color: ZestColors.textPrimary)),
                if (wrote != null)
                  Text(wrote, style: TextStyle(fontSize: 12, color: ZestColors.textSecondary)),
                if (copy.here)
                  Text(l10n.heldBackOnThisDevice, style: TextStyle(fontSize: 12, color: ZestColors.textTertiary)),
              ],
            ),
          ),
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: [
              if (copy.mayKeep)
                teamButton(
                  key: ValueKey('held-back-keep-${copy.crateId}'),
                  label: l10n.heldBackKeep,
                  onPressed: _busy ? null : () => _keep(item, copy, l10n),
                ),
              if (copy.mayRemove)
                teamButton(
                  key: ValueKey('held-back-remove-${copy.crateId}'),
                  label: l10n.heldBackRemove,
                  onPressed: _busy ? null : () => _remove(item, copy, l10n),
                ),
            ],
          ),
        ],
      ),
    );
  }
}
