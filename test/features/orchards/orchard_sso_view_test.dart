import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/sso/oidc_issuer.dart';
import 'package:zestssh/features/orchards/sso/orchard_sso_api.dart';
import 'package:zestssh/features/orchards/widgets/orchard_sso_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled, BrowserSignInFailed;
import 'package:zestssh/ui/widgets/zest_button.dart';

/// An Orchard's company sign-in on the Team page's Sign-in page (3.0):
/// nothing without a proven domain; set up, it stays off until
/// a test sign-in; a field the server refuses says so under the field; the
/// secret and the certificate are left out to keep them; removing asks
/// first.

const _saml = 'saml.zo-0123456789abcdef0123456789abcdef';
const _oidc = 'oidc.zo-0123456789abcdef0123456789abcdef';

/// ZestSSH Cloud's company sign-in routes for one Orchard, in memory.
class _Server {
  List<String> domains = ['example.com'];
  Map<String, Object?>? row;
  final puts = <Map<String, dynamic>>[];
  final tests = <String>[];
  var deletes = 0;

  /// A field to refuse on the next PUT, and how.
  ({String field, String code})? refuse;

  http.Response json(int status, Object body) =>
      http.Response(jsonEncode(body), status, headers: {'content-type': 'application/json'});

  Map<String, Object?> view([Map<String, Object?> extra = const {}]) => {
        'kind': row?['kind'],
        'display_name': row?['display_name'],
        'config': row?['config'],
        'active': row?['active'] ?? false,
        'tested_at': row?['tested_at'],
        'provider_id': row?['provider_id'],
        'service': {
          'saml': {'acs_url': 'https://auth.test/__/auth/handler', 'entity_id': 'urn:zestssh:orchard:0123'},
          'oidc': {'redirect_uri': 'https://auth.test/__/auth/handler'},
        },
        'domains': domains,
        ...extra,
      };

  Future<http.Response> answer(http.Request request) async {
    final tail = request.url.pathSegments.skip(4).toList(); // v1 orchards <id> sso [test|activate]
    switch ((request.method, tail.join('/'))) {
      case ('GET', ''):
        return json(200, view());
      case ('PUT', ''):
        final body = jsonDecode(request.body) as Map<String, dynamic>;
        puts.add(body);
        final r = refuse;
        if (r != null) {
          refuse = null;
          return json(400, {'error': 'Check the ${r.field}', 'code': r.code, 'field': r.field});
        }
        final saml = body['kind'] == 'saml';
        final fields = (saml ? body['saml'] : body['oidc']) as Map<String, dynamic>;
        row = {
          'kind': body['kind'],
          'display_name': body['display_name'],
          'config': saml
              ? {
                  'sso_url': fields['sso_url'],
                  'idp_entity_id': fields['idp_entity_id'],
                  'certificate_sha256': 'AB:CD',
                  'certificate_valid_to': '2030-01-01T00:00:00.000Z',
                }
              : {'issuer': fields['issuer'], 'client_id': fields['client_id']},
          'active': false,
          'tested_at': null,
          'provider_id': saml ? _saml : _oidc,
        };
        return json(200, view());
      case ('POST', 'test'):
        tests.add((jsonDecode(request.body) as Map)['id_token'] as String);
        row!['tested_at'] = '2026-09-25T10:00:00.000Z';
        return json(200, view({'email': 'owner@example.com'}));
      case ('POST', 'activate'):
        row!['active'] = true;
        return json(200, view());
      case ('DELETE', ''):
        deletes++;
        row = null;
        return json(200, {'removed': true});
    }
    return json(404, {'code': 'not-found'});
  }
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late _Server server;
  final signedIn = <String>[];

  // The issuer as the provider gives it: without the slash at the end, as
  // Okta's discovery document says (null: it cannot be read).
  String? Function(String typed) issuerSaid = (typed) => typed.replaceFirst(RegExp(r'/+$'), '');

