import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart' show kHostKeyKind;
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart' show CrateSessionLogsLine;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

// A Crate's trash and changes on screen (3.0). The trash is there
// for anyone who may add in the Crate: what was deleted in the last 30 days,
// brought back as their own change. Who deleted it shows only while the
// team records version history. The changes are for owners and those who
// manage the Crate, while version history is on: who changed, deleted or
// brought back what, and when by their device's clock, with the version
// before a change put back as a change of one's own.

/// An item's icon by its kind.
IconData crateItemIcon(String kind) => switch (kind) {
      'host' => LucideIcons.server,
      'key' => LucideIcons.key,
      'group' => LucideIcons.folder,
      'snippet' => LucideIcons.code,
      'category' => LucideIcons.tag,
      'forward' => LucideIcons.arrowLeftRight,
      'network' => LucideIcons.network,
      'trigger' => LucideIcons.zap,
      kHostKeyKind => LucideIcons.shieldCheck,
      _ => LucideIcons.package,
    };

/// An item's name as recording mode treats its kind.
Redactable crateItemName(String kind, String name) => switch (kind) {
      'host' => Redactable.host(name),
      'key' => Redactable.keyName(name),
      'group' => Redactable.group(name),
      'network' => Redactable.network(name),
      _ => Redactable.freeText(name),
    };

String _named(String name, AppLocalizations l10n) => name.isEmpty ? l10n.crateItemUnnamed : name;

/// A member's name as this device's copy of the Orchard has it.
String _memberName(WidgetRef ref, String orchardId, String uid) {
  final emails = ref.watch(teamRecordProvider(orchardId)).valueOrNull?.emails ?? const <String, String?>{};
  return Redactable.account(emails[uid] ?? shortMemberId(uid)).displayIn(ref);
}

String _when(DateTime at, AppLocalizations l10n) => DateFormat.yMMMd(l10n.localeName).add_jm().formatPlain(at.toLocal());

/// The trash of [crate] in [orchard].
Future<void> showCrateTrash(BuildContext context, OrchardSummary orchard, CrateSummary crate) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.trash2,
    title: l10n.crateTrashTitle(crateDisplayName(crate, l10n)),
    subtitle: l10n.crateTrashSubtitle,
    body: CrateTrashView(orchard: orchard, crate: crate),
  );
}

/// The changes in [crate] in [orchard].
Future<void> showCrateChanges(BuildContext context, OrchardSummary orchard, CrateSummary crate) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.history,
    title: l10n.crateChangesTitle(crateDisplayName(crate, l10n)),
    body: CrateChangesView(orchard: orchard, crate: crate),
  );
}

/// What a read of the trash or the changes failed on, in words.
String _loadError(Object e, AppLocalizations l10n) {
  if (e is OrchardServerException) {
    if (e.code == 'history-off') return l10n.crateHistoryOff;
    if (e.code == 'read-only' && e.need == CrateSwitches.add) return l10n.crateTrashNeedsAdd;
    return orchardChangeErrorMessage(e, l10n);
  }
  return l10n.crateRecordsLoadFailed;
}

