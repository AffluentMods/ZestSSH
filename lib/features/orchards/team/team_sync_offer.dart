import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/team/join_readiness.dart' show accountPageOpenerProvider;
import 'package:zestssh/features/orchards/team/team_seats.dart'
    show billingOnThisDeviceProvider, seatCodeRefusal, seatsArrivedProvider;
import 'package:zestssh/features/orchards/team/team_seats_sheet.dart' show openSeatsSheet;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show orchardDisplayName, showCreateOrchardDialog;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';

// A team with a seat bought includes ZestSSH Cloud sync (and Squeezed) for
// everyone in it, the way business plans of password managers give each
// member their own vault. Sync is
// also what carries a person's team keys to their other devices. Now
// a team is made or joined with sync off (the keys are made on
// the device, which locked a new person out before), so this says how sync
// comes on: after Create a team, after a code gave a team seats, and once
// as a notice when a team's seat first gives this account sync.

/// Reads this account's entitlements again: once its team has a seat bought,
/// ZestSSH Cloud sync and Squeezed are its own (tests stand in).
final teamSyncRefreshProvider = Provider<Future<void> Function()>((ref) => () async {
      await Future.wait([
        ref.read(isCloudSyncProvider.notifier).forceRefresh(),
        ref.read(isProProvider.notifier).forceRefresh(),
      ]);
    });

/// The notice's id, once per account on this device.
String teamSyncNoticeId(String uid) => 'team-sync-$uid';

/// The preference that remembers the notice was shown, per account.
String teamSyncToldKey(String uid) => 'team_sync_offer_told_$uid';

/// Opens the account page, where sync is set up, from wherever this was
/// asked (the pop-ups over the app are closed first).
void openAccountForSync(BuildContext context, WidgetRef ref) {
  final open = ref.read(accountPageOpenerProvider);
  final nav = Navigator.of(context, rootNavigator: true);
  nav.popUntil((route) => route is! PopupRoute);
  open(nav.context);
}

/// The once-only notice that a team's seat gave this account sync while it
/// is off here, with [onSetUp] behind its button.
AppNotification teamSyncNotification(AppLocalizations l10n, String uid, VoidCallback onSetUp, {DateTime? now}) =>
    AppNotification(
      id: teamSyncNoticeId(uid),
      title: l10n.teamSyncOfferTitle,
      body: l10n.teamSyncOfferIncluded,
      severity: NotificationSeverity.info,
      createdAt: now ?? DateTime.now(),
      actionLabel: l10n.joinSetUpSync,
      onAction: onSetUp,
    );

/// After this device made [orchardId] or gave it seats: where sync is not on
/// here, says how it comes on. With a seat bought the team includes it, and
/// the account page sets it up; without one, an owner on a computer is shown
/// where seats are bought, an owner on a phone that it is done on a computer,
/// and anyone else that the owners add them.
Future<void> offerTeamSync(BuildContext context, WidgetRef ref, String orchardId, {required bool owner}) async {
  final l10n = AppLocalizations.of(context)!;
  bool syncOn;
  try {
    syncOn = await ref.read(syncSetupStateServiceProvider).isSyncActive();
  } catch (_) {
    syncOn = false;
  }
  if (syncOn) return;
  var bought = 0;
  try {
    bought = (await ref.read(orchardBillingApiProvider).get(orchardId)).seats.bought;
  } catch (e) {
    AppLogger.info('Orchards: the seats could not be read for the sync offer ($e)');
  }
  final included = bought > 0;
  if (included) {
    // The team's sync is this account's now: the setup reads it from here.
    try {
      await ref.read(teamSyncRefreshProvider)();
    } catch (e) {
      AppLogger.info('Orchards: the entitlements could not be read again ($e)');
    }
  }
  if (!context.mounted) return;
  final buys = owner && ref.read(billingOnThisDeviceProvider);
  final body = included
      ? l10n.teamSyncOfferIncluded
      : owner
          ? (buys ? l10n.teamSyncOfferNeedsSeatOwner : '${l10n.teamSyncOfferNeedsSeatOwner} ${l10n.teamSeatsOnComputer}')
          : l10n.teamSyncOfferNeedsSeatMember;
  final choice = await ZestDialogShell.showModal<String>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.cloud,
    title: l10n.teamSyncOfferTitle,
    body: Text(
      body,
      key: const ValueKey('team-sync-offer'),
      style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary),
    ),
    primaryAction: included
        ? (label: l10n.joinSetUpSync, onPressed: () => Navigator.of(context).pop('sync'), icon: LucideIcons.cloud)
        : buys
            ? (label: l10n.teamSeatsBuy, onPressed: () => Navigator.of(context).pop('seats'), icon: LucideIcons.users)
            : (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
    secondaryAction: included || buys ? (label: l10n.notNow, onPressed: () => Navigator.of(context).pop()) : null,
  );
  if (!context.mounted) return;
  if (choice == 'sync') openAccountForSync(context, ref);
  if (choice == 'seats') await openSeatsSheet(context, ref, orchardId);
}