  Future<void> open(WidgetTester tester,
      {String? token = 'id-token-1',
      Future<SsoTestSignIn?> Function(String provider)? testSignIn,
      VoidCallback? cancelTest}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final api = OrchardSsoApi(client: MockClient(server.answer), baseUrl: 'https://api.test/v1', bearer: () async => 't');
    await tester.pumpWidget(ProviderScope(
      overrides: [
        orchardSsoApiProvider.overrideWithValue(api),
        oidcIssuerReaderProvider.overrideWithValue((typed) async => issuerSaid(typed)),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: OrchardSsoView(
              orchardId: 'o',
              cancelTest: cancelTest,
              testSignIn: testSignIn ??
                  (provider) async {
                    signedIn.add(provider);
                    return token == null ? null : SsoTestSignIn.idToken(token);
                  },
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
  }

  setUp(() {
    server = _Server();
    signedIn.clear();
    issuerSaid = (typed) => typed.replaceFirst(RegExp(r'/+$'), '');
  });

  bool toasted(WidgetTester tester, String message) {
    if (find.text(message).evaluate().isNotEmpty) return true;
    final container = ProviderScope.containerOf(tester.element(find.byType(Scaffold).first));
    return container.read(notificationCenterProvider).history.any((n) => '${n.title} ${n.body ?? ''}'.contains(message));
  }

  Future<void> fill(WidgetTester tester, String key, String text) async {
    await tester.enterText(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(TextField)), text);
  }

  Future<void> tap(WidgetTester tester, String key) async {
    await tester.ensureVisible(find.byKey(ValueKey(key)));
    await tester.tap(find.byKey(ValueKey(key)));
    await settle(tester);
  }

  testWidgets('no proven domain: it says to prove one, and offers nothing else', (tester) async {
    server.domains = [];
    await open(tester);
    expect(find.byKey(const ValueKey('sso-needs-domain')), findsOneWidget);
    expect(find.byKey(const ValueKey('sso-save')), findsNothing);
    expect(find.byKey(const ValueKey('sso-name')), findsNothing);
  });

  testWidgets('SAML: set up, then a test sign-in, then turned on; what to tell the provider is there to copy',
      (tester) async {
    await open(tester);
    expect(find.text(l10n.ssoStatusNotSetUp), findsOneWidget);
    expect(find.text('https://auth.test/__/auth/handler'), findsOneWidget);
    expect(find.text('urn:zestssh:orchard:0123'), findsOneWidget);
    expect(find.byKey(const ValueKey('sso-test')), findsNothing, reason: 'nothing to test yet');

    await fill(tester, 'sso-name', 'Acme SSO');
    await fill(tester, 'sso-url', 'https://idp.example.com/sso');
    await fill(tester, 'sso-entity', 'https://idp.example.com/entity');
    await fill(tester, 'sso-certificate', '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----');
    await tap(tester, 'sso-save');
    expect(server.puts.single, {
      'kind': 'saml',
      'display_name': 'Acme SSO',
      'saml': {
        'sso_url': 'https://idp.example.com/sso',
        'idp_entity_id': 'https://idp.example.com/entity',
        'certificate': '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
      },
    });
    expect(find.text(l10n.ssoStatusUntested), findsOneWidget);
    expect(toasted(tester, l10n.ssoSaved), isTrue);
    expect(find.byKey(const ValueKey('sso-certificate-line')), findsOneWidget, reason: 'when the certificate runs out');
    // Not on before a test.
    expect(tester.widget<ZestButton>(find.byKey(const ValueKey('sso-turn-on'))).onPressed, isNull);

    await tap(tester, 'sso-test');
    expect(signedIn, [_saml]);
    expect(server.tests, ['id-token-1']);
    expect(find.text(l10n.ssoStatusTested), findsOneWidget);
    expect(toasted(tester, l10n.ssoTestedToast('owner@example.com')), isTrue);

    await tap(tester, 'sso-turn-on');
    expect(find.text(l10n.ssoStatusOn('example.com')), findsOneWidget);
    expect(find.byKey(const ValueKey('sso-turn-on')), findsNothing);
    expect(find.text(l10n.ssoSaveTurnsOff), findsOneWidget, reason: 'a change turns it off again');

    // A change leaves the certificate out: the saved one stays.
    await fill(tester, 'sso-url', 'https://idp.example.com/sso2');
    await tap(tester, 'sso-save');
    expect((server.puts.last['saml'] as Map).containsKey('certificate'), isFalse);
    expect(find.text(l10n.ssoStatusUntested), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a closed test sign-in changes nothing', (tester) async {
    server.row = {
      'kind': 'saml',
      'display_name': 'Acme SSO',
      'config': {'sso_url': 'https://idp.example.com/sso', 'idp_entity_id': 'e'},
      'active': false,
      'tested_at': null,
      'provider_id': _saml,
    };
    await open(tester, token: null);
    await tap(tester, 'sso-test');
    expect(signedIn, [_saml]);
    expect(server.tests, isEmpty);
    expect(find.text(l10n.ssoStatusUntested), findsOneWidget);
  });

  testWidgets('a field the server refuses says so under that field', (tester) async {
    await open(tester);
    await fill(tester, 'sso-name', 'Acme SSO');
    await fill(tester, 'sso-url', 'https://idp.example.com/sso');
    await fill(tester, 'sso-entity', 'e');
    await fill(tester, 'sso-certificate', 'old');
    server.refuse = (field: 'certificate', code: 'certificate-expired');
    await tap(tester, 'sso-save');
    expect(find.text(l10n.ssoCertificateExpired), findsOneWidget);
    server.refuse = (field: 'sso_url', code: 'invalid-sso');
    await tap(tester, 'sso-save');
    expect(find.text(l10n.ssoCheckField), findsOneWidget);
    expect(find.text(l10n.ssoCertificateExpired), findsNothing);
    expect(find.text(l10n.ssoStatusNotSetUp), findsOneWidget);
  });

  testWidgets('OIDC: the issuer saved as the provider gives it; one it cannot read, or another, is said under it',
      (tester) async {
    await open(tester);
    await tester.tap(find.text(l10n.ssoKindOidc));
    await settle(tester);
    await fill(tester, 'sso-name', 'Acme OIDC');
    await fill(tester, 'sso-client-id', 'client-1');
    await fill(tester, 'sso-client-secret', 's3cret');
    // Unreadable: nothing is saved, and the field says what to check.
    issuerSaid = (_) => null;
    await fill(tester, 'sso-issuer', 'https://nowhere.example.com');
    await tap(tester, 'sso-save');
    expect(server.puts, isEmpty);
    expect(find.text(l10n.ssoIssuerUnreadable), findsOneWidget);
    // Another address: filled in, to check and save again.
    issuerSaid = (_) => 'https://login.example.com/oauth2/default';
    await fill(tester, 'sso-issuer', 'https://login.example.com');
    await tap(tester, 'sso-save');
    expect(server.puts, isEmpty);
    expect(find.text(l10n.ssoIssuerFilledIn), findsOneWidget);
    expect(find.text('https://login.example.com/oauth2/default'), findsOneWidget);
    await tap(tester, 'sso-save');
    expect(server.puts.last['oidc']['issuer'], 'https://login.example.com/oauth2/default');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('a test sign-in waiting for the browser: Test becomes a red Cancel, which stops it quietly',
      (tester) async {
    server.row = {
      'kind': 'oidc',
      'display_name': 'Acme OIDC',
      'config': {'issuer': 'https://login.example.com', 'client_id': 'c'},
      'active': false,
      'tested_at': null,
      'provider_id': _oidc,
    };
    final waiting = Completer<SsoTestSignIn?>();
    await open(tester,
        testSignIn: (_) => waiting.future,
        cancelTest: () => waiting.completeError(const BrowserSignInCancelled()));
    await tester.tap(find.byKey(const ValueKey('sso-test')));
    await tester.pump();
    expect(find.byKey(const ValueKey('sso-test')), findsNothing);
    final cancel = tester.widget<ZestButton>(find.byKey(const ValueKey('sso-test-cancel')));
    expect(cancel.variant, ZestButtonVariant.danger);
    await tester.tap(find.byKey(const ValueKey('sso-test-cancel')));
    await settle(tester);
    expect(find.byKey(const ValueKey('sso-test')), findsOneWidget, reason: 'back to Test a sign-in');
    expect(server.tests, isEmpty);
    expect(find.textContaining('BrowserSignInCancelled'), findsNothing, reason: 'nothing is said');
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets("a test the website says did not work: the app's words for it, and what the provider said behind them",
      (tester) async {
    server.row = {
      'kind': 'oidc',
      'display_name': 'Acme OIDC',
      'config': {'issuer': 'https://login.example.com', 'client_id': 'c'},
      'active': false,
      'tested_at': null,
      'provider_id': _oidc,
    };
    await open(tester,
        testSignIn: (_) async => throw const BrowserSignInFailed(
            code: 'auth/invalid-credential', detail: 'Firebase: Error (auth/invalid-credential).'));
    await tap(tester, 'sso-test');
    expect(find.text(l10n.ssoTestNotAccepted), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('OIDC: its redirect URI, the secret sent once, left out to keep it; removed after asking',
      (tester) async {
    await open(tester);
    await tester.tap(find.text(l10n.ssoKindOidc));
    await settle(tester);
    expect(find.text(l10n.ssoRedirectUri), findsOneWidget);
    expect(find.text(l10n.ssoAcsUrl), findsNothing);
    await fill(tester, 'sso-name', 'Acme OIDC');
    // Typed with a slash at the end, saved as the provider gives it.
    await fill(tester, 'sso-issuer', 'https://login.example.com/');
    await fill(tester, 'sso-client-id', 'client-1');
    await fill(tester, 'sso-client-secret', 's3cret');
    await tap(tester, 'sso-save');
    expect(server.puts.last['oidc'], {'issuer': 'https://login.example.com', 'client_id': 'client-1', 'client_secret': 's3cret'});
    expect(find.text('s3cret'), findsNothing, reason: 'never shown again');
    // Saved: there, hidden, with Replace (it looked gone when it was blank).
    expect(find.byKey(const ValueKey('sso-client-secret-saved')), findsOneWidget);
    expect(find.text(l10n.ssoSecretSaved), findsOneWidget);

    await fill(tester, 'sso-client-id', 'client-2');
    await tap(tester, 'sso-save');
    expect(server.puts.last['oidc'], {'issuer': 'https://login.example.com', 'client_id': 'client-2'});

    // Replace: a field to type the new one in.
    await tap(tester, 'sso-client-secret-replace');
    expect(find.text(l10n.ssoFieldClientSecretKeep), findsOneWidget);
    await fill(tester, 'sso-client-secret', 'n3w');
    await tap(tester, 'sso-save');
    expect(server.puts.last['oidc'], {'issuer': 'https://login.example.com', 'client_id': 'client-2', 'client_secret': 'n3w'});
    expect(find.byKey(const ValueKey('sso-client-secret-saved')), findsOneWidget);

    // Switching kinds needs everything again: an empty secret is sent as such.
    await tester.tap(find.text(l10n.ssoKindSaml));
    await settle(tester);
    expect(find.text(l10n.ssoFieldCertificateKeep), findsNothing, reason: 'no SAML certificate saved');

    await tester.tap(find.text(l10n.ssoKindOidc));
    await settle(tester);
    await tap(tester, 'sso-remove');
    expect(find.text(l10n.ssoRemoveTitle), findsOneWidget);
    expect(find.text(l10n.ssoRemoveBody('Acme OIDC')), findsOneWidget);
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    expect(server.deletes, 0);
    await tap(tester, 'sso-remove');
    await tester.tap(find.text(l10n.ssoRemove).last);
    await settle(tester);
    expect(server.deletes, 1);
    expect(find.text(l10n.ssoStatusNotSetUp), findsOneWidget);
    expect(toasted(tester, l10n.ssoRemoved), isTrue);
    await tester.pump(const Duration(seconds: 5));
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
