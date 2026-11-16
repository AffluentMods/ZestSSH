import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/browser_sign_in_code.dart';
import 'package:zestssh/services/desktop_auth_server.dart';
import 'package:zestssh/services/desktop_browser_sign_in.dart';
import 'package:zestssh/ui/widgets/browser_sign_in_help.dart';

/// "Check your browser" (a spinner alone was
/// easy to miss): over whatever is on screen while a sign-in waits for the
/// browser, gone by itself when it is done, with Open again, Copy link and
/// Cancel, and the word at once when no browser opened.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final page = Uri.parse('https://zestssh.com/auth?platform=desktop&state=s');

  tearDown(() => DesktopBrowserSignIn.pending.value = null);

  Future<List<String>> pump(WidgetTester tester) async {
    final cancelled = <String>[];
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      builder: (context, child) => BrowserSignInPopup(onCancel: () => cancelled.add('cancel'), child: child!),
      home: const Scaffold(body: Text('the app')),
    ));
    return cancelled;
  }

  testWidgets('shows while a sign-in waits, and goes by itself when it is done', (tester) async {
    await pump(tester);
    expect(find.byKey(const ValueKey('browser-sign-in-popup')), findsNothing);
    DesktopBrowserSignIn.pending.value = BrowserSignInPage(page);
    await tester.pump();
    expect(find.text(l10n.signInBrowserTitle), findsOneWidget);
    expect(find.text(l10n.signInBrowserWaiting), findsOneWidget);
    expect(find.text('the app'), findsOneWidget, reason: 'over the app, not in its place');
    DesktopBrowserSignIn.pending.value = null;
    await tester.pump();
    expect(find.byKey(const ValueKey('browser-sign-in-popup')), findsNothing);
  });

  testWidgets('a browser that did not open is said at once; Copy link copies the page; Cancel stops it',
      (tester) async {
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    final cancelled = await pump(tester);
    DesktopBrowserSignIn.pending.value = BrowserSignInPage(page, opened: false);
    await tester.pump();
    expect(find.text(l10n.signInBrowserNotOpened), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-sign-in-copy')));
    await tester.pump();
    expect(copied, page.toString());
    expect(find.text(l10n.signInBrowserLinkCopied), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('browser-sign-in-cancel')));
    await tester.pump();
    expect(cancelled, ['cancel']);
  });

  // zestssh.com asks for the code
  // of the link's challenge before it signs anything in, so a sign-in another
  // program on this computer started cannot reach it.
  group('the code the sign-in page asks for', () {
    const codeKey = ValueKey('browser-sign-in-code');

    final starts = <String, Future<Object?> Function(Future<void> Function(Uri) open)>{
      'a sign-in': (open) => DesktopBrowserSignIn.session(open: open),
      'adding an account': (open) => DesktopBrowserSignIn.session(create: true, open: open),
      "confirm it's you": (open) =>
          DesktopBrowserSignIn.run(confirm: const BrowserConfirm('alex@example.com', way: 'google.com'), open: open),
      'a fresh ID token (two-step changes)': (open) => DesktopBrowserSignIn.idTokenHandoff(open: open),
      "an owner's company sign-in test": (open) =>
          DesktopBrowserSignIn.ssoTest('oidc.zo-0123456789abcdef0123456789abcdef', open: open),
    };

    for (final MapEntry(key: what, value: start) in starts.entries) {
      testWidgets('$what: the code shown is that of the challenge in the link the app opened', (tester) async {
        await pump(tester);
        Uri? opened;
        late Future<Object?> wait;
        await tester.runAsync(() async {
          wait = start((link) async => opened = link);
          wait.ignore();
          while (opened == null) {
            await Future<void>.delayed(const Duration(milliseconds: 10));
          }
        });
        await tester.pump();
        final link = opened!;
        expect(link.queryParameters['code'], '1', reason: 'the page is told this app shows the code');
        final expected = groupBrowserSignInCode(browserSignInCode(link.queryParameters['challenge']!));
        expect(expected, matches(RegExp(r'^[0-9A-Z]{3} [0-9A-Z]{3}$')));
        expect(tester.widget<SelectableText>(find.byKey(codeKey)).data, expected);
        expect(find.text(l10n.signInBrowserCode), findsOneWidget);
        await tester.runAsync(() async {
          DesktopBrowserSignIn.cancel();
          await expectLater(wait, throwsA(isA<BrowserSignInCancelled>()));
        });
        await tester.pump();
        expect(find.byKey(codeKey), findsNothing, reason: 'gone with the wait');
      });
    }

    testWidgets('a page that hands no sign-in to the app shows no code', (tester) async {
      await pump(tester);
      DesktopBrowserSignIn.pending.value = BrowserSignInPage(
          Uri.parse(DesktopBrowserSignIn.addPasskeyUrl('n0nce', 'http://127.0.0.1:49152/callback')));
      await tester.pump();
      expect(find.text(l10n.signInBrowserTitle), findsOneWidget);
      expect(find.byKey(codeKey), findsNothing);
      expect(find.text(l10n.signInBrowserCode), findsNothing);
    });
  });
}
