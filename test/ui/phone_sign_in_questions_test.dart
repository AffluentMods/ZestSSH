import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/connection_health_service.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/terminal/phone_sign_in_questions.dart';
import 'package:zestssh/ui/screens/terminal/terminal_screen.dart';
import 'package:zestssh/ui/screens/terminal/widgets/passphrase_prompt_dialog.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';

import 'sharing_ui_fakes.dart';

/// The app's lock, as the test sets it.
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  void set(bool locked) => state = locked;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Health extends ConnectionHealthNotifier {}

/// A phone's sign-in questions (3.0, found while comparing the
/// five versions): a session's terminal screen alone asked them, so a password
/// or a host's key that Install key or a workflow's Run asked (they open no
/// terminal) was shown to nobody, and a tablet showing two terminals asked
/// twice. Now the app asks each once, over whatever is on screen, and never
/// over its lock screen.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));
  late ProviderContainer container;
  late GoRouter router;

  Future<void> phone(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1600, 1200);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'cursor_blink': false});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      dbReadyProvider.overrideWithValue(true),
      activeSessionsProvider.overrideWith(FakeSessions.new),
      connectionHealthProvider.overrideWith((ref) => _Health()),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('the list of hosts'))),
      GoRoute(path: '/keys', builder: (_, _) => const Scaffold(body: Text('a key, installing'))),
      GoRoute(path: Routes.securityLock, builder: (_, _) => const Scaffold(body: Text('locked'))),
      // A tablet's two terminals side by side.
      GoRoute(
        path: '/split',
        builder: (_, _) => const Row(children: [
          Expanded(child: TerminalScreen(sessionId: 's1')),
          Expanded(child: TerminalScreen(sessionId: 's2')),
        ]),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => PhoneSignInQuestions(router: router, child: child!),
      ),
    ));
    await tester.pump();
  }

  /// The app moves (its router tells whoever listens), its screens as they were.
  void moved() =>
      // ignore: invalid_use_of_protected_member, invalid_use_of_visible_for_testing_member
      router.routerDelegate.notifyListeners();

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  PasswordPromptRequest askPassword() {
    final request = PasswordPromptRequest(
      host: 'web-01',
      username: 'deploy',
      completer: Completer<PasswordPromptResult?>(),
    );
    container.read(passwordPromptProvider.notifier).state = request;
    return request;
  }

  testWidgets('a password asked over a screen that is no terminal: asked, once, and its answer reaches the sign-in',
      (tester) async {
    await phone(tester);
    router.push('/keys');
    await step(tester);
    final request = askPassword();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);
    moved();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget, reason: 'not asked again while it is asked');
    await tester.enterText(find.descendant(of: find.byType(PasswordPromptDialog), matching: find.byType(TextField)).first, 'correct horse');
    await tester.tap(find.text(en.commonConnect));
    await step(tester);
    expect(request.completer.isCompleted, isTrue);
    expect((await request.completer.future)?.password, 'correct horse');
    expect(find.byType(PasswordPromptDialog), findsNothing);
  });

  testWidgets("a host's key, queued while no terminal is shown: asked; Trust and connect trusts it", (tester) async {
    await phone(tester);
    final verification = HostKeyVerification(
      host: 'web1.example.com',
      port: 22,
      hostKey: SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List(51)),
      fingerprint: 'SHA256:presented',
      isChanged: false,
      completer: Completer<bool>(),
    );
    container.read(hostKeyVerificationQueueProvider.notifier).enqueue(verification);
    await step(tester);
    expect(find.text(en.hostKeyFirstTitle('web1.example.com')), findsOneWidget);
    moved();
    await step(tester);
    expect(find.text(en.hostKeyFirstTitle('web1.example.com')), findsOneWidget,
        reason: 'not asked again while it is asked');
    await tester.tap(find.text(en.hostKeyTrustAndConnect));
    await step(tester);
    expect(await verification.completer.future, isTrue);
    expect(container.read(hostKeyVerificationProvider), isNull);
  });

  testWidgets('never over the lock screen: what is asked while locked comes once the app is open; one its lock took '
      'away is asked again', (tester) async {
    await phone(tester);
    final lock = container.read(isAppLockedProvider.notifier) as _Lock;
    lock.set(true);
    router.go(Routes.securityLock);
    await step(tester);
    final request = askPassword();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsNothing, reason: 'not over the lock screen');

    lock.set(false);
    router.go('/');
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget, reason: 'asked once the app is open');

    // Locked again while it is asked: the lock takes it away, and it is asked again after.
    lock.set(true);
    router.go(Routes.securityLock);
    await tester.pumpAndSettle();
    expect(find.byType(PasswordPromptDialog), findsNothing);
    lock.set(false);
    router.go('/');
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);
    expect(request.completer.isCompleted, isFalse, reason: 'still waits for its answer');
  });

  testWidgets('locked before its lock screen is shown, or open while it still is: nothing is asked', (tester) async {
    await phone(tester);
    final lock = container.read(isAppLockedProvider.notifier) as _Lock;
    lock.set(true);
    askPassword();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsNothing, reason: 'locked, the lock screen not shown yet');
    router.go(Routes.securityLock);
    await tester.pumpAndSettle();
    lock.set(false);
    moved();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsNothing, reason: 'open, the lock screen still shown');
    askPassword();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsNothing, reason: 'nor one that comes then');
    router.go('/');
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);
  });

  testWidgets("a key's passphrase: asked once, however often the app looks for what waits", (tester) async {
    await phone(tester);
    container.read(passphrasePromptProvider.notifier).state = PassphrasePromptRequest(
      host: 'web-01',
      username: 'deploy',
      completer: Completer<PassphrasePromptResult?>(),
    );
    await step(tester);
    expect(find.byType(PassphrasePromptDialog), findsOneWidget);
    for (var i = 0; i < 3; i++) {
      moved();
      await step(tester);
    }
    expect(find.byType(PassphrasePromptDialog), findsOneWidget);
    expect(find.byType(PasswordPromptDialog), findsNothing);
  });

  testWidgets("a tablet's two terminals side by side: asked once", (tester) async {
    await phone(tester);
    (container.read(activeSessionsProvider.notifier) as FakeSessions).show({
      for (final id in ['s1', 's2'])
        id: SessionState(
          status: SessionStatus.connecting,
          connectionId: 'c-$id',
          connectionLabel: 'web-$id',
          host: '192.0.2.21',
          port: 22,
        ),
    });
    router.push('/split');
    await step(tester);
    expect(find.byType(TerminalScreen), findsNWidgets(2));
    askPassword();
    await step(tester);
    expect(find.byType(PasswordPromptDialog), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 3));
  });
}
