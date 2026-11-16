import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/browser_sign_in_code.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';

/// The code a computer's browser sign-in shows (found in a
/// security review): every person signed in to a computer shares its loopback
/// ports, so another could start a sign-in with a challenge of their own and
/// get this person to open its link. zestssh.com asks for the code of the
/// link's challenge before it signs anything in, and only the app that started
/// the sign-in shows it.
void main() {
  // The same vectors as the website's src/lib/signInCode.test.js: the two must
  // never differ, or the page refuses every right code.
  const vectors = {
    // RFC 7636's example challenge (appendix B), with a dash in it.
    'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM': '9BMEK8',
    '': '95YE2F',
    'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA': '4NKTK7',
    'abc_DEF-ghi_JKL-mno_PQR-stu_VWX-yz0_123-456': 'RVQXH7',
    // UTF-8, and the top of the alphabet.
    'café \u{1F34B}': 'ZZZ4MA',
    // Leading zeros are kept.
    'vector-1216': '00QY5A',
    'vector-55': '10D950',
    // 55 bytes hashed: one block; 56: the padding takes a second.
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB': 'KT75VM',
    'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB': '1DNW3D',
  };

  test('the code of a challenge: the shared vectors', () {
    for (final MapEntry(key: challenge, value: code) in vectors.entries) {
      expect(browserSignInCode(challenge), code, reason: challenge);
    }
    expect(browserSignInCode('x' * 200), 'NXMCQ2');
  });

  test("six characters of Crockford's base32, shown as two groups of three", () {
    final allowed = RegExp(r'^[0-9A-HJKMNP-TV-Z]{6}$');
    for (var i = 0; i < 2000; i++) {
      final code = browserSignInCode('challenge-$i');
      expect(code, matches(allowed));
    }
    expect(groupBrowserSignInCode('K7P2QX'), 'K7P 2QX');
    expect(groupBrowserSignInCode(browserSignInCode('vector-1216')), '00Q Y5A');
  });

  test("a page's code is that of its link's challenge; a page that hands no sign-in to the app has none", () {
    const challenge = 'E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM';
    final link = DesktopBrowserSignIn.authUrl('n0nce', challenge, 'http://127.0.0.1:49152/callback');
    expect(BrowserSignInPage(Uri.parse(link)).signInCode, '9BM EK8');
    final passkey = DesktopBrowserSignIn.addPasskeyUrl('n0nce', 'http://127.0.0.1:49152/callback');
    expect(BrowserSignInPage(Uri.parse(passkey)).signInCode, isNull);
  });

  group('every link that hands a sign-in to the app says it shows the code (code=1)', () {
    tearDown(DesktopBrowserSignIn.cancel);

    /// The link [start] opens, then the wait cancelled.
    Future<Uri> linkOf(Future<Object?> Function(Future<void> Function(Uri) open) start) async {
      final opened = Completer<Uri>();
      final wait = start((link) async => opened.complete(link));
      final link = await opened.future;
      DesktopBrowserSignIn.cancel();
      await expectLater(wait, throwsA(isA<BrowserSignInCancelled>()));
      return link;
    }

    final starts = <String, Future<Object?> Function(Future<void> Function(Uri) open)>{
      'a sign-in': (open) => DesktopBrowserSignIn.session(open: open),
      'creating an account': (open) => DesktopBrowserSignIn.session(create: true, open: open),
      'a company sign-in': (open) => DesktopBrowserSignIn.session(sso: true, open: open),
      "confirm it's you": (open) =>
          DesktopBrowserSignIn.run(confirm: const BrowserConfirm('alex@example.com', way: 'password'), open: open),
      'a fresh ID token': (open) => DesktopBrowserSignIn.idTokenHandoff(open: open),
      "an owner's company sign-in test": (open) =>
          DesktopBrowserSignIn.ssoTest('saml.zo-0123456789abcdef0123456789abcdef', open: open),
    };

    for (final MapEntry(key: what, value: start) in starts.entries) {
      test(what, () async {
        final link = await linkOf(start);
        expect(link.queryParameters['code'], '1');
        expect(link.queryParameters['challenge'], matches(RegExp(r'^[A-Za-z0-9_-]{43}$')));
        expect(link.queryParameters['redirect'], startsWith('http://127.0.0.1:'));
        expect(link.queryParameters['platform'], 'desktop');
      });
    }

    test('adding a passkey hands no sign-in, and is not marked', () async {
      final link = await linkOf((open) => DesktopBrowserSignIn.addPasskeyInBrowser(open: open));
      expect(link.path, '/account/security');
      expect(link.queryParameters.containsKey('code'), isFalse);
      expect(link.queryParameters.containsKey('challenge'), isFalse);
    });
  });
}
