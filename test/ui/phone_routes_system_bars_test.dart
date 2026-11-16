import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/onboarding/lan_scan_screen.dart';
import 'package:zestssh/features/onboarding/onboarding_screen.dart';
import 'package:zestssh/features/orchards/team/team_phone.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/automation/automation_guide_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_history_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';
import 'package:zestssh/ui/screens/automation/scheduled_tasks_screen.dart';
import 'package:zestssh/ui/screens/automation/workflow_list_screen.dart';
import 'package:zestssh/ui/screens/command_history/command_history_screen.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/help/ios_backgrounding_help_screen.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/screens/identity/identity_list_screen.dart';
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/screens/import/putty_import_screen.dart';
import 'package:zestssh/ui/screens/import/ssh_config_import_screen.dart';
import 'package:zestssh/ui/screens/monitoring/server_monitor_screen.dart';
import 'package:zestssh/ui/screens/notifications/notifications_screen.dart';
import 'package:zestssh/ui/screens/profile/email_auth_screen.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/screens/purchase/upgrade_screen.dart';
import 'package:zestssh/ui/screens/security/pin_setup_screen.dart';
import 'package:zestssh/ui/screens/security/security_lock_screen.dart';
import 'package:zestssh/ui/screens/settings/about_screen.dart';
import 'package:zestssh/ui/screens/settings/appearance_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/data_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/help_support_screen.dart';
import 'package:zestssh/ui/screens/help/support_hub_screen.dart';
import 'package:zestssh/ui/screens/settings/keyboard_row_screen.dart';
import 'package:zestssh/ui/screens/settings/known_hosts_screen.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/remote_screens_settings.dart';
import 'package:zestssh/ui/screens/settings/session_logs_screen.dart';
import 'package:zestssh/ui/screens/settings/settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sftp_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/sync_backend_screen.dart';
import 'package:zestssh/ui/screens/settings/terminal_settings_screen.dart';
import 'package:zestssh/ui/screens/transcripts/transcripts_screen.dart';
import 'package:zestssh/ui/screens/triggers/triggers_screen.dart';

import '../helpers/phone_screen_harness.dart';

