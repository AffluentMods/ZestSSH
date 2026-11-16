import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/purchase/desktop_upgrade_view.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Sync() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's upgrade page, both halves picked, adds up: $9.99 + $24.99,
/// less the Bundle's $4.99, is $29.99 (it said a Bundle
/// discount of -$5.00, which comes to $29.98, and that the two together save
/// $5; the website says $4.99).
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  String shown(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  testWidgets('both halves picked: the lines add up to the Bundle price', (tester) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
        isCloudSyncProvider.overrideWith((ref) => _Sync()),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: DesktopUpgradeView()),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
    expect(shown(tester), contains(l10n.deskUpgBothTogetherSaves));

    await tester.tap(find.text(l10n.deskUpgSqueezedTagline));
    await tester.pump();
    expect(shown(tester), contains(l10n.deskUpgAddJuicedToSave));
    await tester.tap(find.text(l10n.deskUpgJuicedTagline));
    await tester.pump();

    final text = shown(tester);
    expect(text, contains(r'-$4.99'));
    expect(text, isNot(contains(r'-$5.00')));
    expect(text, contains(r'$34.98'));
    expect(text, contains(r'$29.99'));
    expect(9.99 + 24.99 - 4.99, closeTo(29.99, 0.001));

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  });

  test('in every language, the two together save 4.99, not 5', () {
    final saving = RegExp(r'4[.,]99');
    final five = RegExp(r'(\$ ?5\b|\b5 ?\$)');
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      for (final line in [words.deskUpgBothTogetherSaves, words.deskUpgAddJuicedToSave, words.deskUpgAddSqueezedToSave]) {
        expect(line, contains(saving), reason: '$locale: $line');
        expect(line, isNot(contains(five)), reason: '$locale: $line');
      }
    }
  });
}
