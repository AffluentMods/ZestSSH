import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/automation_refusals.dart';
import 'package:zestssh/features/automation/automation_tab.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Automation as the test has it refuse.
class _Refusing extends AutomationNotifier {
  _Refusing(super.ref);

  void refuse(AutomationBlocked why) => state = state.copyWith(blocked: why);
}

/// The app's root as far as refusals go: it says them, over its router.
class _App extends ConsumerWidget {
  const _App(this.router, {required this.phone});

  final GoRouter router;
  final bool phone;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    sayAutomationRefusals(ref, router: () => router, phone: phone);
    return MaterialApp.router(
      routerConfig: router,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
    );
  }
}

/// Why automation did not run what a link or another app asked (3.0, found
/// while comparing the five platforms' versions): every refusal but
/// automation being off said that automation needs Squeezed, with Upgrade,
/// though a person with Squeezed was refused for an API key that this device
/// does not have, that had expired or that is for another host, or a host
/// whose key is not allowed in runs with nobody there; and the action for
/// automation being off opened a computer's Settings, which has no
/// Automation. Now each says its own reason, and its action goes where that
/// is put right.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group('each refusal is told by its own reason', () {
    const apiKey = 'zk_made-up-key-for-this-test-only';
    const hostKey = 'zk_made-up-key-for-one-host-only';
    late AppDatabase tree;
    late ProviderContainer container;

    Future<void> start({bool pro = true}) async {
      final at = DateTime(2026, 10, 16);
      FlutterSecureStorage.setMockInitialValues({
        'automation_api_keys': AutomationApiKey.encodeList([
          AutomationApiKey.fromSecret(id: 'k-1', label: 'phone', secret: apiKey, createdAt: at),
          AutomationApiKey.fromSecret(id: 'k-2', label: 'web only', secret: hostKey, createdAt: at, scopeConnectionId: 'h-web'),
        ]),
      });
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      tree = AppDatabase.forTesting(NativeDatabase.memory());
      for (final id in ['h-web', 'h-db']) {
        await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
            id: id, label: id, host: '$id.example.com', createdAt: at, updatedAt: at));
      }
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro(pro)),
      ]);
      container.read(databaseSessionProvider.notifier).seed(tree);
      container.read(automationProvider.notifier).setEnabled(true);
    }

    tearDown(() async {
      container.dispose();
      await tree.close();
    });

    Future<AutomationBlocked?> ask(Map<String, dynamic> request) async {
      await container.read(automationProvider.notifier).handleAutomation(request);
      return container.read(automationProvider).blocked;
    }

    test('without Squeezed: needs Squeezed', () async {
      await start(pro: false);
      expect(await ask({'action': 'execute', 'key': apiKey, 'connection_id': 'h-db', 'command': 'uptime'}),
          AutomationBlocked.needsSqueezed);
    });

    test('automation off: off', () async {
      await start();
      container.read(automationProvider.notifier).setEnabled(false);
      expect(await ask({'action': 'execute', 'key': apiKey, 'connection_id': 'h-db', 'command': 'uptime'}),
          AutomationBlocked.off);
    });

    test('an API key this device does not have, or none: a key not known', () async {
      await start();
      expect(await ask({'action': 'execute', 'key': 'zk_not-one-of-these', 'connection_id': 'h-db', 'command': 'uptime'}),
          AutomationBlocked.keyNotKnown);
      expect(await ask({'action': 'execute', 'connection_id': 'h-db', 'command': 'uptime'}),
          AutomationBlocked.keyNotKnown);
    });

    test('a key for one host, asked for another or for a workflow: limited to one host', () async {
      await start();
      expect(await ask({'action': 'execute', 'key': hostKey, 'connection_id': 'h-db', 'command': 'uptime'}),
          AutomationBlocked.otherHost);
      expect(await ask({'action': 'workflow', 'key': hostKey, 'workflow_id': 'w-1'}), AutomationBlocked.otherHost);
    });
  });

  group('each is said, with an action that goes where it is put right', () {
    late ProviderContainer container;
    late GoRouter router;

    Future<void> app(WidgetTester tester, {required bool phone}) async {
      FlutterSecureStorage.setMockInitialValues({});
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        automationProvider.overrideWith((ref) => _Refusing(ref)),
      ]);
      addTearDown(container.dispose);
      router = GoRouter(initialLocation: '/', routes: [
        for (final path in ['/', Routes.upgrade, Routes.automationSettings, Routes.keys, Routes.scheduledTasks])
          GoRoute(path: path, builder: (_, _) => Scaffold(body: Text('page $path'))),
      ]);
      addTearDown(router.dispose);
      await tester.pumpWidget(UncontrolledProviderScope(container: container, child: _App(router, phone: phone)));
      await tester.pump();
    }

    Future<void> refuse(WidgetTester tester, AutomationBlocked why) async {
      (container.read(automationProvider.notifier) as _Refusing).refuse(why);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    Future<void> gone(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 7));
      await tester.pump(const Duration(seconds: 1));
    }

    tearDown(() => debugTopSnackBarOnPhone = null);

    /// The notice of [said] is shown: a phone's card on the screen, or a
    /// computer's in its notification center; its action is pressed.
    Future<void> shownAndPressed(WidgetTester tester, String said, String label, {required bool phone}) async {
      if (phone) {
        expect(find.text(said), findsOneWidget);
        await tester.tap(find.text(label));
      } else {
        final notice = container.read(notificationCenterProvider).history.first;
        final (title, body) = splitToastMessage(said);
        expect((notice.title, notice.body, notice.actionLabel), (title, body, label));
        notice.onAction!();
      }
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    for (final phone in [true, false]) {
      final where = phone ? 'on a phone' : 'on a computer';
      testWidgets(where, (tester) async {
        debugTopSnackBarOnPhone = phone;
        await app(tester, phone: phone);
        for (final why in AutomationBlocked.values) {
          final said = automationBlockedSaid(en, why);
          final fix = automationBlockedFix(en, why, phone: phone);
          router.go('/');
          container.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
          container.read(v3ActiveSessionTabProvider.notifier).state = 's-1';
          await tester.pump();
          await refuse(tester, why);
          if (why != AutomationBlocked.needsSqueezed) {
            expect(said, isNot(contains('Squeezed')), reason: '$why');
          }
          expect(container.read(automationProvider).blocked, isNull, reason: 'cleared once said');
          await shownAndPressed(tester, said, fix.label, phone: phone);
          if (fix.route != null) {
            expect(find.text('page ${fix.route}'), findsOneWidget, reason: '$why');
          } else {
            expect(container.read(activeSidebarNavProvider), fix.section, reason: '$why');
            expect(container.read(automationTabWantedProvider), fix.tab, reason: '$why: the tab asked for');
            container.read(automationTabWantedProvider.notifier).state = null;
            expect(container.read(v3ActiveSessionTabProvider), isNull, reason: 'the section in front');
          }
          await gone(tester);
        }
        // The same reason again is said again.
        final before = container.read(notificationCenterProvider).history.length;
        await refuse(tester, AutomationBlocked.off);
        await gone(tester);
        await refuse(tester, AutomationBlocked.off);
        if (phone) {
          expect(find.text(en.automationBlockedDisabled), findsOneWidget);
        } else {
          final told = container.read(notificationCenterProvider).history.take(2).map((n) => n.title).toList();
          expect(told, [en.automationBlockedDisabled, en.automationBlockedDisabled]);
          expect(container.read(notificationCenterProvider).history.length, before + 2);
        }
        await gone(tester);
        await tester.pumpWidget(const SizedBox());
      });
    }
  });

  test('the words and where each goes, in every language: Squeezed only where it is what is needed; the '
      "key's own switch named", () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l = lookupAppLocalizations(locale);
      for (final why in AutomationBlocked.values) {
        final said = automationBlockedSaid(l, why);
        expect(said, isNotEmpty);
        expect(said.contains('Squeezed'), why == AutomationBlocked.needsSqueezed, reason: '$locale $why');
      }
      expect(automationBlockedSaid(l, AutomationBlocked.keyNotUnattended), contains(l.zestKeysUnattendedSwitch),
          reason: '$locale');
    }
    final table = {
      for (final why in AutomationBlocked.values)
        why: (
          automationBlockedFix(en, why, phone: true).route,
          automationBlockedFix(en, why, phone: false).section,
        ),
    };
    expect(table, {
      AutomationBlocked.needsSqueezed: (Routes.upgrade, null),
      AutomationBlocked.off: (Routes.automationSettings, NavSection.automation),
      // Automation's Triggers tab on a computer, where its API keys are: the
      // sidebar's Triggers are the terminal's, with no keys (found in a 3.0
      // docs review).
      AutomationBlocked.keyNotKnown: (Routes.automationSettings, NavSection.automation),
      AutomationBlocked.otherHost: (Routes.automationSettings, NavSection.automation),
      AutomationBlocked.keyNotUnattended: (Routes.keys, NavSection.keys),
      // A Telnet host: to the hosts, where its person opens it and is asked.
      AutomationBlocked.plaintextHost: (Routes.home, NavSection.hosts),
      // A remote screen: to the hosts too, where its person opens it.
      AutomationBlocked.screenHost: (Routes.home, NavSection.hosts),
      // A phone's scheduled tasks; a computer's are under Automation's Runs (4.0).
      AutomationBlocked.taskGone: (Routes.scheduledTasks, NavSection.automation),
    });
    expect(automationBlockedFix(en, AutomationBlocked.taskGone, phone: false).tab, AutomationTab.runs);
    expect(automationBlockedFix(en, AutomationBlocked.needsSqueezed, phone: false).route, Routes.upgrade);
    for (final why in [AutomationBlocked.keyNotKnown, AutomationBlocked.otherHost]) {
      expect(automationBlockedFix(en, why, phone: false).tab, AutomationTab.triggers);
      expect(automationBlockedFix(en, why, phone: false).label, en.zestAutoSectionApiKeys);
      expect(automationBlockedFix(en, why, phone: true).label, en.zestAutoSectionApiKeys);
    }
  });
}