class CrateTrashView extends ConsumerStatefulWidget {
  const CrateTrashView({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  @override
  ConsumerState<CrateTrashView> createState() => _CrateTrashViewState();
}

class _CrateTrashViewState extends ConsumerState<CrateTrashView> {
  List<TrashEntry>? _items;
  Object? _error;
  String? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final items = await ref.read(orchardServiceProvider).trashOf(widget.orchard.id, widget.crate.id);
      if (mounted) {
        setState(() {
          _items = items;
          _error = null;
        });
      }
    } catch (e) {
      AppLogger.info('Orchard trash: not read ($e)');
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _restore(TrashEntry entry) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = entry.itemId);
    try {
      await ref.read(orchardServiceProvider).restoreFromTrash(widget.orchard.id, entry);
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      if (!mounted) return;
      showTopSnackBar(context, l10n.crateTrashRestored(crateItemName(entry.kind, _named(entry.name, l10n)).displayIn(ref)),
          isSuccess: true);
      setState(() => _items = [for (final i in _items ?? const <TrashEntry>[]) if (i.itemId != entry.itemId) i]);
    } catch (e) {
      AppLogger.warning('Orchard trash: not brought back ($e)');
      if (mounted) {
        showTopSnackBar(context, '$e'.contains('orchard-access') ? l10n.crateTrashNeedsAdd : orchardChangeErrorMessage(e, l10n),
            isError: true, details: '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    if (error != null) {
      return Text(_loadError(error, l10n),
          key: const ValueKey('crate-trash-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final items = _items;
    if (items == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    if (items.isEmpty) {
      return Text(l10n.crateTrashEmpty,
          key: const ValueKey('crate-trash-empty'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    // Who deleted what is version history's to show.
    final history = ref.watch(teamTrackingProvider(widget.orchard.id)).valueOrNull?.history ?? false;
    final date = DateFormat.yMMMd(l10n.localeName);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final entry in items)
          Container(
            key: ValueKey('crate-trash-${entry.itemId}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.v3BorderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(crateItemIcon(entry.kind), size: 15, color: AppColors.v3TextSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        crateItemName(entry.kind, _named(entry.name, l10n)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          if (history) l10n.crateTrashDeletedBy(_memberName(ref, widget.orchard.id, entry.deletedBy)),
                          l10n.crateTrashKeptUntil(date.format(entry.keptUntil.toLocal())),
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (_busy == entry.itemId)
                  const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))
                else
                  TextButton.icon(
                    key: ValueKey('crate-trash-restore-${entry.itemId}'),
                    onPressed: _busy == null ? () => _restore(entry) : null,
                    icon: const Icon(LucideIcons.rotateCcw, size: 14),
                    label: Text(l10n.crateTrashRestore),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class CrateChangesView extends ConsumerStatefulWidget {
  const CrateChangesView({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  @override
  ConsumerState<CrateChangesView> createState() => _CrateChangesViewState();
}

class _CrateChangesViewState extends ConsumerState<CrateChangesView> {
  final _changes = <CrateChange>[];
  CrateChangesPage? _last;
  Object? _error;
  bool _loading = true;
  int? _busy;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(orchardServiceProvider)
          .crateChanges(widget.orchard.id, widget.crate.id, before: _last?.before);
      if (!mounted) return;
      setState(() {
        _changes.addAll(page.changes);
        _last = page;
        _error = null;
      });
    } catch (e) {
      AppLogger.info('Orchard changes: not read ($e)');
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  Future<void> _putBack(CrateChange change) async {
    final l10n = AppLocalizations.of(context)!;
    final item = crateItemName(change.kind, _named(change.previous.name, l10n)).displayIn(ref);
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.crateChangePutBackTitle(item),
      body: l10n.crateChangePutBackBody,
      confirmLabel: l10n.crateChangePutBackConfirm,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = change.previous.historyId);
    try {
      await ref.read(orchardServiceProvider).putVersionBack(widget.orchard.id, change.previous);
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      if (mounted) showTopSnackBar(context, l10n.crateChangePutBackDone(item), isSuccess: true);
    } catch (e) {
      AppLogger.warning('Orchard changes: not put back ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    if (error != null && _changes.isEmpty) {
      return Text(_loadError(error, l10n),
          key: const ValueKey('crate-changes-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final last = _last;
    if (last == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(l10n.crateChangesSince(DateFormat.yMMMd(l10n.localeName).format(last.since.toLocal())),
            key: const ValueKey('crate-changes-since'),
            style: TextStyle(fontSize: 11.5, height: 1.45, color: AppColors.v3TextSecondary)),
        const SizedBox(height: 10),
        if (_changes.isEmpty)
          Text(l10n.crateChangesEmpty,
              key: const ValueKey('crate-changes-empty'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary)),
        for (final change in _changes) _row(change, l10n),
        if (last.more)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('crate-changes-older'),
              onPressed: _loading ? null : _more,
              child: Text(l10n.crateChangesOlder),
            ),
          ),
      ],
    );
  }

  Widget _row(CrateChange change, AppLocalizations l10n) {
    final who = _memberName(ref, widget.orchard.id, change.by);
    final item = crateItemName(change.kind, _named(change.name, l10n)).displayIn(ref);
    final what = change.deleted
        ? l10n.crateChangeDeleted(who, item)
        : change.restored
            ? l10n.crateChangeRestored(who, item)
            : l10n.crateChangeEdited(who, item);
    // An edit can be taken back to the version before it; a deletion goes
    // back from the trash.
    final canPutBack = !change.deleted && !change.previous.record.deleted;
    final id = change.previous.historyId;
    return Container(
      key: ValueKey('crate-change-$id'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
      decoration: BoxDecoration(
        border: Border.all(color: AppColors.v3BorderSubtle),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        children: [
          Icon(change.deleted ? LucideIcons.trash2 : crateItemIcon(change.kind), size: 15, color: AppColors.v3TextSecondary),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(what, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary)),
                const SizedBox(height: 2),
                Text(_when(change.at, l10n), style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
              ],
            ),
          ),
          if (canPutBack) ...[
            const SizedBox(width: 8),
            if (_busy != null && _busy == id)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 1.6))
            else
              TextButton.icon(
                key: ValueKey('crate-change-put-back-$id'),
                onPressed: _busy == null && widget.crate.allows(CrateSwitches.edit) ? () => _putBack(change) : null,
                icon: const Icon(LucideIcons.undo2, size: 14),
                label: Text(l10n.crateChangePutBack),
              ),
          ],
        ],
      ),
    );
  }
}

/// A Crate row's way to its trash (anyone who may add there) and its
/// changes (owners and those who manage it, while version history is on).
class CrateRecordsLine extends ConsumerWidget {
  const CrateRecordsLine({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final history = ref.watch(teamTrackingProvider(orchard.id)).valueOrNull?.history ?? false;
    final trash = orchard.active && crate.allows(CrateSwitches.add);
    final changes = orchard.active && history && crate.allows(CrateSwitches.manage);
    if (!trash && !changes) return const SizedBox.shrink();
    // A window opened from here takes the screen while it is up.
    void open(Future<void> Function() show) => overWindow(context, show);
    final rows = [
      if (trash)
        VaultSettingRow(
          label: l10n.crateTrash,
          helper: l10n.vaultUiTrashHelp,
          control: vaultButton(
            context,
            key: ValueKey('crate-trash-open-${crate.id}'),
            onPressed: () => open(() => showCrateTrash(context, orchard, crate)),
            icon: LucideIcons.trash2,
            label: l10n.vaultUiOpenTrash,
          ),
        ),
      if (changes)
        VaultSettingRow(
          label: l10n.crateChanges,
          helper: l10n.vaultUiChangesHelp,
          control: vaultButton(
            context,
            key: ValueKey('crate-changes-open-${crate.id}'),
            onPressed: () => open(() => showCrateChanges(context, orchard, crate)),
            icon: LucideIcons.history,
            label: l10n.vaultUiViewChanges,
          ),
        ),
    ];
    // Under the session logs where the card shows them (they open the
    // Records group), else a Records group of its own.
    if (CrateSessionLogsLine.shows(ref, orchard, crate)) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final row in rows) ...[const SizedBox(height: 12), row],
        ],
      );
    }
    return VaultSettingGroup(title: l10n.vaultUiGroupRecords, rows: rows);
  }
}

/// An item's versions (3.0): [kind] and [itemKey] in [crateId] of
/// [orchard], named [name].
Future<void> showItemVersions(
  BuildContext context,
  OrchardSummary orchard,
  String crateId, {
  required String kind,
  required String itemKey,
  required String name,
}) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.history,
    title: l10n.itemVersionsTitle(name.isEmpty ? l10n.crateItemUnnamed : name),
    body: ItemVersionsView(orchard: orchard, crateId: crateId, kind: kind, itemKey: itemKey),
  );
}

class ItemVersionsView extends ConsumerStatefulWidget {
  const ItemVersionsView({
    super.key,
    required this.orchard,
    required this.crateId,
    required this.kind,
    required this.itemKey,
  });

  final OrchardSummary orchard;
  final String crateId;
  final String kind;
  final String itemKey;

  @override
  ConsumerState<ItemVersionsView> createState() => _ItemVersionsViewState();
}

class _ItemVersionsViewState extends ConsumerState<ItemVersionsView> {
  List<ItemVersion>? _versions;
  Object? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    try {
      final versions = await ref
          .read(orchardServiceProvider)
          .itemVersions(widget.orchard.id, widget.crateId, kind: widget.kind, key: widget.itemKey);
      if (mounted) {
        setState(() {
          _versions = versions;
          _error = null;
        });
      }
    } catch (e) {
      AppLogger.info('Orchard versions: not read ($e)');
      if (mounted) setState(() => _error = e);
    }
  }

  Future<void> _putBack(ItemVersion version) async {
    final l10n = AppLocalizations.of(context)!;
    final item = crateItemName(widget.kind, _named(version.name, l10n)).displayIn(ref);
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.crateChangePutBackTitle(item),
      body: l10n.itemVersionPutBackBody,
      confirmLabel: l10n.crateChangePutBackConfirm,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      await ref.read(orchardServiceProvider).putVersionBack(widget.orchard.id, version);
      unawaited(ref.read(orchardSyncSchedulerProvider).syncAll());
      if (mounted) showTopSnackBar(context, l10n.crateChangePutBackDone(item), isSuccess: true);
    } catch (e) {
      AppLogger.warning('Orchard versions: not put back ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    if (error != null) {
      return Text(_loadError(error, l10n),
          key: const ValueKey('item-versions-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final versions = _versions;
    if (versions == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    final crate = widget.orchard.crates.where((c) => c.id == widget.crateId).firstOrNull;
    final mayPutBack = crate != null && crate.allows(CrateSwitches.edit) && widget.orchard.active;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (versions.where((v) => !v.isCurrent).isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l10n.itemVersionsEmpty,
                key: const ValueKey('item-versions-empty'),
                style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
          ),
        for (final (i, v) in versions.indexed)
          Container(
            key: ValueKey('item-version-$i'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border.all(color: v.isCurrent ? AppColors.v3Success : AppColors.v3BorderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(v.record.deleted ? LucideIcons.trash2 : crateItemIcon(widget.kind),
                    size: 15, color: AppColors.v3TextSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        crateItemName(widget.kind, _named(v.name, l10n)),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        l10n.itemVersionBy(_memberName(ref, widget.orchard.id, v.record.author),
                            _when(DateTime.fromMillisecondsSinceEpoch(v.record.editedAt), l10n)),
                        style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (v.isCurrent)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    decoration: BoxDecoration(
                      color: AppColors.v3Success.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(999),
                    ),
                    child: Text(l10n.itemVersionNow,
                        style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: AppColors.v3Success)),
                  )
                else if (!v.record.deleted)
                  TextButton.icon(
                    key: ValueKey('item-version-put-back-$i'),
                    onPressed: mayPutBack && !_busy ? () => _putBack(v) : null,
                    icon: const Icon(LucideIcons.undo2, size: 14),
                    label: Text(l10n.itemVersionPutBack),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

/// The way to an item's versions, where it is shown: for owners and those
/// who manage its Crate, while the team records version history. Nothing
/// in your Tree.
class ItemVersionsLink extends ConsumerWidget {
  const ItemVersionsLink({super.key, required this.kind, required this.itemKey, required this.name});

  final String kind;
  final String itemKey;
  final String name;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final rules = ItemRules.of(ref, kind);
    final orchard = rules.orchard;
    if (orchard == null || !orchard.active) return const SizedBox.shrink();
    final history = ref.watch(teamTrackingProvider(orchard.id)).valueOrNull?.history ?? false;
    if (!history || !rules.allows(itemKey, CrateSwitches.manage)) return const SizedBox.shrink();
    final crateId = rules.crates[itemKey] ?? orchard.defaultCrateId;
    if (crateId == null) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: TextButton.icon(
        key: const ValueKey('item-versions-open'),
        onPressed: () => showItemVersions(context, orchard, crateId, kind: kind, itemKey: itemKey, name: name),
        icon: const Icon(LucideIcons.history, size: 14),
        label: Text(l10n.trackingHistoryTitle),
      ),
    );
  }
}
