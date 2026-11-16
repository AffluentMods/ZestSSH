import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// How many of a backup's hosts that do something by themselves are named.
const kRestorePreviewHostsNamed = 8;

/// Asks before a backup is restored, saying what it would do
/// ([RestorePreview]): what it holds, what it writes over here, the hosts that
/// do something by themselves (found in the client's security
/// review: a restore wrote it all at once, unseen), the safety settings it
/// would turn down, each kept as it is here unless ticked, and the host keys it
/// would trust that this device has not confirmed, taken only when ticked. An
/// answer restores; null restores nothing.
Future<RestoreChoice?> showRestorePreview(BuildContext context, RestorePreview preview) async {
  final l10n = AppLocalizations.of(context)!;
  final number = TextStyle(
    fontSize: 13,
    fontWeight: FontWeight.w600,
    fontFeatures: const [FontFeature.tabularFigures()],
    color: AppColors.onSurface,
  );
  const text = TextStyle(fontSize: 13, height: 1.45);

  Widget count(String label, int n) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 2),
        child: Row(children: [
          Expanded(child: Text(label, style: text)),
          Text('$n', style: number),
        ]),
      );

  String act(HostActsAlone a) => switch (a) {
        HostActsAlone.runsCommand => l10n.backupRestoreRunsCommand,
        HostActsAlone.runsSnippet => l10n.backupRestoreRunsSnippet,
        HostActsAlone.setsVariables => l10n.backupRestoreSetsVariables,
        HostActsAlone.runsHere => l10n.backupRestoreRunsHere,
        HostActsAlone.startsForward => l10n.backupRestoreStartsForward,
        HostActsAlone.forwardsAgent => l10n.backupRestoreForwardsAgent,
        HostActsAlone.monitored => l10n.backupRestoreMonitored,
        HostActsAlone.compatibilityMode => l10n.backupRestoreCompatibility,
      };

  String weakens(String key) => switch (key) {
        'ask_before_trusting_keys' => l10n.backupWeakensAskBeforeTrusting,
        'dangerous_command_protection' => l10n.backupWeakensDangerousCommands,
        'notify_security_alerts' => l10n.backupWeakensSecurityAlerts,
        'osc52_clipboard' => l10n.backupWeakensClipboard,
        'snippet_destructive_confirm' => l10n.backupWeakensSnippetConfirm,
        _ => key,
      };

  final named = preview.acting.take(kRestorePreviewHostsNamed).toList();
  final namedKeys = preview.hostKeys.take(kRestorePreviewHostsNamed).toList();
  final take = <String>{};
  var takeHostKeys = false;
  // On the app's own navigator, a phone's sheet too: its buttons close it
  // there.
  return showZestModal<RestoreChoice>(
    context: context,
    size: ZestModalSize.compact,
    useRootNavigator: true,
    child: ZestDialogShell(
      size: ZestModalSize.compact,
      // Amber only on the sentence that warns, where hosts act by themselves
      // (3.4); otherwise an ordinary question.
      tone: preview.acting.isEmpty ? ZestDialogTone.neutral : ZestDialogTone.warning,
      title: l10n.backupRestoreTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          count(l10n.narrowSidebarHosts, preview.hosts),
          count(l10n.narrowSidebarKeys, preview.keys),
          count(l10n.snippetsTitle, preview.snippets),
          count(l10n.backupRestoreOther, preview.other),
          if (preview.replaces > 0) ...[
            const SizedBox(height: 10),
            Text(l10n.backupRestoreReplaces(preview.replaces), style: text),
          ],
          if (named.isNotEmpty) ...[
            const SizedBox(height: 10),
            ZestCallout(l10n.backupRestoreActing),
            for (final (label, acts) in named)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // A label a backup brings is shown with what would hide
                    // or reorder it written as its code.
                    RedactedText(
                      Redactable.host(withHiddenCharactersShown(label)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    for (final a in acts)
                      Padding(
                        padding: const EdgeInsetsDirectional.only(start: 12),
                        child: Text(act(a), style: TextStyle(fontSize: 12.5, color: AppColors.onSurfaceDim)),
                      ),
                  ],
                ),
              ),
            if (preview.acting.length > named.length)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text('+${preview.acting.length - named.length}', style: number),
              ),
          ],
          if (preview.weakens.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(l10n.backupWeakensTitle, key: const ValueKey('restore-preview-weakens'), style: text),
            StatefulBuilder(
              builder: (context, setState) => Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Align(
                    alignment: AlignmentDirectional.centerEnd,
                    child: TextButton(
                      key: const ValueKey('restore-preview-weakens-all'),
                      onPressed: () => setState(() {
                        if (take.length == preview.weakens.length) {
                          take.clear();
                        } else {
                          take.addAll(preview.weakens);
                        }
                      }),
                      child: Text(take.length == preview.weakens.length ? l10n.sshImportDeselectAll : l10n.sshImportSelectAll),
                    ),
                  ),
                  for (final key in preview.weakens)
                    CheckboxListTile(
                      key: ValueKey('restore-preview-weakens-$key'),
                      dense: true,
                      contentPadding: EdgeInsets.zero,
                      controlAffinity: ListTileControlAffinity.leading,
                      value: take.contains(key),
                      title: Text(weakens(key), style: const TextStyle(fontSize: 12.5, height: 1.4)),
                      onChanged: (on) => setState(() => on == true ? take.add(key) : take.remove(key)),
                    ),
                ],
              ),
            ),
          ],
          // Host keys this device has not confirmed: taken only when ticked
          // (found in a security review).
          if (namedKeys.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(l10n.backupRestoreHostKeys, key: const ValueKey('restore-preview-host-keys'), style: text),
            // Each with its route: through a jump host, it says which.
            for (final h in namedKeys)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RedactedText(
                      Redactable.host(withHiddenCharactersShown(h.host)),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12.5, color: AppColors.onSurfaceDim),
                    ),
                    if (h.via case final via?)
                      Consumer(
                        builder: (context, ref, _) => Text(
                          l10n.pfPageVia(Redactable.host(withHiddenCharactersShown(
                                  via.startsWith('via:') ? via.substring(4) : via))
                              .displayIn(ref)),
                          key: ValueKey('restore-preview-host-key-via-${h.host}'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: AppColors.onSurfaceDim),
                        ),
                      ),
                  ],
                ),
              ),
            if (preview.hostKeys.length > namedKeys.length)
              Padding(
                padding: const EdgeInsetsDirectional.only(start: 12, top: 4),
                child: Text('+${preview.hostKeys.length - namedKeys.length}', style: number),
              ),
            StatefulBuilder(
              builder: (context, setState) => CheckboxListTile(
                key: const ValueKey('restore-preview-host-keys-take'),
                dense: true,
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
                value: takeHostKeys,
                title: Text(l10n.backupRestoreTrustHostKeys, style: const TextStyle(fontSize: 12.5, height: 1.4)),
                onChanged: (on) => setState(() => takeHostKeys = on == true),
              ),
            ),
          ],
        ],
      ),
      // The main button in the footer, as every dialog's (it stood in the
      // body): what is ticked when it is pressed is taken.
      primaryKey: const ValueKey('restore-preview-go'),
      primaryAction: (
        label: l10n.backupRestoreAction,
        icon: null,
        onPressed: () => Navigator.of(context, rootNavigator: true)
            .pop(RestoreChoice(takeSettings: take, takeHostKeys: takeHostKeys)),
      ),
      secondaryAction: (
        label: l10n.cancel,
        onPressed: () => Navigator.of(context, rootNavigator: true).pop(),
      ),
    ),
  );
}
