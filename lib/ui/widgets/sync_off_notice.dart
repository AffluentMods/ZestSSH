import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

// Not syncing made obvious (as 1Password does):
// a host saved while sync is off is said to be on this device only, in a
// dialog over the editor, with the way to set sync up.

/// Whether the notice may show at all. Off under `flutter test`, where the
/// editors save with no sync set up; a test of the notice turns it on.
final syncOffNoticeEnabledProvider =
    Provider<bool>((ref) => !Platform.environment.containsKey('FLUTTER_TEST'));

/// After a personal host was saved: where sync is off and the person has not
/// asked not to be told, says it is on this device only. True when they
/// chose Set up sync.
Future<bool> maybeShowSyncOffNotice(BuildContext context, WidgetRef ref) async {
  if (!ref.read(syncOffNoticeEnabledProvider)) return false;
  // A team's hosts go to the team whether personal sync is on or not.
  if (ref.read(activeSpaceProvider) is! TreeSpace) return false;
  final settings = ref.read(settingsServiceProvider);
  if (settings.syncOffNoticeHidden) return false;
  bool active;
  try {
    active = await ref.read(syncIsActiveProvider.future);
  } catch (_) {
    // Not known: nothing is said rather than something wrong.
    return false;
  }
  if (active || !context.mounted) return false;
  final l10n = AppLocalizations.of(context)!;
  var hide = false;
  final setUp = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.compact,
    // A notice that offers sync: nothing amber (3.4).
    tone: ZestDialogTone.neutral,
    icon: LucideIcons.cloudOff,
    title: l10n.syncOffNoticeTitle,
    body: StatefulBuilder(
      builder: (context, setState) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(l10n.syncOffNoticeBody, style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
          const SizedBox(height: 10),
          CheckboxListTile(
            key: const ValueKey('sync-off-notice-hide'),
            value: hide,
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.leading,
            title: Text(l10n.syncOffNoticeHide, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
            onChanged: (v) => setState(() => hide = v ?? false),
          ),
        ],
      ),
    ),
    primaryAction: (
      label: l10n.syncOffNoticeSetUp,
      onPressed: () => Navigator.of(context).pop(true),
      icon: LucideIcons.cloud,
    ),
    secondaryAction: (label: l10n.syncOffNoticeNotNow, onPressed: () => Navigator.of(context).pop(false)),
  );
  if (hide) await settings.setSyncOffNoticeHidden(true);
  return setUp == true;
}
