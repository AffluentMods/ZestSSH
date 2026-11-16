import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/triggers/trigger_engine.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/trigger_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/triggers/widgets/trigger_edit_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// Open the create/edit dialog for a trigger rule and persist the result.
Future<void> openTriggerEditor(
  BuildContext context,
  WidgetRef ref, {
  TerminalTrigger? trigger,
}) async {
  final connections =
      ref.read(triggerScopeConnectionsProvider).valueOrNull ?? const [];
  final result = await showTriggerEditDialog(
    context: context,
    trigger: trigger,
    connections: connections,
  );
  if (result == null) return;
  final crud = ref.read(triggerCrudProvider);
  if (trigger == null) {
    await crud.create(
      name: result.name,
      pattern: result.pattern,
      caseSensitive: result.caseSensitive,
      notify: result.notify,
      highlight: result.highlight,
      highlightColor: result.highlightColor,
      playSound: result.playSound,
      connectionId: result.connectionId,
      enabled: result.enabled,
    );
  } else {
    await crud.update(
      id: trigger.id,
      name: result.name,
      pattern: result.pattern,
      caseSensitive: result.caseSensitive,
      notify: result.notify,
      highlight: result.highlight,
      highlightColor: result.highlightColor,
      playSound: result.playSound,
      connectionId: result.connectionId,
      enabled: result.enabled,
    );
  }
}

/// Management screen for trigger / highlight rules (Settings -> Triggers).
class TriggersScreen extends ConsumerWidget {
  const TriggersScreen({super.key, this.embedded = false});

