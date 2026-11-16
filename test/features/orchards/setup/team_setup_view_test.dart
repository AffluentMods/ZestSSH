import 'dart:async';
import 'dart:convert';

import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/intl.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/setup/setup_apply.dart';
import 'package:zestssh/features/orchards/setup/setup_export.dart';
import 'package:zestssh/features/orchards/setup/setup_file.dart';
import 'package:zestssh/features/orchards/setup/setup_plan.dart';
import 'package:zestssh/features/orchards/setup/setup_runner.dart';
import 'package:zestssh/features/orchards/setup/setup_words.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show kNewRecordKindsVersion, newRecordKindsOn;
import 'package:zestssh/features/orchards/team/team_setup.dart';
import 'package:zestssh/features/orchards/team/team_trust.dart' show recordLogSaverProvider;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../visual/shots_util.dart';
import 'setup_world.dart';
import 'package:zestssh/l10n/time_text.dart';

// The Team page's "Setup file" on screen (3.0), on a real Orchard:
// saving it as a file, checking a file (what is wrong with it, what it
// would change, what stands in the way, what it leaves alone), and applying
// it: asked first, step by step, signing in again where the server wants
// it, and saying where it stopped when it does.

const _savedAt = '/home/demo/team/zestssh-setup-northwind-ops.json';

