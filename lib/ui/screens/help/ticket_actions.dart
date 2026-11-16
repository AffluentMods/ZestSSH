import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_service.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/help/ticket_widgets.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/report_scrub.dart';

/// What can be done to a whole ticket, from its menu in the Help panel and on a
/// phone, and from the Support Hub's buttons: one question and one outcome each.

/// Puts the whole ticket on the clipboard.
Future<void> copyTicket(BuildContext context, SupportTicketRow t) async {
  final l10n = AppLocalizations.of(context)!;
  await Clipboard.setData(ClipboardData(text: ticketAsText(l10n, t)));
  if (context.mounted) showTopSnackBar(context, l10n.ticketCopied, isSuccess: true);
}

/// The Support Hub's Copy link (3.4): the forum post of a public report, where
/// it has one, which anyone can open; else the ticket's number, which is how
/// support finds it. Never the ticket's id or token.
Future<void> copyTicketLink(BuildContext context, SupportTicketRow t) async {
  final l10n = AppLocalizations.of(context)!;
  final link = t.discordUrl;
  final text = link ?? (t.number == null ? null : ticketNumberLabel(t.number));
  if (text == null) return;
  await Clipboard.setData(ClipboardData(text: text));
  if (context.mounted) showTopSnackBar(context, l10n.ticketCopied, isSuccess: true);
}

/// The Support Hub's Copy details: the whole ticket with the facts it was sent
/// with, scrubbed as every Copy details is, since it is what gets pasted
/// somewhere else. (The menu's Copy conversation is the person's own text, as
/// they wrote it.)
Future<void> copyTicketDetails(BuildContext context, SupportTicketRow t) async {
  final l10n = AppLocalizations.of(context)!;
  final sent = t.cachedConversation?.sentWith;
  final b = StringBuffer(ticketAsText(l10n, t));
  if (sent != null) {
    b
      ..writeln()
      ..writeln()
      ..write('App ${sent.appVersion} (${sent.build}) on ${sent.platform} ${sent.osVersion}, ${sent.locale}, ${sent.tier}');
  }
  await Clipboard.setData(ClipboardData(text: ReportScrub.scrub(b.toString())));
  if (context.mounted) showTopSnackBar(context, l10n.ticketCopied, isSuccess: true);
}

/// Closes the ticket once the person says so, and says so where that fails.
Future<void> closeTicketAsking(BuildContext context, WidgetRef ref, SupportTicketRow t) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(ticketServiceProvider);
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.neutral,
    title: l10n.ticketCloseConfirmTitle,
    body: t.isPrivate ? l10n.ticketCloseConfirmBody : l10n.ticketCloseConfirmBodyPublic,
    confirmLabel: l10n.ticketClose,
  );
  if (ok != true) return;
  final closed = await service.close(t.nonce);
  if (!closed && context.mounted) {
    showTopSnackBar(context, l10n.ticketCloseFailed);
  }
}

/// Removes the ticket from this device once the person says so.
Future<void> forgetTicketAsking(
  BuildContext context,
  WidgetRef ref,
  SupportTicketRow t, {
  required VoidCallback onRemoved,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final service = ref.read(ticketServiceProvider);
  final ok = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.ticketRemoveConfirmTitle,
    body: t.isSent && !t.isGone ? l10n.ticketRemoveConfirmBody : l10n.ticketRemoveConfirmBodyLocal,
    confirmLabel: l10n.ticketRemoveConfirm,
  );
  if (ok != true) return;
  await service.forget(t.nonce);
  onRemoved();
}

/// The whole ticket as plain text, for the clipboard: what the person would
/// paste somewhere themselves.
String ticketAsText(AppLocalizations l10n, SupportTicketRow t) {
  final c = t.cachedConversation;
  final b = StringBuffer()
    ..writeln(t.title)
    ..writeln([
      ticketTypeLabel(l10n, t.ticketType),
      if (t.number != null) ticketNumberLabel(t.number),
    ].join(' '))
    ..writeln()
    ..writeln('${l10n.ticketYou}:')
    ..writeln(c?.body ?? '');
  if (c?.expected != null) {
    b
      ..writeln()
      ..writeln('${l10n.reportBugWhatExpected}:')
      ..writeln(c!.expected);
  }
  for (final m in c?.messages ?? const <TicketMessage>[]) {
    b
      ..writeln()
      ..writeln(m.fromStaff
          ? '${m.staffName ?? l10n.ticketSupportName}:'
          : '${l10n.ticketYou}:')
      ..writeln(m.body);
  }
  return b.toString().trimRight();
}
