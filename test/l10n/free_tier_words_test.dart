import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimitDesktop, freeSessionLimitMobile;

/// The free tier's numbers (4.0: 5 sessions on a computer, 3 on a phone) are
/// placeholders in every language, taken from the app's limit, so the next
/// change is one line in purchase_providers.dart and no string says an old
/// number.
void main() {
  final locales = AppLocalizations.supportedLocales;
  String tiers(AppLocalizations t, [int d = freeSessionLimitDesktop, int m = freeSessionLimitMobile]) =>
      t.helpFaqTiersBody(d, m);
  String pricing(AppLocalizations t, [int d = freeSessionLimitDesktop, int m = freeSessionLimitMobile]) =>
      t.pricingFeatureSessionLimit(d, m);

  test('every language says the limits the app checks, and nothing of 4 and 2', () {
    expect(locales, hasLength(12));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [tiers(t), pricing(t)]) {
        expect(s, contains('$freeSessionLimitDesktop'), reason: '$locale: $s');
        expect(s, contains('$freeSessionLimitMobile'), reason: '$locale: $s');
        expect(s, isNot(contains('{')), reason: '$locale: $s');
      }
      // The old numbers are not written into the text: other numbers show through.
      expect(pricing(t, 4, 2), isNot(pricing(t)), reason: '$locale');
      expect(tiers(t, 4, 2), isNot(tiers(t)), reason: '$locale');
    }
  });

  test('English, and the plural forms of the languages that need them', () {
    final en = lookupAppLocalizations(const Locale('en'));
    expect(pricing(en, 5, 3), '5 sessions on desktop, 3 on mobile');
    expect(pricing(en, 1, 1), '1 session on desktop, 1 on mobile');
    expect(tiers(en, 5, 3), startsWith('Free: 5 sessions on desktop and 3 on mobile, unlimited hosts'));

    final ru = lookupAppLocalizations(const Locale('ru'));
    expect(pricing(ru, 5, 3), '5 сеансов на компьютере, 3 на мобильном');
    expect(pricing(ru, 4, 2), '4 сеанса на компьютере, 2 на мобильном');
    expect(pricing(ru, 21, 3), startsWith('21 сеанс '));
    expect(tiers(ru, 5, 3), startsWith('Free: 5 сессий на компьютере и 3 на мобильном,'));

    final ar = lookupAppLocalizations(const Locale('ar'));
    expect(pricing(ar, 5, 3), startsWith('5 جلسات على سطح المكتب'));
    expect(pricing(ar, 11, 3), startsWith('11 جلسة '));

    final fr = lookupAppLocalizations(const Locale('fr'));
    expect(pricing(fr, 5, 3), '5 sessions sur ordinateur, 3 sur mobile');
    final de = lookupAppLocalizations(const Locale('de'));
    expect(tiers(de, 5, 3), startsWith('Free: 5 Sitzungen am Desktop und 3 auf dem Mobilgerät,'));
    final zh = lookupAppLocalizations(const Locale('zh'));
    expect(pricing(zh, 5, 3), '桌面端 5 个会话，移动端 3 个');
  });
}