Future<void> settle(WidgetTester tester) async {
  for (var i = 0; i < 60; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 60)));
    await tester.pump();
    if (i >= 1 && find.byType(CircularProgressIndicator).evaluate().isEmpty) break;
  }
  await tester.pump(const Duration(milliseconds: 400));
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));

  late SetupWorld world;
  late SetupDevice owner;
  late ({String id, String production, String staging, String members}) o;

  /// What the person picks, what was saved, and how signing in again goes.
  SetupFilePicked? picked;
  Object? pickFails;
  final saved = <({String name, String text})>[];
  String? savePath;
  Future<bool> Function()? signInAgain;
  var signInsAsked = 0;

  String email(String uid) => SetupWorld.emailOf(uid);

  setUpAll(SetupWorld.makeKeys);

  setUp(() {
    picked = null;
    pickFails = null;
    saved.clear();
    savePath = _savedAt;
    signInAgain = null;
    signInsAsked = 0;
  });

  tearDown(() {
    Redactor.instance.enabled = false;
  });

  /// The Orchard Northwind Ops, on the owner's device.
  Future<void> start(WidgetTester tester) async {
    await tester.runAsync(() async {
      world = SetupWorld();
      await world.start();
      owner = world.device(SetupWorld.owner);
      o = await world.orchard(owner);
    });
    addTearDown(() => world.stop());
  }

  Future<SetupDevice> joined(WidgetTester tester, String uid, String role) async => (await tester.runAsync(() async {
        final d = world.device(uid);
        await world.join(owner, d, o.id, role);
        return d;
      }))!;

  void file(Map<String, Object?> body, {String name = 'team.json'}) =>
      picked = (name: name, text: const JsonEncoder.withIndent('  ').convert({kSetupFileMarker: 1, ...body}));

  /// The page on [as]'s device.
  Future<ProviderContainer> pump(
    WidgetTester tester,
    SetupDevice as, {
    bool small = false,
    bool recording = false,
    Locale locale = const Locale('en'),
    ThemeData? theme,
    Future<void> Function()? sync,
    bool? onComputer,
  }) async {
    tester.view.physicalSize = small ? const Size(360, 640) : const Size(1100, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    // The page has a service of its own: see [SetupDevice.again].
    final view = as.again();
    await tester.pumpWidget(ProviderScope(
      key: UniqueKey(),
      overrides: [
        setupRunnerProvider.overrideWithValue(SetupRunner(
          snapshot: (id) => view.snapshot(id),
          actions: (id) => sync == null ? view.actions(id) : OrchardSetupActions(view.service, id, sync: sync),
        )),
        setupFilePickerProvider.overrideWithValue(({required String dialogTitle}) async {
          final fails = pickFails;
          if (fails != null) throw fails;
          return picked;
        }),
        recordLogSaverProvider.overrideWithValue(({
          required String fileName,
          required Uint8List bytes,
          required String dialogTitle,
        }) async {
          saved.add((name: fileName, text: utf8.decode(bytes)));
          return savePath;
        }),
        signInRefresherProvider.overrideWithValue((context, ref, {wrongAccount}) async {
          signInsAsked++;
          return await signInAgain?.call() ?? false;
        }),
        recordingModeProvider.overrideWith((ref) => recording),
        recordingRedactLevelProvider.overrideWith((ref) => RedactLevel.layout),
      ],
      child: MaterialApp(
        theme: theme,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: locale,
        home: Scaffold(
          body: SingleChildScrollView(
            padding: const EdgeInsets.all(16),
            child: TeamSetup(
              onComputer: onComputer,
              orchard: OrchardSummary(
                id: o.id,
                name: 'Northwind Ops',
                role: as.uid == SetupWorld.owner ? FixedRoles.owner : FixedRoles.admin,
                crates: const [],
                defaultCrateId: null,
              ),
            ),
          ),
        ),
      ),
    ));
    await settle(tester);
    return ProviderScope.containerOf(tester.element(find.byType(TeamSetup)));
  }

  Finder key(String k) => find.byKey(ValueKey(k));

  /// Whether the person was told [message] in a notice at the top.
  bool toasted(WidgetTester tester, String message) =>
      find.text(message).evaluate().isNotEmpty ||
      ProviderScope.containerOf(tester.element(find.byType(TeamSetup)))
          .read(notificationCenterProvider)
          .history
          .any((n) => n.title == message || n.body == message);
  Finder inKey(String k, Finder f) => find.descendant(of: key(k), matching: f);

  /// Every line of text under [k], top to bottom.
  List<String> linesOf(WidgetTester tester, String k) => [
        for (final w in tester.widgetList(inKey(k, find.byWidgetPredicate((w) => w is Text || w is SelectableText))))
          if (w is Text) w.data ?? '' else if (w is SelectableText) w.data ?? '',
      ];

  Future<void> tap(WidgetTester tester, Finder f) async {
    await tester.ensureVisible(f);
    await tester.pump();
    await tester.tap(f);
    await settle(tester);
  }

  Future<void> choose(WidgetTester tester) => tap(tester, key('setup-choose'));

  /// The plan the page shows, as it would be made from [as]'s device now.
  Future<SetupPlan> planOf(WidgetTester tester, SetupDevice as) async =>
      (await tester.runAsync(() async => planSetup(readSetupFile(picked!.text!).file!, await as.snapshot(o.id))))!;

  testWidgets('says what it is for, and offers the same from a terminal on a computer', (tester) async {
    await start(tester);
    await pump(tester, owner);
    expect(inKey('setup-save', find.text(l10n.setupSaveTitle)), findsOneWidget);
    expect(inKey('setup-save', find.text(l10n.setupSaveBody)), findsOneWidget);
    expect(inKey('setup-check', find.text(l10n.setupCheckTitle)), findsOneWidget);
    expect(inKey('setup-check', find.text(l10n.setupCheckBody)), findsOneWidget);
    expect(inKey('setup-terminal', find.text(l10n.setupTerminalTitle)), findsOneWidget);
    expect(inKey('setup-terminal', find.text(l10n.setupTerminalBody)), findsOneWidget);
    expect(inKey('setup-terminal', find.textContaining('zestssh admin plan team.json')), findsOneWidget);
    // Nothing chosen yet: nothing to check again, apply or copy.
    for (final k in ['setup-check-again', 'setup-file-name', 'setup-steps', 'setup-apply', 'setup-left-out']) {
      expect(key(k), findsNothing, reason: k);
    }
  });

  testWidgets('saving writes the Orchard as a file under its name, and says where it went', (tester) async {
    await start(tester);
    await pump(tester, owner);
    await tap(tester, key('setup-save-button'));
    final export = (await tester.runAsync(() async => exportSetup(await owner.snapshot(o.id))))!;
    expect(saved.single.name, 'zestssh-setup-northwind-ops.json');
    expect(saved.single.text, export.text);
    expect(readSetupFile(saved.single.text).ok, isTrue);
    // Where it went, with the path to copy: the file's name first, its
    // folder under it (the dialog rules of 3.4), and Done.
    expect(find.text(l10n.setupSavedTitle), findsOneWidget);
    expect(find.text(l10n.setupSavedBody), findsOneWidget);
    expect(find.text('zestssh-setup-northwind-ops.json'), findsOneWidget);
    expect(find.text('/home/demo/team'), findsOneWidget);
    await tap(tester, find.text(l10n.done));
    expect(find.text(l10n.setupSavedTitle), findsNothing);
    // All of it was written: nothing to say about what was left out.
    expect(key('setup-left-out'), findsNothing);

    // Backing out of the save dialog says nothing.
    savePath = null;
    await tap(tester, key('setup-save-button'));
    expect(saved, hasLength(2));
    expect(find.text(l10n.setupSavedTitle), findsNothing);
  });

  testWidgets('what a saved file leaves out is listed under the button', (tester) async {
    await start(tester);
    await tester.runAsync(() => owner.service.createCrate(o.id, 'Vault', ownersOnly: true));
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await pump(tester, ada);
    await tap(tester, key('setup-save-button'));
    await tap(tester, find.text(l10n.done));
    expect(linesOf(tester, 'setup-left-out'), [l10n.setupLeftOutTitle, l10n.setupLeftOutClosedCrates(1)]);
    expect(saved.single.text, isNot(contains('Vault')));
  });

  test('the name a file is saved under is one any system takes', () {
    expect(setupFileNameFor('Northwind Ops'), 'zestssh-setup-northwind-ops.json');
    expect(setupFileNameFor('  R&D / Platform (EU)  '), 'zestssh-setup-r-d-platform-eu.json');
    expect(setupFileNameFor('---'), 'zestssh-setup-orchard.json');
    expect(setupFileNameFor(''), 'zestssh-setup-orchard.json');
    expect(setupFileNameFor('2nd Team'), 'zestssh-setup-2nd-team.json');
  });

  testWidgets('a file that is not a setup file says everything wrong with it, with the place, to copy',
      (tester) async {
    await start(tester);
    await pump(tester, owner);
    file({
      'crates': [
        {'name': 'Production', 'password': 'x', 'hosts': 7},
      ],
      'extra': true,
    }, name: 'broken.json');
    await choose(tester);
    // The file's name in its chip.
    expect(tester.widget<Text>(key('setup-file-name')).data, 'broken.json');
    expect(linesOf(tester, 'setup-file-problems').take(4), [
      l10n.setupFileProblemsTitle,
      l10n.setupFileUnknownField('extra'),
      l10n.setupFileSecretField('crates[0].password'),
      l10n.setupFileWrongList('crates[0].hosts'),
    ]);
    final copy = tester.widget<CopyDetailsButton>(inKey('setup-file-problems', find.byType(CopyDetailsButton)));
    expect(copy.detail.split('\n'), [
      l10n.setupFileUnknownField('extra'),
      l10n.setupFileSecretField('crates[0].password'),
      l10n.setupFileWrongList('crates[0].hosts'),
    ]);
    expect(copy.label, l10n.desktopShellCopyDetails);
    for (final k in ['setup-steps', 'setup-apply', 'setup-problems', 'setup-notes', 'setup-nothing']) {
      expect(key(k), findsNothing, reason: k);
    }
    // Text that is not JSON at all.
    picked = (name: 'notes.txt', text: 'not a file\nat all');
    await choose(tester);
    expect(linesOf(tester, 'setup-file-problems'), contains(l10n.setupFileNotJsonAt(1, 1)));
    // One too large to be read: said, and there is nothing to check again.
    picked = (name: 'huge.json', text: null);
    await choose(tester);
    expect(linesOf(tester, 'setup-file-problems'), [l10n.setupFileProblemsTitle, l10n.setupFileTooBig]);
    expect(key('setup-check-again'), findsNothing);
    // A good file after it is read as one.
    file({'crates': <Object?>[]});
    await choose(tester);
    expect(key('setup-file-problems'), findsNothing);
    expect(key('setup-nothing'), findsOneWidget);
  });

  testWidgets('choosing no file changes nothing; a file that cannot be opened says so', (tester) async {
    await start(tester);
    await pump(tester, owner);
    await choose(tester);
    expect(key('setup-file-name'), findsNothing);
    expect(toasted(tester, l10n.setupPickFailed), isFalse);
    pickFails = const FormatException('unreadable');
    await choose(tester);
    expect(toasted(tester, l10n.setupPickFailed), isTrue);
    expect(key('setup-file-name'), findsNothing);
  });

  testWidgets('a file is checked: every change in words, what is left alone, and what applying will ask',
      (tester) async {
    await start(tester);
    await joined(tester, SetupWorld.ada, o.members);
    await tester.runAsync(() => owner.addKey(o.id, 'deploy', crateId: o.production));
    await pump(tester, owner);
    file({
      'orchard': 'Northwind Ops',
      'crates': [
        {
          'name': 'Production',
          'allow': ['sftp'],
          'session_logs': true,
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11', 'key': 'deploy', 'group': 'Web', 'tags': ['prod']},
          ],
        },
        {'name': 'Lab'},
      ],
      'roles': [
        {
          'name': 'Operators',
          'can': ['invite'],
          'crates': {'Lab': 'manage'},
        },
      ],
      'members': [
        {'email': email(SetupWorld.ada), 'role': 'Operators', 'until': kLater},
        {'email': email(SetupWorld.lin), 'role': 'Members'},
      ],
    });
    await choose(tester);
    final plan = await planOf(tester, owner);
    expect(plan.problems, isEmpty);
    expect(plan.steps, hasLength(7));
    expect(key('setup-problems'), findsNothing);
    expect(key('setup-nothing'), findsNothing);
    expect(linesOf(tester, 'setup-steps'), [
      l10n.setupPlanChanges(7),
      // As a screen shows them: times in words on this device's clock.
      for (final s in plan.steps) ...[
        setupStepWords(s, l10n, show: const SetupShow.onScreen()).title,
        ...setupStepWords(s, l10n, show: const SetupShow.onScreen()).details,
      ],
    ]);
    // In words, not in the file's own.
    expect(linesOf(tester, 'setup-step-0'), [
      'Vault Production',
      'Allowed here: SFTP',
      'Session logs: on',
    ]);
    expect(linesOf(tester, 'setup-notes'), [
      l10n.setupPlanNotesTitle,
      for (final n in plan.notes) setupNoteWords(n, l10n),
    ]);
    expect(linesOf(tester, 'setup-notes'), contains(l10n.setupNoteCrate('Staging')));
    expect(tester.widget<Text>(key('setup-needs-sign-in')).data, l10n.setupNeedsSignIn);
    expect(inKey('setup-apply', find.text(l10n.setupApplyButton(7))), findsOneWidget);
    // Copied, the time is the file's own (for a log or support), where the
    // screen says it in words on this device's clock.
    final copied = tester.widget<CopyDetailsButton>(key('setup-copy-plan')).detail;
    expect(copied, setupPlanText(plan, l10n, show: const SetupShow.copied()));
    final iso = setupTime(secondsOf(kLater));
    final local =
        DateFormat.yMMMd('en_US').add_jm().formatPlain(DateTime.fromMillisecondsSinceEpoch(secondsOf(kLater) * 1000));
    expect(linesOf(tester, 'setup-steps').join('\n'), contains(local));
    expect(copied, contains(iso));
    expect(copied, isNot(contains(local)));
    // Nothing was changed by looking.
    expect(world.server.recordOf(o.id).crates, hasLength(2));
    expect(world.server.sentInvites, hasLength(1), reason: 'only the one Ada joined by');
  });

  testWidgets('a file that says what the Orchard is already has nothing to apply', (tester) async {
    await start(tester);
    await pump(tester, owner);
    final export = (await tester.runAsync(() async => exportSetup(await owner.snapshot(o.id))))!;
    picked = (name: 'same.json', text: export.text);
    await choose(tester);
    expect(tester.widget<Text>(inKey('setup-nothing', find.byType(Text))).data, l10n.setupPlanNothing);
    for (final k in ['setup-steps', 'setup-apply', 'setup-copy-plan', 'setup-needs-sign-in', 'setup-problems']) {
      expect(key(k), findsNothing, reason: k);
    }
    // A file that only adds a Crate changes nobody's rights: no word about signing in again.
    file({
      'crates': [
        {'name': 'Lab'},
      ],
    });
    await choose(tester);
    expect(key('setup-apply'), findsOneWidget);
    expect(key('setup-needs-sign-in'), findsNothing);
  });

  testWidgets('with something in its way, the file says what, and cannot be applied', (tester) async {
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await pump(tester, ada);
    file({
      'crates': [
        {'name': 'Lab'},
        {'name': 'Production', 'session_logs': true},
      ],
      'members': [
        {'email': email(SetupWorld.ada), 'role': 'owner'},
      ],
    });
    await choose(tester);
    final plan = await planOf(tester, ada);
    expect(plan.problems, hasLength(2));
    expect(linesOf(tester, 'setup-problems'), [
      l10n.vaultUiSetupInTheWay(2),
      l10n.setupPlanInTheWayBody,
      l10n.setupPair(l10n.setupStepCrate('Production'), l10n.setupRefusedLogsOwners),
      l10n.setupProblemOwnMembership(email(SetupWorld.ada)),
    ]);
    // What it could do is still shown, and copied with the rest.
    expect(linesOf(tester, 'setup-steps'), [l10n.setupPlanChanges(1), l10n.setupStepAddCrate('Lab')]);
    expect(key('setup-apply'), findsNothing);
    expect(key('setup-needs-sign-in'), findsNothing);
    expect(tester.widget<CopyDetailsButton>(key('setup-copy-plan')).detail,
        setupPlanText(plan, l10n, show: const SetupShow.copied()));
    // Only something in the way, and nothing it could do: no list of changes at all.
    file({
      'crates': [
        {'name': 'Production', 'session_logs': true},
      ],
    });
    await choose(tester);
    expect(key('setup-problems'), findsOneWidget);
    expect(key('setup-steps'), findsNothing);
    expect(key('setup-nothing'), findsNothing);
    expect(key('setup-copy-plan'), findsNothing);
  });

  testWidgets('applying asks first, makes every change, says so, and the Orchard is then what the file says',
      (tester) async {
    await start(tester);
    final container = await pump(tester, owner);
    file({
      'crates': [
        {'name': 'Lab', 'ask_again': true},
        {
          'name': 'Production',
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11'},
          ],
        },
      ],
      'roles': [
        {
          'name': 'Operators',
          'crates': {'Lab': 'use'},
        },
      ],
    });
    await choose(tester);
    final version = container.read(orchardListVersionProvider);

    // Asked first; backing out changes nothing.
    await tap(tester, key('setup-apply'));
    expect(find.text(l10n.setupApplyConfirmTitle), findsOneWidget);
    expect(find.text(l10n.setupApplyConfirmBody('Northwind Ops')), findsOneWidget);
    await tap(tester, find.text(l10n.cancel));
    expect(world.server.recordOf(o.id).crates, hasLength(2));
    expect(key('setup-done'), findsNothing);

    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(4)).last);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text))).data, l10n.setupDone(4));
    expect(key('setup-sync-later'), findsNothing);
    expect(signInsAsked, 0);
    // The file checked again by itself: nothing is left of it, and the one
    // success is all that is said (no second line that it is as the file
    // says).
    expect(key('setup-steps'), findsNothing);
    expect(key('setup-nothing'), findsNothing);
    expect(key('setup-apply'), findsNothing);
    expect(container.read(orchardListVersionProvider), greaterThan(version), reason: 'the other pages read again');
    final record = (await tester.runAsync(() => world.record(owner, o.id)))!;
    expect(record, containsAll(['crate Lab: allow=forward+sftp ask-again', 'role Operators (500): can= Lab="use"']));
    expect(await tester.runAsync(() => owner.hosts(o.id)),
        ['Production/web-1 10.50.0.11:22 ssh key=null group=null tags=']);
    // Checking again takes the note away.
    await tap(tester, key('setup-check-again'));
    expect(key('setup-done'), findsNothing);
    expect(key('setup-nothing'), findsOneWidget);
  });

  testWidgets('where the server wants a recent sign-in: what is about to happen is said, and after signing in '
      'again the rest is made', (tester) async {
    await start(tester);
    await pump(tester, owner);
    file({
      'crates': [
        {'name': 'Lab', 'ask_again': true},
      ],
      'rules': {'no_export': true},
    });
    await choose(tester);
    await tester.runAsync(() async => world.server.requireRecentSignIn = true);
    signInAgain = () async {
      world.server.requireRecentSignIn = false;
      return true;
    };
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(3)).last);
    // Adding the Crate needed nothing; its settings do.
    expect(find.text(l10n.stepUpTitle), findsOneWidget);
    expect(inKey('step-up-summary', find.text(l10n.setupStepUpWhat('Northwind Ops'))), findsOneWidget);
    expect(inKey('step-up-summary', find.text(l10n.setupStepUpEffect)), findsOneWidget);
    expect(world.server.recordOf(o.id).crates, hasLength(3));
    await tap(tester, find.text(l10n.devicesSignInAgainTitle));
    expect(signInsAsked, 1);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text))).data, l10n.setupDone(3),
        reason: 'the one made before signing in again counts');
    expect(key('setup-steps'), findsNothing);
    expect(key('setup-nothing'), findsNothing, reason: 'one success, said once');
    expect(world.server.recordOf(o.id).rules.noExport, isTrue);
    expect(world.server.recordOf(o.id).crates.values.where((c) => c.confirmReveal), hasLength(1));
  });

  testWidgets('backing out of signing in again: it stopped there, says what was made, and what is left can be '
      'applied later', (tester) async {
    await start(tester);
    await pump(tester, owner);
    file({
      'crates': [
        {'name': 'Lab', 'ask_again': true},
      ],
      'rules': {'no_export': true},
    });
    await choose(tester);
    await tester.runAsync(() async => world.server.requireRecentSignIn = true);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(3)).last);
    await tap(tester, find.text(l10n.cancel));
    expect(signInsAsked, 0);
    final stopped = linesOf(tester, 'setup-stopped');
    expect(stopped.first, l10n.setupStoppedAt(l10n.setupStepCrate('Lab')));
    expect(stopped, contains(l10n.setupStopped(1, 1)));
    // Why, in words: not the server's code for it.
    expect(stopped, contains('ZestSSH Cloud takes this change only after a sign-in from the last two hours.'));
    expect(stopped.join(' '), isNot(contains('recent-sign-in-required')));
    final copy = tester.widget<CopyDetailsButton>(inKey('setup-stopped', find.byType(CopyDetailsButton))).detail;
    expect(copy.split('\n'), [
      'Setup file: applying',
      'Orchard: ${o.id}',
      'Stopped at: crate Lab: ask again on',
      'Error: Orchards: HTTP 403 recent-sign-in-required',
      'Made before it: 1',
      'Not tried: 1',
    ]);
    // What is left is what the page shows now.
    expect(linesOf(tester, 'setup-steps').first, l10n.setupPlanChanges(2));
    expect(key('setup-apply'), findsOneWidget);
    expect(world.server.recordOf(o.id).rules.noExport, isFalse);

    // Signing in again was tried and did not happen: the same.
    signInAgain = () async => false;
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(2)).last);
    await tap(tester, find.text(l10n.devicesSignInAgainTitle));
    expect(signInsAsked, 1);
    expect(linesOf(tester, 'setup-stopped'), contains(l10n.setupStopped(0, 1)));
  });

  testWidgets('an Orchard that changed since the file was checked is looked at again, not applied', (tester) async {
    await start(tester);
    await pump(tester, owner);
    file({
      'crates': [
        {'name': 'Production', 'ask_again': true},
        {'name': 'Staging', 'ask_again': true},
      ],
    });
    await choose(tester);
    expect(linesOf(tester, 'setup-steps').first, l10n.setupPlanChanges(2));
    // Someone makes one of the two changes by hand meanwhile.
    await tester.runAsync(() => owner.service.setCrateConfirmReveal(o.id, o.production, true));
    final requests = world.server.appends.length;
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(2)).last);
    expect(linesOf(tester, 'setup-moved'), [l10n.setupChanged]);
    expect(world.server.appends, hasLength(requests), reason: 'nothing was applied');
    expect(key('setup-done'), findsNothing);
    // What is on screen now is the Orchard as it is.
    expect(linesOf(tester, 'setup-steps'), [l10n.setupPlanChanges(1), 'Vault Staging', 'Ask again before revealing: on']);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(1)).last);
    expect(key('setup-moved'), findsNothing);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text))).data, l10n.setupDone(1));
    expect(world.server.recordOf(o.id).crates[o.staging]!.confirmReveal, isTrue);
  });

  testWidgets("the team's first limit asks its owner about older versions before the file; backing out makes "
      'nothing, and the next file is not asked about', (tester) async {
    await start(tester);
    await joined(tester, SetupWorld.ada, o.members);
    await pump(tester, owner);
    final ada = email(SetupWorld.ada);
    file({
      'members': [
        {
          'email': ada,
          'limits': {'Production': 'connect'},
        },
      ],
    });
    await choose(tester);
    expect(linesOf(tester, 'setup-steps'),
        [l10n.setupPlanChanges(1), l10n.setupStepLimit(ada, 'Production', l10n.crateLevelConnect)]);
    // Asked first; backing out makes nothing, and nothing more is asked.
    await tap(tester, key('setup-apply'));
    expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsOneWidget);
    expect(find.text(l10n.newKindsBody), findsOneWidget);
    await tap(tester, find.text(l10n.cancel));
    expect(find.text(l10n.setupApplyConfirmTitle), findsNothing);
    expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits, isEmpty);
    expect(key('setup-done'), findsNothing);
    // Made: then the file itself is asked about, and applied.
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.newKindsConfirm));
    expect(find.text(l10n.setupApplyConfirmTitle), findsOneWidget);
    await tap(tester, find.text(l10n.setupApplyButton(1)).last);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text))).data, l10n.setupDone(1));
    expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits,
        {o.production: levelSwitches(CrateLevel.connect)});
    // The team has one now: the next file goes straight to its own question.
    file({
      'members': [
        {
          'email': ada,
          'limits': {'Production': 'connect', 'Staging': 'none'},
        },
      ],
    });
    await choose(tester);
    await tap(tester, key('setup-apply'));
    expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsNothing);
    await tap(tester, find.text(l10n.setupApplyButton(1)).last);
    expect(world.server.recordOf(o.id).members[SetupWorld.ada]!.limits[o.staging], isEmpty);
  });

  testWidgets('someone who is not an owner is told that an owner makes the first one, and nothing is applied',
      (tester) async {
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await joined(tester, SetupWorld.lin, o.members);
    await pump(tester, ada);
    file({
      'members': [
        {
          'email': email(SetupWorld.lin),
          'limits': {'Production': 'none'},
        },
      ],
    });
    await choose(tester);
    expect(key('setup-problems'), findsNothing, reason: 'the record takes it; who goes first is the server\'s');
    await tap(tester, key('setup-apply'));
    expect(find.text(l10n.newKindsOwnerFirstTitle), findsOneWidget);
    expect(find.text(l10n.newKindsOwnerFirstBody(kNewRecordKindsVersion)), findsOneWidget);
    await tap(tester, find.text(l10n.close));
    expect(find.text(l10n.setupApplyConfirmTitle), findsNothing);
    expect(signInsAsked, 0);
    expect(key('setup-done'), findsNothing);
    expect(world.server.recordOf(o.id).members[SetupWorld.lin]!.limits, isEmpty);
  });

  testWidgets("while new kinds of entry are not on, a limit stands in the way in the member panel's words",
      (tester) async {
    await start(tester);
    await joined(tester, SetupWorld.ada, o.members);
    world.server.newRecordKinds = false;
    addTearDown(() => newRecordKindsOn.value = true);
    await pump(tester, owner);
    file({
      'members': [
        {
          'email': email(SetupWorld.ada),
          'until': kLater,
          'limits': {'Production': 'connect'},
        },
      ],
    });
    await choose(tester);
    expect(
        linesOf(tester, 'setup-problems'),
        contains(l10n.setupPair(l10n.setupStepLimit(email(SetupWorld.ada), 'Production', l10n.crateLevelConnect),
            l10n.vaultAccessNotYet(kNewRecordKindsVersion))));
    expect(key('setup-apply'), findsNothing);
    expect(find.text(l10n.newKindsTitle(kNewRecordKindsVersion)), findsNothing);
  });

  testWidgets('hosts that were written and did not reach ZestSSH Cloud are said to go with the next sync',
      (tester) async {
    await start(tester);
    await pump(tester, owner, sync: () async => throw StateError('offline'));
    file({
      'crates': [
        {
          'name': 'Production',
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11'},
          ],
        },
      ],
    });
    await choose(tester);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(1)).last);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text)).first).data, l10n.setupDone(1));
    expect(tester.widget<Text>(key('setup-sync-later')).data, l10n.setupSyncLater);
  });

  testWidgets('an Orchard that cannot be read says so, with what to copy', (tester) async {
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, o.members);
    await tester.runAsync(() async {
      await ada.snapshot(o.id);
      await owner.service.suspendMember(o.id, SetupWorld.ada);
    });
    await pump(tester, ada);
    file({'crates': <Object?>[]});
    await choose(tester);
    expect(linesOf(tester, 'setup-check-error').first, l10n.setupNotOpen);
    final copy = tester.widget<CopyDetailsButton>(inKey('setup-check-error', find.byType(CopyDetailsButton))).detail;
    expect(copy, contains('Orchard: ${o.id}'));
    expect(copy, contains('suspended'));
    expect(key('setup-steps'), findsNothing);
    // Saving needs the Orchard too: said, and nothing is written.
    await tap(tester, key('setup-save-button'));
    expect(
        ProviderScope.containerOf(tester.element(find.byType(TeamSetup)))
            .read(notificationCenterProvider)
            .history
            .any((n) => n.title == l10n.setupNotOpen || n.body == l10n.setupNotOpen),
        isTrue);
    expect(saved, isEmpty);
  });

  testWidgets('while the screen is recorded, the names in a plan are masked', (tester) async {
    await start(tester);
    await joined(tester, SetupWorld.ada, o.members);
    Redactor.instance
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = true;
    await pump(tester, owner, recording: true);
    file({
      'crates': [
        {
          'name': 'Production',
          'ask_again': true,
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11'},
          ],
        },
      ],
      'members': [
        {'email': email(SetupWorld.ada), 'until': kLater},
        {'email': email(SetupWorld.lin), 'role': 'Members'},
      ],
    }, name: 'northwind-team.json');
    await choose(tester);
    final shown = [...linesOf(tester, 'setup-steps'), ...linesOf(tester, 'setup-notes')].join('\n');
    for (final name in ['Production', 'web-1', '10.50.0.11', email(SetupWorld.ada), email(SetupWorld.lin)]) {
      expect(shown, isNot(contains(name)), reason: name);
    }
    expect(shown, contains(l10n.setupPlanChanges(4)));
    expect(tester.widget<CopyDetailsButton>(key('setup-copy-plan')).detail, isNot(contains('web-1')));
  });

  testWidgets('while the screen is recorded: the file\'s name, what is wrong with it and where it stopped are masked',
      (tester) async {
    await start(tester);
    Redactor.instance
      ..salt = 'a test'
      ..level = RedactLevel.layout
      ..enabled = true;
    await pump(tester, owner, recording: true);
    // A file called after a host, with the same person in it twice.
    const name = 'web-1.northwind.example.json';
    file({
      'members': [
        {'email': email(SetupWorld.ada), 'role': 'Members'},
        {'email': email(SetupWorld.ada), 'role': 'admin'},
      ],
    }, name: name);
    await choose(tester);
    final shownName = tester.widget<Text>(key('setup-file-name')).data!;
    expect(shownName, Redactable.freeText(name).display);
    expect(shownName, isNot(contains('northwind')));
    final wrong = linesOf(tester, 'setup-file-problems');
    expect(wrong.first, l10n.setupFileProblemsTitle);
    expect(wrong[1], startsWith('members[1].email'));
    expect(wrong.join('\n'), isNot(contains(email(SetupWorld.ada))));
    // What is copied has every place and name as the file has it.
    final copy = tester.widget<CopyDetailsButton>(inKey('setup-file-problems', find.byType(CopyDetailsButton)));
    expect(copy.detail, contains(email(SetupWorld.ada)));
    // And the clipboard gets it so: the person's own file, not scrubbed as the
    // details of a failure are (3.0).
    final pasted = <String>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') pasted.add((call.arguments as Map)['text'] as String);
      return null;
    });
    addTearDown(() => TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null));
    await tap(tester, inKey('setup-file-problems', find.byType(CopyDetailsButton)));
    await tester.pump(const Duration(seconds: 3));
    expect(pasted, [copy.detail]);

    // A file that stops at a step: the step is named with its names masked.
    file({
      'crates': [
        {'name': 'Laboratory', 'ask_again': true},
      ],
    });
    await choose(tester);
    await tester.runAsync(() async => world.server.requireRecentSignIn = true);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(2)).last);
    await tap(tester, find.text(l10n.cancel));
    final stopped = linesOf(tester, 'setup-stopped');
    expect(stopped.first, l10n.setupStoppedAt(l10n.setupStepCrate(Redactable.account('Laboratory').display)));
    expect(stopped.first, isNot(contains('Laboratory')));
    // And copied as it is.
    expect(tester.widget<CopyDetailsButton>(inKey('setup-stopped', find.byType(CopyDetailsButton))).detail,
        contains('Stopped at: crate Laboratory: ask again on'));
  });

  testWidgets('while a file is applied, the step it is at is said, and no other file can be chosen', (tester) async {
    await start(tester);
    // Sending the hosts on does not come back until it is let go.
    final gate = Completer<void>();
    await pump(tester, owner, sync: () => gate.future);
    file({
      'crates': [
        {
          'name': 'Production',
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11', 'group': 'Web'},
          ],
        },
      ],
    });
    await choose(tester);
    expect(tester.widget<ZestButton>(key('setup-choose')).onPressed, isNotNull);
    expect(tester.widget<ZestButton>(key('setup-check-again')).onPressed, isNotNull);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(2)).last);
    // The second of two steps was the last one started.
    // One progress: how far, and the step under way; the button waits
    // without a spinner of its own.
    expect(linesOf(tester, 'setup-progress'),
        [l10n.vaultUiSetupApplying(2, 2, l10n.setupStepAddHost('web-1', 'Production'))]);
    expect(tester.widget<LinearProgressIndicator>(inKey('setup-progress', find.byType(LinearProgressIndicator))).value,
        1.0);
    expect(tester.widget<ZestButton>(key('setup-apply')).isLoading, isFalse);
    expect(tester.widget<ZestButton>(key('setup-choose')).onPressed, isNull);
    expect(tester.widget<ZestButton>(key('setup-check-again')).onPressed, isNull);
    expect(tester.widget<ZestButton>(key('setup-apply')).onPressed, isNull);
    expect(key('setup-done'), findsNothing);
    gate.complete();
    await settle(tester);
    expect(key('setup-progress'), findsNothing);
    expect(tester.widget<Text>(inKey('setup-done', find.byType(Text))).data, l10n.setupDone(2));
    expect(tester.widget<ZestButton>(key('setup-choose')).onPressed, isNotNull);
    // Another file chosen after it: how the one before went is no longer said.
    file({'crates': <Object?>[]});
    await choose(tester);
    expect(key('setup-done'), findsNothing);
    expect(key('setup-nothing'), findsOneWidget);
  });

  testWidgets('an Orchard that can no longer be read when a file is applied: said, and nothing is made',
      (tester) async {
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await pump(tester, ada);
    file({
      'crates': [
        {'name': 'Lab'},
      ],
    });
    await choose(tester);
    expect(key('setup-apply'), findsOneWidget);
    await tester.runAsync(() => owner.service.suspendMember(o.id, SetupWorld.ada));
    expect(toasted(tester, l10n.setupNotOpen), isFalse);
    await tap(tester, key('setup-apply'));
    await tap(tester, find.text(l10n.setupApplyButton(1)).last);
    expect(toasted(tester, l10n.setupNotOpen), isTrue);
    expect(key('setup-done'), findsNothing);
    expect(key('setup-stopped'), findsNothing);
    expect(world.server.recordOf(o.id).crates, hasLength(2));
  });

  testWidgets('a file with something in its way says nothing about signing in again, whatever its steps need',
      (tester) async {
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await pump(tester, ada);
    file({
      'crates': [
        {'name': 'Production', 'ask_again': true},
      ],
      'members': [
        {'email': email(SetupWorld.ada), 'role': 'owner'},
      ],
    });
    await choose(tester);
    final plan = await planOf(tester, ada);
    expect(plan.problems, hasLength(1));
    expect(plan.needsRecentSignIn, isTrue, reason: 'a Crate\'s settings are such a change');
    expect(key('setup-steps'), findsOneWidget);
    expect(key('setup-apply'), findsNothing);
    expect(key('setup-needs-sign-in'), findsNothing);
  });

  testWidgets('on a phone: nothing is said about a terminal, and a saved file is said in a notice', (tester) async {
    await start(tester);
    await pump(tester, owner, small: true, onComputer: false);
    expect(key('setup-save'), findsOneWidget);
    expect(key('setup-check'), findsOneWidget);
    expect(key('setup-terminal'), findsNothing);
    expect(find.textContaining('zestssh admin'), findsNothing);
    await tap(tester, key('setup-save-button'));
    expect(saved, hasLength(1));
    expect(toasted(tester, l10n.setupSavedTitle), isTrue);
    expect(find.text(l10n.setupSavedBody), findsNothing, reason: 'there is no folder to show it in');
    await tester.pump(const Duration(seconds: 6));
  });

  testWidgets('in every language, on a computer and on a small phone, a full plan fits', (tester) async {
    // With the shipped font: the test font draws each glyph as a square,
    // far wider than real text.
    await tester.runAsync(loadShotFonts);
    final theme = ThemeData(fontFamily: 'GeistSans');
    await start(tester);
    final ada = await joined(tester, SetupWorld.ada, FixedRoles.admin);
    await joined(tester, SetupWorld.sam, o.members);
    await tester.runAsync(() => owner.addKey(o.id, 'deploy', crateId: o.production));
    await tester.runAsync(() => owner.sync(o.id));
    file({
      'rules': {'no_export': true, 'reauth_days': 30},
      'crates': [
        {
          'name': 'Production',
          'allow': ['sftp'],
          'ask_again': true,
          'session_logs': true,
          'hosts': [
            {'name': 'web-1', 'address': '10.50.0.11', 'key': 'deploy', 'group': 'Web', 'tags': ['prod', 'web']},
          ],
        },
        {'name': 'Lab'},
      ],
      'members': [
        {'email': email(SetupWorld.lin), 'role': 'Members', 'crates': {'Staging': 'use'}, 'until': kLater},
        {'email': email(SetupWorld.ada), 'role': 'owner'},
        // A member held in one vault and kept out of another; someone not a
        // member yet, named with a limit.
        {
          'email': email(SetupWorld.sam),
          'limits': {'Production': 'connect', 'Staging': 'none'},
        },
        {
          'email': 'kai@northwind.example',
          'role': 'Members',
          'limits': {'Production': 'none'},
        },
      ],
    });
    for (final locale in AppLocalizations.supportedLocales) {
      for (final small in [false, true]) {
        await pump(tester, ada, small: small, locale: locale, theme: theme);
        await choose(tester);
        final words = lookupAppLocalizations(locale);
        expect(find.text(words.setupCheckTitle), findsOneWidget, reason: '$locale');
        expect(key('setup-problems'), findsOneWidget, reason: '$locale');
        expect(key('setup-steps'), findsOneWidget, reason: '$locale');
        expect(key('setup-notes'), findsOneWidget, reason: '$locale');
        expect(tester.takeException(), isNull, reason: '$locale small=$small');
      }
    }
  });
}
