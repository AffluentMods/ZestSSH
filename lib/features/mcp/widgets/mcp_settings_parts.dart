import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/mcp/mcp_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

// The parts of Settings > AI apps (4.1) that are more than a switch:
// whether the server is listening, the token, the setup to paste into an AI
// app and what AI apps did.

/// Whether the server listens, and where; or why it does not.
class McpStatusText extends ConsumerWidget {
  const McpStatusText({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final status = ref.watch(mcpServerProvider);
    final (text, color) = switch (status) {
      McpOff() => (l10n.mcpStatusOff, AppColors.v3TextSecondary),
      McpStarting() => (l10n.mcpStatusStarting, AppColors.v3TextSecondary),
      McpListening(:final port) => (l10n.mcpStatusListening(mcpUrl(port)), AppColors.success),
      McpFailed(:final port, :final inUse) =>
        (inUse ? l10n.mcpStatusInUse(port) : l10n.mcpStatusFailed, AppColors.error),
    };
    return SelectableText(
      text,
      key: const ValueKey('mcp-status'),
      style: TextStyle(fontSize: 13, color: color),
    );
  }
}

/// Copy the token, or make a new one.
class McpTokenButtons extends ConsumerWidget {
  const McpTokenButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final token = ref.watch(mcpTokenProvider).valueOrNull;
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ZestButton(
          key: const ValueKey('mcp-copy-token'),
          label: l10n.mcpCopyToken,
          icon: LucideIcons.copy,
          size: ZestButtonSize.medium,
          variant: ZestButtonVariant.secondary,
          onPressed: token == null ? null : () => _copy(context, l10n, token),
        ),
        ZestButton(
          key: const ValueKey('mcp-new-token'),
          label: l10n.mcpNewToken,
          icon: LucideIcons.refreshCw,
          size: ZestButtonSize.medium,
          variant: ZestButtonVariant.secondary,
          onPressed: token == null
              ? null
              : () async {
                  final yes = await ZestConfirmDialog.show(
                    context,
                    tone: ZestDialogTone.neutral,
                    title: l10n.mcpNewTokenTitle,
                    body: l10n.mcpNewTokenBody,
                    confirmLabel: l10n.mcpNewToken,
                  );
                  if (yes == true) await ref.read(mcpTokenProvider.notifier).renew();
                },
        ),
      ],
    );
  }
}

/// The setup an AI app takes, with the token in it.
class McpSetupButtons extends ConsumerWidget {
  const McpSetupButtons({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final token = ref.watch(mcpTokenProvider).valueOrNull;
    final url = mcpUrl(ref.watch(mcpPortProvider));
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        ZestButton(
          key: const ValueKey('mcp-copy-claude-code'),
          label: l10n.mcpCopyClaudeCode,
          icon: LucideIcons.terminal,
          size: ZestButtonSize.medium,
          variant: ZestButtonVariant.secondary,
          onPressed: token == null ? null : () => _copy(context, l10n, mcpClaudeCodeCommand(url, token)),
        ),
        ZestButton(
          key: const ValueKey('mcp-copy-json'),
          label: l10n.mcpCopyJson,
          icon: LucideIcons.braces,
          size: ZestButtonSize.medium,
          variant: ZestButtonVariant.secondary,
          onPressed: token == null ? null : () => _copy(context, l10n, mcpJsonConfig(url, token)),
        ),
      ],
    );
  }
}

/// The command that adds ZestSSH to Claude Code.
String mcpClaudeCodeCommand(String url, String token) =>
    'claude mcp add --transport http zestssh $url --header "Authorization: Bearer $token"';

/// The JSON most AI apps take (Cursor, VS Code, Windsurf and others): a
/// server by its URL, with the token as a header.
String mcpJsonConfig(String url, String token) => const JsonEncoder.withIndent('  ').convert({
      'mcpServers': {
        'zestssh': {
          'type': 'http',
          'url': url,
          'headers': {'Authorization': 'Bearer $token'},
        },
      },
    });

Future<void> _copy(BuildContext context, AppLocalizations l10n, String text) async {
  await SecretClipboard.copy(text, life: const Duration(minutes: 3));
  if (context.mounted) {
    showTopSnackBar(context, clearsSoon(l10n, l10n.mcpCopied, note: l10n.mcpCopiedNote));
  }
}

/// What AI apps did, newest first: the last 20 entries.
class McpActivityList extends ConsumerWidget {
  const McpActivityList({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final entries = ref.watch(mcpActivityProvider).valueOrNull ?? const <AutomationHistoryData>[];
    if (entries.isEmpty) {
      return Text(l10n.mcpActivityEmpty,
          key: const ValueKey('mcp-activity-empty'),
          style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final loc = MaterialLocalizations.of(context);
    return Column(
      key: const ValueKey('mcp-activity'),
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        for (final e in entries.take(20))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(e.success ? LucideIcons.check : LucideIcons.x,
                    size: 14, color: e.success ? AppColors.success : AppColors.v3TextSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    [
                      '${loc.formatShortDate(e.timestamp)} ${loc.formatTimeOfDay(TimeOfDay.fromDateTime(e.timestamp))}',
                      e.snippetName ?? l10n.mcpUnknownApp,
                      mcpActionText(l10n, e.action, success: e.success),
                      if (e.command.isNotEmpty) e.command,
                    ].join('  ·  '),
                    style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

/// What an activity entry says was done.
String mcpActionText(AppLocalizations l10n, String action, {required bool success}) {
  final what = switch (action) {
    'mcp_list_hosts' => l10n.mcpActListHosts,
    'mcp_list_sessions' => l10n.mcpActListSessions,
    'mcp_open_session' => l10n.mcpActOpen,
    'mcp_read_output' => l10n.mcpActRead,
    'mcp_run_command' => l10n.mcpActRun,
    _ => action,
  };
  return success ? what : l10n.mcpActNotDone(what);
}

/// What AI apps did: the entries of the Tree's automation history that are
/// theirs, newest first.
final mcpActivityProvider = StreamProvider<List<AutomationHistoryData>>((ref) {
  final db = ref.watch(treeDatabaseProvider);
  return db.automationHistoryDao
      .watchAll()
      .map((all) => [for (final e in all) if (e.action.startsWith('mcp_')) e]);
});