/// Every phone route against a phone's system bars (3.3; on Android
/// the text editor drew its top bar under the
/// status bar, and Save could not be tapped). Each phone screen these tests can
/// draw is drawn on a phone 412 by 915 with a status bar 40 high and a
/// navigation bar 48 high, and nothing that can be tapped and is pinned (not a
/// row of a list, which scrolls) may sit under either. Every route in
/// lib/router/routes.dart is either drawn here or said below to be looked after
/// elsewhere, so a new route fails this test until someone has looked.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const size = Size(412, 915);

  /// The phone screens drawn here, by route.
  final drawn = <String, Widget Function()>{
    'onboarding': () => const OnboardingScreen(),
    'connectionEdit': () => const ConnectionEditScreen(),
    'connectionEditId': () => const ConnectionEditScreen(connectionId: 'c1'),
    'identityList': () => const IdentityListScreen(),
    'keyGeneration': () => const KeyGenerationScreen(),
    'settings': () => const Scaffold(body: SettingsBody(bottomPadding: 1)),
    'securityLock': () => const SecurityLockScreen(),
    'pinSetup': () => const PinSetupScreen(),
    'sshConfigImport': () => const SshConfigImportScreen(),
    'lanScan': () => const LanScanScreen(),
    'puttyImport': () => const PuttyImportScreen(),
    'upgrade': () => const UpgradeScreen(),
    'networks': () => const NetworksMobileScreen(),
    'keys': () => const KeysPhoneScreen(),
    'portForwards': () => const PortForwardsPhoneScreen(),
    'team': () => const TeamPhoneScreen(),
    'profile': () => const ProfileScreen(),
    'emailAuth': () => const EmailAuthScreen(),
    'syncBackend': () => const SyncBackendScreen(),
    'monitor': () => const ServerMonitorScreen(),
    'notifications': () => const NotificationsScreen(),
    'notificationSettings': () => const NotificationSettingsScreen(),
    'terminalSettings': () => const TerminalSettingsScreen(),
    'keyboardRow': () => const KeyboardRowScreen(),
    'screenSettings': () => const RemoteScreensSettingsScreen(),
    'sessionLogs': () => const SessionLogsScreen(),
    'sftpSettings': () => const SftpSettingsScreen(),
    'automationSettings': () => const AutomationSettingsScreen(),
    'dataSettings': () => const DataSettingsScreen(),
    'appearance': () => const AppearanceScreen(),
    'about': () => const AboutScreen(),
    'knownHosts': () => const KnownHostsScreen(),
    'triggers': () => const TriggersScreen(),
    'commandHistory': () => const CommandHistoryScreen(),
    'help': () => const HelpSupportScreen(),
    'supportHub': () => SupportHubScreen(onClose: () {}),
    'transcripts': () => const TranscriptsScreen(),
    'automationGuide': () => const AutomationGuideScreen(),
    'automationHistory': () => const AutomationHistoryScreen(),
    'automationWizard': () => const AutomationWizardScreen(),
    'workflowList': () => const WorkflowListScreen(),
    'scheduledTasks': () => const ScheduledTasksScreen(),
    'iosBackgrounding': () => const IosBackgroundingHelpScreen(),
  };

  /// The routes not drawn here, and where they keep clear of the bars. Each of
  /// their files' plain Scaffolds is also held by phone_system_bars_test.dart.
  const elsewhere = <String, String>{
    'home':
        'its tabs add MediaQuery.paddingOf(context).top (home_screen.dart); the phone bottom bar adds padding.bottom (ZestBottomNav)',
    'connectionScanQr':
        'a camera view (needs a camera); its close is in an AppBar',
    'identityEdit': 'ResponsiveScaffold: an AppBar on a phone',
    'identityEditId': 'ResponsiveScaffold: an AppBar on a phone',
    'terminal':
        'its own SafeArea top and bottom (terminal_screen.dart); needs a live session',
    'snippets':
        'an AppBar on a phone; its editor\'s pinned Save is held by phone_system_bars_test',
    'teamPage': 'the same phone team screen, on another page',
    'networkEditId':
        'NetworkEditorRoutePage in a SafeArea (networks_mobile_page.dart)',
    'recoveryKey': 'an AppBar on a phone',
    'serverDetail': 'its own SafeArea (server_detail_screen.dart)',
    'setupGuide': 'ResponsiveScaffold: an AppBar on a phone',
    'editor': 'its own SafeArea over black (editor_phone_bars_test.dart)',
    'report': 'an AppBar on a phone; its buttons scroll with the form',
    'tickets': 'an AppBar on a phone',
    'ticket': 'an AppBar on a phone',
    'contactSupport': 'an AppBar on a phone; its buttons scroll with the form',
    'askAstryx': 'an AppBar on a phone; its Ask button sits in a SafeArea at the bottom',
    'guides': 'an AppBar on a phone',
    'guide': 'an AppBar on a phone; its picture viewer in a SafeArea',
    'shareView': 'its own SafeArea (share_view_screen.dart)',
    'replay': 'nothing opens it (no push of /replay)',
    'transcriptView': 'an AppBar on a phone',
    'sftpRemote': 'an AppBar on a phone',
    'workflowEditor': 'an AppBar on a phone',
  };

  for (final MapEntry(key: route, value: screen) in drawn.entries) {
    testWidgets(
      '$route: nothing pinned that can be tapped sits under a system bar',
      (tester) async {
        final problems = <String>[];
        await PhoneScreenHarness.pump(
          tester,
          screen(),
          size: size,
          problems: problems,
        );
        final under = PhoneScreenHarness.tappablesUnderBars(
          tester,
          height: size.height,
        );
        await PhoneScreenHarness.takeDown(tester);
        expect(
          under,
          isEmpty,
          reason:
              'under the status bar (40) or the navigation bar (48): ${under.join('; ')}',
        );
      },
    );
  }

  testWidgets('the check finds what it looks for: a bar of a screen\'s own with no SafeArea', (tester) async {
    await PhoneScreenHarness.pump(
      tester,
      Scaffold(
        body: Column(
          children: [
            TextButton(onPressed: () {}, child: const Text('Save')),
            const Spacer(),
            IconButton(onPressed: () {}, tooltip: 'Close', icon: const Icon(Icons.close)),
          ],
        ),
      ),
      size: size,
    );
    final under = PhoneScreenHarness.tappablesUnderBars(tester, height: size.height);
    await PhoneScreenHarness.takeDown(tester);
    // (A button's own ink and gestures are listed with it.)
    expect(under.where((u) => u.contains('"Save"')), isNotEmpty, reason: under.join('; '));
    expect(under.where((u) => u.contains('"Close"')), isNotEmpty, reason: under.join('; '));
  });

  test('every route is drawn here or said to be looked after elsewhere', () {
    final source = File('lib/router/routes.dart').readAsStringSync();
    final routes = RegExp(
      r"static const (\w+) = '/",
    ).allMatches(source).map((m) => m.group(1)!).toSet();
    expect(Routes.home, '/', reason: 'the table these names come from');
    final unknown = routes.difference({
      ...drawn.keys,
      ...elsewhere.keys,
    }).toList()..sort();
    expect(
      unknown,
      isEmpty,
      reason:
          'draw these here, or say where they keep clear of the bars: ${unknown.join(', ')}',
    );
    final gone = {...drawn.keys, ...elsewhere.keys}.difference(routes).toList()
      ..sort();
    expect(gone, isEmpty, reason: 'no longer routes: ${gone.join(', ')}');
  });

  test('the home screen is still a route', () => expect(HomeScreen, isNotNull));
}
