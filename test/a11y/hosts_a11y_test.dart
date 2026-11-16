import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_dialog.dart';
import 'package:zestssh/features/hosts/pages/hosts_home_page.dart';
import 'package:zestssh/features/hosts/state/host_multi_select.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/features/networks/engine/network_detector.dart';
import 'package:zestssh/features/networks/engine/network_state.dart';
import 'package:zestssh/features/networks/models/network.dart';
import 'package:zestssh/features/networks/models/network_trigger.dart';
import 'package:zestssh/features/networks/pages/networks_mobile_page.dart';
import 'package:zestssh/features/networks/pages/networks_page.dart';
import 'package:zestssh/providers/network_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/screens/desktop/widgets/port_forward_list_view.dart';
import 'package:zestssh/ui/screens/home/home_screen.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';

import 'hosts_a11y_harness.dart';

/// The accessibility guard of the Hosts area (4.0, the large
/// accessibility pass): each main screen against Flutter's guidelines (tap
/// targets: 48 on a touch screen, 32 with a mouse; every tappable thing
/// named; text contrast in Ember, Graphite and Daylight).
const _audit = bool.fromEnvironment('ZEST_A11Y_AUDIT');

/// Flutter's text contrast check, in the audit only (`--dart-define=
/// ZEST_A11Y_AUDIT=true`): it reads the colours off the picture, and on text
/// of 12 px and less it takes the edge of an antialiased letter, or an
/// outlined chip's border, for the text's colour, and fails words that read
/// at 5:1 and more (each it reported was checked). The guard holds
/// the contrast of the words' colours themselves instead
/// (hosts_contrast_test.dart).
const AccessibilityGuideline? _contrast = _audit ? textContrastGuideline : null;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  void check(List<String> found) {
    final failures = [...found];
    if (_audit) {
      for (final f in failures) {
        debugPrint('A11Y $f');
      }
      return;
    }
    expect(failures, isEmpty, reason: failures.join('\n\n'));
  }

  Finder card(String name) => find.descendant(of: find.byType(HostCard), matching: find.text(name));

  for (final themeId in a11yThemes) {
    testWidgets('computer Hosts page: cards, list, panel, selection, menu ($themeId)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final handle = tester.ensureSemantics();
      final s = await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}), themeId: themeId);
      final failures = <String>[...takeAllExceptions(tester, 'hosts-cards')];
      final guides = [...computerGuidelines, ?_contrast];
      failures.addAll(await a11yFailures(tester, 'hosts-cards-$themeId', guides));
      await tester.tap(card('db-primary'));
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'hosts-panel-$themeId', guides));
      await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'hosts-list-$themeId', guides));
      await tester.tap(find.byKey(const ValueKey('hosts-view-compact')));
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'hosts-compact-$themeId', guides));
      await tester.tap(find.byKey(const ValueKey('hosts-view-cards')));
      await a11ySettle(tester);
      s.container.read(hostMultiSelectProvider.notifier).selectAll(['c0', 'c1', 'c8']);
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'hosts-select-$themeId', guides));
      s.container.read(hostMultiSelectProvider.notifier).exit();
      await a11ySettle(tester);
      await tester.tapAt(tester.getCenter(card('web-02')), buttons: kSecondaryButton);
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'hosts-menu-$themeId', guides));
      failures.addAll(takeAllExceptions(tester, 'hosts-end'));
      check(failures);
      handle.dispose();
      await finishA11y(tester);
    });
  }

  // A tablet is touch sized: 48 to every target.
  testWidgets('tablet Hosts page: cards, panel, list (graphite)', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final handle = tester.ensureSemantics();
    await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}), size: const Size(1366, 1024), touch: true);
    final failures = <String>[...takeAllExceptions(tester, 'tablet')];
    failures.addAll(await a11yFailures(tester, 'tablet-cards', touchGuidelines));
    await tester.tap(card('db-primary'));
    await a11ySettle(tester);
    failures.addAll(await a11yFailures(tester, 'tablet-panel', touchGuidelines));
    await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
    await a11ySettle(tester);
    failures.addAll(await a11yFailures(tester, 'tablet-list', touchGuidelines));
    failures.addAll(takeAllExceptions(tester, 'tablet-end'));
    check(failures);
    handle.dispose();
    await finishA11y(tester);
  });

  GoRouter phoneRouter() => GoRouter(routes: [
        GoRoute(path: '/', builder: (_, _) => const HomeScreen()),
        GoRoute(path: '/a11y/edit-host', builder: (_, _) => const ConnectionEditScreen(connectionId: 'c0')),
        GoRoute(path: Routes.portForwards, builder: (_, _) => const PortForwardsPhoneScreen()),
        GoRoute(path: Routes.networks, builder: (_, _) => const NetworksMobileScreen()),
        GoRoute(path: '/:rest(.*)', builder: (_, state) => Scaffold(body: Text(state.uri.toString()))),
      ]);

  List<Override> networkOverrides() {
    final fallback = Network.systemDefault();
    return [
      currentNetworkStateProvider.overrideWith((ref) async => const NetworkState(
          localAddresses: ['10.0.1.37'], connectivityKind: ConnectivityKind.wifi, ssid: 'Cafe-Guest')),
      detectedNetworkProvider.overrideWith((ref) => Stream.value(fallback)),
      detectedNetworkMatchProvider
          .overrideWith((ref) => Stream.value(NetworkMatch(network: fallback, reason: const AlwaysTrigger()))),
      activeForwardIdsProvider.overrideWith((ref) => {'pf-graf'}),
    ];
  }

  for (final themeId in a11yThemes) {
    testWidgets('phone Hosts tab, its host sheet, the host form, forwards and networks ($themeId)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      debugHostFormOnComputer = false;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugHostFormOnComputer = null;
      });
      final handle = tester.ensureSemantics();
      final router = phoneRouter();
      final db = (await tester.runAsync(forwardsDatabase))!;
      await pumpA11y(tester, const SizedBox(),
          router: router, themeId: themeId, size: const Size(390, 844), db: db, overrides: networkOverrides(), touch: true);
      final guides = [...touchGuidelines, ?_contrast];
      final failures = <String>[...takeAllExceptions(tester, 'phone')];
      failures.addAll(await a11yFailures(tester, 'phone-hosts-$themeId', guides));
      await tester.tap(find.byKey(const ValueKey('phone-host-more-c8')));
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'phone-sheet-$themeId', guides));
      Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
      await a11ySettle(tester);
      router.push('/a11y/edit-host');
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'phone-form-$themeId', guides));
      router.pop();
      await a11ySettle(tester);
      router.push(Routes.portForwards);
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'phone-forwards-$themeId', guides));
      router.pop();
      await a11ySettle(tester);
      router.push(Routes.networks);
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'phone-networks-$themeId', guides));
      failures.addAll(takeAllExceptions(tester, 'phone-end'));
      check(failures);
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets('computer host editor ($themeId)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      debugHostFormOnComputer = true;
      addTearDown(() {
        debugDefaultTargetPlatformOverride = null;
        debugHostFormOnComputer = null;
      });
      final handle = tester.ensureSemantics();
      await pumpA11y(tester, ConnectionEditScreen(connectionId: 'c8', inDialog: true, onClose: () {}),
          themeId: themeId, size: const Size(1100, 900));
      final guides = [...computerGuidelines, ?_contrast];
      final failures = <String>[...takeAllExceptions(tester, 'editor')];
      failures.addAll(await a11yFailures(tester, 'editor-$themeId', guides));
      failures.addAll(takeAllExceptions(tester, 'editor-end'));
      check(failures);
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets('command palette and Import hosts ($themeId)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final handle = tester.ensureSemantics();
      late BuildContext at;
      late WidgetRef refAt;
      await pumpA11y(
          tester,
          Consumer(builder: (context, ref, _) {
            at = context;
            refAt = ref;
            return const SizedBox.expand();
          }),
          themeId: themeId);
      final guides = [...computerGuidelines, ?_contrast];
      final failures = <String>[];
      showCommandPalette(at, refAt, actions: const [], onOpenInSplit: (_) {}, onOpenSftp: (_) {}).ignore();
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'palette-$themeId', guides));
      await tester.enterText(find.byKey(const ValueKey('palette-query')), 'web');
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'palette-typed-$themeId', guides));
      Navigator.of(at, rootNavigator: true).pop();
      await a11ySettle(tester);
      showImportHostsDialog(at).ignore();
      await a11ySettle(tester);
      failures.addAll(await a11yFailures(tester, 'import-$themeId', guides));
      failures.addAll(takeAllExceptions(tester, 'palette-end'));
      check(failures);
      handle.dispose();
      await finishA11y(tester);
    });

    testWidgets('computer Networks and Port forwarding ($themeId)', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);
      final handle = tester.ensureSemantics();
      final guides = [...computerGuidelines, ?_contrast];
      await pumpA11y(tester, const NetworksPage(),
          themeId: themeId, overrides: networkOverrides(), db: (await tester.runAsync(forwardsDatabase))!);
      final failures = <String>[...takeAllExceptions(tester, 'networks')];
      failures.addAll(await a11yFailures(tester, 'networks-$themeId', guides));
      await tester.pumpWidget(const SizedBox());
      await pumpA11y(tester, const PortForwardListView(),
          themeId: themeId, overrides: networkOverrides(), db: (await tester.runAsync(forwardsDatabase))!);
      failures.addAll(await a11yFailures(tester, 'forwards-$themeId', guides));
      failures.addAll(takeAllExceptions(tester, 'forwards-end'));
      check(failures);
      handle.dispose();
      await finishA11y(tester);
    });
  }

  // The system's text at 150% on a computer: nothing cut or overlapping (an
  // overflow is an exception in a test), the targets as large.
  testWidgets('computer Hosts page, editor, palette, forwards and networks at 150% text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    debugHostFormOnComputer = true;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugHostFormOnComputer = null;
    });
    final handle = tester.ensureSemantics();
    final failures = <String>[];
    await pumpA11y(tester, HostsHomePage(onConnectTo: (_) {}), textScale: 1.5);
    failures.addAll(takeAllExceptions(tester, 'hosts-150'));
    failures.addAll(await a11yFailures(tester, 'hosts-150', computerGuidelines));
    await tester.tap(card('db-primary'));
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'panel-150'));
    failures.addAll(await a11yFailures(tester, 'panel-150', computerGuidelines));
    await tester.tap(find.byKey(const ValueKey('hosts-view-list')));
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'list-150'));
    failures.addAll(await a11yFailures(tester, 'list-150', computerGuidelines));
    await tester.pumpWidget(const SizedBox());
    await pumpA11y(tester, ConnectionEditScreen(connectionId: 'c8', inDialog: true, onClose: () {}),
        size: const Size(1100, 900), textScale: 1.5);
    failures.addAll(takeAllExceptions(tester, 'editor-150'));
    failures.addAll(await a11yFailures(tester, 'editor-150', computerGuidelines));
    await tester.pumpWidget(const SizedBox());
    await pumpA11y(tester, const NetworksPage(),
        textScale: 1.5, overrides: networkOverrides(), db: (await tester.runAsync(forwardsDatabase))!);
    failures.addAll(takeAllExceptions(tester, 'networks-150'));
    await tester.pumpWidget(const SizedBox());
    await pumpA11y(tester, const PortForwardListView(),
        textScale: 1.5, overrides: networkOverrides(), db: (await tester.runAsync(forwardsDatabase))!);
    failures.addAll(takeAllExceptions(tester, 'forwards-150'));
    check(failures);
    handle.dispose();
    await finishA11y(tester);
  });

  // A phone at 200% text.
  testWidgets('phone Hosts tab, host sheet, host form, forwards and networks at 200% text', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    debugHostFormOnComputer = false;
    addTearDown(() {
      debugDefaultTargetPlatformOverride = null;
      debugHostFormOnComputer = null;
    });
    final handle = tester.ensureSemantics();
    final router = phoneRouter();
    final db = (await tester.runAsync(forwardsDatabase))!;
    await pumpA11y(tester, const SizedBox(),
        router: router, size: const Size(390, 844), db: db, overrides: networkOverrides(), touch: true, textScale: 2);
    final failures = <String>[...takeAllExceptions(tester, 'phone-200')];
    failures.addAll(await a11yFailures(tester, 'phone-200', touchGuidelines));
    await tester.tap(find.byKey(const ValueKey('phone-host-more-c8')));
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'sheet-200'));
    failures.addAll(await a11yFailures(tester, 'sheet-200', touchGuidelines));
    Navigator.of(tester.element(find.byKey(const ValueKey('zest-sheet')))).pop();
    await a11ySettle(tester);
    router.push('/a11y/edit-host');
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'form-200'));
    failures.addAll(await a11yFailures(tester, 'form-200', touchGuidelines));
    router.pop();
    await a11ySettle(tester);
    router.push(Routes.portForwards);
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'forwards-200'));
    router.pop();
    await a11ySettle(tester);
    router.push(Routes.networks);
    await a11ySettle(tester);
    failures.addAll(takeAllExceptions(tester, 'networks-200'));
    check(failures);
    handle.dispose();
    await finishA11y(tester);
  });
}
