import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// The host editor's Save is on only when something was changed (picking the
/// same identity again showed Save as on, with nothing
/// changed). A click into a field moves its
/// cursor, not its words; a picker given what the host has again changes
/// nothing.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _blue = 0xFF3B82F6;

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final theme = TerminalThemes.freeThemeIds.first;

  late AppDatabase db;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// web-01 on port 2222, signed in with alex's key, in the Web group; with
  /// [everything], also a colour, a jump host, a snippet, a keep-alive of
  /// 30 s, a theme of its own and an environment variable.
  Future<void> pump(WidgetTester tester, {bool everything = false}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({if (everything) 'terminal_theme_c1': theme});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime(2026, 10, 19);
    await tester.runAsync(() async {
      for (final (id, user) in [('alex', 'alex'), ('root', 'root')]) {
        await db.into(db.identities).insert(IdentitiesCompanion.insert(
              id: id,
              label: '$user key',
              username: user,
              authMethod: 'publicKey',
              createdAt: now,
            ));
      }
      for (final (id, name) in [('g-web', 'Web'), ('g-db', 'Databases')]) {
        await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(
              id: id,
              name: name,
              createdAt: now,
              updatedAt: Value(now),
            ));
      }
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: 's1', label: 'Disk usage', command: 'df -h', createdAt: now, updatedAt: now));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'jump',
            label: 'bastion',
            host: '192.168.10.2',
            createdAt: now,
            updatedAt: now,
          ));
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: 'c1',
            label: 'web-01',
            host: '192.168.10.21',
            port: const Value(2222),
            identityId: const Value('alex'),
            groupId: const Value('g-web'),
            iconId: const Value('debian'),
            colorValue: everything ? const Value(_blue) : const Value.absent(),
            connectViaId: everything ? const Value('jump') : const Value.absent(),
            snippetId: everything ? const Value('s1') : const Value.absent(),
            keepAliveSeconds: everything ? const Value(30) : const Value.absent(),
            envVars: everything ? const Value('{"LANG":"C.UTF-8"}') : const Value.absent(),
            createdAt: now,
            updatedAt: now,
          ));
    });
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(c.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ConnectionEditScreen(connectionId: 'c1', inDialog: true, onClose: () {})),
      ),
    ));
    await settle(tester);
  }

  bool saveOn(WidgetTester tester) => tester.widget<ZestPaneFooter>(find.byType(ZestPaneFooter)).saveEnabled;

  Future<void> tap(WidgetTester tester, Finder target) async {
    await tester.ensureVisible(target);
    await tester.pump();
    await tester.tap(target);
    await settle(tester);
  }

  /// The select showing [value] (on any of the editor's tabs), given it
  /// again, as a pick from its menu gives it.
  Future<void> pickAgain<T>(WidgetTester tester, T value) async {
    final select = tester.widget<ZestSelect<T>>(find.byWidgetPredicate(
        (w) => w is ZestSelect<T> && w.value == value && w.items.any((i) => i.value == value),
        description: 'the select showing $value',
        skipOffstage: false));
    select.onChanged!(value);
    await settle(tester);
  }

  /// The words of the field showing [text] (on any of the editor's tabs).
  TextEditingController field(WidgetTester tester, String text) => tester
      .widget<EditableText>(find.byWidgetPredicate((w) => w is EditableText && w.controller.text == text,
          description: 'the field showing $text', skipOffstage: false))
      .controller;

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(hours: 1));
  }

  testWidgets('a click into a field, or the identity it has picked again from its menu, leaves Save off; '
      'a letter typed turns it on', (tester) async {
    await pump(tester);
    expect(saveOn(tester), isFalse, reason: 'nothing changed yet');

    // A click into the name field puts its cursor there: its words are the same.
    await tap(tester, find.widgetWithText(TextField, 'web-01'));
    expect(saveOn(tester), isFalse, reason: 'a click into a field');
    final address = field(tester, '192.168.10.21');
    address.selection = const TextSelection(baseOffset: 0, extentOffset: 7);
    await settle(tester);
    expect(saveOn(tester), isFalse, reason: 'some of its words selected');

    // The case reported: the identity's menu, and the one it has.
    await tap(tester, find.byType(ZestSelect<String?>).first);
    await tap(tester, find.descendant(of: find.byType(MenuItemButton), matching: find.text('alex key (alex)')));
    expect(saveOn(tester), isFalse, reason: 'the identity it has, picked again');

    // No colour, and None picked again.
    tester.widget<ZestColorPicker>(find.byType(ZestColorPicker)).onNoneSelected!();
    await settle(tester);
    expect(saveOn(tester), isFalse, reason: 'no colour, and None picked again');

    await tester.enterText(find.widgetWithText(TextField, 'web-01'), 'web-02');
    await settle(tester);
    expect(saveOn(tester), isTrue, reason: 'a name changed');
    await finish(tester);
  });

  testWidgets('every picker given what the host has again leaves Save off, and the port as it was; '
      'something else picked turns it on', (tester) async {
    await pump(tester, everything: true);
    expect(saveOn(tester), isFalse, reason: 'nothing changed yet');

    await pickAgain<String?>(tester, 'alex');
    expect(saveOn(tester), isFalse, reason: 'the identity');
    await pickAgain<String?>(tester, 'g-web');
    expect(saveOn(tester), isFalse, reason: 'the group');
    await pickAgain<String?>(tester, 'jump');
    expect(saveOn(tester), isFalse, reason: 'the jump host');
    await pickAgain<String?>(tester, 's1');
    expect(saveOn(tester), isFalse, reason: 'the snippet');
    await pickAgain<String?>(tester, theme);
    expect(saveOn(tester), isFalse, reason: 'the theme');
    await pickAgain<int>(tester, 30);
    expect(saveOn(tester), isFalse, reason: 'the keep-alive');

    tester.widget<ZestColorPicker>(find.byType(ZestColorPicker)).onChanged(const Color(_blue));
    await settle(tester);
    expect(saveOn(tester), isFalse, reason: 'the colour');

    // The icon's picker, opened and applied with nothing chosen.
    await tap(tester, find.text('Change'));
    await tap(tester, find.text('Apply'));
    expect(saveOn(tester), isFalse, reason: 'the icon');

    // SSH's pill, tapped again: it put the port back to 22.
    await tap(
        tester,
        find.ancestor(
            of: find.text('SSH'), matching: find.byWidgetPredicate((w) => '${w.runtimeType}' == '_MChoicePill')));
    expect(saveOn(tester), isFalse, reason: 'the protocol');
    expect(field(tester, '2222'), isNotNull, reason: 'the port as it was');

    // An environment variable's name, its cursor moved.
    field(tester, 'LANG').selection = const TextSelection.collapsed(offset: 2);
    await settle(tester);
    expect(saveOn(tester), isFalse, reason: 'a variable\'s cursor');

    await pickAgain<String?>(tester, 'g-web');
    final group = tester.widget<ZestSelect<String?>>(find.byWidgetPredicate(
        (w) => w is ZestSelect<String?> && w.value == 'g-web', skipOffstage: false));
    group.onChanged!('g-db');
    await settle(tester);
    expect(saveOn(tester), isTrue, reason: 'another group');
    await finish(tester);
  });
}
