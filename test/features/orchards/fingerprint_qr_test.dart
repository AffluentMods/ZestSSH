import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_qr.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';

/// Comparing keys by QR code (3.0 UI): the code holds only the
/// fingerprint, a scan that matches counts like "They match", and one that
/// does not says so and counts for nothing.
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));
  final theirs = Uint8List.fromList(List<int>.generate(32, (i) => i * 7 % 256));
  final mine = Uint8List.fromList(List<int>.generate(32, (i) => 255 - i));

  group('the code', () {
    test('holds the fingerprint and reads back', () {
      final payload = fingerprintQrPayload(theirs);
      expect(payload, startsWith('zestssh-fp:1:'));
      expect(fingerprintFromQr(payload), theirs);
      expect(fingerprintFromQr('  $payload\n'), theirs, reason: 'stray whitespace from a scanner');
    });

    test('anything else is not one of ours', () {
      expect(fingerprintFromQr('zestssh://share?d=abc'), isNull);
      expect(fingerprintFromQr('zestssh-fp:2:${fingerprintQrPayload(theirs).substring(13)}'), isNull);
      expect(fingerprintFromQr('zestssh-fp:1:short'), isNull);
      expect(fingerprintFromQr('zestssh-fp:1:${'A' * 44}'), isNull, reason: 'not 32 bytes');
      expect(fingerprintFromQr('zestssh-fp:1:${'+' * 43}'), isNull, reason: 'not base64url');
    });

    test('a match is byte for byte', () {
      expect(sameFingerprint(theirs, Uint8List.fromList(theirs)), isTrue);
      final other = Uint8List.fromList(theirs)..[31] ^= 1;
      expect(sameFingerprint(theirs, other), isFalse);
      expect(sameFingerprint(theirs, theirs.sublist(0, 31)), isFalse);
    });
  });

  group('comparing', () {
    Future<List<String>> pump(WidgetTester tester, Uint8List? scanned, {bool canScan = true}) async {
      final matches = <String>[];
      tester.view.physicalSize = const Size(900, 1400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: SingleChildScrollView(
            child: CompareCodes(
              theirs: theirs,
              mine: mine,
              name: 'maya@example.com',
              canScan: canScan,
              scan: (context, {required name}) async => scanned,
              onScanMatch: () => matches.add('match'),
            ),
          ),
        ),
      ));
      return matches;
    }

    testWidgets('my code shows on request', (tester) async {
      await pump(tester, null);
      expect(find.byKey(const ValueKey('fingerprint-qr')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('fingerprint-show-qr')));
      await tester.pump();
      expect(find.byKey(const ValueKey('fingerprint-qr')), findsOneWidget);
      expect(find.text(l10n.fpQrCaption('maya@example.com')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('fingerprint-show-qr')));
      await tester.pump();
      expect(find.byKey(const ValueKey('fingerprint-qr')), findsNothing);
    });

    testWidgets('a scan that matches counts', (tester) async {
      final matches = await pump(tester, Uint8List.fromList(theirs));
      await tester.tap(find.byKey(const ValueKey('fingerprint-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fingerprint-scan-match')), findsOneWidget);
      expect(matches, ['match']);
    });

    testWidgets('a scan that does not match says so and counts for nothing', (tester) async {
      final matches = await pump(tester, mine);
      await tester.tap(find.byKey(const ValueKey('fingerprint-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fingerprint-scan-mismatch')), findsOneWidget);
      expect(find.text(l10n.fpScanMismatch('maya@example.com')), findsOneWidget);
      expect(matches, isEmpty);
    });

    testWidgets('backing out of the scan changes nothing', (tester) async {
      final matches = await pump(tester, null);
      await tester.tap(find.byKey(const ValueKey('fingerprint-scan')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('fingerprint-scan-match')), findsNothing);
      expect(find.byKey(const ValueKey('fingerprint-scan-mismatch')), findsNothing);
      expect(matches, isEmpty);
    });

    testWidgets('no camera, no scan button', (tester) async {
      await pump(tester, null, canScan: false);
      expect(find.byKey(const ValueKey('fingerprint-scan')), findsNothing);
      expect(find.byKey(const ValueKey('fingerprint-show-qr')), findsOneWidget, reason: 'the code still shows');
    });
  });
}
