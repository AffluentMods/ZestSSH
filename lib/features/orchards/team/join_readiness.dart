import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/teams/account_key_service.dart' show AccountKeyStatus;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

// Before this device creates or joins a team (Create a team, accepting an
// invitation, a join code): the person's team keys must be here, since
// everything the team hands them is sealed to those keys. They are made
// here when the account has none yet, with or without sync: sync carries
// them to the person's other devices once it is on, and a team with a seat
// brings ZestSSH Cloud sync with it. Asking for sync first locked a new
// person out (a fresh account could not make a
// team, and the sync it needed comes from being in one). Keys made on
// another of the person's devices still come here through sync, and that
// case is said in plain words with the way out.

/// Where this device stands for joining a team.
enum JoinReadiness {
  /// The team keys are here: joining can go on.
  ready,

  /// The keys were made on another of the person's devices (or replaced
  /// there) and have not come here yet: sync brings them.
  keysOnOtherDevice,

  /// ZestSSH Cloud could not tell (signed out, or its answer could not be
  /// trusted).
  unavailable,
}

/// Finds out [JoinReadiness], making the keys where that is all it takes
/// (nothing published yet: they are made here, sync on or not).
class JoinPreparer {
  JoinPreparer({
    required this.hasKeys,
    required this.ensureKeys,
    required this.forgetKeys,
    required this.syncNow,
  });

  /// Whether this device holds the account's published keys now.
  final Future<bool> Function() hasKeys;

  /// Makes and publishes the keys, or adopts those published
  /// (AccountKeyService.ensureKeys).
  final Future<AccountKeyStatus> Function() ensureKeys;

  /// Forgets what was known of the keys, so the next ask reads them again.
  final void Function() forgetKeys;

  /// A sync now, the same as Sync now on the account page; throws what
  /// stopped it.
  final Future<void> Function() syncNow;

  Future<JoinReadiness> prepare() async {
    if (await hasKeys()) return JoinReadiness.ready;
    final status = await ensureKeys();
    forgetKeys();
    return switch (status) {
      AccountKeyStatus.ready => await hasKeys() ? JoinReadiness.ready : JoinReadiness.unavailable,
      AccountKeyStatus.waitingForAnotherDevice || AccountKeyStatus.changedElsewhere => JoinReadiness.keysOnOtherDevice,
      AccountKeyStatus.unavailable => JoinReadiness.unavailable,
    };
  }

  /// Syncs now (what brings keys from another device), then [prepare].
  Future<JoinReadiness> syncThenPrepare() async {
    await syncNow();
    return prepare();
  }
}

final joinPreparerProvider = Provider<JoinPreparer>((ref) => JoinPreparer(
      hasKeys: () async => await ref.read(orchardServiceProvider).currentAuthor() != null,
      ensureKeys: () => ref.read(accountKeyServiceProvider).ensureKeys(),
      forgetKeys: () => ref.read(orchardAuthorProvider).forget(),
      syncNow: () async {
        await ref.read(autoSyncServiceProvider).syncNowManual();
      },
    ));

/// Opens the account page, where sync is set up and where "Start over"
/// with new keys is: Settings, Account on a computer, the Account screen
/// on a phone. [rootContext] is the app's own navigator's (the screen that
/// asked has gone by then). Tests stand in.
final accountPageOpenerProvider = Provider<void Function(BuildContext rootContext)>((ref) => (rootContext) {
      if (isDesktopPlatform) {
        ref.read(settingsJumpProvider.notifier).state = SettingsJumpTarget.account;
        ref.read(settingsPopupOpenProvider.notifier).state = true;
      } else if (rootContext.mounted) {
        unawaited(ProfileScreen.showAdaptive(rootContext));
      }
    });

