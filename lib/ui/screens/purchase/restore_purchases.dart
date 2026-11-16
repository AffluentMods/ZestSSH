import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/auth_service.dart';
import 'package:zestssh/services/purchase_service.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The app's one Restore purchases, wherever it is offered (the upgrade
/// pages, a locked page's card): on a phone or a tablet the store's own
/// restore, then the plans read again; on a computer, whose purchases are
/// the account's (bought on zestssh.com), the account's plans read again.
/// Each says what came of it. Tests stand in.
final purchaseRestorerProvider = Provider<Future<void> Function(BuildContext context)>(
  (ref) => (context) => restorePurchases(context, ref),
);

/// See [purchaseRestorerProvider].
Future<void> restorePurchases(BuildContext context, Ref ref) async {
  final l10n = AppLocalizations.of(context)!;
  if (!PurchaseService.isPlatformSupported) {
    await refreshAccountPlans(context, ref);
    return;
  }
  try {
    final customerInfo = await PurchaseService.restorePurchases();
    final isPro = customerInfo.entitlements.all[PurchaseService.proEntitlementId]?.isActive ?? false;
    final isSync = customerInfo.entitlements.all[PurchaseService.cloudSyncEntitlementId]?.isActive ?? false;
    if (!context.mounted) return;
    if (isPro || isSync) {
      await ref.read(isProProvider.notifier).refresh();
      await ref.read(isCloudSyncProvider.notifier).refresh();
      if (!context.mounted) return;
      final restored = [
        if (isPro) l10n.upgradeSqueezedTitle,
        if (isSync) l10n.upgradeFeatureCloudSync,
      ].join(' + ');
      showTopSnackBar(context, l10n.upgradeRestored(restored), isSuccess: true);
      return;
    }
    // Nothing came back from the store. Two distinct situations:
    //
    // 1. Genuinely no purchases - generic message.
    // 2. The purchases exist but are stranded on a previous RevenueCat
    //    profile on this device (lifetime IAPs get consumed on Android, so
    //    the store can't re-produce the receipt - the entitlement lives only
    //    on the old RC customer). Telling this user "no purchases found"
    //    reads as "you lost my money." Give them an actionable path.
    final strandedId = await PurchaseService.readStrandedAnonymousId();
    if (!context.mounted) return;
    // Show the support path not only when we RECORDED a strand (1.5.15+)
    // but also for any signed-in user - users stranded by the 1.5.14
    // identity switch have no local marker, and they are exactly the
    // signed-in-with-zero-entitlements population. A genuinely-free
    // signed-in user hitting Restore loses nothing by seeing a support
    // pointer.
    if (strandedId != null || AuthService.isSignedIn) {
      showTopSnackBar(context, l10n.upgradeStrandedProfileMessage, duration: const Duration(seconds: 10));
    } else {
      showTopSnackBar(context, l10n.upgradeNoPurchasesFound);
    }
  } on PurchaseUnavailableException {
    // The store is not here after all: what the account has, read again.
    if (context.mounted) await refreshAccountPlans(context, ref);
  } on PlatformException catch (e) {
    if (!context.mounted) return;
    showTopSnackBar(
      context,
      l10n.upgradeRestoreNotDone,
      isError: true,
      details: 'The store: ${e.code}: ${e.message ?? ''}',
    );
  }
}

/// A computer's Restore purchases: the account's plans read again (a
/// computer's purchases are the account's), and what came of it.
Future<void> refreshAccountPlans(BuildContext context, Ref ref) async {
  await ref.read(isProProvider.notifier).refresh();
  await ref.read(isCloudSyncProvider.notifier).refresh();
  if (!context.mounted) return;
  final l10n = AppLocalizations.of(context)!;
  if (ref.read(isProProvider) || ref.read(isCloudSyncProvider)) {
    showTopSnackBar(context, l10n.deskUpgPurchaseConfirmed, isSuccess: true);
  } else {
    showTopSnackBar(context, l10n.deskUpgNoPurchaseFound);
  }
}
