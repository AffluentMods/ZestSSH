import 'dart:convert' show utf8;
import 'dart:io' show gzip;

import 'package:flutter/foundation.dart';
// The app is on package:flutter/material.dart until its material_ui move (deferred with Flutter 3.50).
// ignore: deprecated_member_use
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/platform_licences.dart';
import 'package:zestssh/ui/screens/settings/licenses_screen.dart';

/// The licences page (Settings, About, Open source licenses) as a build has it: Flutter's
/// registry with the NOTICES the build bundled (every package's licence, the Rust crates', and the
/// files under the pubspec's `flutter: licenses:`), and the running platform's native libraries
/// (lib/services/platform_licences.dart).
void main() {
  // A test binding registers no licences (flutter_test's initLicenses): the app's NOTICES, which
  // `flutter test` bundles as the build does, is added here as ServicesBinding adds it in the app.
  setUp(() {
    LicenseRegistry.reset();
    LicenseRegistry.addLicense(() async* {
      final bytes = await rootBundle.load('NOTICES.Z');
      final text = utf8.decode(gzip.decode(bytes.buffer.asUint8List()));
      yield* Stream.fromIterable(parsePlatformLicences(text));
    });
    resetPlatformLicencesForTest();
  });

  /// Every entry of the registry, by name, read off the test's fake clock.
  Future<Map<String, List<String>>> registry(WidgetTester tester) async {
    final out = <String, List<String>>{};
    await tester.runAsync(() async {
      await for (final entry in LicenseRegistry.licenses) {
        final text = entry.paragraphs.map((p) => p.text).join('\n');
        for (final p in entry.packages) {
          out.putIfAbsent(p, () => []).add(text);
        }
      }
    });
    return out;
  }

  testWidgets('every bundled font family, the copied code\'s notices, the credits and the Rust notices are listed', (
    tester,
  ) async {
    final all = await registry(tester);
    for (final family in [
      'Geist',
      'JetBrains Mono',
      'Fira Code',
      'Source Code Pro',
      'Cascadia Code',
      'Hack',
      'Symbols Nerd Font',
    ]) {
      expect(all[family], isNotNull, reason: '$family has no licence on the page');
    }
    expect(all['Geist']!.join(), contains('SIL OPEN FONT LICENSE Version 1.1'));
    expect(all['Hack']!.join(), contains('BITSTREAM VERA LICENSE'));
    // zest_ssh_core: its own MIT licence, and the notices its bcrypt keeps.
    final core = all['zest_ssh_core']!.join('\n');
    expect(core, contains('Permission is hereby granted'));
    expect(core, contains('Niels Provos'));
    expect(core, contains('Ted Unangst'));
    expect(core, contains('Joyent'));
    // The VNC engine's DES keeps Antoni Boucher's MIT notice.
    expect(all['vnc-rs']!.join('\n'), contains('Boucher, Antoni'));
    // The app's own licence: the additional permission, and the GNU GPL version 3 itself.
    final own = all['ZestSSH']!.join('\n');
    expect(own, contains('Additional permission under GNU GPL version 3 section 7'));
    expect(own, contains('GNU GENERAL PUBLIC LICENSE'));
    expect(own, contains('TERMS AND CONDITIONS'));
    expect(
      all['ZestSSH credits and trademarks']!.single,
      contains('trademarks or registered trademarks of their owners'),
    );
  });

  testWidgets('a computer lists its native libraries; a platform with no file adds nothing', (tester) async {
    final before = await registry(tester);
    expect(before['PDFium'], isNull, reason: 'nothing registered yet');

    resetPlatformLicencesForTest();
    registerPlatformLicences(platform: TargetPlatform.windows);
    registerPlatformLicences(platform: TargetPlatform.windows); // once only
    final windows = await registry(tester);
    expect(windows['PDFium'], isNotNull);
    expect(windows['Firebase C++ SDK'], isNotNull);
    expect(windows['Windows Implementation Libraries (WIL)'], isNotNull);
    expect(
      windows['PDFium']!.where((t) => t.contains('Copyright 2014 PDFium Authors')),
      hasLength(1),
      reason: 'registered once',
    );

    // A platform whose file is not in the build (no pods file yet) gives no entry and no error.
    final missing = _Missing();
    resetPlatformLicencesForTest();
    registerPlatformLicences(platform: TargetPlatform.iOS, bundle: missing);
    final ios = await registry(tester);
    expect(ios.length, windows.length);
    expect(missing.asked, ['assets/licenses/ios.txt']);
  });

  test('a platform file reads as Flutter reads a NOTICES file', () {
    final entries = parsePlatformLicences(
      'A\nB\n\nthe text\nof A and B\n${'-' * 80}\nC\n\nC\'s\r\n${'-' * 80}\nno text',
    );
    expect(entries.map((e) => e.packages.toList()), [
      ['A', 'B'],
      ['C'],
    ]);
    expect(entries.first.paragraphs.map((p) => p.text).join('\n'), contains('of A and B'));
    expect(platformLicencesAsset(TargetPlatform.linux), 'assets/licenses/linux.txt');
    expect(platformLicencesAsset(TargetPlatform.fuchsia), isNull);
  });

  testWidgets('the page shows the fonts\' licences: found by the search, opened by a tap', (tester) async {
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: LicensesScreen(version: '4.0.0'),
      ),
    );
    for (var i = 0; i < 100 && find.byType(CircularProgressIndicator).evaluate().isNotEmpty; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
    }
    expect(find.byType(CircularProgressIndicator), findsNothing, reason: 'the licences loaded');
    for (final family in ['Cascadia Code', 'Hack', 'JetBrains Mono']) {
      await tester.enterText(find.byType(TextField), family);
      await tester.pump();
      expect(
        find.descendant(of: find.byType(ListView), matching: find.text(family)),
        findsOneWidget,
        reason: family,
      );
    }
    await tester.tap(find.descendant(of: find.byType(ListView), matching: find.text('JetBrains Mono')));
    await tester.pump();
    expect(find.textContaining('JetBrains Mono Project Authors', findRichText: true), findsWidgets);
  });
}

/// A bundle that has no file at all, and says what was asked of it.
class _Missing extends CachingAssetBundle {
  final asked = <String>[];

  @override
  Future<ByteData> load(String key) async {
    asked.add(key);
    throw FlutterError('Unable to load asset: "$key".');
  }

  @override
  Future<String> loadString(String key, {bool cache = true}) async {
    asked.add(key);
    throw FlutterError('Unable to load asset: "$key".');
  }
}
