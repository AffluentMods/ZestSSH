import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/screens/desktop/widgets/pill_bar.dart';

/// The Hosts pill opens the Hosts drawer wherever it is pressed (on
/// the Hosts page it lit up and nothing opened, as the page
/// hides the drawer, which it would show otherwise).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
  });

  Future<ProviderContainer> pump(WidgetTester tester,
      {required NavSection nav, String? tab, bool? terminalShown}) async {
    tester.view.physicalSize = const Size(1600, 400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        // The strip's sync glyph ticks every 30 seconds: no clock here.
        syncHealthClockProvider.overrideWith((ref) => const Stream<DateTime>.empty()),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topCenter,
            child: PillBar(
              activeNav: nav,
              activeSessionId: tab,
              terminalShown: terminalShown,
              sessions: [
                if (tab != null)
                  MapEntry(
                      tab,
                      const SessionState(
                        status: SessionStatus.connected,
                        connectionId: 'c-web',
                        connectionLabel: 'web-01',
                        host: '192.168.10.21',
                        port: 22,
                        username: 'deploy',
                      )),
              ],
              onNavChanged: (_) {},
              onSessionSelected: (_) {},
              onSessionClosed: (_) {},
              onNewSession: () {},
              onCommandPalette: () {},
              onHelp: () {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();
    return ProviderScope.containerOf(tester.element(find.byType(PillBar)));
  }

  bool lit(WidgetTester tester) => (tester.widget(find.ancestor(
          of: find.text(en.pillHosts),
          matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_ContextPill'))) as dynamic)
      .isActive as bool;

  Future<void> press(WidgetTester tester) async {
    await tester.tap(find.text(en.pillHosts));
    await tester.pump();
  }

  testWidgets('on the Hosts page with no terminal on screen, it opens the drawer there, lit, and closes it again',
      (tester) async {
    final c = await pump(tester, nav: NavSection.hosts);
    expect(lit(tester), isFalse);
    await press(tester);
    expect(c.read(hostsDrawerOnHostsPageProvider), isTrue, reason: 'opened on the Hosts page');
    expect(c.read(hostPanelVisibleProvider), isFalse, reason: 'the switch for elsewhere as it was');
    expect(lit(tester), isTrue);
    await press(tester);
    expect(c.read(hostsDrawerOnHostsPageProvider), isFalse);
    expect(lit(tester), isFalse);
  });

  testWidgets('with a tab open but no terminal of it on screen (each popped out, say), the same', (tester) async {
    final c = await pump(tester, nav: NavSection.hosts, tab: 't1', terminalShown: false);
    await press(tester);
    expect(c.read(hostsDrawerOnHostsPageProvider), isTrue);
    expect(c.read(hostPanelVisibleProvider), isFalse);
    expect(lit(tester), isTrue);
  });

  testWidgets('over a terminal, or on another page, it switches the drawer on and off, lit while on', (tester) async {
    var c = await pump(tester, nav: NavSection.hosts, tab: 't1', terminalShown: true);
    await press(tester);
    expect(c.read(hostPanelVisibleProvider), isTrue);
    expect(c.read(hostsDrawerOnHostsPageProvider), isFalse);
    expect(lit(tester), isTrue);
    await press(tester);
    expect(c.read(hostPanelVisibleProvider), isFalse);
    expect(lit(tester), isFalse);

    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(const SizedBox());
    c = await pump(tester, nav: NavSection.keys);
    await press(tester);
    expect(c.read(hostPanelVisibleProvider), isTrue, reason: 'on the Keys page');
    expect(c.read(hostsDrawerOnHostsPageProvider), isFalse);
    expect(lit(tester), isTrue);
  });

  test('the shell asks the drawer and the pill the same question, with the same answers (read from its file)', () {
    final shell = File('lib/ui/screens/desktop/desktop_shell.dart').readAsStringSync().replaceAll('\r\n', '\n');
    String call(String start, String end) {
      final from = shell.indexOf(start);
      expect(from, isNot(-1), reason: start);
      return shell.substring(from, shell.indexOf(end, from));
    }

    final drawer = call('final hostsDrawerIsShown = hostsDrawerShown(', ');');
    expect(drawer, contains('terminalShown: activeSessionId != null && terminalShown,'));
    expect(drawer, contains('openedOnHostsPage: ref.watch(hostsDrawerOnHostsPageProvider),'));
    // (The bar is built by one function, for the app bar and for a tablet's
    // strip of tabs under it.)
    final pill = call('=> PillBar(', 'onNavChanged:');
    expect(pill, contains('terminalShown: activeSessionId != null && terminalShown,'));
  });
}
