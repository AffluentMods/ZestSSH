import 'dart:convert';
import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimitDesktop, freeSessionLimitMobile;
import 'package:zestssh/services/policy_notice_service.dart';

/// The app's words held to the 3.0 legal pack (ZestSSH-Website: src/routes/privacy, terms and
/// delete-account, src/lib/legal/meta.js and services.js). The pages are the truth; the
/// app may say less, never something they contradict:
///
/// - sync is end-to-end encrypted (the word "zero-knowledge" is gone);
/// - deleting an account deletes it and its synced data from ZestSSH Cloud at once, from the backups
///   within 6 weeks, keeps purchase records for accounting, and waits 30 days after a reset of cloud sync;
/// - nothing absolute that is not exactly so: no analytics, telemetry or crash reporting, but the purchase
///   and sign-in libraries send device details; the personal plans are bought once, Business is a
///   subscription; a purchase has no end date, for as long as ZestSSH is offered;
/// - Juiced is ZestSSH Cloud on up to 7 devices; Team seats are sold on zestssh.com, not "coming";
/// - a bug report or suggestion is also kept on the server as a ticket;
/// - a refund within 30 days, by email, removes what it paid for;
/// - priority support is Business's, not the Bundle's;
/// - the policy notice is version 3; the Windows installer's licence names Affluent Labs LLC.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  final locales = AppLocalizations.supportedLocales;
  Map<String, dynamic> arb(String lang) =>
      jsonDecode(File('lib/l10n/app_$lang.arb').readAsStringSync()) as Map<String, dynamic>;

  /// Every sentence this pass changed, in one language.
  List<String> changed(AppLocalizations t) => [
        t.deskUpgEncryptionDisc,
        t.upgradeFeatureSyncSnippets,
        t.pricingFeatureZeroKnowledge,
        t.accountDeleteAccountDesc,
        t.profileDeleteAccountConfirmMsg,
        t.accountDeleteConfirmSubtitle('you@example.com'),
        t.accountDeleteServerDoneBody,
        t.accountDeleteAllDoneTitle,
        t.accountDeleteAllDoneBody,
        t.accountDeleteStepVerifying,
        t.accountDeleteNotVerified,
        t.helpFaqDeleteAccountBody,
        t.syncResetAskKept,
        t.helpFaqDataCollectBody,
        t.deskUpgTrustZeroTracking,
        t.deskUpgTrustZeroTrackingDetail,
        t.upgradeOneTimePurchase,
        t.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile),
        t.deskUpgLicenseHeroBody,
        t.deskUpgJuicedTagline,
        t.deskUpgJuicedOfferTagline,
        t.deskUpgFreeExplainer,
        t.pricingFeatureJuicedCloud,
        t.pricingTeamsComingSoon,
        t.feedbackPublicNotice,
        t.deskUpgAddonFootbarText,
        t.pricingTagline,
        t.deskUpgTrustNoSubDetail,
        t.deskUpgThanksFooter,
        t.upgradeLifetime,
        t.policyUpdatedBodyThisVersion,
      ];

  test('every changed sentence is in every language, translated, with no em or en dash', () {
    final english = changed(en);
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      final said = changed(t);
      for (var i = 0; i < said.length; i++) {
        expect(said[i], isNot(anyOf(contains('\u2014'), contains('\u2013'))), reason: '$locale: ${said[i]}');
        if (locale.languageCode != 'en') {
          expect(said[i], isNot(english[i]), reason: '$locale: ${english[i]}');
        }
      }
    }
  });

  test('sync is end-to-end encrypted: "zero-knowledge" is said in no language, nor in the release notes', () {
    const words = [
      'zero-knowledge', 'zero knowledge', 'معرفة صفرية', 'عديم المعرفة', 'conocimiento cero', 'divulgation nulle',
      'शून्य-ज्ञान', 'ज़ीरो-नॉलेज', 'ゼロ知識', '제로 지식', '무지식', 'conhecimento zero', 'нулевым разглашением', '零知识',
    ];
    for (final locale in locales) {
      for (final e in arb(locale.languageCode).entries) {
        if (e.key.startsWith('@') || e.value is! String) continue;
        final value = (e.value as String).toLowerCase();
        for (final w in words) {
          expect(value, isNot(contains(w)), reason: '$locale ${e.key}');
        }
      }
    }
    expect(File('lib/features/changelog/changelog_data.dart').readAsStringSync().toLowerCase(),
        isNot(contains('zero-knowledge')));
    expect(en.upgradeFeatureSyncSnippets, 'Same end-to-end encryption');
    expect(en.pricingFeatureZeroKnowledge, 'Same end-to-end encryption as your own storage');
  });

  test('deleting an account: at once from the server, from backups within 6 weeks, purchase records kept', () {
    for (final s in [
      en.accountDeleteAccountDesc,
      en.profileDeleteAccountConfirmMsg,
      en.accountDeleteConfirmSubtitle('you@example.com'),
      en.accountDeleteServerDoneBody,
      en.accountDeleteAllDoneBody,
    ]) {
      expect(s, contains('urchase records are kept for accounting'), reason: s);
      expect(s, isNot(anyOf(contains('all synced data'), contains('everything'), contains('Everything'))), reason: s);
    }
    for (final s in [
      en.profileDeleteAccountConfirmMsg,
      en.accountDeleteConfirmSubtitle('you@example.com'),
      en.accountDeleteServerDoneBody,
      en.accountDeleteAllDoneBody,
      en.helpFaqDeleteAccountBody,
    ]) {
      expect(s, contains('within 6 weeks'), reason: s);
    }
    expect(en.accountDeleteAllDoneTitle, 'Your account has been deleted');
    expect(en.accountDeleteStepVerifying, 'Checking that the server no longer has your account');
    expect(en.accountDeleteNotVerified, startsWith('The server did not confirm that your account is gone'));
    expect(en.accountDeleteAllDoneBody, contains('stays with the team'));
    expect(en.helpFaqDeleteAccountBody, allOf(contains('reset of cloud sync'), contains('30 days')));
    expect(en.syncResetAskKept, allOf(contains('for 30 days'), contains('cannot be deleted'), isNot(contains('for a time'))));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [
        t.profileDeleteAccountConfirmMsg,
        t.accountDeleteConfirmSubtitle('you@example.com'),
        t.accountDeleteServerDoneBody,
        t.accountDeleteAllDoneBody,
        t.helpFaqDeleteAccountBody,
      ]) {
        expect(s, contains('6'), reason: '$locale: the 6 weeks of the backups: $s');
      }
      expect(t.helpFaqDeleteAccountBody, contains('30'), reason: '$locale: the 30 days after a reset');
      expect(t.syncResetAskKept, contains('30'), reason: '$locale');
    }
  });

  test('no absolute that is not exactly so', () {
    expect(en.helpFaqDataCollectBody, isNot(contains('Period')));
    expect(en.helpFaqDataCollectBody, allOf(contains('device details'), contains('privacy policy')));
    expect(en.deskUpgTrustZeroTracking, 'No analytics');
    expect(en.deskUpgTrustZeroTrackingDetail, 'no telemetry, no crash reports');
    for (final s in [en.upgradeOneTimePurchase, en.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile), en.pricingTagline, en.deskUpgThanksFooter]) {
      expect(s, isNot(anyOf(contains('Ever.'), contains(', ever'), contains('subscription-free'))), reason: s);
    }
    for (final s in [en.pricingTagline, en.deskUpgTrustNoSubDetail, en.deskUpgLicenseHeroBody]) {
      expect(s.toLowerCase(), isNot(anyOf(contains('forever'), contains('lifetime'), contains('nothing left'))),
          reason: s);
    }
    expect(en.deskUpgLicenseHeroBody, contains('for as long as we offer ZestSSH'));
    expect(en.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile), endsWith('only Business, which adds company sign-in, is a subscription.'));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.helpFaqTiersBody(freeSessionLimitDesktop, freeSessionLimitMobile), contains('Business'), reason: '$locale');
      expect(t.upgradeLifetime, t.pricingOneTime, reason: '$locale: under a price, one-time, never lifetime');
    }
  });

  test('Juiced is ZestSSH Cloud on up to 7 devices, wherever it is offered', () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      for (final s in [t.deskUpgJuicedTagline, t.deskUpgJuicedOfferTagline, t.deskUpgFreeExplainer,
          t.pricingFeatureJuicedCloud]) {
        expect(s, contains('7'), reason: '$locale: $s');
      }
      // The tagline is found on its own on the card, beside the feature line that says the same.
      expect(t.deskUpgJuicedTagline, isNot(t.juicedSevenDevices), reason: '$locale');
    }
    expect(en.deskUpgJuicedTagline, 'Your vault, on up to 7 devices.');
    expect(en.deskUpgFreeExplainer, contains('Juiced on up to 7 at a time'));
  });

  test('teams are here: seats on zestssh.com, not "coming in 3.0"', () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.pricingTeamsComingSoon, allOf(contains('zestssh.com'), isNot(contains('3.0'))), reason: '$locale');
    }
  });

  test('a report is public on Discord and kept on the server as a ticket, as the privacy policy says', () {
    expect(en.feedbackPublicNotice, allOf(contains('Discord'), contains('keeps a copy as a ticket'),
        contains('without a screenshot, your account or any address'), contains('removed')));
    for (final locale in locales) {
      expect(lookupAppLocalizations(locale).feedbackPublicNotice, contains('Discord'), reason: '$locale');
    }
  });

  test('the checkout line: sentences, a refund by email within 30 days, and what a refund removes', () {
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(t.deskUpgAddonFootbarText, allOf(contains('support@zestssh.com'), contains('30'), isNot(contains('·'))),
          reason: '$locale');
    }
    expect(en.deskUpgAddonFootbarText, contains('removes what the purchase unlocked'));
  });

  test('priority support is Business\'s: the Bundle no longer lists it, and its words are gone', () {
    for (final locale in locales) {
      final a = arb(locale.languageCode);
      for (final key in ['pricingFeaturePrioritySupport', 'profileUpsellBulletEncryption']) {
        expect(a.containsKey(key), isFalse, reason: '$locale $key');
        expect(a.containsKey('@$key'), isFalse, reason: '$locale @$key');
      }
    }
    expect(File('lib/ui/screens/purchase/pricing_modal.dart').readAsStringSync(), isNot(contains('PrioritySupport')));
    expect(en.teamServicesAbout, contains('priority support'), reason: 'where it is sold');
  });

  test('the policy notice is version 3, in effect from 23 October 2026, and reads well with or without its day', () {
    expect(kPolicyVersion, 3);
    // The policy's effective date, the same as LEGAL_EFFECTIVE on the website.
    expect(kPolicyEffectiveDate, 'October 23, 2026');
    expect(policyNoticeBody(en, kPolicyEffectiveDate),
        'We have updated our Privacy Policy and Terms of Service (in effect from October 23, 2026).');
    expect(policyNoticeBody(en, ''), en.policyUpdatedBodyThisVersion);
    expect(policyNoticeBody(en, 'October 30, 2026'), contains('October 30, 2026'));
    for (final locale in locales) {
      final t = lookupAppLocalizations(locale);
      expect(policyNoticeBody(t, kPolicyEffectiveDate), allOf(contains('October 23, 2026'), isNot(contains('{')), isNot(contains('()'))),
          reason: '$locale');
      expect(t.policyUpdatedBodyThisVersion, allOf(contains('ZestSSH'), isNot(contains('{'))), reason: '$locale');
    }
  });

  test("the Windows installer's licence names the company in full, gives the GPL and follows the terms", () {
    final eula = File('installer/eula.txt').readAsStringSync();
    final flat = eula.replaceAll(RegExp(r'\s+'), ' ');
    expect(eula.codeUnits.every((c) => c < 128), isTrue, reason: 'plain text');
    expect(eula, contains('Last updated: 16 November 2026'));
    expect(flat, contains('Affluent Labs LLC ("we", "us")'));
    expect(RegExp(r'Affluent Labs(?!\s+LLC)').hasMatch(eula), isFalse);
    // The program is free software (4.0): the notice grants what the GPL grants and takes nothing
    // away; the Terms are for the services (the paid features, ZestSSH Cloud).
    expect(flat, contains('GNU General Public License version 3'));
    expect(flat, contains('additional permission under section 7'));
    expect(flat, contains('You do not have to accept the licence to install or run ZestSSH.'));
    expect(
      flat.toLowerCase(),
      isNot(anyOf(contains('non-transferable'), contains('reverse engineer'), contains('decompile'),
          contains('may not sell'), contains('sublicense'))),
    );
    for (final url in ['https://zestssh.com/terms', 'https://zestssh.com/privacy', 'https://zestssh.com/acceptable-use']) {
      expect(eula, contains(url));
    }
    expect(flat, contains('the Terms of Service govern'));
    expect(eula, isNot(anyOf(contains('revocable'), contains('terminates'), contains('subscriptions are'))));
  });

  test("the stand-in hosts are the demo fleet's, not real hosts' names", () {
    // Put together here, so that this file does not hold them either.
    final gone = [
      ['Debian', 'Main'].join('-'),
      ['debian', 'main'].join('-'),
      ['Log', 'vault'].join(),
    ];
    for (final dir in ['lib', 'test']) {
      for (final f in Directory(dir).listSync(recursive: true).whereType<File>()) {
        if (!f.path.endsWith('.dart') || f.path.contains('generated')) continue;
        final text = f.readAsStringSync().toLowerCase();
        for (final g in gone) {
          expect(text, isNot(contains(g.toLowerCase())), reason: f.path);
        }
      }
    }
  });
}
