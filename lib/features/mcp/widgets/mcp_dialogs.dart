import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:window_manager/window_manager.dart';
import 'package:zestssh/features/mcp/mcp_requests.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Answers the MCP server's questions on screen, in the context [navigator]
/// gives (the app's navigator), bringing the window forward first: the
/// person is likely in their AI app's window when it asks. Call it from a
/// build: the app's root does.
void answerMcpRequests(WidgetRef ref, BuildContext? Function() navigator) {
  ref.listen<McpRequest?>(mcpRequestProvider, (_, request) {
    if (request == null || !request.isOpen) return;
    unawaited(_answer(navigator(), request));
  });
}

Future<void> _answer(BuildContext? context, McpRequest request) async {
  try {
    if (context == null || !context.mounted) {
      request.reply(false);
      return;
    }
    if (isDesktopPlatform) {
      try {
        await windowManager.show();
        await windowManager.focus();
      } catch (_) {}
    }
    if (!context.mounted) {
      request.reply(false);
      return;
    }
    request.reply(await showMcpRequest(context, request) ?? false);
  } catch (e) {
    AppLogger.warning('MCP: a question was not shown (${errorKind(e)})');
    request.reply(false);
  }
}

/// The question [request] asks, as a dialog: true when allowed. Enter does
/// not allow it (the confirm button is not focused): an AI app's command is
/// allowed by a click or a deliberate Tab. The dialog closes by itself (null)
/// once the question is taken back: no answer in time, the AI app gave up on
/// its call, or AI apps were turned off, so nobody allows what nothing waits
/// for any more.
Future<bool?> showMcpRequest(BuildContext context, McpRequest request) {
  final l10n = AppLocalizations.of(context)!;
  final app = request.caller.shownName ?? l10n.mcpUnknownApp;
  return switch (request) {
    McpReadRequest r => ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.bot,
        title: l10n.mcpReadTitle(app),
        body: l10n.mcpReadBody(r.hostName),
        confirmLabel: l10n.mcpReadAllow,
        cancelLabel: l10n.mcpDeny,
        autofocusConfirm: false,
        closeWhen: request.answer,
      ),
    McpRunRequest r => ZestConfirmDialog.show(
        context,
        tone: r.dangers.isEmpty ? ZestDialogTone.neutral : ZestDialogTone.warning,
        icon: LucideIcons.bot,
        title: l10n.mcpRunTitle(app),
        body: l10n.mcpRunBody(r.hostName),
        bullets: [r.command],
        warning: r.dangers.isEmpty ? null : l10n.mcpRunDanger,
        confirmLabel: l10n.mcpRunAllow,
        cancelLabel: l10n.mcpDeny,
        autofocusConfirm: false,
        closeWhen: request.answer,
      ),
  };
}
