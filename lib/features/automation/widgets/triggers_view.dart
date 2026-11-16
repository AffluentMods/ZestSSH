import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/automation/widgets/automation_shared.dart';
import 'package:zestssh/features/automation/widgets/api_key_once_dialog.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/workflow.dart' show Workflow;
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/ui/widgets/button_box.dart';
import 'package:zestssh/l10n/time_ago.dart';

// ══════════════════════════════════════════════════════════════════
// Triggers view - the "Triggers" tab.
//
// Combines the two ways an external caller reaches into automation:
//   1. API keys   - the secrets that authorize external triggers, now with an
//                   optional single-connection SCOPE.
//   2. Deep links - the copyable `zestssh://workflow?...` URL per workflow.
// ══════════════════════════════════════════════════════════════════

class TriggersView extends ConsumerWidget {
  const TriggersView({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final keys = ref.watch(automationKeysProvider);
    // Its links run your Tree's workflows, whichever space is on screen.
    final workflows = ref.watch(automationWorkflowsProvider).valueOrNull ?? const <Workflow>[];

    // Tier-2: the trigger SOURCES share ONE bordered card. Each section is a
    // dense header line (label + count + help glyph) over a single italic
    // empty line (or its rows) - never stacked whole-pane tier-1 empty
    // states.
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(16, 14, 16, 24),
      child: Container(
        padding: const EdgeInsets.all(15),
        decoration: BoxDecoration(
          color: AppColors.v3Background,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: AppColors.v3BorderSubtle, width: 0.5),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // ── 1. API keys ───────────────────────────────────────────
            ZestSectionHeader.category(
              label: l10n.zestAutoSectionApiKeys,
              count: keys.length,
              infoTooltip: l10n.apiKeysEmptyMessage,
            ),
            if (keys.isEmpty)
              // Tier-2 empty: one dense italic line, CTA on the trailing edge.
              ZestEmptyRow(
                message: l10n.apiKeysEmptyTitle,
                padding: EdgeInsets.zero,
                action: _CreateKeyButton(
                  onTap: () => _showCreateApiKeyDialog(context, ref),
                ),
              )
            else ...[
              for (final key in keys)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _ApiKeyRow(apiKey: key),
                ),
              // Keep the create CTA reachable once keys exist (the header no
              // longer carries a trailing action in the tier-2 layout).
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Align(
                  alignment: Alignment.centerRight,
                  child: _CreateKeyButton(
                    onTap: () => _showCreateApiKeyDialog(context, ref),
                  ),
                ),
              ),
            ],

            const SizedBox(height: 18),

            // ── 2. Deep links ─────────────────────────────────────────
            ZestSectionHeader.category(
              label: l10n.zestAutoSectionDeepLinks,
              count: workflows.length,
              infoTooltip: l10n.zestAutoDeepLinksExplainer,
            ),
            if (workflows.isEmpty)
              ZestEmptyRow(
                message: l10n.zestAutoDeepLinksEmpty,
                padding: EdgeInsets.zero,
              )
            else
              for (final wf in workflows)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: _DeepLinkRow(workflowName: wf.name),
                ),
            // (A third section, Webhooks, said "Coming soon" over nothing:
            // gone, as a control with nothing behind it goes (found in the 3.0 docs
            // check).)
          ],
        ),
      ),
    );
  }
}

