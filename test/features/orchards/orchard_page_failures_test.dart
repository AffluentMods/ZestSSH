import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/widgets/orchard_domains_view.dart';
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// An Orchard's domains and company sign-in pages keep what failed for Copy
/// details (3.0). Each showed its sentence alone on the page
/// (the error went to the log), with nothing to copy for whoever asks for
/// help, where every other surface of the app has Copy details.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  const bearer = 'secret-bearer-0123456789abcdef';

  /// ZestSSH Cloud answering every request with a fault of its own.
  final faulty = MockClient((request) async => http.Response('{"error":"Internal server error"}', 500));

  Future<void> pump(WidgetTester tester, Widget page) async {
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardDomainsApiProvider.overrideWithValue(
            OrchardDomainsApi(client: faulty, baseUrl: 'https://cloud.example.test', bearer: () async => bearer)),
        orchardSsoApiProvider.overrideWithValue(
            OrchardSsoApi(client: faulty, baseUrl: 'https://cloud.example.test', bearer: () async => bearer)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: SingleChildScrollView(child: page)),
      ),
    ));
    for (var i = 0; i < 5; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
      await tester.pump();
    }
  }

  void saidWithDetails(WidgetTester tester, String key, String where) {
    final said = tester.widget<Text>(find.byKey(ValueKey(key))).data!;
    expect(said, '${en.cloudFault(500)} (ZS-1103)', reason: "ZestSSH Cloud's own fault, said as sync says it, with its code");
    final copy = tester.widget<CopyDetailsButton>(find.byType(CopyDetailsButton));
    expect(copy.detail, contains('Where: $where'));
    expect(copy.detail, contains('500'));
    expect(copy.detail, isNot(contains(bearer)), reason: 'the sign-in is no part of the details');
  }

  testWidgets("an Orchard's domains that cannot be read: said, with what failed to copy", (tester) async {
    await pump(tester, const OrchardDomainsView(orchardId: 'o-demo'));
    saidWithDetails(tester, 'domain-error', 'Orchard domains: reading them');
  });

  testWidgets("an Orchard's company sign-in that cannot be read: said, with what failed to copy", (tester) async {
    await pump(tester, const OrchardSsoView(orchardId: 'o-demo'));
    saidWithDetails(tester, 'sso-error', 'Company sign-in: reading it');
  });
}
