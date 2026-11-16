// Remote screens (4.0): a session's details. The card and the
// sheet draw what the session hands them as it changes, leave out what is not
// known (no round trip yet, no encoding yet), say the numbers to a screen
// reader, never take the keyboard on a computer, and turn the details off
// however they are closed.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/screens/details/screen_session_details.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/platform_utils.dart' show debugTouchLayout;

import '../a11y/a11y_checks.dart';

ScreenSessionDetails _running({int? roundTrip, String drawnWith = 'H.264 (AVC420)'}) => ScreenSessionDetails(
      last: [
        for (var i = 0; i < 12; i++)
          ScreenSessionSample(
            at: Duration(seconds: i + 1),
            bytesIn: 200000 + i * 50000,
            bytesOut: 4000 + i * 100,
            frames: 30,
          ),
      ],
      drawnWith: drawnWith,
      roundTripMs: roundTrip,
      width: 4480,
      height: 1440,
      protocol: 'RDP',
    );

void main() {
  late ValueNotifier<ScreenSessionDetails> details;

  setUp(() => details = ValueNotifier(ScreenSessionDetails.none));

  Future<void> pump(WidgetTester tester, Widget child, {Size size = const Size(1280, 800)}) async {
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(backgroundColor: ZestColors.surfacePanel, body: child),
    ));
  }

  testWidgets("a computer's card: counting first, then the minute's numbers; the round trip only once measured",
      (tester) async {
    var closed = 0;
    await pump(
      tester,
      Align(
        alignment: AlignmentDirectional.topEnd,
        child: ScreenSessionDetailsCard(details: details, onClose: () => closed++),
      ),
    );
    expect(find.text('Session details'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-details-counting')), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-details-protocol')), findsNothing, reason: 'nothing known yet');

    details.value = _running();
    await tester.pump();
    expect(find.byKey(const ValueKey('screen-details-counting')), findsNothing);
    expect(find.text('732.4 KB/s'), findsOneWidget, reason: "the last second's in: 750,000 bytes, in powers of 1024");
    expect(find.text('30'), findsOneWidget);
    expect(find.text('4480 × 1440'), findsOneWidget);
    expect(find.text('RDP'), findsOneWidget);
    expect(find.text('H.264 (AVC420)'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-details-roundTrip')), findsNothing, reason: 'not measured yet');

    details.value = _running(roundTrip: 24, drawnWith: '');
    await tester.pump();
    expect(find.text('24 ms'), findsOneWidget);
    expect(find.byKey(const ValueKey('screen-details-drawnWith')), findsNothing, reason: 'not known: no row, no dash');

    await tester.tap(find.byKey(const ValueKey('screen-details-close')));
    expect(closed, 1);
  });

  testWidgets('the card never takes the keyboard from the picture', (tester) async {
    final picture = FocusNode();
    addTearDown(picture.dispose);
    details.value = _running();
    await pump(
      tester,
      Stack(children: [
        Focus(focusNode: picture, autofocus: true, child: const SizedBox.expand()),
        Align(
          alignment: AlignmentDirectional.topEnd,
          child: ScreenSessionDetailsCard(details: details, onClose: () {}),
        ),
      ]),
    );
    await tester.pump();
    expect(picture.hasFocus, isTrue);
    await tester.tap(find.byKey(const ValueKey('screen-details-close')));
    await tester.pump();
    expect(picture.hasFocus, isTrue);
  });

  testWidgets("a phone's sheet: the same numbers; closed by its button or by the scrim, it turns them off",
      (tester) async {
    debugTouchLayout = true;
    addTearDown(() => debugTouchLayout = null);
    details.value = _running(roundTrip: 31);
    var off = 0;
    await pump(
      tester,
      Builder(
        builder: (context) => Center(
          child: TextButton(
            key: const ValueKey('open'),
            onPressed: () => showScreenSessionDetailsSheet(context, details: details, onClosed: () => off++),
            child: const Text('open'),
          ),
        ),
      ),
      size: const Size(390, 800),
    );
    await tester.tap(find.byKey(const ValueKey('open')));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-details-sheet')), findsOneWidget);
    expect(find.text('31 ms'), findsOneWidget);
    // It follows the session while open.
    details.value = _running(roundTrip: 45);
    await tester.pump();
    expect(find.text('45 ms'), findsOneWidget);
    await tester.tap(find.text('Close'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('screen-details-sheet')), findsNothing);
    expect(off, 1);
  });

  testWidgets('the accessibility pass: named, read, contrast, on a computer and on a narrow phone', (tester) async {
    final handle = tester.ensureSemantics();
    details.value = _running(roundTrip: 24);
    await pump(
      tester,
      Align(
        alignment: AlignmentDirectional.topEnd,
        child: ScreenSessionDetailsCard(details: details, onClose: () {}),
      ),
    );
    expect(await a11yCheck(tester, computer: true, where: 'the card'), isEmpty);
    expect(find.bySemanticsLabel(RegExp(r'Received[\s\S]*732\.4 KB/s')), findsOneWidget, reason: 'the rate is read with its name');
    handle.dispose();
  });

  testWidgets('German at the largest text in the card: nothing overflows', (tester) async {
    tester.platformDispatcher.textScaleFactorTestValue = 2.0;
    addTearDown(tester.platformDispatcher.clearTextScaleFactorTestValue);
    details.value = _running(roundTrip: 24, drawnWith: 'RemoteFX Progressive');
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      locale: const Locale('de'),
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(
        body: Align(
          alignment: AlignmentDirectional.topEnd,
          child: ScreenSessionDetailsCard(details: details, onClose: () {}),
        ),
      ),
    ));
    expect(tester.takeException(), isNull);
  });
}
