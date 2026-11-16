import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/automation/automation_tab.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/desktop_providers.dart'
    show NavSection, activeSidebarNavProvider, v3ActiveSessionTabProvider;
import 'package:zestssh/providers/work_tabs_provider.dart' show workTabsProvider;
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Says, each time automation does not run what a link or another app asked
/// of it, why, with an action that goes where that is put right (called from
/// the app's build; [router] is the app's). (3.0: in English,
/// never shown, and its action turned automation on in one tap, from a notice
/// any link could bring up. Found while comparing the five
/// versions: every reason but automation being off said that it needs
/// Squeezed, with Upgrade, to people who have it; and the action for
/// automation being off opened a computer's Settings, which has no
/// Automation.)
void sayAutomationRefusals(WidgetRef ref, {required GoRouter Function() router, required bool phone}) {
  ref.listen(automationProvider, (prev, next) {
    final why = next.blocked;
    if (why == null || why == prev?.blocked) return;
    // Said where it can be seen, in the app's language (3.0: it
    // looked for a messenger above the app, found none and was never shown).
    final context = router().routerDelegate.navigatorKey.currentContext;
    if (context == null || !context.mounted) return;
    final fix = automationBlockedFix(AppLocalizations.of(context)!, why, phone: phone);
    showAutomationBlockedNotice(
      context,
      why: why,
      actionLabel: fix.label,
      onAction: () {
        final route = fix.route;
        if (route == Routes.home) {
          // The hosts are the page under every other: gone back to, not
          // opened a second time over itself.
          router().go(route!);
        } else if (route != null) {
          router().push(route);
        } else {
          // A computer's section, in front of any session or work tab.
          ref.read(v3ActiveSessionTabProvider.notifier).state = null;
          ref.read(activeSidebarNavProvider.notifier).state = fix.section!;
          ref.read(workTabsProvider.notifier).clearActiveTab();
          if (fix.tab != null) ref.read(automationTabWantedProvider.notifier).state = fix.tab;
        }
      },
    );
    // Cleared, so that the next refusal is said even for the same reason.
    ref.read(automationProvider.notifier).clearBlocked();
  });
}

/// The notice of a refusal: why ([automationBlockedSaid]), and an action.
void showAutomationBlockedNotice(BuildContext context,
    {required AutomationBlocked why, required String actionLabel, required VoidCallback onAction}) {
  showTopSnackBar(
    context,
    automationBlockedSaid(AppLocalizations.of(context)!, why),
    isWarning: true,
    duration: const Duration(seconds: 6),
    actionLabel: actionLabel,
    onAction: onAction,
  );
}

/// What a notice says of why automation did not run what it was asked.
String automationBlockedSaid(AppLocalizations l10n, AutomationBlocked why) => switch (why) {
      AutomationBlocked.needsSqueezed => l10n.automationBlockedPro,
      AutomationBlocked.off => l10n.automationBlockedDisabled,
      AutomationBlocked.keyNotKnown => l10n.automationBlockedKey,
      AutomationBlocked.otherHost => l10n.automationBlockedScope,
      AutomationBlocked.keyNotUnattended => l10n.automationBlockedUnattended(l10n.zestKeysUnattendedSwitch),
      AutomationBlocked.plaintextHost => l10n.automationBlockedTelnet,
      AutomationBlocked.screenHost => l10n.automationBlockedScreen,
      AutomationBlocked.taskGone => l10n.automationBlockedTaskGone,
    };

/// Where what stopped automation is put right, and the name of the notice's
/// action that goes there: Upgrade; automation's settings (on a phone, where
/// it is turned on and its API keys are; on a computer, the Automation
/// section turns it on, and its Triggers tab ([tab]) has the API keys); the
/// keys, where a key is allowed in runs with nobody there; the scheduled
/// tasks, for a task deleted or turned off. A phone goes to a
/// route, a computer to a section of its shell. (A refused key went, on a
/// computer, to the sidebar's Triggers, which are the terminal's output
/// triggers and hold no API keys, by an action named "Triggers".)
({String label, String? route, NavSection? section, AutomationTab? tab}) automationBlockedFix(
  AppLocalizations l10n,
  AutomationBlocked why, {
  required bool phone,
}) =>
    switch (why) {
      AutomationBlocked.needsSqueezed => (label: l10n.upgrade, route: Routes.upgrade, section: null, tab: null),
      AutomationBlocked.off => phone
          ? (label: l10n.settingsTitle, route: Routes.automationSettings, section: null, tab: null)
          : (label: l10n.narrowSidebarAutomation, route: null, section: NavSection.automation, tab: null),
      AutomationBlocked.keyNotKnown || AutomationBlocked.otherHost => phone
          ? (label: l10n.zestAutoSectionApiKeys, route: Routes.automationSettings, section: null, tab: null)
          : (
              label: l10n.zestAutoSectionApiKeys,
              route: null,
              section: NavSection.automation,
              tab: AutomationTab.triggers,
            ),
      AutomationBlocked.keyNotUnattended => phone
          ? (label: l10n.narrowSidebarKeys, route: Routes.keys, section: null, tab: null)
          : (label: l10n.narrowSidebarKeys, route: null, section: NavSection.keys, tab: null),
      // A Telnet host: the hosts, where its person opens it and is asked. A
      // remote screen: the hosts, where its person opens it and looks at it.
      AutomationBlocked.plaintextHost || AutomationBlocked.screenHost => phone
          ? (label: l10n.narrowSidebarHosts, route: Routes.home, section: null, tab: null)
          : (label: l10n.narrowSidebarHosts, route: null, section: NavSection.hosts, tab: null),
      // A computer's scheduled tasks are under Automation's Runs (4.0).
      AutomationBlocked.taskGone => phone
          ? (label: l10n.schedTaskTitle, route: Routes.scheduledTasks, section: null, tab: null)
          : (label: l10n.narrowSidebarAutomation, route: null, section: NavSection.automation, tab: AutomationTab.runs),
    };
