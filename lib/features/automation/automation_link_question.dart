/// The question a `zestssh://` automation link asks before anything runs
/// (3.0, found while comparing the five versions): a link
/// that runs a command on a saved host (`zestssh://execute`), a snippet
/// (`zestssh://snippet`), a command on several hosts (`zestssh://batch`),
/// or a workflow (`zestssh://workflow`).
///
/// Any web page or app can open such a link, so none runs before its person
/// says so (DeepLinkService.extractAutomationParams asks
/// [DeepLinkService.onAutomationRequested]). Nothing in the app answered that
/// question since automation links came in (1.5.0), so every such link was
/// refused, on every platform, while the automation guide, its wizard and
/// the Triggers tab handed them out. The automation key the link carries is
/// checked after the question, as for every automation request.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/services/automation_service.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// Asks whether a link may run [action]: what it runs ([command]: the
/// command, a snippet's name, or a workflow's name) and where ([target]: a
/// saved host's id or name, or several, by commas; a workflow's id), named as
/// your Tree has them and masked while the screen is recorded, with the command
/// a snippet runs, filled in with the link's [variables] as it runs them.
/// Nothing is asked, and nothing runs, while the app is locked, or while
/// automation could run nothing (turned off, or no Squeezed), which is said
/// instead.
Future<bool> askAutomationLink(
  BuildContext context,
  WidgetRef ref, {
  required String action,
  String? command,
  String? target,
  Map<String, String> variables = const {},
}) async {
  // Locked: nothing can be read, and nothing runs.
  final tree = ref.read(databaseSessionProvider);
  if (tree == null) return false;
  // Automation off, or no Squeezed: nothing would run, so nothing is asked;
  // the refusal says which (AutomationBlocked.off, .needsSqueezed). It
  // asked, and a Run then ran nothing (found in the
  // whitepaper check).
  if (ref.read(automationProvider.notifier).refuseIfNothingRuns()) return false;
  // The question shows what the link would do as it is: while the screen is
  // recorded, which paints stand-ins for hosts and commands, recording is
  // turned off first, or nothing runs. (It showed a harmless stand-in, and
  // the real command ran on Run: found in a
  // security review.)
  if (!await confirmRevealWhileRecording(context, ref) || !context.mounted) return false;
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(automationServiceProvider);

  /// A host as the link names it: by the name your Tree gives it.
  Future<String> hostShown(String named) async {
    final id = await service.resolveConnectionId(named);
    final host = id == null ? null : await tree.connectionsDao.getById(id);
    final name = host == null ? named : (host.label.isNotEmpty ? host.label : host.host);
    return Redactable.host(visibleCommand(name)).display;
  }

  final String what;
  String? runs;
  switch (action) {
    case 'execute':
      what = l10n.automationLinkOnHost(await hostShown(target ?? ''));
      runs = command;
    case 'snippet':
      final name = command ?? '';
      final lower = name.toLowerCase();
      final snippets = await tree.snippetsDao.getAll();
      final snippet = snippets.where((s) => s.label.toLowerCase() == lower).firstOrNull;
      what = l10n.automationLinkSnippetOn(Redactable.freeText(visibleCommand(name)).display, await hostShown(target ?? ''));
      runs = snippet == null ? null : snippetCommandToRun(snippet.command, variables);
    case 'batch':
      final named = (target ?? '').split(',').map((s) => s.trim()).where((s) => s.isNotEmpty);
      what = l10n.automationLinkOnHosts([for (final h in named) await hostShown(h)].join(', '));
      runs = command;
    case 'workflow':
      // One of your Tree's, whichever space is on screen: a link runs no other
      // (AutomationNotifier._handleWorkflow), and the one it runs: looked up as
      // the run looks it up, and named by its name where the link gave its id.
      final workflows = await ref.read(workflowsProvider.notifier).ofTheTree();
      final workflow = workflowOfLink(workflows, id: target, name: command);
      final named = workflow?.name ?? ((command ?? '').isNotEmpty ? command! : target ?? '');
      what = l10n.automationLinkWorkflow(Redactable.freeText(visibleCommand(named)).display);
    default:
      AppLogger.warning('Automation link of an unknown kind not asked about: $action');
      return false;
  }
  if (!context.mounted) return false;
  final approved = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.automationLinkTitle,
    // The command as it runs, a character that would hide or reorder what it
    // says shown as its code, and a line break as `\n`: a link's 200 line breaks
    // put what it really runs out of sight below `uptime`, with Run in view.
    body: [what, if (runs != null && runs.isNotEmpty) visibleCommand(runs)].join('\n\n'),
    // What makes it safe, in its amber sentence (3.4).
    warning: l10n.automationLinkOnlyYours,
    confirmLabel: l10n.automationLinkRun,
    // Nothing is chosen for them: an Enter meant for the terminal the
    // question came up over must not answer it.
    autofocusConfirm: false,
  );
  return approved == true;
}

/// Lets automation links ask their question ([askAutomationLink]) on the
/// app's own screen: [router]'s, once it is up. A link that comes before
/// anything is on screen is not run.
void answerAutomationLinks(WidgetRef ref, GoRouter Function() router) {
  DeepLinkService.onAutomationRequested = (action, command, target, [variables = const {}]) async {
    final context = router().routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) {
      AppLogger.warning('Automation link arrived before the app was on screen - not run');
      return false;
    }
    return askAutomationLink(context, ref, action: action, command: command, target: target, variables: variables);
  };
}