/// Before this device creates or joins a team: whether to go on. Where the
/// team keys are here, at once; where the account has none yet, they are
/// made now (sync on or not); where they were made on another of the
/// person's devices, that is said with the way out (sync now, or start over
/// without the device that has them), and false comes back unless that
/// made them ready. What could not be found out is one notice with what to
/// copy. The caller shows itself busy meanwhile and asks again on the next
/// tap.
///
/// Called before Create a team, accepting an invitation
/// (MyInvitationsView) and joining with a code.
Future<bool> readyToJoin(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final preparer = ref.read(joinPreparerProvider);
  final openAccount = ref.read(accountPageOpenerProvider);
  JoinReadiness readiness;
  try {
    readiness = await preparer.prepare();
  } catch (e) {
    AppLogger.warning('Orchards: this device could not be made ready to join a team (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, l10n.joinNotReady, isError: true, details: '$e');
    return false;
  }
  if (!context.mounted) return false;
  switch (readiness) {
    case JoinReadiness.ready:
      return true;
    case JoinReadiness.unavailable:
      showTopSnackBar(context, l10n.joinNotReady, isError: true, details: 'AccountKeyStatus.unavailable');
      return false;
    case JoinReadiness.keysOnOtherDevice:
      final choice = await showZestModal<_ElsewhereChoice>(
        context: context,
        size: ZestModalSize.standard,
        child: const _KeysElsewhereDialog(),
      );
      if (choice == _ElsewhereChoice.ready) return true;
      if (choice == _ElsewhereChoice.account && context.mounted) _openAccountFrom(context, openAccount);
      return false;
  }
}

/// Closes the pop-ups over the app (this dialog and the one that asked) and
/// opens the account page.
void _openAccountFrom(BuildContext context, void Function(BuildContext) openAccount) {
  final nav = Navigator.of(context, rootNavigator: true);
  nav.popUntil((route) => route is! PopupRoute);
  openAccount(nav.context);
}

enum _ElsewhereChoice { ready, account }

/// The keys are on another of the person's devices: sync now brings them
/// (and joining goes on), or, without that device, the account page has
/// "Start over".
class _KeysElsewhereDialog extends ConsumerStatefulWidget {
  const _KeysElsewhereDialog();

  @override
  ConsumerState<_KeysElsewhereDialog> createState() => _KeysElsewhereDialogState();
}

class _KeysElsewhereDialogState extends ConsumerState<_KeysElsewhereDialog> {
  bool _busy = false;

  /// A sync ran and the keys did not come with it.
  bool _stillMissing = false;

  Future<void> _sync() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = true);
    try {
      final readiness = await ref.read(joinPreparerProvider).syncThenPrepare();
      if (!mounted) return;
      if (readiness == JoinReadiness.ready) {
        Navigator.of(context).pop(_ElsewhereChoice.ready);
        return;
      }
      setState(() => _stillMissing = true);
    } catch (e) {
      AppLogger.warning('Orchards: a sync to bring the team keys did not finish (${errorKind(e)})');
      if (!mounted) return;
      // In the words a sync that stopped is said in everywhere, with what
      // stands behind it to copy.
      final status = ref.read(syncStatusProvider.notifier);
      status.setErrorFrom(e);
      final said = ref.read(syncStatusProvider);
      showTopSnackBar(context, said.error ?? l10n.joinNotReady, isError: true, details: said.errorDetail ?? '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final text = TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary);
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.monitorSmartphone,
      title: l10n.joinKeysElsewhereTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(l10n.joinKeysElsewhereBody, key: const ValueKey('join-keys-elsewhere'), style: text),
          if (_stillMissing) ...[
            const SizedBox(height: 10),
            Text(
              l10n.joinKeysStillElsewhere,
              key: const ValueKey('join-keys-still-elsewhere'),
              style: TextStyle(fontSize: 12.5, height: 1.45, color: AppColors.v3Warning),
            ),
          ],
          const SizedBox(height: 10),
          Text(l10n.joinNoOtherDeviceHelp, style: TextStyle(fontSize: 12, height: 1.45, color: AppColors.v3TextTertiary)),
        ],
      ),
      primaryKey: const ValueKey('join-sync-now'),
      primaryAction: (
        label: _busy ? l10n.settingsSyncing : l10n.accountSyncNow,
        onPressed: _busy ? null : _sync,
        icon: LucideIcons.refreshCw,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
      tertiaryKey: const ValueKey('join-no-other-device'),
      tertiaryAction: (
        label: l10n.joinNoOtherDevice,
        onPressed: _busy ? null : () => Navigator.of(context).pop(_ElsewhereChoice.account),
      ),
    );
  }
}
