import 'package:flutter/material.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/saved_tab_groups_provider.dart' show telnetHostsAmong;
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Two questions the desktop shell asks, as the app's own dialogs (they were
/// plain ones, built in place).

/// Asks before the window closes while [activeCount] sessions are connected:
/// they end with it. True for "close".
Future<bool> confirmCloseWithSessions(BuildContext context, int activeCount) async {
  final l10n = AppLocalizations.of(context)!;
  // An ordinary question (the dialog rules, 3.4): nothing amber.
  final close = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.neutral,
    title: l10n.desktopCloseZestssh,
    body: l10n.desktopActiveSessionsWillDisconnect(activeCount),
    confirmLabel: l10n.close,
  );
  return close == true;
}

/// Asks before an update restarts the app while [activeCount] sessions are
/// connected, as [confirmCloseWithSessions] asks before quitting, with the
/// same words for what ends: the restart closes them all. True for "update
/// and restart".
Future<bool> confirmUpdateWithSessions(BuildContext context, int activeCount, {bool reopen = true}) async {
  final l10n = AppLocalizations.of(context)!;
  // An ordinary question (the dialog rules, 3.4): nothing amber.
  final go = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.neutral,
    title: reopen ? l10n.appUpdateConfirmTitle : l10n.appUpdateConfirmCloseTitle,
    body: l10n.desktopActiveSessionsWillDisconnect(activeCount),
    confirmLabel: reopen ? l10n.appUpdateNow : l10n.appUpdateAndClose,
  );
  return go == true;
}

/// Asks before a connection that nothing encrypts (Telnet) is made: what is
/// typed there, a password among it, crosses the network as it is. True for
/// "connect anyway". [lead], where given, is said first: which hosts, where
/// the person did not just pick the one host themselves.
Future<bool> confirmUnencryptedConnection(BuildContext context, {String? lead}) async {
  final l10n = AppLocalizations.of(context)!;
  // It exposes what is typed (the dialog rules, 3.4): red, and the risk in
  // its amber sentence.
  final connect = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.destructive,
    title: l10n.desktopShellUnencryptedConnection,
    body: lead == null ? l10n.desktopShellTelnetAdvice : '$lead\n\n${l10n.desktopShellTelnetAdvice}',
    warning: l10n.desktopShellTelnetWarning,
    confirmLabel: l10n.desktopShellConnectAnyway,
    // Enter does not connect: the safe choice stands (L10).
    autofocusConfirm: false,
  );
  return connect == true;
}

/// [confirmUnencryptedConnection] for the Telnet hosts among several things
/// opened by one click, or by none: the tabs of the last run brought back as
/// the app starts, a workspace's panes. Asked once for the lot; [lead] says
/// what is opening, with the hosts' names in it. True for "connect anyway";
/// on false the caller leaves [telnet] out and opens the rest. (They opened
/// with no question, found in a security audit. Asked at restore and for
/// a workspace, not at Retry.)
Future<bool> confirmUnencryptedHosts(
  BuildContext context,
  List<Connection> telnet,
  String Function(AppLocalizations l10n, String hosts) lead,
) {
  final names = telnet.map((c) => Redactable.host(c.label.isNotEmpty ? c.label : c.host).display).join(', ');
  return confirmUnencryptedConnection(context, lead: lead(AppLocalizations.of(context)!, names));
}

/// The hosts among [connIds] that the tabs of the last run come back
/// without, as the app starts: its Telnet hosts, where the person says no to
/// the question, which names them. None where no host among them is Telnet,
/// or on "connect anyway".
Future<Set<String>> telnetHostsNotToReopen(BuildContext context, ConnectionsDao dao, Iterable<String> connIds) async {
  final telnet = await telnetHostsAmong(dao, connIds);
  if (telnet.isEmpty) return const {};
  final ids = {for (final c in telnet) c.id};
  // Nobody to ask: they stay closed.
  if (!context.mounted) return ids;
  final ok = await confirmUnencryptedHosts(context, telnet, (l10n, hosts) => l10n.desktopShellTelnetReopenTabs(hosts));
  return ok ? const {} : ids;
}
