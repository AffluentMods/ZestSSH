/// Opening a saved host from outside the app (3.0): a home-screen widget's
/// host, `zestssh://connect?id=<id>`, or a shortcut that names one,
/// `zestssh://connect?name=<name or id>` (Siri on an iPhone). The iPhone's
/// widget and Siri sent `connect?host=`, which nothing answered, so both did
/// nothing. Any web page can open such a link, so it never connects without
/// asking; the hosts it can open are your Tree's, the ones a widget lists.
/// And a host by its address, `zestssh://connect?host=`, opens Quick connect
/// with it typed in.
library;

import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/quick_target.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/connection_share_url_service.dart';
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart' show confirmUnencryptedConnection;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart' show desktopShellInUse;
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/utils/host_address.dart';

/// Whether a connect link shows its session as a computer does. Null in the
/// app (the system it runs on decides).
@visibleForTesting
bool? debugConnectLinkOnComputer;

/// What a connect link names: a host by its id, or by its name (or its id).
typedef ConnectLinkTarget = ({String? id, String? name});

/// What [uri] names, where it is a connect link.
ConnectLinkTarget? connectLinkOf(Uri uri) {
  if (uri.scheme != 'zestssh' || (uri.host + uri.path) != 'connect') return null;
  final id = uri.queryParameters['id']?.trim();
  if (id != null && id.isNotEmpty) return (id: id, name: null);
  final name = uri.queryParameters['name']?.trim();
  if (name != null && name.isNotEmpty) return (id: null, name: name);
  return null;
}

/// The host of [tree] that [link] names: by its id; by its name, in any
/// case, else by its id. [twice] where more than one host has the name.
Future<({Connection? host, bool twice})> hostOfConnectLink(AppDatabase tree, ConnectLinkTarget link) async {
  final id = link.id;
  if (id != null) return (host: await tree.connectionsDao.getById(id), twice: false);
  final name = link.name!.toLowerCase();
  final all = await tree.connectionsDao.getAll();
  final named = [for (final c in all) if (c.label.toLowerCase() == name) c];
  if (named.length > 1) return (host: null, twice: true);
  return (host: named.singleOrNull ?? all.where((c) => c.id == link.name).firstOrNull, twice: false);
}

/// Opens the host [link] names, once the person says so: a session started
/// in your Tree (shown first where another space is on screen). What stands
/// in the way is said: no such host, two of that name, or the free plan's
/// limit. Returns the session started, or null.
Future<String?> openConnectLink(BuildContext context, WidgetRef ref, ConnectLinkTarget link) async {
  // Locked: nothing can be read, and nothing is opened.
  final tree = ref.read(databaseSessionProvider);
  if (tree == null) return null;
  final l10n = AppLocalizations.of(context)!;
  final found = await hostOfConnectLink(tree, link);
  if (!context.mounted) return null;
  final host = found.host;
  if (host == null) {
    final named = Redactable.host(link.name ?? link.id!).display;
    showTopSnackBar(context, found.twice ? l10n.connectLinkTwoHosts(named) : l10n.connectLinkNoHost(named), isWarning: true);
    return null;
  }
  // Names the host as it is: while the screen is recorded, recording is
  // turned off first, or nothing is opened (it named a stand-in).
  if (!await confirmRevealWhileRecording(context, ref) || !context.mounted) return null;
  final shownLabel = Redactable.host(host.label.isNotEmpty ? host.label : host.host).display;
  final shownAddress = Redactable.address(hostWithPort(host.host, host.port)).display;
  // Who asked is outside the app: said in its amber sentence (the dialog
  // rules, 3.4).
  final approved = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.warning,
    title: l10n.connectLinkTitle(shownLabel),
    body: '',
    warning: l10n.connectLinkBody(shownAddress),
    confirmLabel: l10n.commonConnect,
    // Something outside the app raised it: Enter meant for a terminal answers
    // nothing.
    autofocusConfirm: false,
  );
  if (approved != true || !context.mounted) return null;
  // A host that speaks Telnet: warned of, as everywhere else it is opened
  // (it was opened with no word of it).
  if (host.protocol == 'telnet') {
    if (!await confirmUnencryptedConnection(context) || !context.mounted) return null;
  }
  // The host is your Tree's: its session works there.
  if (ref.read(activeSpaceProvider) is! TreeSpace) {
    await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
    if (!context.mounted) return null;
  }
  final sessionId = ref.read(activeSessionsProvider.notifier).startSession(host);
  if (sessionId == null) showTopSnackBar(context, l10n.hostsHomeFreeTierLimit, isError: true);
  return sessionId;
}

