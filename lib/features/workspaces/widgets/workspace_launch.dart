import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'package:zestssh/features/workspaces/state/workspaces_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedHosts;
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Launch a workspace from a placement surface (drawer row, Hosts card, or
/// Split-tab card) and surface the outcome.
///
/// Launching opens every pane it can; when a referenced host was deleted the
/// workspace keeps the slot and [WorkspaceLaunchResult.unresolvedHostNames]
/// names what could not be opened (§6 data rule). We report those so a launch
/// never fails silently.
///
/// Where a pane's host is Telnet the question every other way of opening one
/// asks is asked first, once, naming those hosts; on Cancel their panes stay
/// empty and the others open. [context] has to outlive the dialog or
/// sheet the workspace was picked in.
Future<void> launchWorkspaceFromSurface(
  BuildContext context,
  WidgetRef ref,
  String id,
) async {
  final result = await launchWorkspace(
    ref,
    id,
    askPlaintext: (telnet) async =>
        context.mounted &&
        await confirmUnencryptedHosts(context, telnet, (l10n, hosts) => l10n.desktopShellTelnetInWorkspace(hosts)),
  );
  if (!context.mounted || !result.workspaceFound) return;
  final missing =
      result.unresolvedHostNames.where((n) => n.isNotEmpty).toList();
  if (missing.isEmpty) return;
  final l10n = AppLocalizations.of(context)!;
  // Host names in a toast: painted, so they go through the host rule.
  final shown = missing.map((n) => Redactable.host(n).display).join(', ');
  showTopSnackBar(
    context,
    l10n.workspaceLaunchedWithMissing(result.launchedTabCount, shown),
  );
}
