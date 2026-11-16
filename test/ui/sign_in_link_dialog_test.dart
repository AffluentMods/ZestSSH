import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
// The messages a played server sends are not in the package's barrel.
// ignore: implementation_imports
import 'package:zest_ssh_core/src/message/msg_userauth.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/security_providers.dart';
import 'package:zestssh/providers/server_question_providers.dart';
import 'package:zestssh/services/ssh_auth_prompts.dart';
import 'package:zestssh/services/ssh_service.dart';
import 'package:zestssh/ui/screens/terminal/phone_sign_in_questions.dart';
import 'package:zestssh/ui/screens/terminal/widgets/sign_in_link_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';

import '../../packages/zest_ssh_core/test/src/played_server.dart';

/// A login banner with a link the sign-in waits on (Tailscale SSH's "check"
/// mode; seen on an iPhone), shown to the person
/// while the app connects: on a phone by the app's sign-in questions, as a
/// sheet, and on a computer by its shell, as a dialog. The host is played by
/// the test and says yes only after longer than a sign-in is usually given;
/// links open through a fake launcher.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  const tailscale = '# Tailscale SSH requires an additional check.\n'
      '# To authenticate, visit: \x1b[4mhttps://login.tailscale.com/a/l1b2c3d4e5f6\x1b[0m\n';
  final link = Uri.parse('https://login.tailscale.com/a/l1b2c3d4e5f6');
  final shower = Provider<SignInNoticeShower>(
      (ref) => signInNoticeShower(ref, host: 'web-01.example.com', port: 22, username: 'deploy'));

  late List<Uri> opened;
  late bool opens;

  setUp(() {
    L10nGlobal.update(l10n);
    AuthDeadline.debugPatience = const Duration(seconds: 1);
    opened = [];
    opens = true;
    debugOpenSignInLink = (uri) async {
      opened.add(uri);
      return opens;
    };
  });
  tearDown(() {
    AuthDeadline.debugPatience = null;
    debugOpenSignInLink = null;
  });

  /// The app at [size]: on a phone ([phone]) with its sign-in questions over
  /// the router's screens, on a computer with a shell's listener as the
  /// desktop shell has it. Returns the app's providers.
  Future<ProviderContainer> app(WidgetTester tester, {required bool phone}) async {
    tester.view.physicalSize = phone ? const Size(390, 844) : const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      dbReadyProvider.overrideWithValue(true),
      isAppLockedProvider.overrideWith((ref) => _Unlocked()),
    ]);
    addTearDown(container.dispose);
    final router = GoRouter(routes: [GoRoute(path: '/', builder: (_, _) => const Scaffold(body: Text('hosts')))]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        builder: (context, child) => phone
            ? PhoneSignInQuestions(router: router, child: child!)
            : _DesktopShellQuestions(navigator: router.routerDelegate.navigatorKey, child: child!),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  /// Real time, for what the played host and the connection do.
  Future<void> wait(WidgetTester tester, Duration d) => tester.runAsync(() => Future<void>.delayed(d));

  for (final phone in [true, false]) {
    final layout = phone ? 'a phone' : 'a computer';
    // A phone's platform is what makes the app's dialogs sheets there.
    final platform = TargetPlatformVariant.only(phone ? TargetPlatform.iOS : TargetPlatform.windows);

    testWidgets('on $layout: the banner is shown while the sign-in waits on it, past the time a sign-in is '
        'usually given; Open link opens it and only it; the session opens and the notice closes', (tester) async {
      final container = await app(tester, phone: phone);
      late PlayedServer server;
      late SshService ssh;
      Object? failure;
      var done = false;
      await tester.runAsync(() async {
        server = PlayedServer();
        ssh = SshService(
          host: 'web-01.example.com',
          port: 22,
          username: 'deploy',
          keepAliveSeconds: 0,
          onHostKeyVerify: (_, _, _) async => true,
          onSignInNotice: container.read(shower),
          tunnelSocket: server.socket,
        );
        unawaited(ssh.connect().then<void>((_) => done = true, onError: (Object e) {
          failure = e;
          done = true;
        }));
        await server.greet();
        await server.next(SSH_Message_Userauth_Request.messageId);
        server.send([SSH_Message_Userauth_Banner(message: tailscale, language: '').encode()]);
        final clock = Stopwatch()..start();
        while (container.read(signInNoticeQueueProvider).isEmpty && clock.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      addTearDown(() => tester.runAsync(ssh.disconnect));
      await tester.pumpAndSettle();

      expect(find.byType(ZestDialogShell), findsOneWidget);
      expect(find.byType(ZestSheetScope), phone ? findsOneWidget : findsNothing);
      expect(find.text(l10n.signInLinkTitle), findsOneWidget);
      expect(find.text(l10n.signInLinkFromServer), findsOneWidget);
      // The server's words, without the escape codes around the link.
      expect(find.textContaining('# To authenticate, visit: https://login.tailscale.com/a/l1b2c3d4e5f6'),
          findsOneWidget);
      expect(find.textContaining('\x1b'), findsNothing);
      expect(find.text(l10n.signInLinkGoesTo('login.tailscale.com')), findsOneWidget);
      // Nothing is opened by itself.
      expect(opened, isEmpty);

      await tester.tap(find.text(l10n.signInLinkOpen));
      await tester.pumpAndSettle();
      expect(opened, [link]);
      // Opening it keeps the notice: the sign-in still waits.
      expect(find.text(l10n.signInLinkTitle), findsOneWidget);

      // Longer than the sign-in's usual time.
      await wait(tester, const Duration(milliseconds: 2500));
      await tester.pump();
      expect(done, isFalse, reason: 'the sign-in ended while its person had the link: $failure');
      expect(find.text(l10n.signInLinkTitle), findsOneWidget);

      // Approved: the host says yes, and the shell opens.
      await tester.runAsync(() async {
        server.send([SSH_Message_Userauth_Success().encode()]);
        final channel = await server.confirmChannel();
        expect((await channel.nextRequest()).requestType, 'pty-req');
        server.send([channel.success]);
        expect((await channel.nextRequest()).requestType, 'shell');
        server.send([channel.success]);
        final clock = Stopwatch()..start();
        while (!done && clock.elapsed < const Duration(seconds: 10)) {
          await Future<void>.delayed(const Duration(milliseconds: 10));
        }
      });
      await tester.pumpAndSettle();
      expect(failure, isNull);
      expect(ssh.isConnected, isTrue);
      expect(find.text(l10n.signInLinkTitle), findsNothing);
      expect(container.read(signInNoticeQueueProvider), isEmpty);
    }, variant: platform, timeout: const Timeout(Duration(seconds: 90)));

    testWidgets('on $layout: Cancel ends the sign-in, as a cancel', (tester) async {
      final container = await app(tester, phone: phone);
      final withdrawn = Completer<void>();
      final cancelled = container.read(shower)(SignInNotice.of(tailscale, withdrawn: withdrawn.future));
      await tester.pumpAndSettle();
      expect(find.text(l10n.signInLinkTitle), findsOneWidget);
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(find.text(l10n.signInLinkTitle), findsNothing);
      expect(await cancelled, isTrue);
      expect(opened, isEmpty);
    }, variant: platform);
  }

  testWidgets('a link that does not open: said, with Copy link to take it elsewhere', (tester) async {
    final container = await app(tester, phone: false);
    final withdrawn = Completer<void>();
    final cancelled = container.read(shower)(SignInNotice.of(tailscale, withdrawn: withdrawn.future));
    await tester.pumpAndSettle();
    opens = false;
    await tester.tap(find.text(l10n.signInLinkOpen));
    await tester.pump();
    expect(find.text(l10n.signInLinkNotOpened), findsOneWidget);

    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.tap(find.text(l10n.signInLinkCopy));
    await tester.pump();
    expect(copied, link.toString());

    // The sign-in is over (it failed, or the host let it in): the notice closes, and that is no cancel.
    withdrawn.complete();
    await tester.pumpAndSettle(const Duration(seconds: 10));
    expect(find.text(l10n.signInLinkTitle), findsNothing);
    expect(await cancelled, isFalse);
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));

  // A jump host's banner names the jump host and where it leads; a run's and
  // a connection test's say that it goes on, not that a session opens.
  for (final (purpose, waiting) in [
    (SignInNoticeFor.session, l10n.signInLinkWaiting),
    (SignInNoticeFor.run, l10n.signInLinkWaitingRun),
    (SignInNoticeFor.test, l10n.signInLinkWaitingTest),
  ]) {
    testWidgets('for a ${purpose.name}, at a jump host on the way: which one, to where, and what goes on',
        (tester) async {
      final container = await app(tester, phone: false);
      final withdrawn = Completer<void>();
      final notice = Provider<SignInNoticeShower>((ref) => signInNoticeShower(ref,
          host: 'bastion.example.com',
          port: 22,
          username: 'deploy',
          jumpHost: 'bastion',
          onward: 'web-01',
          purpose: purpose));
      unawaited(container.read(notice)(SignInNotice.of(tailscale, withdrawn: withdrawn.future)));
      await tester.pumpAndSettle();
      expect(find.text('deploy@bastion.example.com'), findsOneWidget);
      expect(find.text(l10n.signInLinkJumpHost('bastion', 'web-01')), findsOneWidget);
      expect(find.text(waiting), findsOneWidget);
      withdrawn.complete();
      await tester.pumpAndSettle(const Duration(seconds: 10));
      expect(find.text(l10n.signInLinkTitle), findsNothing);
    }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
  }

  testWidgets("the host's own banner names no jump host", (tester) async {
    final container = await app(tester, phone: false);
    final withdrawn = Completer<void>();
    unawaited(container.read(shower)(SignInNotice.of(tailscale, withdrawn: withdrawn.future)));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('sign-in-link-jump-host')), findsNothing);
    expect(find.text(l10n.signInLinkWaiting), findsOneWidget);
    withdrawn.complete();
    await tester.pumpAndSettle(const Duration(seconds: 10));
  }, variant: TargetPlatformVariant.only(TargetPlatform.windows));
}

/// What the desktop shell does with a login banner's link: listens, and
/// shows each with [showSignInNotices] over its navigator.
class _DesktopShellQuestions extends ConsumerStatefulWidget {
  const _DesktopShellQuestions({required this.navigator, required this.child});

  final GlobalKey<NavigatorState> navigator;
  final Widget child;

  @override
  ConsumerState<_DesktopShellQuestions> createState() => _DesktopShellQuestionsState();
}

class _DesktopShellQuestionsState extends ConsumerState<_DesktopShellQuestions> {
  bool _showing = false;

  Future<void> _show() async {
    final at = widget.navigator.currentContext;
    if (_showing || at == null) return;
    _showing = true;
    try {
      await showSignInNotices(at, ref, isMounted: () => mounted);
    } finally {
      _showing = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    ref.listen<SignInNoticeRequest?>(signInNoticeProvider, (prev, next) {
      if (next != null) _show();
    });
    return widget.child;
  }
}

class _Unlocked extends StateNotifier<bool> implements AppLockNotifier {
  _Unlocked() : super(false);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
