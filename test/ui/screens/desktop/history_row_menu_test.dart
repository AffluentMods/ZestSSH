import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/notifications/notification_center.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/command_history_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/redaction_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_edit_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/history_view.dart';
import 'package:zestssh/utils/redactor.dart';

import '../../../helpers/desktop_mouse.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The actions of a row in a computer's History (3.0): they show under the
/// mouse, each acts on its own row, and the Run again menu keeps them while
/// it is open (the three dots of 2.2.1 did nothing once their row was left).
/// While the screen is recorded the rows show
/// stand-ins, and what would carry the real command out is off.
/// The salt of the stand-ins a recorded screen shows (see [setUp]).
const _salt = 'history rows';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  late AppLocalizations l10n;
  late SharedPreferences prefs;
  final copied = <String>[];

  setUpAll(() async {
    l10n = await AppLocalizations.delegate.load(const Locale('en'));
  });

  setUp(() async {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    // The stand-in a command is shown as while recording is picked by a
    // salt each install makes up for itself. Left to chance here, about one
    // run in ten picks "df -h" itself as a stand-in, or one stand-in for
    // both commands: the salt is the same for every run.
    SharedPreferences.setMockInitialValues({'recording_mask_salt': _salt});
    prefs = await SharedPreferences.getInstance();
    Redactor.instance.salt = _salt;
    copied.clear();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') {
        copied.add((call.arguments as Map)['text'] as String);
      }
      return null;
    });
  });

  tearDown(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(SystemChannels.platform, null);
    Redactor.instance.salt = '';
    await db.close();
  });

  Future<List<CommandHistoryEntry>> seed(WidgetTester tester) async {
    final now = DateTime.now();
    final rows = await tester.runAsync(() async {
      for (final (id, command, minutes) in [
        ('h1', 'df -h', 3),
        ('h2', 'sudo systemctl restart nginx', 9),
      ]) {
        await db.commandHistoryDao.upsert(CommandHistoryCompanion.insert(
          id: id,
          command: command,
          hostLabel: const Value('web-01'),
          createdAt: now.subtract(Duration(minutes: minutes)),
        ));
      }
      final all = await db.commandHistoryDao.getAll();
      all.sort((a, b) => b.createdAt.compareTo(a.createdAt));
      return all;
    });
    return rows!;
  }

  Future<void> pumpPage(WidgetTester tester, List<CommandHistoryEntry> entries,
      {bool recording = false}) async {
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(ProviderScope(
      overrides: [
        databaseProvider.overrideWithValue(db),
        sharedPreferencesProvider.overrideWithValue(prefs),
        redactionFleetRegistrar.overrideWith((ref) {}),
        isProProvider.overrideWith((ref) => _Pro()),
        if (recording) recordingModeProvider.overrideWith((ref) => true),
        // Held still: the test reads the database for what an action did.
        recentCommandHistoryProvider
            .overrideWith((ref) => Stream.value(entries)),
      ],
      child: const MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: HistoryView()),
      ),
    ));
    await tester.pumpAndSettle();
  }

  Future<void> closePage(WidgetTester tester) async {
    await tester.pump(const Duration(seconds: 6));
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(milliseconds: 20));
    await tester.pump(const Duration(milliseconds: 20));
  }

  Finder copyOf(String id) => find.byKey(ValueKey('history-copy-$id'));
  Finder saveOf(String id) => find.byKey(ValueKey('history-save-$id'));
  Finder runOf(String id) => find.byKey(ValueKey('history-run-again-$id'));
  const away = Offset(1390, 890);

  Future<List<String>> commandsInDatabase(WidgetTester tester) async {
    final rows = await tester.runAsync(() => db.commandHistoryDao.getAll());
    return [for (final e in rows!) e.command]..sort();
  }

  desktopTest('the actions show under the mouse only, and each acts on its own row', (tester) async {
    await pumpPage(tester, await seed(tester));
    final mouse = TestMouse(tester);
    expect(copyOf('h1'), findsNothing);
    await mouse.moveOver(find.text('sudo systemctl restart nginx'));
    expect(copyOf('h2'), findsOneWidget);
    expect(copyOf('h1'), findsNothing);
    await mouse.click(copyOf('h2'));
    expect(copied, ['sudo systemctl restart nginx']);
    final notices = ProviderScope.containerOf(tester.element(find.byType(HistoryView)))
        .read(notificationCenterProvider)
        .history;
    expect([for (final n in notices) n.title], [l10n.cmdhCommandCopied]);

    await mouse.moveTo(away);
    expect(copyOf('h2'), findsNothing);
    await closePage(tester);
  });

  desktopTest('the Run again menu keeps the row\'s actions while it is open, and closing it does nothing',
      (tester) async {
    await pumpPage(tester, await seed(tester));
    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text('df -h'));
    await mouse.click(runOf('h1'));
    expect(find.byKey(const ValueKey('history-run-on')), findsOneWidget);
    await mouse.moveTo(away);
    expect(runOf('h1'), findsOneWidget, reason: 'the menu came from here');
    await mouse.clickAt(away);
    expect(find.byKey(const ValueKey('history-run-on')), findsNothing);
    expect(runOf('h1'), findsNothing);
    expect(copied, isEmpty);
    expect(await commandsInDatabase(tester), ['df -h', 'sudo systemctl restart nginx']);
    await closePage(tester);
  });

  desktopTest('Save as snippet opens the editor with that row\'s command', (tester) async {
    await pumpPage(tester, await seed(tester));
    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text('df -h'));
    await mouse.click(saveOf('h1'));
    expect(find.descendant(of: find.byType(SnippetEditor), matching: find.text('df -h')), findsOneWidget);
    await closePage(tester);
  });

  desktopTest('Delete in the opened row removes that row', (tester) async {
    await pumpPage(tester, await seed(tester));
    await tester.tap(find.text('sudo systemctl restart nginx'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('history-delete-h2')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(await commandsInDatabase(tester), ['df -h']);
    await closePage(tester);
  });

  desktopTest('while the screen is recorded, rows show stand-ins, Copy and Save are off and Delete still works',
      (tester) async {
    Redactor.instance.enabled = true;
    addTearDown(() => Redactor.instance.enabled = false);
    await pumpPage(tester, await seed(tester), recording: true);

    // The rows show a stand-in for each command, never the command.
    final shown = Redactor.command('df -h');
    final other = Redactor.command('sudo systemctl restart nginx');
    expect({shown, other}, hasLength(2), reason: 'with this salt, each has a stand-in of its own');
    expect({shown, other}, isNot(contains('df -h')), reason: 'and neither is a command of the list');
    expect(find.text('df -h'), findsNothing);
    expect(find.text('sudo systemctl restart nginx'), findsNothing);
    expect(find.text(shown), findsOneWidget);
    expect(find.text(other), findsOneWidget);

    final mouse = TestMouse(tester);
    await mouse.moveOver(find.text(shown));
    // An action that is off takes no click.
    await mouse.click(copyOf('h1'));
    await mouse.click(saveOf('h1'));
    expect(copied, isEmpty);
    expect(find.byType(SnippetEditor), findsNothing);
    expect(find.byTooltip(l10n.cmdhOffWhileRecording), findsWidgets, reason: 'the buttons say why they are off');

    await mouse.click(find.text(shown));
    await tester.tap(find.byKey(const ValueKey('history-delete-h1')));
    await tester.runAsync(() => Future<void>.delayed(Duration.zero));
    expect(await commandsInDatabase(tester), ['sudo systemctl restart nginx']);
    await closePage(tester);
  });
}