/// Answers [uri] where it is a connect link: opens the host it names, once
/// the person says so, and shows its session. False where it is none.
Future<bool> answerConnectLink(Uri uri, WidgetRef ref, GoRouter router) async {
  final link = connectLinkOf(uri);
  if (link == null) return false;
  AppLogger.info('Deep link → connect to a saved host');
  final context = router.routerDelegate.navigatorKey.currentContext;
  if (context == null || !context.mounted) {
    AppLogger.warning('Connect link arrived before UI ready - dropping');
    return true;
  }
  final sessionId = await openConnectLink(context, ref, link);
  if (sessionId == null) return true;
  if (debugConnectLinkOnComputer ?? desktopShellInUse) {
    // A computer shows it in its shell, the session's tab in front (a new
    // tab is). (It went to a phone's terminal page, which took the shell's
    // place.)
    ref.read(workTabsProvider.notifier).onSessionCreated(sessionId);
    router.go(Routes.home);
  } else {
    router.go('/terminal/$sessionId');
  }
  return true;
}

// ─── A host by its address: Quick connect ──────────────────────────

/// What [uri] asks where it is a quick connect link,
/// `zestssh://connect?host=<address>&user=<user>&port=<port>` (documented,
/// and answered by nothing until 3.0; found while comparing
/// the five versions): the text Quick connect is opened with, as it would be
/// typed ([QuickTarget.typed]), or null where the link names no host Quick
/// connect would read; [isLink] false where it is no such link (one naming
/// a saved host by its id or name is [connectLinkOf]'s).
({bool isLink, String? text}) quickConnectLinkOf(Uri uri) {
  if (uri.scheme != 'zestssh' || (uri.host + uri.path) != 'connect' || connectLinkOf(uri) != null) {
    return (isLink: false, text: null);
  }
  // An IPv6 host may come between brackets; Quick connect's text puts
  // them on itself (they were put on twice, and the link named no host).
  final host = unbracketHost(uri.queryParameters['host']?.trim() ?? '');
  if (host.isEmpty) return (isLink: false, text: null);
  final user = uri.queryParameters['user']?.trim();
  final named = user == null || user.isEmpty ? null : user;
  // A user that would read as more than a user, or other than it is (as a
  // share link refuses one).
  if (named != null &&
      (named.contains('@') ||
          named.length > 64 ||
          named.runes.any((r) => (r >= 0x80 && r <= 0x9f) || ConnectionShareUrlService.isSpoofingControl(r)))) {
    return (isLink: true, text: null);
  }
  final portGiven = uri.queryParameters['port']?.trim() ?? '';
  final port = portGiven.isEmpty ? null : int.tryParse(portGiven);
  // (One out of range Quick connect does not read, below.)
  if (portGiven.isNotEmpty && port == null) return (isLink: true, text: null);
  final target = QuickTarget(user: named, host: host, port: port ?? 22, portTyped: port != null);
  // What Quick connect reads back as this same host, or no host at all (an
  // address that is no name or address it takes, or longer than one may be).
  final typed = target.typed;
  return (isLink: true, text: parseQuickTarget(typed) == target ? typed : null);
}

/// The text a quick connect link asked Quick connect to be opened with,
/// waiting for the screen that opens it: a computer's shell, a phone's list
/// of hosts (its quick connect bar). Taken by the one that shows it.
final quickConnectLinkText = ValueNotifier<String?>(null);

/// Answers [uri] where it is a quick connect link: Quick connect is opened
/// with the host it names typed in, for the person to connect or not
/// (nothing connects by itself: any web page can open such a link). One that
/// names no host is said to. False where it is none.
bool answerQuickConnectLink(Uri uri, GoRouter router) {
  final link = quickConnectLinkOf(uri);
  if (!link.isLink) return false;
  final text = link.text;
  if (text == null) {
    AppLogger.warning('Quick connect link names no host');
    final context = router.routerDelegate.navigatorKey.currentContext;
    if (context != null && context.mounted) {
      showTopSnackBar(context, AppLocalizations.of(context)!.connectLinkNotHost, isWarning: true);
    }
    return true;
  }
  AppLogger.info('Deep link → quick connect');
  quickConnectLinkText.value = text;
  // A phone's quick connect bar is on its list of hosts; a computer's shell
  // opens Quick connect over whatever it shows.
  if (!(debugConnectLinkOnComputer ?? desktopShellInUse)) router.go(Routes.home);
  return true;
}
