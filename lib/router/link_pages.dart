/// The pages a `zestssh://` link names (settings, snippets, identities,
/// profile, connection/new, connection/edit/ and an id, import/ssh-config,
/// upgrade), opened where each device opens them (3.0; found 16 October 2026
/// while comparing the five versions). A phone goes to the page. A computer
/// went there too, to a phone's page that took the shell's place, its whole
/// window, with nothing to go back by; it opens each in its shell now, which
/// stays: Settings as its pop-up, Snippets and Keys as its pages, the
/// account in Settings, a host's editor and the SSH config import as their
/// dialogs, Upgrade over the shell as its palette opens it.
library;

import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/config/official_identity.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_jump_provider.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart';
import 'package:zestssh/utils/platform_utils.dart' show desktopShellInUse;

/// Switches a computer's shell to its page [section], in front of any
/// terminal.
void openShellSection(WidgetRef ref, NavSection section) {
  ref.read(v3ActiveSessionTabProvider.notifier).state = null;
  ref.read(activeSidebarNavProvider.notifier).state = section;
  ref.read(workTabsProvider.notifier).clearActiveTab();
}

/// Opens the page [route] names, as DeepLinkService.uriToRoute gives it:
/// a phone goes to it; a computer opens it in its shell, and a route that
/// is no page there leaves the shell as it is. [onComputer] is for tests.
Future<void> openLinkPage(WidgetRef ref, GoRouter router, String route, {bool? onComputer}) async {
  if (!(onComputer ?? desktopShellInUse)) {
    router.go(route);
    return;
  }
  final context = router.routerDelegate.navigatorKey.currentContext;
  if (context == null || !context.mounted) return;
  const editOne = '${Routes.connectionEdit}/';
  switch (route) {
    case Routes.settings:
      ref.read(settingsPopupOpenProvider.notifier).state = true;
    case Routes.snippets:
      openShellSection(ref, NavSection.snippets);
    case Routes.identityList:
      openShellSection(ref, NavSection.keys);
    case Routes.profile:
      jumpToDesktopSettings(ref, SettingsJumpTarget.account);
    case Routes.connectionEdit:
      await ConnectionEditScreen.showAdaptive(context);
    case Routes.sshConfigImport:
      final outcome = await showDesktopSshConfigImport(context);
      if (outcome != null && context.mounted) {
        toastImportOutcome(context, added: outcome.imported, failedLimit: outcome.failedLimit);
      }
    case Routes.upgrade:
      // (A link to the upgrade opens nothing in a build with no plans.)
      if (zestHasPlans) unawaited(router.push<void>(Routes.upgrade));
    default:
      if (route.startsWith(editOne)) {
        await ConnectionEditScreen.showAdaptive(context, connectionId: route.substring(editOne.length));
      }
  }
}
