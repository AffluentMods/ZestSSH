import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/screens/error/mac_keychain_update_screen.dart';

/// On a Mac, after an update, macOS asks for the login password for each of
/// ZestSSH's saved keys (the app is signed ad-hoc: each build is a new app to it).
/// Nothing said so, and a person who chose Allow, not Always Allow, was asked again
/// and again. Now a short notice says it before
/// anything reads the keychain, once for each build (3.3.2).
void main() {
  final l10n = lookupAppLocalizations(const Locale('en'));

  Future<SharedPreferences> prefs([Map<String, Object> values = const {}]) async {
    SharedPreferences.setMockInitialValues(values);
    return SharedPreferences.getInstance();
  }

  Future<List<String>> some() async => ['profiles_v1', 'p.a.zestssh_db_encryption_key'];
  Future<List<String>> none() async => const [];

  group('whether it is said', () {
    test('after an update, where the keychain holds something of ZestSSH\'s', () async {
      expect(await keychainAsksAfterUpdate(prefs: await prefs(), build: '302', names: some), isTrue,
          reason: 'the first start of the version that has it: from 3.3.1, nothing was noted');
      expect(
          await keychainAsksAfterUpdate(prefs: await prefs({kKeychainToldBuildKey: '301'}), build: '302', names: some),
          isTrue);
    });

    test('not again for the same build', () async {
      expect(
          await keychainAsksAfterUpdate(prefs: await prefs({kKeychainToldBuildKey: '302'}), build: '302', names: some),
          isFalse);
    });

    test('not at a first install, which has nothing to be asked about: its build is noted', () async {
      final store = await prefs();
      expect(await keychainAsksAfterUpdate(prefs: store, build: '302', names: none), isFalse);
      expect(store.getString(kKeychainToldBuildKey), '302');
    });

    test('where the names cannot be listed, it is said, as the questions may come', () async {
      expect(
          await keychainAsksAfterUpdate(
              prefs: await prefs(), build: '302', names: () async => throw StateError('the list failed')),
          isTrue);
    });
  });

  testWidgets('it waits for Continue, then the start goes on and the build is noted; once', (tester) async {
    final store = await prefs({kKeychainToldBuildKey: '301'});
    final shown = <Widget>[];
    var done = false;
    final saying = sayKeychainAsksAfterUpdate(prefs: store, build: '302', names: some, show: shown.add)
        .then((_) => done = true);
    await tester.pump();
    expect(shown, hasLength(1));
    tester.view.physicalSize = const Size(1200, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(shown.single);
    await tester.pump();
    expect(find.text(l10n.macKeychainUpdateTitle), findsOneWidget);
    expect(find.text(l10n.macKeychainUpdateBody), findsOneWidget);
    expect(l10n.macKeychainUpdateBody,
        "macOS will ask for your login password for ZestSSH's saved keys after this update. Choose Always Allow for each.");
    expect(done, isFalse, reason: 'nothing reads the keychain before the person has read it');
    expect(store.getString(kKeychainToldBuildKey), '301');

    await tester.tap(find.byKey(const ValueKey('mac-keychain-update-continue')));
    await tester.pump();
    await saying;
    expect(done, isTrue);
    expect(store.getString(kKeychainToldBuildKey), '302');

    await sayKeychainAsksAfterUpdate(prefs: store, build: '302', names: some, show: shown.add);
    expect(shown, hasLength(1), reason: 'one notice for each update');
    await tester.pumpWidget(const SizedBox());
  });

  test('main.dart says it on a Mac before anything reads the keychain: before Firebase, before the profiles', () {
    final main = File('lib/main.dart').readAsStringSync();
    final said = main.indexOf('await sayKeychainAsksAfterUpdate(');
    expect(said, greaterThan(0));
    expect(main.lastIndexOf('if (Platform.isMacOS && _adminArgs == null) {', said), greaterThan(0));
    expect(said, lessThan(main.indexOf('await Firebase.initializeApp();')));
    expect(said, lessThan(main.indexOf('await bootProfiles(')));
    expect(main.indexOf('installKeychainStore();'), lessThan(said), reason: 'the names are listed by the Mac store');
  });
}
