import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// The ways on for a person who chose ZestSSH Cloud for sync on an account
/// without Juiced ([showSyncHostingNeeded]).
enum SyncHostingChoice { chooseStorage, getJuiced }

/// Says that ZestSSH Cloud storage comes with Juiced and that sync is free
/// with storage of the person's own ([message]: what the refusal said, with
/// its code, SyncHostingRequiredException), with a button for each way on.
/// Null when it is closed. (It was "Couldn't reach the sync server" in 2.2.1,
/// a snackbar that went by and read
/// as an outage.)
Future<SyncHostingChoice?> showSyncHostingNeeded(BuildContext context, String message) {
  final l10n = AppLocalizations.of(context)!;
  void choose(SyncHostingChoice choice) => Navigator.of(context, rootNavigator: true).pop(choice);
  return ZestDialogShell.showModal<SyncHostingChoice>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.cloud,
    title: l10n.syncHostingTitle,
    body: SelectableText(message, key: const Key('sync-hosting-message')),
    primaryAction: (
      label: l10n.syncHostingChooseStorage,
      icon: null,
      onPressed: () => choose(SyncHostingChoice.chooseStorage),
    ),
    secondaryAction: (label: l10n.profileGetCloudSync, onPressed: () => choose(SyncHostingChoice.getJuiced)),
  );
}
