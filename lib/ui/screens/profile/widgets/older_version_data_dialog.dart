import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/profiles/older_version_data.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/error_kind.dart';

/// What the notice says of what an older version left: its hosts, or its keys
/// where it left no host, or that it cannot be read.
String olderDataWords(AppLocalizations l10n, OlderVersionSummary summary) {
  if (summary.locked) return l10n.olderDataLocked;
  if (!summary.opened) return l10n.olderDataUnreadable;
  return summary.hosts > 0 ? l10n.olderDataBody(summary.hosts) : l10n.olderDataBodyKeys(summary.keys);
}

/// What was set aside: put back, which closes the app to do it, or deleted.
Future<void> showSetAsideData(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final back = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    title: l10n.profileSetAsideTitle,
    body: l10n.profileSetAsideQuestion,
    confirmLabel: l10n.profileSetAsidePutBack,
    cancelLabel: l10n.olderDataDeleteInstead,
  );
  if (!context.mounted || back == null) return;
  if (back) {
    try {
      await ref.read(profileControllerProvider).askPutBack();
    } catch (e) {
      AppLogger.warning('Data that was set aside was not put back (${errorKind(e)})');
      if (context.mounted) showTopSnackBar(context, l10n.profilePutBackFailed, isError: true, details: '$e');
    }
    return;
  }
  await confirmDeleteSetAside(context, ref);
}

/// Data that did not open and was set aside goes, once the person has said so.
Future<void> confirmDeleteSetAside(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final sure = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.profileSetAsideDeleteTitle,
    body: l10n.profileSetAsideDeleteBody,
    confirmLabel: l10n.delete,
  );
  if (sure != true) return;
  try {
    await ref.read(profileControllerProvider).deleteSetAside();
    ref.read(notificationCenterProvider.notifier).remove('data-set-aside');
  } catch (e) {
    AppLogger.warning('Data that was set aside was not deleted (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, l10n.olderDataNotBrought, isError: true, details: '$e');
  }
}

/// What an older version of the app left at the old place: brought into the
/// profile on screen, or deleted, on the person's word (to-do 60). It is never
/// taken over a profile by itself. Closing this leaves it as it is, and the next
/// start asks again.
Future<void> showOlderVersionData(
    BuildContext context, WidgetRef ref, OlderVersionData older, OlderVersionSummary summary) async {
  final l10n = AppLocalizations.of(context)!;
  // What cannot be read cannot be brought in: it is said plainly why, and leaving it
  // is the first answer.
  if (!summary.opened) {
    final leave = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.olderDataTitle,
      body: olderDataWords(l10n, summary),
      confirmLabel: l10n.olderDataLeave,
      cancelLabel: l10n.olderDataDeleteInstead,
    );
    if (!context.mounted || leave != false) return;
  } else {
    final bring = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.info,
      title: l10n.olderDataTitle,
      body: summary.hosts > 0 ? l10n.olderDataQuestion(summary.hosts) : l10n.olderDataQuestionKeys(summary.keys),
      confirmLabel: l10n.olderDataBring,
      cancelLabel: l10n.olderDataDeleteInstead,
    );
    if (!context.mounted || bring == null) return;
    if (bring) {
      try {
        await ref.read(profileControllerProvider).bringOlderVersionData(older);
        ref.read(notificationCenterProvider.notifier).remove('older-version-data');
        if (context.mounted) showTopSnackBar(context, l10n.olderDataBrought, isSuccess: true);
      } catch (e) {
        AppLogger.warning('Data from an older version was not brought in (${errorKind(e)})');
        if (context.mounted) showTopSnackBar(context, l10n.olderDataNotBrought, isError: true, details: '$e');
      }
      return;
    }
  }
  final sure = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.olderDataDeleteTitle,
    body: summary.opened ? l10n.olderDataDeleteBody : l10n.olderDataDeleteUnreadBody,
    confirmLabel: l10n.delete,
  );
  if (sure != true) return;
  try {
    await older.delete();
    ref.read(notificationCenterProvider.notifier).remove('older-version-data');
  } catch (e) {
    AppLogger.warning('Data from an older version was not deleted (${errorKind(e)})');
    if (context.mounted) showTopSnackBar(context, l10n.olderDataNotBrought, isError: true, details: '$e');
  }
}