class _CreateKeyButton extends StatelessWidget {
  const _CreateKeyButton({required this.onTap});
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ButtonBox(
      height: 28,
      child: TextButton.icon(
        onPressed: onTap,
        style: TextButton.styleFrom(
          minimumSize: const Size(64, 28),
          foregroundColor: AppColors.v3AccentInk,
          padding: const EdgeInsets.symmetric(horizontal: 10),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(6),
            side: BorderSide(color: AppColors.v3BorderDefault),
          ),
        ),
        icon: const Icon(LucideIcons.plus, size: 13),
        label: Text(
          l10n.zestAutoCreateApiKey,
          style: const TextStyle(fontSize: 12),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// API-key row (with scope chip)
// ══════════════════════════════════════════════════════════════════

class _ApiKeyRow extends ConsumerStatefulWidget {
  final AutomationApiKey apiKey;

  const _ApiKeyRow({required this.apiKey});

  @override
  ConsumerState<_ApiKeyRow> createState() => _ApiKeyRowState();
}

class _ApiKeyRowState extends ConsumerState<_ApiKeyRow> {
  bool _hovered = false;

  // No Copy here: a key is shown once, when it is made (api_key_once_dialog),
  // and only its hash and last 4 characters are kept.

  Future<void> _revoke() async {
    final l10n = AppLocalizations.of(context)!;
    final ok = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.triggersViewRevokeConfirmTitle(widget.apiKey.label),
      body: l10n.triggersViewRevokeConfirmBody,
      confirmLabel: l10n.triggersViewRevokeConfirmAction,
    );
    if (ok == true) {
      ref.read(automationKeysProvider.notifier).deleteKey(widget.apiKey.id);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final key = widget.apiKey;
    final isExpired = key.isExpired;

    // Resolve the scope chip. null scope = "All connections" (AMBER - broad).
    // A specific scope = a NEUTRAL chip carrying the connection's label.
    final scopeId = key.scopeConnectionId;
    Widget scopeChip;
    if (scopeId == null) {
      scopeChip = AutomationStatusBadge(
        label: l10n.zestAutoScopeAll,
        color: AppColors.v3Warning,
      );
    } else {
      final conns = ref.watch(connectionsWithDetailsProvider).valueOrNull;
      String? matchLabel;
      if (conns != null) {
        for (final c in conns) {
          if (c.connection.id == scopeId) {
            matchLabel = c.connection.label;
            break;
          }
        }
      }
      scopeChip = AutomationStatusBadge(
        label: matchLabel ?? scopeId,
        color: AppColors.v3TextSecondary,
      );
    }

    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _hovered ? AppColors.v3Hover : AppColors.v3Surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderDefault, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.keyRound,
              size: 14,
              color: isExpired ? AppColors.v3Error : AppColors.v3TextSecondary,
            ),
            const SizedBox(width: 10),

            // Label + created + scope
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Flexible(
                        child: Text(
                          key.label,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w500,
                            color: AppColors.v3TextPrimary,
                          ),
                        ),
                      ),
                      const SizedBox(width: 8),
                      scopeChip,
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      // Which key it is: its last 4 characters, all that is
                      // kept beside its hash.
                      RedactedText(
                        Redactable.password(key.displayHint),
                        key: ValueKey('api-key-hint-${key.id}'),
                        style: TextStyle(
                          fontFamily: 'JetBrainsMono',
                          fontSize: 11,
                          color: AppColors.v3TextTertiary,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Flexible(
                        child: Tooltip(
                          message: automationDateTime(l10n, key.createdAt),
                          waitDuration: const Duration(milliseconds: 400),
                          child: Text(
                            l10n.triggersViewCreatedAgo(
                              timeAgoInSentence(l10n, key.createdAt),
                            ),
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 11,
                              color: AppColors.v3TextTertiary,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),

            if (key.lastUsedAt != null)
              Padding(
                padding: const EdgeInsets.only(right: 16),
                child: Tooltip(
                  message: automationDateTime(l10n, key.lastUsedAt!),
                  waitDuration: const Duration(milliseconds: 400),
                  child: Text(
                    l10n.triggersViewUsedAgo(
                      timeAgoInSentence(l10n, key.lastUsedAt!),
                    ),
                    style: TextStyle(
                      fontSize: 11,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ),
              ),

            AutomationStatusBadge(
              label: automationKeyExpiry(l10n, key),
              color: isExpired ? AppColors.v3Error : AppColors.v3Success,
            ),
            const SizedBox(width: 10),

            Tooltip(
              message: l10n.triggersViewRevokeTooltip,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _revoke,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    LucideIcons.trash2,
                    size: 14,
                    color: AppColors.v3Error,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Deep-link row (per workflow)
// ══════════════════════════════════════════════════════════════════

class _DeepLinkRow extends StatefulWidget {
  const _DeepLinkRow({required this.workflowName});
  final String workflowName;

  @override
  State<_DeepLinkRow> createState() => _DeepLinkRowState();
}

class _DeepLinkRowState extends State<_DeepLinkRow> {
  bool _hovered = false;

  String get _url =>
      'zestssh://workflow?name=${Uri.encodeComponent(widget.workflowName)}'
      '&key=YOUR_KEY';

  Future<void> _copy() async {
    final l10n = AppLocalizations.of(context)!;
    final url = _url;
    // Mirror the API-key copy: cleared after 45s if the clipboard still holds
    // this URL (the URL carries a YOUR_KEY placeholder, but users often paste a
    // real key in place before it lands anywhere, so treat it like a secret).
    await SecretClipboard.copy(url);
    if (!mounted) return;
    showTopSnackBar(
      context,
      l10n.zestAutoUrlCopied,
      duration: const Duration(seconds: 2),
    );
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
        decoration: BoxDecoration(
          color: _hovered ? AppColors.v3Hover : AppColors.v3Surface,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderDefault, width: 0.5),
        ),
        child: Row(
          children: [
            Icon(
              LucideIcons.workflow,
              size: 14,
              color: AppColors.v3TextSecondary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.workflowName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                      color: AppColors.v3TextPrimary,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    _url,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontFamily: 'JetBrainsMono',
                      fontSize: 11,
                      color: AppColors.v3TextTertiary,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Tooltip(
              message: l10n.zestAutoCopyUrl,
              child: InkWell(
                borderRadius: BorderRadius.circular(4),
                onTap: _copy,
                child: Padding(
                  padding: const EdgeInsets.all(4),
                  child: Icon(
                    LucideIcons.copy,
                    size: 14,
                    color: AppColors.v3TextSecondary,
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Create-API-key dialog (with scope selector)
// ══════════════════════════════════════════════════════════════════

/// Name a new API key, optionally set expiry + a single-connection scope, then
/// persist it. On success, opens the "show key once" panel.
Future<void> _showCreateApiKeyDialog(
  BuildContext context,
  WidgetRef ref,
) async {
  final dialog = GlobalKey<_CreateApiKeyDialogState>();
  final created = await showZestModal<({AutomationApiKey key, String secret})>(
    context: context,
    size: ZestModalSize.compact,
    onSubmit: () => dialog.currentState?._create(),
    child: _CreateApiKeyDialog(key: dialog),
  );
  if (created == null || !context.mounted) return;
  await showApiKeyOnceDialog(context, apiKey: created.key, secret: created.secret);
}

class _CreateApiKeyDialog extends ConsumerStatefulWidget {
  const _CreateApiKeyDialog({super.key});

  @override
  ConsumerState<_CreateApiKeyDialog> createState() =>
      _CreateApiKeyDialogState();
}

class _CreateApiKeyDialogState extends ConsumerState<_CreateApiKeyDialog> {
  final _labelController = TextEditingController();

  /// Days until expiry. Null = never. Defaults to 90 (a default expiry is good
  /// hygiene - forgotten long-lived secrets are the #1 cause of key leaks).
  int? _expiresInDays = 90;

  /// null = ALL connections (unrestricted, the default). Non-null = the key is
  /// restricted to that single connection.
  String? _scopeConnectionId;
  String? _scopeLabel;

  /// What is wrong with the name, under its field (it was a toast).
  String? _labelError;
  var _closing = false;

  @override
  void dispose() {
    _labelController.dispose();
    super.dispose();
  }

  Future<void> _pickScope() async {
    final l10n = AppLocalizations.of(context)!;
    final res = await ConnectionPickerDialog.show(
      context,
      title: l10n.zestAutoScopeChoose,
    );
    final picked = res.connection;
    if (picked != null) {
      setState(() {
        _scopeConnectionId = picked.connection.id;
        _scopeLabel = picked.connection.label;
      });
    }
  }

  void _create() {
    if (_closing) return;
    final l10n = AppLocalizations.of(context)!;
    final label = _labelController.text.trim();
    if (label.isEmpty) {
      setState(() => _labelError = l10n.triggersViewLabelRequired);
      return;
    }
    // Defence-in-depth: the field caps at 64, but re-check here so a
    // programmatic bypass can't push a huge label into the store.
    if (label.length > 64) {
      setState(() => _labelError = l10n.triggersViewLabelTooLong(label.length));
      return;
    }
    _closing = true;
    final notifier = ref.read(automationKeysProvider.notifier);
    final expiresAt = _expiresInDays == null
        ? null
        : DateTime.now().add(Duration(days: _expiresInDays!));
    final created = notifier.createKey(
      label,
      expiresAt: expiresAt,
      scopeConnectionId: _scopeConnectionId,
    );
    Navigator.of(context).pop(created);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The app's dialog (3.4): the name's error under its field, Create in
    // the footer.
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.zestAutoCreateApiKey,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            l10n.triggersViewCreateKeyExplainer,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.v3TextSecondary,
              height: 1.4,
            ),
          ),
          const SizedBox(height: 16),
          ZestTextField(
            controller: _labelController,
            label: l10n.triggersViewLabelField,
            hintText: l10n.triggersViewLabelHint,
            errorText: _labelError,
            inputFormatters: [LengthLimitingTextInputFormatter(64)],
            onChanged: (_) {
              if (_labelError != null) setState(() => _labelError = null);
            },
            onSubmit: _create,
          ),
          const SizedBox(height: 16),
          Text(
            l10n.triggersViewExpiresIn,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.v3TextSecondary,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              _ExpiryChip(
                label: l10n.triggersViewExpiry30Days,
                selected: _expiresInDays == 30,
                onTap: () => setState(() => _expiresInDays = 30),
              ),
              _ExpiryChip(
                label: l10n.triggersViewExpiry90Days,
                selected: _expiresInDays == 90,
                onTap: () => setState(() => _expiresInDays = 90),
              ),
              _ExpiryChip(
                label: l10n.triggersViewExpiry180Days,
                selected: _expiresInDays == 180,
                onTap: () => setState(() => _expiresInDays = 180),
              ),
              _ExpiryChip(
                label: l10n.triggersViewExpiry1Year,
                selected: _expiresInDays == 365,
                onTap: () => setState(() => _expiresInDays = 365),
              ),
              _ExpiryChip(
                label: l10n.triggersViewExpiryNever,
                selected: _expiresInDays == null,
                onTap: () => setState(() => _expiresInDays = null),
              ),
            ],
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              Text(
                l10n.zestAutoScopeLabel,
                style: TextStyle(
                  fontSize: 12,
                  color: AppColors.v3TextSecondary,
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.zestAutoScopeHelp,
                  style: TextStyle(
                    fontSize: 11,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 6,
            children: [
              _ExpiryChip(
                label: l10n.zestAutoScopeAll,
                selected: _scopeConnectionId == null,
                onTap: () => setState(() {
                  _scopeConnectionId = null;
                  _scopeLabel = null;
                }),
              ),
              _ExpiryChip(
                label: _scopeConnectionId == null
                    ? l10n.zestAutoScopeSpecific
                    : _scopeLabel!,
                selected: _scopeConnectionId != null,
                onTap: _pickScope,
              ),
            ],
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      primaryKey: const ValueKey('create-api-key-go'),
      primaryAction: (label: l10n.create, icon: null, onPressed: _create),
    );
  }
}

class _ExpiryChip extends StatelessWidget {
  const _ExpiryChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });
  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
          decoration: BoxDecoration(
            color: selected
                ? AppColors.v3AccentPrimary.withValues(alpha: 0.15)
                : AppColors.v3Surface,
            borderRadius: BorderRadius.circular(13),
            border: Border.all(
              color: selected
                  ? AppColors.v3AccentPrimary
                  : AppColors.v3BorderDefault,
              width: selected ? 1.0 : 0.5,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: selected
                  ? AppColors.v3AccentInk
                  : AppColors.v3TextPrimary,
            ),
          ),
        ),
      ),
    );
  }
}
