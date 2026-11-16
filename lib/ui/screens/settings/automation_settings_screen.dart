import 'package:zestssh/ui/screens/settings/widgets/settings_section.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';

import '../../../features/automation/automation_switch.dart';
import '../help/setup_guide_screen.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../models/automation_api_key.dart';
import '../../../models/redactable.dart';
import '../../../providers/automation_provider.dart';
import '../../../providers/purchase_providers.dart';
import '../purchase/plan_popover.dart' show PlanChip;
import '../../../providers/settings_providers.dart';
import '../../../router/routes.dart';
import '../../../theme/app_colors.dart';
import '../../../theme/desktop_dimensions.dart';
import '../../../utils/platform_utils.dart';
import '../../widgets/redacted_text.dart';
import '../../widgets/responsive_scaffold.dart';
import '../../widgets/top_snackbar.dart';
import '../../widgets/zest_dialog.dart';
import '../../widgets/zest_empty_state.dart';
import 'package:zestssh/features/automation/widgets/automation_shared.dart' show automationKeyExpiry;
import 'package:zestssh/features/automation/widgets/api_key_once_dialog.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/phone_list.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// Drill-down screen for external automation (Pro). Reached from the mobile
/// settings root (Automation category row). The Triggers / Command History
/// rows live under Terminal now; this screen keeps the external-automation API
/// surface (keys, guide, history, wizard, workflows, scheduled tasks).
class AutomationSettingsScreen extends ConsumerWidget {
  const AutomationSettingsScreen({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final isPro = ref.watch(isProProvider);
    final automationEnabled = ref.watch(automationEnabledProvider);

    return ResponsiveScaffold(
      title: l10n.settingsMobAutomation,
      maxWidth: isDesktopPlatform ? DesktopDimensions.settingsMaxWidth : 680,
      actions: const [SetupGuideButton(SetupTopic.automation)],
      body: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        children: [
          _Section(
            // The page's one section: its name is the page's own.
            title: null,
            child: Column(
              children: [
                // Triggers and Command history moved to their own rows in the
                // Utilities tab, so they are no longer duplicated here.
                SwitchListTile(
                  // The badge after the name, so the name keeps the row's
                  // width (beside it, a long name was cut on a phone).
                  title: Text.rich(TextSpan(
                    text: l10n.settingsMobExternalAutomation,
                    children: [
                      if (!isPro) ...[
                        const TextSpan(text: '\u00A0'),
                        // What it needs, which says what Squeezed is when
                        // tapped (the plan's chip, 4.0).
                        const WidgetSpan(
                          alignment: PlaceholderAlignment.middle,
                          child: PlanChip(
                            key: ValueKey('automation-tier-badge'),
                            plan: AccountPlan.squeezed,
                          ),
                        ),
                      ],
                    ],
                  )),
                  subtitle: Text(l10n.settingsMobExternalAutomationDesc),
                  secondary: Opacity(opacity: isPro ? 1 : 0.4, child: const PhoneIconTile(LucideIcons.bot)),
                  value: automationEnabled,
                  onChanged: isPro ? (v) => setAutomationOn(context, ref, v) : null,
                ),

                // API Keys: visible when Pro and automation is enabled
                if (isPro && automationEnabled)
                  Builder(
                    builder: (context) {
                      final keys = ref.watch(automationKeysProvider);
                      final count = keys.length;
                      return ListTile(
                        title: Text(l10n.settingsMobApiKeys),
                        subtitle: Text(
                          count == 0
                              ? l10n.settingsMobNoKeys
                              : l10n.settingsMobKeyCount(count),
                          // A count, not a value to copy: the app's own type
                          // on a phone and a tablet (3.0 quick wins).
                          style: TextStyle(
                            fontFamily: isTouchLayout ? null : 'JetBrainsMono',
                            fontSize: 12,
                          ),
                        ),
                        leading: const PhoneIconTile(LucideIcons.keyRound),
                        trailing: const Icon(LucideIcons.chevronRight),
                        onTap: () {
                          Navigator.push(
                            context,
                            MaterialPageRoute<void>(
                              builder: (_) => const _ApiKeyManagementScreen(),
                            ),
                          );
                        },
                      );
                    },
                  ),

                // Guide & History: always visible when Pro (regardless of toggle)
                if (isPro)
                  ListTile(
                    title: Text(l10n.settingsMobAutomationGuide),
                    subtitle: Text(l10n.settingsMobAutomationGuideDesc),
                    leading: const PhoneIconTile(LucideIcons.bookOpen),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => context.push(Routes.automationGuide),
                  ),

                if (isPro)
                  ListTile(
                    title: Text(l10n.settingsMobAutomationHistory),
                    subtitle: Text(l10n.settingsMobAutomationHistoryDesc),
                    leading: const PhoneIconTile(LucideIcons.history),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => context.push(Routes.automationHistory),
                  ),

                // The wizard builds links and intents for other apps: only
                // when automation lets them in.
                if (isPro && automationEnabled)
                  ListTile(
                    title: Text(l10n.settingsMobAutomationWizard),
                    subtitle: Text(l10n.settingsMobAutomationWizardDesc),
                    leading: const PhoneIconTile(LucideIcons.wand2),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => context.push(Routes.automationWizard),
                  ),

                // Workflows are run by their person here with Squeezed alone,
                // whatever the switch for other apps says, as a computer runs
                // them (they were hidden while it was off).
                if (isPro)
                  ListTile(
                    key: const ValueKey('automation-workflows-row'),
                    title: Text(l10n.settingsMobWorkflows),
                    subtitle: Text(l10n.settingsMobWorkflowsDesc),
                    leading: const PhoneIconTile(LucideIcons.gitFork),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => context.push(Routes.workflowList),
                  ),

                if (isPro && automationEnabled)
                  ListTile(
                    title: Text(l10n.settingsMobScheduledTasks),
                    subtitle: Text(l10n.settingsMobScheduledTasksDesc),
                    leading: const PhoneIconTile(LucideIcons.clock),
                    trailing: const Icon(LucideIcons.chevronRight),
                    onTap: () => context.push(Routes.scheduledTasks),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Section header matching the app's settings sub-screens (orange bar + label).
class _Section extends StatelessWidget {
  final String? title;
  final Widget child;

  const _Section({required this.title, required this.child});

  // The 3.0 look every phone settings page shares (widgets/settings_section.dart).
  @override
  Widget build(BuildContext context) => SettingsSection(title: title, child: child);
}

// ═══════════════════════════════════════════════════════════════════════
// API Key Management Screen (moved from settings_screen.dart - mobile only)
// ═══════════════════════════════════════════════════════════════════════

class _ApiKeyManagementScreen extends ConsumerWidget {
  const _ApiKeyManagementScreen();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final keys = ref.watch(automationKeysProvider);

    return Scaffold(
      backgroundColor: AppColors.background,
      appBar: AppBar(
        title: Text(l10n.settingsMobApiKeys),
        backgroundColor: Colors.transparent,
        elevation: 0,
        actions: [
          const GuideHelpButton(feature: 'api_keys', size: 20),
          IconButton(
            icon: const Icon(LucideIcons.plus),
            tooltip: l10n.settingsMobCreateApiKey,
            onPressed: () => _showCreateDialog(context, ref),
          ),
        ],
      ),
      body: keys.isEmpty
          ? ZestEmptyState(
              icon: LucideIcons.keyRound,
              title: l10n.apiKeysEmptyTitle,
              message: l10n.apiKeysEmptyMessage,
              actionLabel: l10n.apiKeysEmptyAction,
              onAction: () => _showCreateDialog(context, ref),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
              itemCount: keys.length,
              separatorBuilder: (_, _) => const SizedBox(height: 8),
              itemBuilder: (context, index) {
                final apiKey = keys[index];
                return _ApiKeyCard(apiKey: apiKey);
              },
            ),
    );
  }

  void _showCreateDialog(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final labelController = TextEditingController();
    String expiryOption = 'never';

    void create(BuildContext ctx) {
      final label = labelController.text.trim();
      if (label.isEmpty) return;

      DateTime? expiresAt;
      if (expiryOption == '30') {
        expiresAt = DateTime.now().add(const Duration(days: 30));
      } else if (expiryOption == '60') {
        expiresAt = DateTime.now().add(const Duration(days: 60));
      } else if (expiryOption == '90') {
        expiresAt = DateTime.now().add(const Duration(days: 90));
      } else if (expiryOption != 'never' && expiryOption != 'custom') {
        expiresAt = DateTime.tryParse(expiryOption);
      }

      final created = ref.read(automationKeysProvider.notifier).createKey(label, expiresAt: expiresAt);
      Navigator.pop(ctx);
      // The one time the key is shown: only its hash is kept. (The next step,
      // once this one is closed: not a dialog over it.)
      showApiKeyOnceDialog(context, apiKey: created.key, secret: created.secret);
    }

    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: StatefulBuilder(
        builder: (ctx, setDialogState) => ZestDialogShell(
          size: ZestModalSize.compact,
          tone: ZestDialogTone.neutral,
          icon: LucideIcons.keyRound,
          title: l10n.settingsMobCreateApiKey,
          body: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              TextField(
                controller: labelController,
                autofocus: true,
                textCapitalization: TextCapitalization.words,
                decoration: InputDecoration(
                  labelText: l10n.settingsMobLabel,
                  hintText: l10n.settingsMobApiKeyLabelHint,
                  border: const OutlineInputBorder(),
                ),
              ),
              const SizedBox(height: 16),
              Text(l10n.settingsMobExpiration,
                  style: TextStyle(
                      fontSize: 13, color: AppColors.textSecondary)),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: [
                  for (final opt in [
                    ('never', l10n.settingsMobNever),
                    ('30', l10n.settingsMobExpiryDays(30)),
                    ('60', l10n.settingsMobExpiryDays(60)),
                    ('90', l10n.settingsMobExpiryDays(90)),
                    ('custom', l10n.settingsMobCustom),
                  ])
                    ChoiceChip(
                      label: Text(opt.$2, style: const TextStyle(fontSize: 12)),
                      selected: expiryOption == opt.$1,
                      onSelected: (selected) async {
                        if (opt.$1 == 'custom' && selected) {
                          final picked = await showDatePicker(
                            context: ctx,
                            initialDate:
                                DateTime.now().add(const Duration(days: 30)),
                            firstDate:
                                DateTime.now().add(const Duration(days: 1)),
                            lastDate:
                                DateTime.now().add(const Duration(days: 365)),
                          );
                          if (picked != null) {
                            setDialogState(() =>
                                expiryOption = picked.toIso8601String());
                          }
                        } else {
                          setDialogState(() => expiryOption = opt.$1);
                        }
                      },
                      showCheckmark: false,
                      visualDensity: VisualDensity.compact,
                    ),
                ],
              ),
              if (expiryOption != 'never' &&
                  expiryOption != '30' &&
                  expiryOption != '60' &&
                  expiryOption != '90' &&
                  expiryOption != 'custom')
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text(
                    l10n.settingsMobExpiresOn(DateTime.parse(expiryOption)
                        .toString()
                        .substring(0, 10)),
                    style: TextStyle(
                        fontSize: 12, color: AppColors.textSecondary),
                  ),
                ),
            ],
          ),
          secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(ctx)),
          primaryAction: (label: l10n.create, icon: null, onPressed: () => create(ctx)),
        ),
      ),
    );
  }
}

class _ApiKeyCard extends ConsumerWidget {
  final AutomationApiKey apiKey;

  const _ApiKeyCard({required this.apiKey});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return Card(
      color: AppColors.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: AppColors.divider),
      ),
      elevation: 0,
      // No tap to copy: a key is shown once, when it is made, and only its
      // hash and last 4 characters are kept.
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        child: Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    apiKey.label,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: AppColors.onSurface,
                    ),
                  ),
                  const SizedBox(height: 4),
                  RedactedText(
                    Redactable.password(apiKey.displayHint),
                    key: ValueKey('api-key-hint-${apiKey.id}'),
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 12,
                      color: AppColors.onSurfaceDim,
                    ),
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Text(
                        l10n.settingsMobCreatedTime(
                            timeAgoInSentence(l10n, apiKey.createdAt)),
                        style: TextStyle(
                          fontSize: 11,
                          color: AppColors.textSecondary,
                        ),
                      ),
                      const SizedBox(width: 12),
                      Text(
                        apiKey.lastUsedAt != null
                            ? l10n.settingsMobUsedTime(
                                timeAgoInSentence(l10n, apiKey.lastUsedAt!))
                            : l10n.settingsMobNeverUsed,
                        style: TextStyle(
                          fontSize: 11,
                          color: apiKey.lastUsedAt != null
                              ? AppColors.textSecondary
                              : AppColors.onSurfaceDim,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    automationKeyExpiry(l10n, apiKey),
                    style: TextStyle(
                      fontSize: 11,
                      color: apiKey.isExpired
                          ? AppColors.error
                          : (apiKey.daysUntilExpiry != null &&
                                  apiKey.daysUntilExpiry! <= 7)
                              ? AppColors.warning
                              : AppColors.textSecondary,
                    ),
                  ),
                ],
              ),
            ),
            PopupMenuButton<String>(
              icon: Icon(LucideIcons.moreVertical,
                  size: 20, color: AppColors.onSurfaceVariant),
              onSelected: (action) {
                switch (action) {
                  case 'rename':
                    _showRenameDialog(context, ref);
                  case 'delete':
                    _showDeleteConfirmation(context, ref);
                }
              },
              itemBuilder: (_) => [
                PopupMenuItem(
                  value: 'rename',
                  child: Row(
                    children: [
                      const Icon(LucideIcons.pencil, size: 18),
                      const SizedBox(width: 8),
                      Text(l10n.commonRename),
                    ],
                  ),
                ),
                PopupMenuItem(
                  value: 'delete',
                  child: Row(
                    children: [
                      Icon(LucideIcons.trash2,
                          size: 18, color: AppColors.error),
                      const SizedBox(width: 8),
                      Text(l10n.delete,
                          style: TextStyle(color: AppColors.error)),
                    ],
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showRenameDialog(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    // One field: the shell's input dialog, an empty name said under it.
    final newLabel = await showZestInputDialog(
      context: context,
      title: l10n.settingsMobRenameApiKey,
      subtitle: l10n.settingsMobRenameApiKeySubtitle(apiKey.label),
      icon: LucideIcons.pencil,
      fieldLabel: l10n.settingsMobLabel,
      hintText: l10n.settingsMobRenameApiKeyHint,
      initialValue: apiKey.label,
      confirmLabel: l10n.commonRename,
      validator: (v) => v.trim().isEmpty ? l10n.settingsMobRequired : null,
    );
    if (newLabel == null) return;
    ref.read(automationKeysProvider.notifier).renameKey(apiKey.id, newLabel.trim());
  }

  Future<void> _showDeleteConfirmation(BuildContext context, WidgetRef ref) async {
    final l10n = AppLocalizations.of(context)!;
    // The app's own question (it was a plain dialog built here).
    final sure = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.settingsMobDeleteKey,
      body: l10n.settingsMobDeleteKeyBody(apiKey.label),
      confirmLabel: l10n.delete,
    );
    if (sure != true) return;
    ref.read(automationKeysProvider.notifier).deleteKey(apiKey.id);
    if (context.mounted) showTopSnackBar(context, l10n.settingsMobKeyDeleted(apiKey.label));
  }
}
