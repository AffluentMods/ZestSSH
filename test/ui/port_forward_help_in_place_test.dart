import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/port_forward/port_forward_screen.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

/// A computer's port forward editor is the shell (the dialog rules of 3.4):
/// its help opens in the dialog's place, not as a sheet over it (rule 4), and
/// Back returns to the form with what was typed; Cancel and Add are in the
/// footer, the help a link at its left.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets('the help swaps in place of the form, and Back keeps what was typed', (tester) async {
    debugTouchLayout = false;
    addTearDown(() => debugTouchLayout = null);
    tester.view.physicalSize = const Size(1280, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    PortForwardResult? got;
    var closed = false;
    await tester.pumpWidget(ProviderScope(
      overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        recordingModeProvider.overrideWith((ref) => false),
      ],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => showPortForwardEditor(context).then((r) {
                got = r;
                closed = true;
              }),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();

    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(find.text(en.portForwardNewTitle), findsOneWidget);
    final nickname = find.byType(TextFormField).first;
    await tester.enterText(nickname, 'Orders database');

    await tester.tap(find.byKey(const ValueKey('pf-help')));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsOneWidget, reason: 'one dialog: the help is in its place');
    expect(find.byType(BottomSheet), findsNothing, reason: 'no sheet over the dialog');
    expect(find.byKey(const ValueKey('pf-help-in-place')), findsOneWidget);
    expect(find.text(en.portForwardHelpWhatHeader), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('pf-help-back')));
    await tester.pumpAndSettle();
    expect(find.text(en.portForwardNewTitle), findsOneWidget);
    expect(find.text('Orders database'), findsOneWidget, reason: 'what was typed is kept');

    await tester.tap(find.text(en.cancel));
    await tester.pumpAndSettle();
    expect(closed, isTrue);
    expect(got, isNull);
  });
}
