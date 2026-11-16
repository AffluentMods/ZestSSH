import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/domains/orchard_domains_api.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/widgets/orchard_domains_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// An Orchard's domains (3.0): what the app reads of the server's
/// answers, and the Domains screen: claiming a domain shows the TXT record
/// to publish, checking says when it is not there yet, a proven domain says
/// so, and one can be removed.

/// ZestSSH Cloud's domain routes for one Orchard, in memory, with a DNS
/// the test controls ([published]).
class _Server {
  final claims = <String, Map<String, Object?>>{};
  final published = <String>{};
  final taken = <String>{};

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, Object?> view(Map<String, Object?> c) => {
        'domain': c['domain'],
        'verified': c['verified'],
        'verified_at': c['verified_at'],
        'checked_at': null,
        'txt': 'zestssh-verify=${c['token']}',
      };

  Future<http.Response> answer(http.Request request) async {
    final parts = request.url.pathSegments; // v1 orchards <id> domains [domain [verify]]
    final tail = parts.skip(4).toList();
    if (request.method == 'GET') return json(200, {'domains': [for (final c in claims.values) view(c)]});
    if (request.method == 'POST' && tail.isEmpty) {
      final d = (jsonDecode(request.body) as Map)['domain'].toString().trim().toLowerCase();
      if (!d.contains('.')) return json(400, {'code': 'invalid-request'});
      if (taken.contains(d)) return json(409, {'code': 'domain-taken'});
      final c = claims.putIfAbsent(d, () => {'domain': d, 'verified': false, 'verified_at': null, 'token': 'tok-$d'});
      return json(201, view(c));
    }
    if (request.method == 'POST' && tail.length == 2 && tail[1] == 'verify') {
      final c = claims[Uri.decodeComponent(tail[0])];
      if (c == null) return json(404, {'code': 'not-found'});
      if (!published.contains(c['domain'])) {
        return json(409, {'code': 'not-proven', 'txt': 'zestssh-verify=${c['token']}'});
      }
      c['verified'] = true;
      c['verified_at'] = '2026-09-24T12:00:00.000Z';
      return json(200, view(c));
    }
    if (request.method == 'DELETE' && tail.length == 1) {
      return claims.remove(Uri.decodeComponent(tail[0])) == null
          ? json(404, {'code': 'not-found'})
          : json(200, {'removed': true});
    }
    return json(404, {'code': 'not-found'});
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  OrchardDomainsApi api(_Server server) =>
      OrchardDomainsApi(client: MockClient(server.answer), baseUrl: 'https://api.test/v1', bearer: () async => 't');

  group('what the app reads', () {
    test('claims, the record to publish, a check that finds nothing yet, and the refusals', () async {
      final server = _Server();
      final a = api(server);
      final claim = await a.claim('o', ' Example.COM ');
      expect((claim.domain, claim.verified, claim.txt), ('example.com', false, 'zestssh-verify=tok-example.com'));
      await expectLater(a.verify('o', 'example.com'),
          throwsA(isA<DomainNotProven>().having((e) => e.txt, 'txt', 'zestssh-verify=tok-example.com')));
      server.published.add('example.com');
      final proven = await a.verify('o', 'example.com');
      expect(proven.verified, isTrue);
      expect(proven.verifiedAt, DateTime.utc(2026, 9, 24, 12));
      expect((await a.list('o')).single.domain, 'example.com');
      server.taken.add('corp.example');
      await expectLater(a.claim('o', 'corp.example'),
          throwsA(isA<OrchardServerException>().having((e) => e.code, 'code', 'domain-taken')));
      await a.drop('o', 'example.com');
      expect(await a.list('o'), isEmpty);
    });

    test('a member sees no record to publish', () {
      final d = OrchardDomain.fromJson({'domain': 'example.com', 'verified': true, 'verified_at': null, 'checked_at': null});
      expect((d!.domain, d.verified, d.txt), ('example.com', true, null));
      expect(OrchardDomain.fromJson({'verified': true}), isNull);
    });
  });

  group('the Domains screen', () {
    late _Server server;

    Future<void> open(WidgetTester tester) async {
      server = _Server();
      tester.view.physicalSize = const Size(1200, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(ProviderScope(
        overrides: [orchardDomainsApiProvider.overrideWithValue(api(server))],
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(
            body: Consumer(
              builder: (context, ref, _) => TextButton(
                onPressed: () => showOrchardDomains(context, ref, 'o'),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await settle(tester);
    }

    bool toasted(WidgetTester tester, String message) {
      if (find.text(message).evaluate().isNotEmpty) return true;
      final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
      return container.read(notificationCenterProvider).history.any((n) => n.title == message);
    }

    testWidgets('claim, publish, check and remove', (tester) async {
      await open(tester);
      expect(find.text(l10n.orchardDomainsEmpty), findsOneWidget);

      await tester.enterText(find.byKey(const ValueKey('domain-field')), 'Example.com');
      await tester.tap(find.byKey(const ValueKey('domain-add')));
      await settle(tester);
      expect(find.text(l10n.orchardDomainWaiting), findsOneWidget);
      expect(find.text('zestssh-verify=tok-example.com'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('domain-check-example.com')));
      await settle(tester);
      expect(find.text(l10n.orchardDomainNotYet), findsOneWidget);

      server.published.add('example.com');
      await tester.tap(find.byKey(const ValueKey('domain-check-example.com')));
      await settle(tester);
      expect(find.textContaining('Proven on'), findsOneWidget);
      expect(find.text('zestssh-verify=tok-example.com'), findsNothing, reason: 'nothing to publish any more');
      expect(toasted(tester, l10n.orchardDomainProvenToast('example.com')), isTrue);

      await tester.tap(find.byKey(const ValueKey('domain-remove-example.com')));
      await settle(tester);
      expect(find.text(l10n.orchardDomainRemoveTitle('example.com')), findsOneWidget);
      await tester.tap(find.text(l10n.orchardDomainRemove).last);
      await settle(tester);
      expect(find.text(l10n.orchardDomainsEmpty), findsOneWidget);
      await tester.pump(const Duration(seconds: 5));
    });

    testWidgets("another Orchard's domain says so", (tester) async {
      await open(tester);
      server.taken.add('corp.example');
      await tester.enterText(find.byKey(const ValueKey('domain-field')), 'corp.example');
      await tester.tap(find.byKey(const ValueKey('domain-add')));
      await settle(tester);
      expect(find.text(l10n.orchardDomainTaken), findsOneWidget);
    });
  });
}

/// Lets the requests finish, then the frames.
Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
    await tester.pump();
    if (i >= 2 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pumpAndSettle();
}
