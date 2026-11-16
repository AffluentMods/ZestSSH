// A phone's comparison of the plans says what the app holds each to (found
// in a survey of what the app gates). It said, in English in
// every language, that Free kept 3 hosts, 5 snippets and 3 themes, had no
// variable substitution, no sync and no backups, and that Juiced had every
// Squeezed feature; the app keeps hosts and snippets without limit on Free,
// with variables, gives every built-in theme, syncs with storage of one's own
// and backs up, and Juiced is ZestSSH Cloud, with Free or with Squeezed. Its
// card for Squeezed listed unlimited snippets and variable substitution too.

import 'dart:io';

import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeMonitorLimit, freeSessionLimit;
import 'package:zestssh/ui/screens/purchase/widgets/plan_comparison_table.dart';

void main() {
  final fr = lookupAppLocalizations(const Locale('fr'));

  Future<void> pump(WidgetTester tester) async {
    tester.view.physicalSize = const Size(480, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(const MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: Locale('fr'),
      home: Scaffold(body: SingleChildScrollView(child: PlanComparisonTable())),
    ));
    await tester.pumpAndSettle();
  }

  /// What the row named [name] says for Free, Squeezed and Juiced: a tick, a
  /// cross, or the value written.
  List<String> row(WidgetTester tester, String name) {
    final line = find.ancestor(of: find.text(name), matching: find.byType(Row)).first;
    final said = <String>[];
    for (final element in find.descendant(of: line, matching: find.byWidgetPredicate((w) => w is Icon || w is Text))
        .evaluate()) {
      final widget = element.widget;
      if (widget is Icon) {
        said.add(widget.icon == LucideIcons.checkCircle2 ? 'yes' : 'no');
      } else if (widget is Text && widget.data != name) {
        said.add(widget.data!);
      }
    }
    return said;
  }

  testWidgets("each row, in the person's language, as the app holds Free, Squeezed and Juiced to it", (tester) async {
    await pump(tester);
    expect(find.text(fr.upgradeFeature), findsOneWidget);
    for (final tier in [fr.upgradeFreshTitle, fr.upgradeSqueezedTitle, fr.upgradeFeatureCloudSync]) {
      expect(find.text(tier), findsOneWidget, reason: tier);
    }
    final everyone = ['yes', 'yes', 'yes'];
    final squeezed = ['no', 'yes', 'no'];
    expect(row(tester, fr.planRowBasics), everyone);
    expect(row(tester, fr.planRowOwnStorageSync), everyone);
    expect(row(tester, fr.planRowBackups), everyone);
    expect(row(tester, fr.planRowBuiltInThemes), everyone);
    // Port forwarding is free.
    expect(row(tester, fr.upgradeFeaturePortForwarding), everyone);
    expect(row(tester, fr.planRowSessions), ['$freeSessionLimit', '∞', '$freeSessionLimit']);
    expect(row(tester, fr.planRowMonitors), ['$freeMonitorLimit', '∞', '$freeMonitorLimit']);
    for (final name in [
      fr.upgradeFeatureAllThemes,
      fr.upgradeFeatureJumpServer,
      fr.upgradeFeatureSpeechToText,
      fr.deskUpgSqueezedFeatureAutomation,
    ]) {
      expect(row(tester, name), squeezed, reason: name);
    }
    expect(row(tester, fr.planRowZestCloud), ['no', 'no', 'yes']);
    // (Juiced is a name, and stays one.)
    for (final gone in ['Connections', 'Snippets', 'Themes', 'Feature', 'Auto Backups']) {
      expect(find.text(gone), findsNothing, reason: gone);
    }
  });

  test("the phone's card for Squeezed lists what Squeezed unlocks, nothing every tier has", () {
    final screen = File('lib/ui/screens/purchase/upgrade_screen.dart').readAsStringSync();
    expect('l10n.upgradeFeatureUnlimitedMonitors,'.allMatches(screen), hasLength(2));
    expect('l10n.deskUpgSqueezedFeatureAutomation,'.allMatches(screen), hasLength(2));
    expect(screen, isNot(contains('l10n.upgradeFeatureUnlimitedSnippets')));
    expect(screen, isNot(contains('l10n.upgradeFeatureVariableSubstitution')));
    // Port forwarding is every tier's, and Juiced names its 7 devices.
    expect(screen, isNot(contains('l10n.upgradeFeaturePortForwarding')));
    expect('l10n.juicedSevenDevices,'.allMatches(screen), hasLength(2));
    final desktop = File('lib/ui/screens/purchase/desktop_upgrade_view.dart').readAsStringSync();
    expect('l10n.juicedSevenDevices,'.allMatches(desktop), hasLength(2));
    expect(File('lib/ui/screens/purchase/pricing_modal.dart').readAsStringSync(),
        isNot(contains('l10n.pricingFeaturePortForwarding')));
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      // What Squeezed unlocks no longer names port forwarding, in any language.
      expect(t.terminalProGateMsg('X'), isNot(contains(t.upgradeFeaturePortForwarding.toLowerCase())),
          reason: locale.toLanguageTag());
    }
    // Nor the computer's list: snippets with variables are every tier's.
    expect(lookupAppLocalizations(const Locale('en')).deskUpgSqueezedFeatureThemes, isNot(contains('snippet')));
  });
}
