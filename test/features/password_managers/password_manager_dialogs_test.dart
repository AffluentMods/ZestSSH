import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/password_managers/password_manager_cli.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_manager_requests.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';

/// The password manager questions on screen (3.0): unlocking
/// Bitwarden or KeePassXC, allowing a password to go to an address, and
/// typing one this once (with what the tool said, copyable); a session's
/// question reaches the screen through the app's answerer, one at a time,
/// and nothing answering counts as no.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final navigatorKey = GlobalKey<NavigatorState>();

  Future<ProviderContainer> app(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1200, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final container = ProviderContainer(overrides: [
      recordingModeProvider.overrideWith((ref) => false),
      recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        navigatorKey: navigatorKey,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Consumer(builder: (context, ref, _) {
          answerPasswordManagerRequests(ref, () => navigatorKey.currentContext);
          return const Scaffold(body: SizedBox.expand());
        }),
      ),
    ));
    return container;
  }

  testWidgets('unlocking Bitwarden: says what is kept, and says so when the password was wrong', (tester) async {
    final c = await app(tester);
    final answer = askPasswordManager(c.read, PmUnlockRequest(kind: PasswordManagerKind.bitwarden, again: true),
        onTimeout: null);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmUnlockBitwardenTitle), findsOneWidget);
    expect(find.text(l10n.pmUnlockBitwardenBody), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-unlock-wrong')), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('pm-unlock-field')), 'master');
    await tester.tap(find.text(l10n.pmUnlock));
    await tester.pumpAndSettle();
    expect(await answer, 'master');
    expect(c.read(passwordManagerRequestProvider), isNull);

    // Cancelled: null. KeePassXC says its own thing.
    final cancelled = askPasswordManager(c.read, PmUnlockRequest(kind: PasswordManagerKind.keePassXc, again: false),
        onTimeout: null);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmUnlockKeePassXcTitle), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-unlock-wrong')), findsNothing);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(await cancelled, isNull);
  });

  testWidgets('allowing a password to go somewhere: the item as the manager names it, and where it goes', (tester) async {
    final c = await app(tester);
    const item = PasswordRefDescription(title: 'Bank', where: 'Private', username: 'me');
    var answer = askPasswordManager(
        c.read, PmApprovalRequest(kind: PasswordManagerKind.onePassword, item: item, destination: 'deploy@evil.example.com:22'),
        onTimeout: false);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmApproveTitle('1Password')), findsOneWidget);
    expect(find.text('Bank'), findsOneWidget);
    expect(find.text('Private'), findsOneWidget);
    expect(find.text(l10n.pmApproveTo('deploy@evil.example.com:22')), findsOneWidget);
    await tester.tap(find.text(l10n.pmApproveDeny));
    await tester.pumpAndSettle();
    expect(await answer, isFalse);

    answer = askPasswordManager(
        c.read, PmApprovalRequest(kind: PasswordManagerKind.onePassword, item: item, destination: 'deploy@web1:22'),
        onTimeout: false);
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.pmApproveAllow));
    await tester.pumpAndSettle();
    expect(await answer, isTrue);
  });

  testWidgets('typing it once after a failure: why, what the tool said (copied in one tap), and that it is not kept',
      (tester) async {
    final c = await app(tester);
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));

    final answer = askPasswordManager(
        c.read,
        PmTypeOnceRequest(
            kind: PasswordManagerKind.onePassword,
            destination: 'deploy@web1.example.com:22',
            failure: PmFailure.notSignedIn,
            details: '[ERROR] account is not signed in'),
        onTimeout: null);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmFailedTitle('1Password')), findsOneWidget);
    expect(find.text(l10n.pmFailSignedOutOnePassword), findsOneWidget);
    expect(find.text('[ERROR] account is not signed in'), findsOneWidget);
    expect(find.text(l10n.pmTypeNotKept), findsOneWidget);
    expect(find.text(l10n.pmTypeFor('deploy@web1.example.com:22')), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('pm-details-copy')));
    await tester.pump();
    expect(copied, '[ERROR] account is not signed in');
    await tester.pumpAndSettle();
    await tester.enterText(find.byKey(const ValueKey('pm-type-field')), 'typed');
    await tester.tap(find.text(l10n.pmConnect));
    await tester.pumpAndSettle();
    expect(await answer, 'typed');

    // A phone: no failure, the phone's password manager can fill it.
    final phone = askPasswordManager(
        c.read, PmTypeOnceRequest(kind: PasswordManagerKind.bitwarden, destination: 'root@db:22'), onTimeout: null);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmTypeTitle('Bitwarden')), findsOneWidget);
    expect(find.text(l10n.pmTypePhoneBody('Bitwarden')), findsOneWidget);
    expect(find.byKey(const ValueKey('pm-details')), findsNothing);
    final field = tester.widget<TextField>(find.byKey(const ValueKey('pm-type-field')));
    expect(field.obscureText, isTrue);
    expect(field.autofillHints, [AutofillHints.password]);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(await phone, isNull);
    // The "Copied" note goes away on its own.
    await tester.pump(const Duration(seconds: 10));
  });

  testWidgets('questions wait their turn; nothing answering counts as no', (tester) async {
    final c = await app(tester);
    final first = askPasswordManager(c.read, PmUnlockRequest(kind: PasswordManagerKind.bitwarden, again: false),
        onTimeout: null);
    final second = askPasswordManager(
        c.read,
        PmApprovalRequest(
            kind: PasswordManagerKind.onePassword,
            item: const PasswordRefDescription(title: 'db'),
            destination: 'a@b:22'),
        onTimeout: false);
    await tester.pumpAndSettle();
    expect(find.text(l10n.pmUnlockBitwardenTitle), findsOneWidget);
    expect(find.text(l10n.pmApproveTitle('1Password')), findsNothing, reason: 'one at a time');
    await tester.enterText(find.byKey(const ValueKey('pm-unlock-field')), 'm');
    await tester.tap(find.text(l10n.pmUnlock));
    await tester.pumpAndSettle();
    expect(await first, 'm');
    expect(find.text(l10n.pmApproveTitle('1Password')), findsOneWidget);

    // Left unanswered: no.
    await tester.pump(kPasswordManagerRequestTimeout + const Duration(seconds: 1));
    expect(await second, isFalse);
    await tester.pumpAndSettle();
  });
}