/// A code entered under Redeem a code that gives a team seats: they go to a
/// team this account owns (one chosen, where it owns more), or to a new team
/// named here. Then what waited for seats is sent and sync is offered.
/// Before, the code was only said to belong on a team's Seats page, and a
/// person with no team could do nothing with it.
Future<void> redeemTeamCode(BuildContext context, WidgetRef ref, String code) async {
  final l10n = AppLocalizations.of(context)!;
  List<OrchardSummary> owned;
  try {
    owned = [
      for (final o in await ref.read(orchardSummariesProvider.future))
        if (o.isOwner && o.status == 'active' && o.name != null) o,
    ];
  } catch (_) {
    owned = const [];
  }
  if (!context.mounted) return;
  String? orchardId;
  if (owned.isEmpty) {
    orchardId = await showCreateOrchardDialog(context, ref, note: l10n.redeemTeamCodeNameTeam, offerSync: false);
  } else {
    final picked = await showZestModal<String>(
      context: context,
      size: ZestModalSize.standard,
      child: _TeamCodeTarget(teams: owned),
    );
    if (picked == null || !context.mounted) return;
    orchardId = picked == _newTeam
        ? await showCreateOrchardDialog(context, ref, note: l10n.redeemTeamCodeNameTeam, offerSync: false)
        : picked;
  }
  if (orchardId == null || !context.mounted) return;
  try {
    final done = await ref.read(orchardBillingApiProvider).redeem(orchardId, code);
    if (done.added > 0) ref.read(seatsArrivedProvider)();
    ref.invalidate(orchardBillingProvider(orchardId));
    if (!context.mounted) return;
    showTopSnackBar(context, done.added > 0 ? l10n.teamSeatsCodeAdded(done.added) : l10n.teamSeatsCodeUsed,
        isSuccess: done.added > 0);
  } catch (e) {
    AppLogger.warning('Orchards: a seat code entered under Redeem a code was not taken ($e)');
    if (context.mounted) {
      showTopSnackBar(context, seatCodeRefusal(e, l10n, buysHere: ref.read(billingOnThisDeviceProvider)),
          isError: true, details: '$e');
    }
    return;
  }
  if (context.mounted) await offerTeamSync(context, ref, orchardId, owner: true);
}

const _newTeam = '\u0000new';

/// Which team gets a code's seats: each team this account owns, or a new one.
class _TeamCodeTarget extends StatelessWidget {
  const _TeamCodeTarget({required this.teams});

  final List<OrchardSummary> teams;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.gift,
      title: l10n.redeemTeamCodeTitle,
      subtitle: l10n.redeemTeamCodeChoose,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final t in teams) ...[
            OutlinedButton.icon(
              key: ValueKey('team-code-to-${t.id}'),
              onPressed: () => Navigator.of(context).pop(t.id),
              icon: const Icon(LucideIcons.users, size: 16),
              label: Text(l10n.redeemTeamCodeAddTo(orchardDisplayName(t.name, l10n))),
            ),
            const SizedBox(height: 8),
          ],
          TextButton.icon(
            key: const ValueKey('team-code-new-team'),
            onPressed: () => Navigator.of(context).pop(_newTeam),
            icon: const Icon(LucideIcons.plus, size: 16),
            label: Text(l10n.redeemTeamCodeNewTeam),
          ),
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }
}
