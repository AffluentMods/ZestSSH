import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/two_step_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/account/account_name.dart';
import 'package:zestssh/services/account/sign_in_ways.dart';
import 'package:zestssh/services/account/two_step.dart';
import 'package:zestssh/services/account/two_step_api.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/ui/screens/profile/profile_screen.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;
import 'package:zestssh/ui/widgets/copy_details_button.dart';

/// Settings > Account and security on a computer (3.2.x): the
/// account's Manage opens a menu at the button, not a phone's sheet from the
/// bottom of the window; and two-step sign-in, which a computer signed in
/// through the browser sets up on zestssh.com, never reads as an error with
/// a Retry when ZestSSH Cloud cannot say whether it is on. A phone and a
/// tablet keep their sheet.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final windows = TargetPlatformVariant.only(TargetPlatform.windows);

  tearDown(() => debugTouchLayout = null);

  Future<void> settle(WidgetTester tester, {int rounds = 8}) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  /// The account page as Settings shows it, signed in through the browser
  /// (no Firebase sign-in here), with ZestSSH Cloud answering the two-step
  /// question with [twoStep] (its recovery codes route, as a server from
  /// before 3.3 does: GET /v1/account/two-step answers 404), or with
  /// [twoStepState] (a 3.3 server's GET /v1/account/two-step).
  Future<void> pumpAccount(
    WidgetTester tester, {
    Future<http.Response> Function()? twoStep,
    Map<String, Object?>? twoStepState,
    PasskeyPlatform passkeys = const NoPasskeys(),
    Future<SignInWays?> Function()? signInWays,
    Map<String, Object> prefs = const {},
    Future<void> Function(String name)? setName,
  }) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues(prefs);
    final preferences = await SharedPreferences.getInstance();
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    tester.view.physicalSize = const Size(1000, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final answer = twoStep ??
        () async => http.Response(jsonEncode({'two_step': false, 'count': 0}), 200);
    final client = MockClient((request) async {
      if (request.url.path.endsWith('/account/two-step')) {
        return twoStepState == null ? http.Response('Cannot GET', 404) : http.Response(jsonEncode(twoStepState), 200);
      }
      if (request.url.path.endsWith('/account/passkeys')) return http.Response(jsonEncode({'passkeys': []}), 200);
      return answer();
    });
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(preferences),
        databaseProvider.overrideWithValue(db),
        treeDatabaseProvider.overrideWithValue(db),
        currentUserProvider.overrideWith(
            (_) => const UserProfile(uid: 'u1', email: 'alex@example.com', displayName: 'Alex Rivera')),
        recordingModeProvider.overrideWith((ref) => false),
        syncHealthClockProvider.overrideWith((ref) => Stream.value(DateTime(2026, 10, 25, 12))),
        signInWaysProvider.overrideWith((ref) =>
            signInWays?.call() ?? Future.value(SignInWays.fromProviders('alex@example.com', ['google.com']))),
        recoveryCodesApiProvider.overrideWithValue(RecoveryCodesApi(
          client: client,
          baseUrl: 'https://cloud.example.dev/v1',
          bearer: () async => 'session-token',
        )),
        passkeyPlatformProvider.overrideWithValue(passkeys),
        if (setName != null) accountNameChangerProvider.overrideWithValue(setName),
        twoStepApiProvider.overrideWithValue(TwoStepApi(
          client: client,
          baseUrl: 'https://cloud.example.dev/v1',
          bearer: () async => 'session-token',
        )),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: Locale('en'),
        home: Scaffold(body: SingleChildScrollView(child: ProfileScreen(embedded: true))),
      ),
    ));
    await settle(tester);
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  Future<void> tapManage(WidgetTester tester) async {
    final manage = find.byKey(const ValueKey('account-manage'));
    await tester.ensureVisible(manage);
    await tester.tap(manage);
    await settle(tester, rounds: 4);
  }

  /// A photo set in ZestSSH on this device (the file need not be an image:
  /// the avatar shows the initial where it does not decode).
  Map<String, Object> withPhoto() {
    final dir = Directory.systemTemp.createTempSync('zest-avatar-');
    addTearDown(() => dir.deleteSync(recursive: true));
    final file = File('${dir.path}${Platform.pathSeparator}avatar.png')..writeAsBytesSync([0, 1, 2, 3]);
    return {'profile_custom_avatar_path': file.path};
  }

  // An account made with a password has no name,
  // and nothing could give it one.
  group('Edit name', () {
    final en = lookupAppLocalizations(const Locale('en'));

    Future<void> openIt(WidgetTester tester, Object? fails, List<String> set) async {
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      NotificationCenter.debugToastsDrawn = true;
      addTearDown(() => NotificationCenter.debugToastsDrawn = null);
      await pumpAccount(tester, setName: (name) async {
        if (fails != null) throw fails;
        set.add(name);
      });
      await tapManage(tester);
      await tester.tap(find.byKey(const ValueKey('account-photo-edit-name')));
      await settle(tester, rounds: 4);
    }

    String said(WidgetTester tester) {
      final c = ProviderScope.containerOf(tester.element(find.byType(ProfileScreen)), listen: false);
      return c.read(notificationCenterProvider).history.first.title;
    }

    testWidgets('asks for it with the name there is, and sets what is typed, trimmed', (tester) async {
      final set = <String>[];
      await openIt(tester, null, set);
      expect(find.text(en.accountEditNameTitle), findsOneWidget);
      expect(find.widgetWithText(TextField, 'Alex Rivera'), findsOneWidget);
      await tester.enterText(find.byType(TextField).last, '  Sam Doe  ');
      await tester.pump();
      await tester.tap(find.text(en.save).last);
      await settle(tester, rounds: 4);
      expect(set, ['Sam Doe']);
      expect(said(tester), en.accountEditNameSaved);
      await close(tester);
    });

    testWidgets('an empty name is refused, and nothing is sent', (tester) async {
      final set = <String>[];
      await openIt(tester, null, set);
      await tester.enterText(find.byType(TextField).last, '   ');
      await tester.pump();
      await tester.tap(find.text(en.save).last);
      await settle(tester, rounds: 4);
      expect(set, isEmpty);
      expect(find.text(en.accountEditNameRequired), findsOneWidget);
      await close(tester);
    });

    for (final (refusal, words) in [
      (const AccountNameRefusal(400, code: 'invalid-name'), en.accountEditNameInvalid),
      (const AccountNameRefusal(502, code: 'identity-update-failed'), en.accountEditNameIdentityFailed),
      (const AccountNameRefusal(500), en.accountEditNameFailed),
      (const AccountNameRefusal(404), en.accountEditNameFailed),
    ]) {
      testWidgets('$refusal: said in the dialog, with Copy details, and what was typed stays there', (tester) async {
        await openIt(tester, refusal, []);
        await tester.enterText(find.byType(TextField).last, 'Sam Doe');
        await tester.pump();
        await tester.tap(find.text(en.save).last);
        await settle(tester, rounds: 4);
        expect(find.text(en.accountEditNameTitle), findsOneWidget, reason: 'the dialog stays open');
        expect(find.text(words), findsOneWidget);
        expect(find.widgetWithText(TextField, 'Sam Doe'), findsOneWidget, reason: 'the name typed is not gone');
        expect(find.byType(CopyDetailsButton), findsOneWidget);
        await close(tester);
      });
    }

    testWidgets('what was refused can be tried again from where it is', (tester) async {
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      NotificationCenter.debugToastsDrawn = true;
      addTearDown(() => NotificationCenter.debugToastsDrawn = null);
      final set = <String>[];
      var fails = true;
      await pumpAccount(tester, setName: (name) async {
        if (fails) throw const AccountNameRefusal(502, code: 'identity-update-failed');
        set.add(name);
      });
      await tapManage(tester);
      await tester.tap(find.byKey(const ValueKey('account-photo-edit-name')));
      await settle(tester, rounds: 4);
      await tester.enterText(find.byType(TextField).last, 'Sam Doe');
      await tester.pump();
      await tester.tap(find.text(en.save).last);
      await settle(tester, rounds: 4);
      expect(find.text(en.accountEditNameIdentityFailed), findsOneWidget);
      fails = false;
      await tester.tap(find.text(en.save).last);
      await settle(tester, rounds: 4);
      expect(set, ['Sam Doe']);
      expect(said(tester), en.accountEditNameSaved);
      await tester.pump(const Duration(seconds: 1));
      await settle(tester, rounds: 2);
      expect(find.text(en.accountEditNameTitle), findsNothing);
      await close(tester);
    });

    testWidgets('what draws text wrongly or not at all is not part of a name, on the way a phone takes as well',
        (tester) async {
      final set = <String>[];
      await openIt(tester, null, set);
      // Past the field's own filter, as a paste through another way would be.
      final field = tester.widget<TextField>(find.byType(TextField).last);
      field.controller!.text = 'Sa\u202em\u0085 \u200bDoe\u2066';
      await tester.pump();
      await tester.tap(find.text(en.save).last);
      await settle(tester, rounds: 4);
      expect(set, ['Sam Doe']);
      await close(tester);
    });

    test('the field keeps them out as they are typed, and only them', () {
      for (final bad in ['\x00', '\x1b', '\x7f', '\u0085', '\u009b', '\u00ad', '\u061c', '\u200b', '\u200f', '\u2028', '\u202e', '\u2066', '\u2069', '\ufeff']) {
        expect(kAccountNameRefuses.hasMatch(bad), isTrue, reason: bad.runes.first.toRadixString(16));
      }
      for (final good in ['Sam', 'Zoë', 'علي', '山田', 'Јован', '😀']) {
        expect(cleanAccountName(good), good);
      }
      expect(cleanAccountName('  Sam\n\tDoe  '), 'Sam Doe');
      expect(cleanAccountName('\u202e'), '');
    });

    testWidgets('while the screen is recorded the real name is not drawn: recording goes off first, or nothing opens',
        (tester) async {
      final set = <String>[];
      debugTouchLayout = false;
      addTearDown(() => debugTouchLayout = null);
      NotificationCenter.debugToastsDrawn = true;
      addTearDown(() => NotificationCenter.debugToastsDrawn = null);
      await pumpAccount(tester, setName: (name) async => set.add(name));
      final c = ProviderScope.containerOf(tester.element(find.byType(ProfileScreen)), listen: false);
      c.read(recordingModeProvider.notifier).state = true;
      await settle(tester, rounds: 2);
      await tapManage(tester);
      await tester.tap(find.byKey(const ValueKey('account-photo-edit-name')));
      await settle(tester, rounds: 4);
      expect(find.text(en.recModeRevealTitle), findsOneWidget);
      expect(find.text(en.accountEditNameTitle), findsNothing);
      expect(find.widgetWithText(TextField, 'Alex Rivera'), findsNothing);
      await tester.tap(find.text(en.cancel).last);
      await settle(tester, rounds: 4);
      expect(find.text(en.accountEditNameTitle), findsNothing, reason: 'declined, nothing opens');
      c.read(recordingModeProvider.notifier).state = false;
      await close(tester);
    });

    testWidgets("a phone's sheet has it too", (tester) async {
      debugTouchLayout = true;
      addTearDown(() => debugTouchLayout = null);
      await pumpAccount(tester);
      await tapManage(tester);
      expect(find.byKey(const ValueKey('account-photo-edit-name')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-photo-sign-out')), findsOneWidget, reason: 'Sign out, as item 62 asked');
      await close(tester);
    });

    test('a computer asks ZestSSH Cloud, and says what it kept', () async {
      late http.Request sent;
      final api = AccountNameApi(
        baseUrl: 'https://cloud.example.dev/v1',
        bearer: () async => 'session-token',
        client: MockClient((request) async {
          sent = request;
          return http.Response(jsonEncode({'display_name': 'Sam'}), 200);
        }),
      );
      expect(await api.setName('Sam '), 'Sam');
      expect(sent.method, 'PATCH');
      expect(sent.url.path, '/v1/account/profile');
      expect(sent.headers['Authorization'], 'Bearer session-token');
      expect(jsonDecode(sent.body), {'display_name': 'Sam '});
    });

    test('what is set is the name cleaned, whichever way it goes; nothing is left, nothing is sent', () async {
      SharedPreferences.setMockInitialValues({});
      final prefs = await SharedPreferences.getInstance();
      FlutterSecureStorage.setMockInitialValues({});
      final sent = <String>[];
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        accountNameApiProvider.overrideWithValue(AccountNameApi(
          baseUrl: 'https://cloud.example.dev/v1',
          bearer: () async => 'session-token',
          client: MockClient((request) async {
            sent.add((jsonDecode(request.body) as Map)['display_name'] as String);
            return http.Response(jsonEncode({'display_name': 'Sam Doe'}), 200);
          }),
        )),
      ]);
      addTearDown(c.dispose);
      final change = c.read(accountNameChangerProvider);
      await change('Sa\u202em\u0085 \u200bDoe\u2066');
      expect(sent, ['Sam Doe']);
      await expectLater(
        change('\u202e'),
        throwsA(isA<AccountNameRefusal>().having((e) => e.invalidName, 'invalidName', isTrue)),
      );
      expect(sent, hasLength(1));
    });

    test('each refusal of the server is told by its code', () async {
      AccountNameApi answering(http.Response r) => AccountNameApi(
            baseUrl: 'https://cloud.example.dev/v1',
            bearer: () async => 'session-token',
            client: MockClient((_) async => r),
          );
      await expectLater(
        answering(http.Response(jsonEncode({'error': 'Give a name of 1 to 100 characters', 'code': 'invalid-name'}), 400)).setName('Sam'),
        throwsA(isA<AccountNameRefusal>().having((e) => e.invalidName, 'invalidName', isTrue)),
      );
      await expectLater(
        answering(http.Response(jsonEncode({'code': 'identity-update-failed'}), 502)).setName('Sam'),
        throwsA(isA<AccountNameRefusal>().having((e) => e.signInServiceDown, 'signInServiceDown', isTrue)),
      );
      await expectLater(
        answering(http.Response('Cannot PATCH', 404)).setName('Sam'),
        throwsA(isA<AccountNameRefusal>()
            .having((e) => e.invalidName, 'invalidName', isFalse)
            .having((e) => e.signInServiceDown, 'signInServiceDown', isFalse)),
      );
    });
  });

  group('Manage, on a computer', () {
    testWidgets('opens a menu at the button, not a sheet at the bottom of the window', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester);
      await tapManage(tester);

      expect(find.byType(BottomSheet), findsNothing);
      final change = find.byKey(const ValueKey('account-photo-change'));
      expect(change, findsOneWidget);
      expect(find.text(l10n.profileAvatarChangePhoto), findsOneWidget);
      // No photo set in ZestSSH: there is none to remove (as on a phone).
      expect(find.byKey(const ValueKey('account-photo-remove')), findsNothing);

      // Just under the button, not at the bottom of the window.
      final button = tester.getRect(find.byKey(const ValueKey('account-manage')));
      final item = tester.getRect(find.byKey(const ValueKey('account-photo-edit-name')));
      expect(item.top, greaterThanOrEqualTo(button.bottom - 1));
      expect(item.top - button.bottom, lessThan(40));
      expect(item.bottom, lessThan(tester.view.physicalSize.height / 2));

      // A click beside it closes it, as any of a computer's menus.
      await tester.tapAt(const Offset(5, 2900));
      await settle(tester);
      expect(change, findsNothing);
      await close(tester);
    }, variant: windows);

    testWidgets('offers Remove photo once a photo was set, as a phone does', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester, prefs: withPhoto());
      await tapManage(tester);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('account-photo-change')), findsOneWidget);
      expect(find.byKey(const ValueKey('account-photo-remove')), findsOneWidget);
      expect(find.text(l10n.profileAvatarRemovePhoto), findsOneWidget);
      await tester.tapAt(const Offset(5, 2900));
      await settle(tester, rounds: 4);
      await close(tester);
    }, variant: windows);

    testWidgets('the photo opens the same menu', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester);
      final photo = find.byType(ProfileAvatar).first;
      await tester.ensureVisible(photo);
      await tester.tap(photo);
      await settle(tester, rounds: 4);
      expect(find.byType(BottomSheet), findsNothing);
      expect(find.byKey(const ValueKey('account-photo-change')), findsOneWidget);
      await tester.tapAt(const Offset(5, 2900));
      await settle(tester, rounds: 4);
      await close(tester);
    }, variant: windows);
  });

  testWidgets('a phone keeps its sheet', (tester) async {
    debugTouchLayout = true;
    await pumpAccount(tester, prefs: withPhoto());
    await tapManage(tester);
    expect(find.byType(BottomSheet), findsOneWidget);
    expect(find.byKey(const ValueKey('account-photo-change')), findsNothing);
    expect(find.text(l10n.profileAvatarChangePhoto), findsOneWidget);
    expect(find.text(l10n.profileAvatarRemovePhoto), findsOneWidget);
    await close(tester);
  });

  group('Two-step sign-in, on a computer signed in through the browser', () {
    Finder inRow(Finder f) => find.descendant(of: find.byKey(const ValueKey('two-step-web')), matching: f);

    /// The row says where two-step sign-in is managed, with the way there,
    /// and nothing in it reads as a failure.
    void saysWhereItIsManaged() {
      expect(inRow(find.text(l10n.accountTwoStep)), findsOneWidget);
      expect(inRow(find.text(l10n.twoStepWebManagedDesc)), findsOneWidget);
      expect(inRow(find.text(l10n.twoStepOpenWeb)), findsOneWidget);
      expect(find.text('Could not check two-step sign-in.'), findsNothing);
      expect(inRow(find.text(l10n.retry)), findsNothing);
      expect(inRow(find.text(l10n.twoStepStatusOn)), findsNothing);
      expect(inRow(find.byType(CircularProgressIndicator)), findsNothing);
    }

    testWidgets('ZestSSH Cloud could not ask the sign-in service: where it is managed, no error', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester,
          twoStep: () async => http.Response(jsonEncode({'two_step': null, 'count': 0}), 200));
      saysWhereItIsManaged();
      await close(tester);
    }, variant: windows);

    testWidgets('ZestSSH Cloud could not be reached: the same, no error', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester,
          twoStep: () async => http.Response('<html>down</html>', 503),
          twoStepState: null);
      saysWhereItIsManaged();
      await close(tester);
    }, variant: windows);

    testWidgets('while it is asked: the same, with no spinner', (tester) async {
      debugTouchLayout = false;
      final gate = Completer<http.Response>();
      await pumpAccount(tester, twoStep: () => gate.future);
      saysWhereItIsManaged();
      gate.complete(http.Response(jsonEncode({'two_step': true, 'count': 10}), 200));
      await settle(tester);
      expect(inRow(find.text(l10n.twoStepWebOnDesc)), findsOneWidget);
      await close(tester);
    }, variant: windows);

    testWidgets('on: the On pill, and where to change it', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester,
          twoStep: () async => http.Response(jsonEncode({'two_step': true, 'count': 10}), 200));
      expect(inRow(find.text(l10n.twoStepStatusOn)), findsOneWidget);
      expect(inRow(find.text(l10n.twoStepWebOnDesc)), findsOneWidget);
      // The pill says On; the words after it do not say it again (they began
      // "On. ...").
      expect(l10n.twoStepWebOnDesc, isNot(startsWith(l10n.twoStepStatusOn)));
      expect(inRow(find.text(l10n.twoStepOpenWeb)), findsOneWidget);
      expect(find.text('Could not check two-step sign-in.'), findsNothing);
      await close(tester);
    }, variant: windows);

    testWidgets('off: where to set it up', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester,
          twoStep: () async => http.Response(jsonEncode({'two_step': false, 'count': 0}), 200));
      expect(inRow(find.text(l10n.twoStepStatusOn)), findsNothing);
      expect(inRow(find.text(l10n.twoStepWebOffDesc)), findsOneWidget);
      expect(inRow(find.text(l10n.twoStepOpenWeb)), findsOneWidget);
      // Setting it up in the app is a phone's (Firebase) way, not a computer's.
      expect(find.text(l10n.twoStepSetUp), findsNothing);
      await close(tester);
    }, variant: windows);

    testWidgets('with ZestSSH Cloud of 3.3: its passkeys added in the browser, the authenticator set up on '
        'zestssh.com, and what is changed here, here', (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester, twoStepState: {
        'on': true,
        'authenticator': true,
        'passkeys': 0,
        'recovery_codes': 7,
        'passkeys_available': true,
        'recovery_proof': false,
        'lockout_recovery': null,
      });
      expect(find.byKey(const ValueKey('two-step-web')), findsNothing);
      expect(find.byKey(const ValueKey('two-step-status')), findsOneWidget);
      expect(find.text(l10n.twoStepSectionOnDesc), findsOneWidget);
      // A computer with no passkeys of its own (Linux, the Mac): the browser,
      // where a passkey replaces the authenticator app (one or the other).
      expect(find.text(l10n.passkeysInsteadDesc), findsOneWidget);
      expect(find.text(l10n.twoStepRule), findsOneWidget);
      expect(find.byKey(const ValueKey('passkey-add')), findsOneWidget);
      expect(find.byKey(const ValueKey('authenticator-remove')), findsOneWidget);
      expect(find.text(l10n.twoStepCodesRowDescAny(7)), findsOneWidget);
      expect(find.text(l10n.twoStepSetUp), findsNothing, reason: "setting it up in the app is a phone's way");
      await close(tester);
    }, variant: windows);

    testWidgets('with ZestSSH Cloud of 3.3, on a computer with passkeys of its own (Windows): added here, not in the browser',
        (tester) async {
      debugTouchLayout = false;
      await pumpAccount(tester, passkeys: const _PasskeysHere(), twoStepState: {
        'on': false,
        'authenticator': false,
        'passkeys': 0,
        'recovery_codes': 0,
        'passkeys_available': true,
        'recovery_proof': false,
        'lockout_recovery': null,
      });
      expect(find.text(l10n.passkeysDesc), findsOneWidget);
      expect(find.text(l10n.passkeysBrowserDesc), findsNothing);
      expect(find.byKey(const ValueKey('passkey-add')), findsOneWidget);
      await close(tester);
    }, variant: windows);
  });

  // How you sign in failed on a computer too: where
  // ZestSSH Cloud cannot say, the row says where it is seen and changed.
  testWidgets('How you sign in, on a computer, where ZestSSH Cloud cannot say: zestssh.com, no error',
      (tester) async {
    debugTouchLayout = false;
    await pumpAccount(tester, signInWays: () => Future.error(const SignInWaysException(502, 'upstream')));
    final row = find.byKey(const ValueKey('sign-in-ways'));
    expect(find.descendant(of: row, matching: find.text(l10n.accountSignInWaysWeb)), findsOneWidget);
    expect(find.descendant(of: row, matching: find.text(l10n.twoStepOpenWeb)), findsOneWidget);
    expect(find.text(l10n.accountSignInWaysFailed), findsNothing);
    expect(find.descendant(of: row, matching: find.text(l10n.retry)), findsNothing);
    await close(tester);
  }, variant: windows);
}

/// A computer with passkeys of its own, as Windows has.
class _PasskeysHere implements PasskeyPlatform {
  const _PasskeysHere();

  @override
  Future<bool> isAvailable() async => true;

  @override
  Future<Map<String, Object?>> create(Map<String, Object?> options) => throw UnimplementedError();

  @override
  Future<Map<String, Object?>> get(Map<String, Object?> options) => throw UnimplementedError();
}
