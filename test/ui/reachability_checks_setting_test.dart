// The setting for the checks of whether hosts can be reached (checks
// led to bans by fail2ban's sshd jail in its ddos mode,
// even with Server Monitor off). It was on unless turned off, under words
// that called a check a ping. Now: off until turned on, turned on only
// after a question that says what a server sees of a check, and from every
// switch there is for it; and nothing else in the app connects to a host
// without signing in unless its person pressed the button that says so.

import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/notifications/widgets/notification_prefs_sheet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/settings_service.dart';
import 'package:zestssh/ui/screens/settings/notification_settings_screen.dart';
import 'package:zestssh/ui/screens/settings/reachability_checks_setting.dart';

import '../visual/shots_util.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  final l10n = lookupAppLocalizations(const Locale('en'));
  const toggle = ValueKey('settings-reach-checks');

  Future<ProviderContainer> pump(
    WidgetTester tester,
    Widget home, {
    Map<String, Object> saved = const {},
    Locale locale = const Locale('en'),
    Size size = const Size(1100, 800),
  }) async {
    await tester.runAsync(loadShotFonts);
    SharedPreferences.setMockInitialValues(saved);
    final prefs = await SharedPreferences.getInstance();
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [sharedPreferencesProvider.overrideWithValue(prefs)]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: home,
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// The question's words, all on screen or none of them.
  List<String> question(AppLocalizations t) => [
        t.reachChecksAskTitle,
        t.reachChecksAskBody,
        t.reachChecksAskSeen,
        t.reachChecksAskBan,
        t.reachChecksAskSkipped,
        t.reachChecksAskMonitor,
      ];
  int asked(AppLocalizations t) => question(t).where((s) => find.text(s).evaluate().isNotEmpty).length;

  Future<void> tapOn(WidgetTester tester, Finder what) async {
    await tester.ensureVisible(what);
    await tester.pumpAndSettle();
    await tester.tap(what);
    await tester.pumpAndSettle();
  }

  testWidgets('off until turned on; turning it on asks first and says what a check is; a no turns nothing on, a '
      'yes does, and turning it off asks nothing', (tester) async {
    final container = await pump(tester, const NotificationSettingsScreen());
    final prefs = await SharedPreferences.getInstance();
    bool on() => tester.widget<SwitchListTile>(find.byKey(toggle)).value;
    expect(on(), isFalse);
    expect(container.read(healthChecksEnabledProvider), isFalse);
    expect(find.descendant(of: find.byKey(toggle), matching: find.text(l10n.settingsServerHealthChecks)), findsOneWidget);
    // What a check is, behind its More (4.0); the switch asks first anyway.
    expect(
        find.descendant(of: find.byKey(toggle), matching: find.text(l10n.settingsServerHealthChecksDesc)), findsNothing);
    await tester.tap(find.byKey(ValueKey('settings-row-more-${l10n.settingsServerHealthChecks}')));
    await tester.pumpAndSettle();
    expect(on(), isFalse, reason: "More's tap is More's");
    expect(
        find.descendant(of: find.byKey(toggle), matching: find.text(l10n.settingsServerHealthChecksDesc)), findsOneWidget);
    expect(find.text(l10n.settingsInlineCheckInterval), findsNothing, reason: 'nothing runs at any interval');

    // Asked, and no: nothing is turned on.
    await tapOn(tester, find.byKey(toggle));
    expect(asked(l10n), 6, reason: 'what it does, what a server sees, who may be banned, what is left alone');
    expect(on(), isFalse, reason: 'not on while it is being asked');
    await tapOn(tester, find.text(l10n.cancel));
    expect(asked(l10n), 0);
    expect((on(), container.read(healthChecksEnabledProvider), prefs.getBool('reachability_checks_enabled')),
        (false, false, null));

    // Asked, and yes.
    await tapOn(tester, find.byKey(toggle));
    expect(asked(l10n), 6);
    await tapOn(tester, find.text(l10n.reachChecksAskTurnOn));
    expect(asked(l10n), 0);
    expect((on(), container.read(healthChecksEnabledProvider), prefs.getBool('reachability_checks_enabled')),
        (true, true, true));
    expect(find.text(l10n.settingsInlineCheckInterval), findsOneWidget);
    expect(SettingsService(prefs).serverHealthChecksEnabled, isTrue, reason: 'read again as the app starts');

    // Off: at once, with no question.
    await tapOn(tester, find.byKey(toggle));
    expect(asked(l10n), 0);
    expect((on(), container.read(healthChecksEnabledProvider), prefs.getBool('reachability_checks_enabled')),
        (false, false, false));
  });

  testWidgets('what the setting held before is not taken for a choice to be checked: it was on unless turned off, '
      'under words that called a check a ping', (tester) async {
    final container =
        await pump(tester, const NotificationSettingsScreen(), saved: {'health_checks_enabled': true});
    final prefs = await SharedPreferences.getInstance();
    expect(SettingsService(prefs).serverHealthChecksEnabled, isFalse);
    expect(container.read(healthChecksEnabledProvider), isFalse);
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);
    // Nor is it this device's choice sent to the person's other devices.
    await container.read(settingsUpdaterProvider).setHealthChecksEnabled(true);
    expect(SettingsService(prefs).exportSyncedSettings().keys,
        isNot(anyOf(contains('reachability_checks_enabled'), contains('health_checks_enabled'))));
  });

  testWidgets('the switch in the notification panel\'s own settings asks the same question', (tester) async {
    final container = await pump(
      tester,
      Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => showNotificationPrefsSheet(context),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tapOn(tester, find.text('open'));
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isFalse);
    expect(find.descendant(of: find.byKey(toggle), matching: find.text(l10n.notifPrefsServerHealthChecks)), findsOneWidget);
    await tapOn(tester, find.byKey(toggle));
    expect(asked(l10n), 6);
    expect(container.read(healthChecksEnabledProvider), isFalse);
    await tapOn(tester, find.text(l10n.reachChecksAskTurnOn));
    expect(container.read(healthChecksEnabledProvider), isTrue);
    expect(tester.widget<SwitchListTile>(find.byKey(toggle)).value, isTrue);
  });

  testWidgets('the question on a phone, in every language: all of it can be read and both answers reached',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      for (final locale in AppLocalizations.supportedLocales) {
        final t = lookupAppLocalizations(locale);
        final container = await pump(
          tester,
          Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => setReachabilityChecks(context, ref, true),
                child: const Text('ask'),
              ),
            ),
          ),
          locale: locale,
          size: const Size(360, 640),
        );
        await tapOn(tester, find.text('ask'));
        expect(tester.takeException(), isNull, reason: '$locale');
        expect(find.text(t.reachChecksAskTitle), findsOneWidget, reason: '$locale');
        // The last line of it, by scrolling where it is long.
        await tester.ensureVisible(find.text(t.reachChecksAskMonitor));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull, reason: '$locale');
        final view = tester.getRect(find.byType(MaterialApp));
        for (final answer in [t.reachChecksAskTurnOn, t.cancel]) {
          final at = tester.getRect(find.text(answer).last);
          expect(view.contains(at.topLeft) && view.contains(at.bottomRight), isTrue, reason: '$locale: $answer');
        }
        await tapOn(tester, find.text(t.reachChecksAskTurnOn).last);
        expect(container.read(healthChecksEnabledProvider), isTrue, reason: '$locale');
        await tester.pumpWidget(const SizedBox());
      }
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('its words in every language say what a check is, and not that it is a ping', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = [
        t.settingsHealthChecks,
        t.settingsHealthChecksHelp,
        t.settingsServerHealthChecks,
        t.settingsServerHealthChecksDesc,
        t.notifPrefsServerHealthChecks,
        t.notifPrefsServerHealthChecksDesc,
        ...question(t),
        t.reachChecksAskTurnOn,
      ];
      for (final s in said) {
        expect(s.trim(), isNotEmpty, reason: '$locale');
        for (final ping in ['ping', 'пинг', 'पिंग', '핑']) {
          expect(s.toLowerCase(), isNot(contains(ping)), reason: '$locale: a check is a connection, not a ping');
        }
      }
      // One name for it in all three places.
      expect({t.settingsHealthChecks, t.settingsServerHealthChecks, t.notifPrefsServerHealthChecks}, hasLength(1),
          reason: '$locale');
      expect(question(t).toSet(), hasLength(6), reason: '$locale');
      expect(t.reachChecksAskBody, contains('ZestSSH'), reason: '$locale');
      expect(t.reachChecksAskBan, allOf(contains('fail2ban'), contains('sshd'), contains('ddos')), reason: '$locale');
      expect(t.reachChecksAskSeen, contains('SSH'), reason: '$locale');
      // The setup guide's step for Server Monitor names the monitor's own
      // switch. It said to turn these checks on, which the monitor never
      // needed.
      expect(t.setupMonitor2, contains(t.monitorAgentlessEnable), reason: '$locale');
      expect(t.setupMonitor2, contains('ZestSSH'), reason: '$locale');
      // The status bar's latency is the session's own round trip, not a
      // connection of its own to the host's port.
      for (final gone in ['ping', 'tcp']) {
        expect(t.desktopStatusConnectionLatency.toLowerCase(), isNot(contains(gone)), reason: '$locale');
      }
      expect(t.desktopStatusConnectionLatency.trim(), isNotEmpty, reason: '$locale');
    }
  });

  group('nothing gets around it (read from the app\'s own files)', () {
    Iterable<File> sources() => Directory('lib')
        .listSync(recursive: true)
        .whereType<File>()
        .where((f) => f.path.endsWith('.dart') && !f.path.replaceAll('\\', '/').contains('/l10n/generated/'));
    String path(File f) => f.path.replaceAll('\\', '/');

    test('only the question turns the checks on: no switch does it by itself', () {
      final callers = [
        for (final f in sources())
          if (f.readAsStringSync().contains('setHealthChecksEnabled(')) path(f),
      ]..sort();
      expect(callers, [
        'lib/providers/settings_providers.dart',
        'lib/ui/screens/settings/reachability_checks_setting.dart',
      ]);
      // And every switch for it goes there.
      final switches = {
        'lib/features/notifications/widgets/notification_prefs_sheet.dart': 1,
        'lib/ui/screens/desktop/widgets/settings_inline_view.dart': 2,
        'lib/ui/screens/settings/notification_settings_screen.dart': 1,
        'lib/ui/screens/settings/settings_screen.dart': 1,
      };
      for (final entry in switches.entries) {
        final text = File(entry.key).readAsStringSync();
        expect('onChanged: (v) => setReachabilityChecks(context, ref, v),'.allMatches(text), hasLength(entry.value),
            reason: entry.key);
        expect('value: ref.watch(healthChecksEnabledProvider),'.allMatches(text), hasLength(entry.value),
            reason: '${entry.key}: a switch that shows the setting and sets it some other way');
      }
    });

    test('the app starts the checks as it starts, and stops them wherever it stops Server Monitor: in the '
        'background, with its window not in front, and locked', () {
      final app = File('lib/app.dart').readAsStringSync();
      int times(String what) => what.allMatches(app).length;
      expect(
          times('_reachabilityWiring ??= wireReachabilityChecks(ProviderScope.containerOf(context, listen: false));'),
          1);
      expect(times('_reachabilityWiring?.call();'), 1, reason: 'and ended with the app');
      const monitor = 'ref.read(agentlessMonitorPollerProvider.notifier)';
      const checks = 'ref.read(connectionHealthProvider.notifier)';
      expect(times('$monitor.pause();'), 3, reason: 'the places this test knows of');
      expect(times('$checks.pause();'), times('$monitor.pause();'));
      expect(times('$checks.resume();'), times('$monitor.resume();'));
      // Each right beside the monitor's.
      final lines = app.split('\n').map((l) => l.trim()).toList();
      for (final (i, line) in lines.indexed) {
        if (line == '$monitor.pause();') expect(lines[i + 1], '$checks.pause();', reason: 'line ${i + 1}');
      }
    });

    test('a screen that opens asks for no check that is not due, and its refresh asks for all of them; the '
        'status bar counts reachable hosts only where they are checked', () {
      final table = File('lib/ui/screens/desktop/widgets/monitor_table_view.dart').readAsStringSync();
      expect(table, contains('if (mounted) _refreshEverything();'));
      // The header's refresh button (disabled while a refresh runs).
      expect(table, contains('onRefresh: () => _refreshEverything(asked: true),'));
      expect(table, contains('onPressed: refreshing ? null : onRefresh,'));
      expect(table, contains('.checkAll(conns, asked: asked);'));
      expect(table, contains('.checkAll([match.first.connection], asked: true);'));
      expect('_refreshEverything('.allMatches(table), hasLength(3), reason: 'itself, opening, and the button');

      final phone = File('lib/ui/screens/monitoring/server_monitor_screen.dart').readAsStringSync();
      expect(phone, contains(RegExp(r'^\s*_refreshEverything\(\);', multiLine: true)), reason: 'opening');
      expect(phone, contains(': () => _refreshEverything(showSnackbar: true, asked: true),'));
      expect(phone, contains('onRefresh: () => _refreshEverything(asked: true),'));
      expect(phone, contains('await healthNotifier.checkAll(conns, asked: asked);'));
      expect('_refreshEverything('.allMatches(phone), hasLength(4));

      final detail = File('lib/ui/screens/monitoring/server_detail_screen.dart').readAsStringSync();
      expect(detail, contains('if (mounted) _refreshHost();'));
      expect(detail, contains('onRefresh: () => _refreshHost(asked: true),'));
      expect(detail, contains('.checkAll([match.connection], asked: asked);'));

      // A refresh its person pressed also has Server Monitor try again the
      // hosts it had stopped trying; a screen that opens does not.
      const monitor = 'ref.read(agentlessMonitorPollerProvider.notifier)';
      expect(table, contains('      if (asked) $monitor.retry();'));
      expect(table, contains('    $monitor.retry(connectionId);'));
      expect(phone, contains('      if (asked) $monitor.retry();'));
      expect(detail, contains('    if (asked) $monitor.retry(_id);'));
      for (final screen in [table, phone, detail]) {
        expect('.retry('.allMatches(screen).length, screen == table ? 2 : 1);
      }

      final bar = File('lib/ui/screens/desktop/widgets/desktop_status_bar.dart').readAsStringSync();
      expect(bar, contains('reachableHostsCount(healthMap, checksOn: ref.watch(healthChecksEnabledProvider));'));
    });

    test('every place the app opens a connection itself is known, with what it is for', () {
      // A new one is either a sign-in, something its person asked for by a
      // button that says so, or it belongs behind the setting above.
      const known = {
        'lib/features/cloud_import/cloud_tls.dart': 'a cloud provider\'s API, for an import its person started',
        'lib/features/hosts/host_tester.dart': 'the tests of the host editor and the host panel, when their button is pressed',
        'lib/features/onboarding/data/lan_scan_service.dart': 'the scan of this network, when its button is pressed',
        'lib/features/orchards/orchard_providers.dart': 'ZestSSH Cloud\'s stream of an Orchard',
        'lib/features/screens/proxmox/proxmox_console.dart':
            'a Proxmox guest\'s console, through its account\'s API, when its person opens it',
        'lib/features/screens/session/screen_shell_service.dart':
            'a remote screen reached with no SSH host (VeNCrypt TLS), when its person opens it',
        'lib/features/sharing/share_providers.dart': 'ZestSSH Cloud\'s stream of a shared session',
        'lib/providers/terminal_providers.dart': 'the first hop of a session: it signs in',
        'lib/services/automation_service.dart': 'a command run for an automation: it signs in',
        'lib/services/connection_health_service.dart': 'the checks, behind the setting',
        'lib/services/hardware_token/os_ssh_agent.dart': 'the SSH agent of this device',
        'lib/services/port_forward_service.dart': 'a forward\'s target on this device',
        'lib/services/serial_service.dart': 'a console server: it signs in',
        'lib/services/ssh_service.dart': 'a session: it signs in',
        'lib/services/telnet_service.dart': 'a telnet session',
        'lib/services/worker/worker_connection_isolate.dart': 'a session: it signs in',
      };
      // (The app's own opener of an SSH connection, openSshSocket, is one of
      // them: every place that calls it opens a connection. An opener handed
      // on to be called later, as telnet's `openSocket = Socket.connect` that
      // a test can stand in for, counts as well.)
      final opens = RegExp(
          r'\b(?:(?:Socket|SecureSocket|RawSocket|SSHSocket|WebSocket)\.(?:connect|startConnect)|openSshSocket)(?:\(|\s*[;,)])');
      final found = [
        for (final f in sources())
          if (opens.hasMatch(f.readAsStringSync().split('\n').where((l) => !l.trimLeft().startsWith('//')).join('\n')))
            path(f),
      ]..sort();
      expect(found, known.keys.toList()..sort());
    });
  });
}
