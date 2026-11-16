// Accounts on one computer, as a review found: the X of a question whose two
// buttons each do something is no answer. Nothing moves, and nothing opens.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/services/desktop_auth_server.dart' show BrowserSignInCancelled;
import 'package:zestssh/services/profiles/profile_manager.dart' show GuestDataSummary;
import 'package:zestssh/ui/screens/profile/account_sign_in.dart';
import 'package:zestssh/ui/screens/profile/account_switch.dart';
import 'package:zestssh/ui/screens/profile/widgets/guest_data_question.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

class _P implements ProfileController {
  final said = <bool>[];
  var brought = 0;
  @override
  bool get on => true;
  @override
  int get openSessions => 0;
  @override
  bool get roomForAnotherAccount => true;
  @override
  bool get addAsksWhose => true;
  @override
  Future<SignInSaid> nextSignInIs({required bool mine}) async {
    said.add(mine);
    return SignInSaid.nothing;
  }

  @override
  void forgetNextSignIn(SignInSaid said) {}
  @override
  Future<void> bringGuestData() async => brought++;
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  late _P profiles;
  late WidgetRef rowRef;
  late BuildContext rowContext;

  setUp(() => profiles = _P());
  tearDown(() => debugBrowserSession = null);

  Future<void> pump(WidgetTester tester) async {
    FlutterSecureStorage.setMockInitialValues({});
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    await tester.binding.setSurfaceSize(const Size(1000, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        profileControllerProvider.overrideWithValue(profiles),
        currentUserProvider.overrideWithValue(null),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Consumer(builder: (context, ref, _) {
            rowRef = ref;
            rowContext = context;
            return const SizedBox(width: 220, height: 44);
          }),
        ),
      ),
    ));
    await tester.pump();
  }

  // The dialog's own X, as a person presses it.
  Finder theX() => find.byWidgetPredicate((w) => w.runtimeType.toString() == '_CloseButton');

  testWidgets('control: Escape on the guest data question brings nothing', (tester) async {
    await pump(tester);
    unawaited(showGuestDataQuestion(rowContext, rowRef, const GuestDataSummary(hosts: 3, keys: 1)));
    await tester.pumpAndSettle();
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(profiles.brought, 0);
  });

  testWidgets('the X of the guest data question brings nothing', (tester) async {
    await pump(tester);
    unawaited(showGuestDataQuestion(rowContext, rowRef, const GuestDataSummary(hosts: 3, keys: 1)));
    await tester.pumpAndSettle();
    expect(theX(), findsOneWidget);
    await tester.tap(theX());
    await tester.pumpAndSettle();
    expect(profiles.brought, 0, reason: 'The X moved guest data into the account on screen, and its profile goes after that');
  });

  testWidgets('the X of "Whose account is this?" stops there, with no sign-in', (tester) async {
    var signIns = 0;
    debugBrowserSession = ({bool create = false}) async {
      signIns++;
      throw const BrowserSignInCancelled();
    };
    await pump(tester);
    unawaited(addAccount(rowContext, rowRef));
    await tester.pumpAndSettle();
    final question = tester.widget<ZestConfirmDialog>(find.byType(ZestConfirmDialog));
    expect(question.cancelValue, isNot(isA<bool>()), reason: 'Each answer goes by name, so that no close can pass for one');
    expect(theX(), findsOneWidget);
    await tester.tap(theX());
    await tester.pumpAndSettle();
    expect(profiles.said, isEmpty, reason: 'The X answered "Someone else\'s"');
    expect(signIns, 0, reason: 'The X went on to the sign-in');
  });
}
