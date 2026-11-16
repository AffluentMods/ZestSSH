import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/ui/screens/purchase/desktop_upgrade_view.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Sync extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Sync(super.owned);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// A computer's upgrade page offers the half someone does not own at its own
/// price (for someone who owns Squeezed, the page
/// offered Juiced for $20.00, with a "credit" for the Squeezed owned, and the
/// checkout charged $24.99; released versions since 1.7.0). One at a time,
/// each half costs its own price; only the Bundle, bought at once, costs less.
/// The page now says that the half on offer is all that is needed, as the
/// Bundle would charge for the owned half again.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<void> pump(WidgetTester tester, {required bool pro, required bool sync}) async {
    tester.view.physicalSize = const Size(1400, 1100);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro(pro)),
        isCloudSyncProvider.overrideWith((ref) => _Sync(sync)),
        currentUserProvider.overrideWithValue(const UserProfile(uid: 'u-robin', email: 'robin@example.com')),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: DesktopUpgradeView()),
      ),
    ));
    await tester.pump(const Duration(seconds: 2));
  }

  String shown(WidgetTester tester) => tester
      .widgetList<Text>(find.byType(Text))
      .map((t) => t.data ?? t.textSpan?.toPlainText() ?? '')
      .join('\n');

  bool struckThrough(WidgetTester tester) =>
      tester.widgetList<Text>(find.byType(Text)).any((t) => t.style?.decoration == TextDecoration.lineThrough);

  Future<void> done(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  testWidgets('owning Squeezed: Juiced at its own price, no credit, and Juiced alone is all that is needed',
      (tester) async {
    await pump(tester, pro: true, sync: false);
    final text = shown(tester);
    expect(text, contains(r'$24.99'));
    expect(text, isNot(contains(r'$20.00')));
    expect(text, isNot(contains(r'$5.00')));
    expect(text, isNot(contains(r'$29.99')));
    expect(text.toLowerCase(), isNot(contains('credit')));
    expect(struckThrough(tester), isFalse);
    expect(find.text(l10n.deskUpgAddonAllYouNeed('Juiced')), findsOneWidget);
    expect(find.text(l10n.deskUpgAddonNotTheBundle('Squeezed', 'Juiced')), findsOneWidget);
    expect(l10n.deskUpgAddonNotTheBundle('Squeezed', 'Juiced'),
        allOf(contains('Juiced alone is all you need'), contains('charge you for Squeezed again')));
    await done(tester);
  });

  testWidgets('owning Juiced: Squeezed at its own price, no credit, and Squeezed alone is all that is needed',
      (tester) async {
    await pump(tester, pro: false, sync: true);
    final text = shown(tester);
    expect(text, contains(r'$9.99'));
    expect(text, isNot(contains(r'$5.00')));
    expect(text, isNot(contains(r'$4.99')));
    expect(text, isNot(contains(r'$29.99')));
    expect(text.toLowerCase(), isNot(contains('credit')));
    expect(struckThrough(tester), isFalse);
    expect(find.text(l10n.deskUpgAddonAllYouNeed('Squeezed')), findsOneWidget);
    expect(find.text(l10n.deskUpgAddonNotTheBundle('Juiced', 'Squeezed')), findsOneWidget);
    await done(tester);
  });

  test('in every language, the sentence names the half on offer and, twice, the half owned', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final words = lookupAppLocalizations(locale);
      final sentence = words.deskUpgAddonNotTheBundle('OWNED', 'OFFER');
      expect('OWNED'.allMatches(sentence).length, 2, reason: '$locale: $sentence');
      expect('OFFER'.allMatches(sentence).length, 1, reason: '$locale: $sentence');
      expect(words.deskUpgAddonAllYouNeed('OFFER'), contains('OFFER'), reason: '$locale');
    }
  });
}
