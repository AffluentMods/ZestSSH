import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/team/team_setup.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart' show recordLogSaverProvider;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/utils/redactor.dart';

import '../features/orchards/setup/setup_world.dart';
import 'shots_util.dart';

/// Pictures of the Team page's "Setup file" (3.0), with the real
/// fonts, on a real Orchard:
///
///   flutter test --dart-define=ZEST_SHOTS=true --dart-define=ZEST_ORCHARDS=true test/visual/setup_shots_test.dart
///
/// Pictures land in build/shots/. Everything on them is made up. Another
/// language with --dart-define=ZEST_SHOT_LOCALE=de, and the smallest phone
/// the screens are checked on with --dart-define=ZEST_SHOT_SMALL=true.
const _locale = String.fromEnvironment('ZEST_SHOT_LOCALE', defaultValue: 'en');
const _small = bool.fromEnvironment('ZEST_SHOT_SMALL');

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;
  SetupFilePicked? picked;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 60; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
      await tester.pump();
      if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
    }
    await tester.pump(const Duration(milliseconds: 400));
  }

  /// Platform team with Production and Staging, the role Members, a key and
  /// two people in it.
  Future<SetupDevice> start(WidgetTester tester) async => (await tester.runAsync(() async {
        await SetupWorld.makeKeys();
        world = SetupWorld();
        await world.start();
        owner = world.device(SetupWorld.owner);
        o = await world.orchard(owner, name: 'Platform team');
        await owner.addKey(o.id, 'deploy', crateId: o.production);
        await owner.addHost(o.id, 'web-01', crateId: o.production, address: '192.168.10.21');
        await owner.sync(o.id);
        final ada = world.device(SetupWorld.ada);
        await world.join(owner, ada, o.id, o.members);
        final lin = world.device(SetupWorld.lin);
        await world.join(owner, lin, o.id, o.members);
        return ada;
      }))!;

  void file(Map<String, Object?> body, {String name = 'platform-team.json'}) =>
      picked = (name: name, text: const JsonEncoder.withIndent('  ').convert({kSetupFileMarker: 1, ...body}));

  /// The page as [as] sees it, at [size] with [themeId].
  Future<GlobalKey> show(WidgetTester tester, SetupDevice as, String themeId, Size size, {bool phone = false}) async {
    AppColors.applyTheme(BuiltInThemes.getById(themeId).colorScheme);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final view = as.again();
    final key = GlobalKey();
    await tester.pumpWidget(RepaintBoundary(
      key: key,
      child: ProviderScope(
        key: UniqueKey(),
        overrides: [
          setupRunnerProvider.overrideWithValue(SetupRunner(snapshot: (id) => view.snapshot(id), actions: view.actions)),
          setupFilePickerProvider.overrideWithValue(({required String dialogTitle}) async => picked),
          recordLogSaverProvider.overrideWithValue(({
            required String fileName,
            required Uint8List bytes,
            required String dialogTitle,
          }) async =>
              '/home/demo/team/$fileName'),
          signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async => false),
          recordingModeProvider.overrideWith((ref) => false),
          recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
        ],
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: BuiltInThemes.getById(themeId).toThemeData(),
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale(_locale),
          home: Scaffold(
            backgroundColor: AppColors.v3Background,
            body: SingleChildScrollView(
              padding: EdgeInsets.all(phone ? 16 : 28),
              child: Align(
                alignment: Alignment.topLeft,
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 760),
                  child: TeamSetup(
                    orchard: OrchardSummary(
                      id: o.id,
                      name: 'Platform team',
                      role: as.uid == SetupWorld.owner ? FixedRoles.owner : o.members,
                      crates: const [],
                      defaultCrateId: null,
                    ),
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    return key;
  }

  Finder byKey(String k) => find.byKey(ValueKey(k));

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  /// A whole team's setup: a Crate more, a role more, hosts, and someone to
  /// invite.
  Map<String, Object?> wholeFile() => {
        'orchard': 'Platform team',
        'rules': {'reauth_days': 30},
        'crates': [
          {
            'name': 'Production',
            'allow': ['sftp'],
            'ask_again': true,
            'hosts': [
              {'name': 'web-01', 'address': '192.168.10.21', 'key': 'deploy', 'group': 'Web', 'tags': ['prod', 'web']},
              {'name': 'web-02', 'address': '192.168.10.22', 'port': 2222, 'group': 'Web'},
            ],
          },
          {'name': 'Shared', 'allow': <String>[]},
        ],
        'roles': [
          {
            'name': 'Developers',
            'can': ['invite'],
            'crates': {'Production': 'edit', 'Shared': 'manage'},
          },
          {
            'name': 'Members',
            'crates': {'Production': 'connect'},
          },
        ],
        'members': [
          {'email': SetupWorld.emailOf(SetupWorld.ada), 'role': 'Developers'},
          {'email': SetupWorld.emailOf(SetupWorld.sam), 'role': 'Members', 'until': kLater},
        ],
      };

  Future<void> everyPicture(WidgetTester tester, String themeId, Size size, String tag, {bool phone = false}) async {
    final l10n = lookupAppLocalizations(const Locale(_locale));
    final ada = await start(tester);
    addTearDown(() => world.stop());

    // As it opens.
    picked = null;
    var key = await show(tester, owner, themeId, size, phone: phone);
    await saveShot(tester, key, 'setup_${tag}_1_start');

    // Saved as a file.
    await tap(tester, byKey('setup-save-button'));
    await saveShot(tester, key, 'setup_${tag}_2_saved');
    // (On a computer it says where the file went, in a dialog.)
    Future<void> closeSaved() async {
      final close = find.text(l10n.close);
      if (close.evaluate().isEmpty) return;
      await tester.tap(close.last);
      await settle(tester);
    }

    await closeSaved();

    // A file that is no setup file.
    picked = (name: 'notes.json', text: '{"name": "notes", "crates": "many", "password": "x"}');
    await tap(tester, byKey('setup-choose'));
    await saveShot(tester, key, 'setup_${tag}_3_not_a_setup_file');

    // A file with something in its way.
    file({
      'crates': [
        {
          'name': 'Production',
          'hosts': [
            {'name': 'db-primary'},
            {'name': 'web-01', 'key': 'backup'},
          ],
        },
      ],
      'roles': [
        {
          'name': 'Developers',
          'crates': {'Archive': 'use'},
        },
      ],
    }, name: 'broken.json');
    await tap(tester, byKey('setup-choose'));
    await saveShot(tester, key, 'setup_${tag}_4_in_the_way');

    // A whole setup: what it would change.
    Future<String> applyLabel() async =>
        l10n.setupApplyButton((await tester.runAsync(() => owner.plan(o.id, wholeFile())))!.steps.length);
    file(wholeFile());
    await tap(tester, byKey('setup-choose'));
    await saveShot(tester, key, 'setup_${tag}_5_plan');
    final apply = byKey('setup-apply');
    expect(apply, findsOneWidget);
    await tester.ensureVisible(apply);
    await tester.pump();
    await saveShot(tester, key, 'setup_${tag}_6_plan_end');

    // Asked first.
    await tap(tester, apply);
    await saveShot(tester, key, 'setup_${tag}_7_confirm');

    // The server wants a sign-in from the last minutes for who may do what:
    // the person is asked to sign in again, backs out, and it says where it
    // stopped.
    await tester.runAsync(() async => world.server.requireRecentSignIn = true);
    await tester.tap(find.text(await applyLabel()).last);
    await settle(tester);
    await saveShot(tester, key, 'setup_${tag}_8_sign_in_again');
    await tester.tap(find.text(l10n.cancel).last);
    await settle(tester);
    await tester.ensureVisible(byKey('setup-stopped'));
    await tester.pump();
    await saveShot(tester, key, 'setup_${tag}_9_stopped');
    await tester.runAsync(() async => world.server.requireRecentSignIn = false);

    // Applied, from the page opened afresh.
    await tester.pumpWidget(const SizedBox());
    key = await show(tester, owner, themeId, size, phone: phone);
    await tap(tester, byKey('setup-choose'));
    await tap(tester, byKey('setup-apply'));
    await tester.tap(find.text(await applyLabel()).last);
    await settle(tester);
    await settle(tester);
    await saveShot(tester, key, 'setup_${tag}_10_done');

    // Someone who runs nothing here does not see the page in the app; what
    // saving leaves out is shown to an admin who cannot read every Crate.
    await tester.pumpWidget(const SizedBox());
    picked = null;
    key = await show(tester, ada, themeId, size, phone: phone);
    await tap(tester, byKey('setup-save-button'));
    await closeSaved();
    await saveShot(tester, key, 'setup_${tag}_11_saved_by_someone_else');

    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 5));
  }

  for (final themeId in ['graphite', 'default_light']) {
    final tag = themeId == 'graphite' ? 'dark' : 'light';
    testWidgets('on a computer ($tag)', (tester) async {
      realShadows();
      await tester.runAsync(loadShotFonts);
      // A computer: the theme sizes its controls for one (tests run as Android).
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      try {
        await everyPicture(tester, themeId, const Size(1100, 1200), tag);
      } finally {
        debugDefaultTargetPlatformOverride = null;
        plainShadows();
      }
    }, skip: !shotsEnabled);
  }

  testWidgets('on a phone (dark)', (tester) async {
    realShadows();
    await tester.runAsync(loadShotFonts);
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    try {
      await everyPicture(tester, 'graphite', _small ? const Size(360, 640) : const Size(390, 844), 'phone', phone: true);
    } finally {
      debugDefaultTargetPlatformOverride = null;
      plainShadows();
    }
  }, skip: !shotsEnabled);
}
