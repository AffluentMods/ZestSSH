// A host's key trusted with no question, on a phone (found
// while comparing the five versions): a new host's key trusted because "Ask
// before trusting new host keys" is off, and a key another device recorded,
// trusted here for the first time. A computer tells of each; a phone trusted
// them with no word. Now a phone tells of each once, in a computer's words,
// over whatever is on screen, and never over its lock screen.

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/security/security_settings_screen.dart';
import 'package:zestssh/ui/screens/terminal/phone_sign_in_questions.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/redactor.dart';

/// The app's lock, as the test sets it.
class _Lock extends StateNotifier<bool> implements AppLockNotifier {
  _Lock() : super(false);

  void set(bool locked) => state = locked;

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  late ProviderContainer container;
  late GoRouter router;

  setUp(() => debugTopSnackBarOnPhone = true);
  tearDown(() => debugTopSnackBarOnPhone = null);

  Future<void> phone(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    tester.view.physicalSize = const Size(420, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isAppLockedProvider.overrideWith((ref) => _Lock()),
      dbReadyProvider.overrideWithValue(true),
    ]);
    addTearDown(container.dispose);
    router = GoRouter(initialLocation: '/', routes: [
      GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('the list of hosts'))),
      GoRoute(path: Routes.securityLock, builder: (_, _) => const Scaffold(body: Text('locked'))),
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

  Future<void> step(WidgetTester tester) async {
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  final accepted = l10n.desktopShellHostKeyAutoAccepted('192.168.10.21:22', 'ssh-ed25519', 'SHA256:q2Vx7Example');
  final adopted = l10n.desktopShellHostKeyProvenance('192.168.10.22:2222', "Alex's laptop", '2026-10-02');

  testWidgets("a new host's key trusted with no question is told, once, with the way to the setting that asks",
      (tester) async {
    await phone(tester);
    container.read(hostKeyAutoAcceptProvider.notifier).state = const HostKeyAutoAcceptEvent(
        host: '192.168.10.21', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:q2Vx7Example');
    await step(tester);
    expect(find.text(accepted), findsOneWidget);
    expect(container.read(hostKeyAutoAcceptProvider), isNull, reason: 'told: the next one is told too');
    await tester.tap(find.text(l10n.settingsTitle));
    await tester.pumpAndSettle();
    expect(find.byType(SecuritySettingsScreen), findsOneWidget);
    await tester.scrollUntilVisible(find.text(l10n.secSetAskBeforeTrusting), 300,
        scrollable: find.descendant(of: find.byType(SecuritySettingsScreen), matching: find.byType(Scrollable)).first);
    expect(find.text(l10n.secSetAskBeforeTrusting), findsOneWidget);
    await finish(tester);
  });

  testWidgets('a key another device recorded, trusted here for the first time, is told with that device and the day',
      (tester) async {
    await phone(tester);
    container.read(hostKeyProvenanceProvider.notifier).state = HostKeyProvenanceEvent(
        host: '192.168.10.22', port: 2222, device: "Alex's laptop", recordedAt: DateTime(2026, 10, 2, 14, 30));
    await step(tester);
    expect(find.text(adopted), findsOneWidget);
    expect(container.read(hostKeyProvenanceProvider), isNull);
    await finish(tester);
  });

  testWidgets('while the screen is recorded, the address, the fingerprint and the device are not shown as they are',
      (tester) async {
    await phone(tester);
    final level = Redactor.instance.level;
    addTearDown(() => Redactor.instance
      ..enabled = false
      ..level = level);
    Redactor.instance
      ..enabled = true
      ..level = RedactLevel.layout;
    container.read(hostKeyAutoAcceptProvider.notifier).state = const HostKeyAutoAcceptEvent(
        host: '192.168.10.21', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:q2Vx7Example');
    await step(tester);
    expect(find.textContaining('ssh-ed25519'), findsOneWidget, reason: 'told');
    expect(find.textContaining('192.168.10.21'), findsNothing);
    expect(find.textContaining('q2Vx7Example'), findsNothing);
    container.read(hostKeyProvenanceProvider.notifier).state = HostKeyProvenanceEvent(
        host: '192.168.10.22', port: 2222, device: "Alex's laptop", recordedAt: DateTime(2026, 10, 2));
    await step(tester);
    expect(find.textContaining('2026-10-02'), findsOneWidget, reason: 'told');
    expect(find.textContaining('192.168.10.22'), findsNothing);
    expect(find.textContaining('Alex'), findsNothing);
    await finish(tester);
  });

  testWidgets('while the app is locked nothing is told; once it is open, it is', (tester) async {
    await phone(tester);
    final lock = container.read(isAppLockedProvider.notifier) as _Lock;
    lock.set(true);
    router.go(Routes.securityLock);
    await step(tester);
    container.read(hostKeyAutoAcceptProvider.notifier).state = const HostKeyAutoAcceptEvent(
        host: '192.168.10.21', port: 22, keyType: 'ssh-ed25519', fingerprint: 'SHA256:q2Vx7Example');
    container.read(hostKeyProvenanceProvider.notifier).state = HostKeyProvenanceEvent(
        host: '192.168.10.22', port: 2222, device: "Alex's laptop", recordedAt: DateTime(2026, 10, 2));
    await step(tester);
    expect(find.text(accepted), findsNothing);
    expect(find.text(adopted), findsNothing);
    expect(container.read(hostKeyAutoAcceptProvider), isNotNull, reason: 'it waits');

    lock.set(false);
    router.go('/');
    await step(tester);
    expect(find.text(adopted), findsOneWidget, reason: 'the last told is the one on screen');
    expect(container.read(hostKeyAutoAcceptProvider), isNull, reason: 'told as well');
    expect(container.read(hostKeyProvenanceProvider), isNull);
    await finish(tester);
  });
}