  /// When true, render without a Scaffold/AppBar so the screen can sit inside
  /// a desktop section (the Terminal tools hub). The "New trigger" action
  /// moves to an inline toolbar row. Mobile keeps the default full screen.
  final bool embedded;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final triggersAsync = ref.watch(triggersProvider);
    final content = triggersAsync.when(
      // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
      skipLoadingOnReload: true,
      loading: () => const Center(child: CircularProgressIndicator()),
      error: (_, _) => Center(
        child: Text(l10n.trgLoadError,
            style: TextStyle(color: AppColors.textSecondary)),
      ),
      data: (triggers) {
        if (triggers.isEmpty) return _empty(context, ref);
        final connections =
            ref.watch(triggerScopeConnectionsProvider).valueOrNull ??
                const [];
        final labels = {for (final c in connections) c.id: c.label};
        return ListView.builder(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 24),
          itemCount: triggers.length,
          itemBuilder: (context, i) =>
              _TriggerTile(triggers[i], labels: labels),
        );
      },
    );

    if (embedded) {
      return Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 10, 16, 6),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: () => openTriggerEditor(context, ref),
                icon: const Icon(LucideIcons.plus, size: 16),
                label: Text(l10n.trgNewTrigger),
                style: OutlinedButton.styleFrom(
                  foregroundColor: AppColors.accentInk,
                  side: BorderSide(
                      color: AppColors.brandOrange.withValues(alpha: 0.45)),
                ),
              ),
            ),
          ),
          Expanded(child: content),
        ],
      );
    }

    return Scaffold(
      appBar: AppBar(
        title: Text(l10n.trgTitle),
        actions: [
          const GuideHelpButton(feature: 'alerts', size: 20),
          IconButton(
            tooltip: l10n.trgNewTrigger,
            icon: const Icon(LucideIcons.plus),
            onPressed: () => openTriggerEditor(context, ref),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: content,
    );
  }

  Widget _empty(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.bellRing,
      title: l10n.trgEmptyTitle,
      message: l10n.trgEmptyMessage,
      action: Wrap(
        alignment: WrapAlignment.center,
        spacing: 12,
        runSpacing: 10,
        children: [
          // As every empty state's button: 36 high (a finger's 48 where the
          // app is touch sized), corners of 6 (they were pills of their own).
          ButtonBox(
            height: zestEmptyStateButtonHeight(context),
            child: FilledButton.icon(
              onPressed: () => openTriggerEditor(context, ref),
              icon: const Icon(LucideIcons.plus, size: 16),
              label: Text(l10n.trgNewTrigger),
              style: FilledButton.styleFrom(
                backgroundColor: AppColors.v3AccentPrimary,
                foregroundColor: AppColors.onBrand(AppColors.v3AccentPrimary),
                minimumSize: Size(64, zestEmptyStateButtonHeight(context)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
          ButtonBox(
            height: zestEmptyStateButtonHeight(context),
            child: OutlinedButton.icon(
              onPressed: () => _seedExamples(context, ref),
              icon: const Icon(LucideIcons.sparkles, size: 16),
              label: Text(l10n.trgAddExamples),
              // Beside the one primary, the neutral secondary (it was
              // outlined in the accent).
              style: OutlinedButton.styleFrom(
                minimumSize: Size(64, zestEmptyStateButtonHeight(context)),
                padding: const EdgeInsets.symmetric(horizontal: 16),
                textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w600),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _seedExamples(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final crud = ref.read(triggerCrudProvider);
    await crud.create(
      name: l10n.trgExampleErrorName,
      pattern: r'(?i)\b(error|failed|fatal)\b',
      notify: true,
      highlight: true,
      highlightColor: 0xFFEF4444,
    );
    await crud.create(
      name: l10n.trgExampleBuildFinishedName,
      // Match what build tools actually print: vite/npm "built in 1.2s",
      // webpack/tsc "compiled successfully", and the generic "build finished".
      pattern:
          r'(?i)(built in|build (succeeded|successful|finished|complete|done)|compiled successfully)',
      notify: true,
      playSound: true,
    );
    await crud.create(
      name: l10n.trgExampleWarningName,
      pattern: r'(?i)\bwarn(ing)?\b',
      notify: false,
      highlight: true,
      highlightColor: 0xFFEAB308,
    );
  }
}

class _TriggerTile extends ConsumerWidget {
  final TerminalTrigger trigger;
  final Map<String, String> labels;

  const _TriggerTile(this.trigger, {required this.labels});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final scopeConnId = trigger.connectionId;
    final scopeLabel = scopeConnId == null ? null : labels[scopeConnId];
    final dim = !trigger.enabled;
    final highlightColor =
        Color(trigger.highlightColor ?? kTriggerHighlightPresets.first);
    // The tile's identity colour: the highlight colour when this rule paints
    // the terminal, otherwise the brand accent (a notify-only rule).
    final railColor =
        trigger.highlight ? highlightColor : AppColors.v3AccentPrimary;

    return Card(
      margin: const EdgeInsets.symmetric(vertical: 4),
      child: Opacity(
        opacity: dim ? 0.55 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(12),
          onTap: () => openTriggerEditor(context, ref, trigger: trigger),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 12, 6, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 3,
                  height: 46,
                  margin: const EdgeInsets.only(right: 12, top: 1),
                  decoration: BoxDecoration(
                    color: railColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Flexible(
                            child: Text(
                              trigger.name,
                              style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.w600,
                                  color: AppColors.onSurface),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                          const SizedBox(width: 8),
                          if (trigger.notify)
                            _actionIcon(
                                LucideIcons.bell, AppColors.v3AccentPrimary),
                          if (trigger.playSound)
                            _actionIcon(
                                LucideIcons.volume2, AppColors.textSecondary),
                          if (trigger.highlight)
                            _actionIcon(
                                LucideIcons.highlighter, highlightColor),
                        ],
                      ),
                      const SizedBox(height: 5),
                      Text(
                        trigger.pattern,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 12,
                          height: 1.3,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      // A pattern this app will not run, written here or by a
                      // teammate.
                      if (triggerPatternRefused(trigger.pattern, caseSensitive: trigger.caseSensitive)) ...[
                        const SizedBox(height: 5),
                        Text(
                          l10n.trgPatternRefused,
                          key: ValueKey('alert-refused-${trigger.id}'),
                          style: TextStyle(fontSize: 11.5, height: 1.35, color: AppColors.warning),
                        ),
                      ],
                      const SizedBox(height: 6),
                      // Redactable: the per-host scope shows a fleet host label,
                      // which recording mode must mask.
                      if (scopeConnId == null)
                        Text(l10n.commonAllHosts,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary))
                      else if (scopeLabel == null || scopeLabel.isEmpty)
                        Text(l10n.trgUnknownHost,
                            style: TextStyle(
                                fontSize: 11.5,
                                color: AppColors.textSecondary))
                      else
                        RedactedText(
                          Redactable.host(scopeLabel),
                          style: TextStyle(
                              fontSize: 11.5, color: AppColors.textSecondary),
                        ),
                    ],
                  ),
                ),
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ZestSwitch(value: trigger.enabled, onChanged: (v) => ref
                          .read(triggerCrudProvider)
                          .setEnabled(trigger.id, v)),
                    _menu(context, ref),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _actionIcon(IconData icon, Color color) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Icon(icon, size: 14, color: color),
      );

  Widget _menu(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return PopupMenuButton<String>(
      icon: const Icon(LucideIcons.moreHorizontal, size: 18),
      onSelected: (action) async {
        switch (action) {
          case 'edit':
            await openTriggerEditor(context, ref, trigger: trigger);
          case 'delete':
            await _confirmDelete(context, ref);
        }
      },
      itemBuilder: (_) => [
        PopupMenuItem(value: 'edit', child: Text(l10n.edit)),
        PopupMenuItem(
          value: 'delete',
          child: Text(l10n.delete,
              style: TextStyle(color: AppColors.error)),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.trgDeleteTitle,
      body: l10n.trgDeleteConfirm(trigger.name),
      confirmLabel: l10n.delete,
    );
    if (ok == true) {
      await ref.read(triggerCrudProvider).delete(trigger.id);
    }
  }
}
