import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/shortcuts/shortcut_key.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/command_palette_item.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/widgets/command_palette.dart';
import 'package:zestssh/ui/widgets/kbd.dart';
import 'package:zestssh/ui/widgets/match_marks.dart';
import 'package:zestssh/theme/zest_tokens.dart';

import '../helpers/monitor_table_fixture.dart';
import '../visual/shots_util.dart' show loadShotFonts;

/// The command palette as the 4.0 design draws it:
/// results under Hosts, Actions and Snippets,
/// each row with a second line; what was typed marked in every match; open
/// sessions in words; the row in hand says what Enter and Ctrl+Enter do
/// (Ctrl+Enter, Cmd+Enter on a Mac, opens a host in a split); actions that
/// name a host or a group; snippets found by name, command and category; the
/// keys in the footer; the filters kept; the hosts connected to last first.

/// web-01 has two sessions open, web-02 one.
class _Sessions extends ActiveSessionsNotifier {
  _Sessions(super.ref) {
    state = {
      's1': const SessionState(status: SessionStatus.connected, connectionId: 'web1'),
      's2': const SessionState(status: SessionStatus.connected, connectionId: 'web1'),
      's3': const SessionState(status: SessionStatus.connected, connectionId: 'web2'),
    };
  }
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));
  final did = <String>[];

  /// New host, with its shortcut as the formatter writes it.
  CommandPaletteItem newHost() => CommandPaletteItem(
        id: 'new-host',
        category: CommandCategory.action,
        title: en.hostsNewHost,
        subtitle: en.paletteDescNewHost,
        icon: LucideIcons.plus,
        shortcut: ShortcutKey(keyId: LogicalKeyboardKey.keyN.keyId, ctrl: true, shift: true).displayLabel,
        onSelect: () => did.add('new host'),
      );

  /// Lets the palette read the hosts from the database, which answers in real time.
  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 12; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 20));
    }
  }

  /// The demo fleet, web-01 and web-02 in the group Web, db-primary and
  /// cache-01 in Data, two snippets; [connected]: when hosts were last
  /// connected to. The palette opened over it, what it is asked to do kept
  /// in [did].
  Future<AppDatabase> open(
    WidgetTester tester, {
    Map<String, DateTime> connected = const {},
    bool sftp = true,
    Size size = const Size(1400, 1000),
    Locale locale = const Locale('en'),
  }) async {
    L10nGlobal.update(lookupAppLocalizations(locale));
    did.clear();
    // The app's own fonts: what fits is measured in them.
    await tester.runAsync(loadShotFonts);
    tester.view.physicalSize = size;
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final fleet = MonitorFleet();
    final db = (await tester.runAsync(() async {
      final db = await fleet.database();
      for (final (id, name) in [('g-web', 'Web'), ('g-data', 'Data')]) {
        await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: id, name: name, createdAt: DateTime(2026)));
      }
      for (final (host, group) in [('web1', 'g-web'), ('web2', 'g-web'), ('db', 'g-data'), ('cache', 'g-data')]) {
        await (db.update(db.connections)..where((t) => t.id.equals(host))).write(ConnectionsCompanion(groupId: Value(group)));
      }
      for (final MapEntry(key: id, value: at) in connected.entries) {
        await (db.update(db.connections)..where((t) => t.id.equals(id))).write(ConnectionsCompanion(lastConnected: Value(at)));
      }
      final at = DateTime(2026);
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: 'sn1', label: 'Restart nginx', command: 'sudo systemctl restart nginx', category: const Value('Web'), createdAt: at, updatedAt: at));
      await db.into(db.snippets).insert(SnippetsCompanion.insert(
          id: 'sn2', label: 'Disk usage', command: 'df -h', category: const Value('System'), createdAt: at, updatedAt: at));
      return db;
    }))!;
    final prefs = await fleet.preferences();
    late BuildContext at;
    late WidgetRef refAt;
    await tester.pumpWidget(fleet.app(
      [...fleet.overrides(db, prefs), activeSessionsProvider.overrideWith(_Sessions.new)],
      Consumer(builder: (context, ref, _) {
        at = context;
        refAt = ref;
        return const SizedBox.expand();
      }),
      theme: ThemeData(fontFamily: 'GeistSans'),
      locale: locale,
    ));
    await settle(tester);
    // Closed whatever a test did, so the next one opens (a second call
    // while one is up closes it).
    addTearDown(() async {
      if (at.mounted && find.byKey(const ValueKey('palette-query')).evaluate().isNotEmpty) {
        Navigator.of(at, rootNavigator: true).pop();
        await tester.pump();
      }
    });
    showCommandPalette(
      at,
      refAt,
      actions: [newHost()],
      onConnect: (h) => did.add('open ${h.connection.id}'),
      onOpenInSplit: (h) => did.add('split ${h.connection.id}'),
      onOpenSftp: sftp ? (h) => did.add('sftp ${h.connection.id}') : null,
      onBroadcast: (ids) => did.add('broadcast ${(ids.toList()..sort()).join(',')}'),
    ).ignore();
    await settle(tester);
    return db;
  }

  Future<void> type(WidgetTester tester, String text) async {
    await tester.enterText(find.byKey(const ValueKey('palette-query')), text);
    await settle(tester);
  }

  /// Closed as a person closes it, so the next one opens; the app taken down.
  Future<void> done(WidgetTester tester, AppDatabase db) async {
    if (find.byKey(const ValueKey('palette-query')).evaluate().isNotEmpty) {
      await tester.enterText(find.byKey(const ValueKey('palette-query')), '');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await settle(tester);
    }
    expect(find.byKey(const ValueKey('palette-query')), findsNothing, reason: 'the palette closed');
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(seconds: 5));
    await tester.runAsync(db.close);
  }

  Finder row(String id) => find.byKey(ValueKey('palette-row-$id'));
  Finder inRow(String id, Finder f) => find.descendant(of: row(id), matching: f);
  double top(WidgetTester tester, Finder f) => tester.getTopLeft(f).dy;

  /// The words of [f]'s text marked as a match: underlined in the accent and
  /// bold.
  List<String> marked(WidgetTester tester, Finder f) {
    final text = tester.widget<Text>(f);
    final out = <String>[];
    text.textSpan?.visitChildren((span) {
      final style = (span as TextSpan).style;
      if (span.text != null &&
          style?.decoration == TextDecoration.underline &&
          style?.decorationColor == ZestTokens.brand &&
          style?.fontWeight == FontWeight.w600) {
        out.add(span.text!);
      }
      return true;
    });
    return out;
  }

  testWidgets('typed: its hosts, then its actions, then its snippets, each row with its second line', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester);
    await type(tester, 'web');
    final hosts = find.text(en.zestPaletteConnections.toUpperCase());
    final actions = find.text(en.zestPaletteActions.toUpperCase());
    final snippets = find.text(en.zestPaletteSnippets.toUpperCase());
    expect(hosts, findsOneWidget);
    expect(actions, findsOneWidget);
    expect(snippets, findsOneWidget);
    expect(tester.getTopLeft(hosts).dy, lessThan(tester.getTopLeft(actions).dy));
    expect(tester.getTopLeft(actions).dy, lessThan(tester.getTopLeft(snippets).dy));
    // A host: its name, its open sessions in words, its address under it.
    expect(inRow('host_web1', find.text('web-01')), findsOneWidget);
    expect(inRow('host_web1', find.text(en.paletteOpenCount(2))), findsOneWidget);
    expect(inRow('host_web1', find.text('deploy@192.168.10.21')), findsOneWidget);
    expect(tester.getTopLeft(inRow('host_web1', find.text('deploy@192.168.10.21'))).dy,
        greaterThan(tester.getTopLeft(inRow('host_web1', find.text('web-01'))).dy));
    expect(inRow('host_web2', find.text(en.broadcastToHostsIsOpen)), findsOneWidget);
    // The actions that name it: the best host's files, the group's broadcast.
    expect(inRow('sftp_web1', find.text(en.paletteOpenInSftp('web-01'))), findsOneWidget);
    expect(inRow('sftp_web1', find.text(en.paletteOpenInSftpDesc)), findsOneWidget);
    expect(inRow('broadcast_g-web', find.text(en.paletteBroadcastGroup('Web'))), findsOneWidget);
    expect(inRow('broadcast_g-web', find.text(en.paletteBroadcastTwo('web-01', 'web-02'))), findsOneWidget);
    // A snippet found by its category: its command under its name, the category beside.
    expect(inRow('snippet_sn1', find.text('Restart nginx')), findsOneWidget);
    expect(inRow('snippet_sn1', find.text('sudo systemctl restart nginx')), findsOneWidget);
    expect(inRow('snippet_sn1', find.text('Web')), findsOneWidget);
    expect(find.text('Disk usage'), findsNothing);
    // How many, said where it is typed.
    final count = find.byKey(const ValueKey('palette-count'));
    expect(tester.widget<Text>(count).data, en.zestPaletteResults(5));
    expect(tester.takeException(), isNull);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('what was typed is marked in every match: bold, underlined in the accent', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester);
    await type(tester, 'web');
    expect(marked(tester, inRow('host_web1', find.text('web-01'))), ['web']);
    expect(marked(tester, inRow('host_web2', find.text('web-02'))), ['web']);
    expect(marked(tester, inRow('sftp_web1', find.text(en.paletteOpenInSftp('web-01')))), ['web']);
    expect(marked(tester, inRow('broadcast_g-web', find.text(en.paletteBroadcastGroup('Web')))), ['Web']);
    expect(marked(tester, inRow('snippet_sn1', find.text('Web'))), ['Web'], reason: 'found by its category');
    // A fuzzy match marks its letters.
    await type(tester, 'dbpr');
    expect(marked(tester, inRow('host_db', find.text('db-primary'))), ['db', 'pr']);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('the row in hand says what Enter and Ctrl+Enter do: Enter opens the host, Ctrl+Enter opens it in a split',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var db = await open(tester);
    await type(tester, 'web-01');
    expect(inRow('host_web1', find.text(en.hpanelOpenInSplit)), findsOneWidget);
    expect(inRow('host_web1', find.widgetWithText(Kbd, 'Ctrl+Enter')), findsOneWidget);
    expect(inRow('host_web1', find.text(en.hostsHomeMenuOpen)), findsOneWidget);
    expect(inRow('host_web1', find.widgetWithText(Kbd, 'Enter')), findsOneWidget);
    // Only the row in hand says it.
    expect(find.text(en.hpanelOpenInSplit), findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(did, ['split web1']);
    await done(tester, db);

    db = await open(tester);
    await type(tester, 'web-01');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await settle(tester);
    expect(did, ['open web1']);
    await done(tester, db);

    // A click on Open in split does it too.
    db = await open(tester);
    await type(tester, 'web-01');
    await tester.tap(find.byKey(const ValueKey('palette-row-split')));
    await settle(tester);
    expect(did, ['split web1']);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('on a Mac the split key is Cmd+Enter, said as the Mac writes it', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    final db = await open(tester);
    await type(tester, 'web-01');
    expect(inRow('host_web1', find.widgetWithText(Kbd, '⌘Enter')), findsOneWidget);
    expect(find.descendant(of: find.byKey(const ValueKey('palette-footer-split')), matching: find.text('⌘Enter')),
        findsOneWidget);
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await settle(tester);
    expect(did, ['split web1']);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('the actions that name a host or a group do what the app does for them; an action shows its shortcut',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    var db = await open(tester);
    await type(tester, 'web');
    await tester.tap(row('sftp_web1'));
    await settle(tester);
    expect(did, ['sftp web1']);
    await done(tester, db);

    db = await open(tester);
    await type(tester, 'web');
    await tester.tap(row('broadcast_g-web'));
    await settle(tester);
    expect(did, ['broadcast web1,web2']);
    await done(tester, db);

    // Where the caller opens no files, no files are offered; New host shows
    // what it does and its key as the formatter writes it.
    db = await open(tester, sftp: false);
    await type(tester, 'new host');
    expect(find.text(en.paletteOpenInSftp('web-01')), findsNothing);
    expect(inRow('new-host', find.text(en.paletteDescNewHost)), findsOneWidget);
    expect(inRow('new-host', find.widgetWithText(Kbd, 'Ctrl+Shift+N')), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('snippets are found by name, command and category', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester);
    for (final (typed, found, mark) in [
      ('#nginx', 'Restart nginx', 'nginx'),
      ('#systemctl', 'Restart nginx', null),
      ('#web', 'Restart nginx', 'Web'),
      ('#df -h', 'Disk usage', null),
    ]) {
      await type(tester, typed);
      expect(find.text(found), findsOneWidget, reason: typed);
      expect(find.text(en.zestPaletteConnections.toUpperCase()), findsNothing, reason: '# lists snippets alone');
      if (typed == '#web') expect(marked(tester, inRow('snippet_sn1', find.text('Web'))), [mark]);
      if (typed == '#systemctl') {
        expect(marked(tester, inRow('snippet_sn1', find.text('sudo systemctl restart nginx'))), ['systemctl']);
      }
    }
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('the filters stay: > actions, # snippets, @ every host; Esc takes the filter off, then closes', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester);
    final hosts = en.zestPaletteConnections.toUpperCase();
    final actions = en.zestPaletteActions.toUpperCase();
    final snippets = en.zestPaletteSnippets.toUpperCase();
    await type(tester, '>');
    expect([find.text(hosts), find.text(actions), find.text(snippets)].map((f) => f.evaluate().length), [0, 1, 0]);
    await type(tester, '#');
    expect([find.text(hosts), find.text(actions), find.text(snippets)].map((f) => f.evaluate().length), [0, 0, 1]);
    await type(tester, '@');
    expect([find.text(hosts), find.text(actions), find.text(snippets)].map((f) => f.evaluate().length), [1, 0, 0]);
    expect(find.text('build-runner'), findsOneWidget, reason: 'every host, by name');
    await type(tester, '@web');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(tester.widget<TextField>(find.byKey(const ValueKey('palette-query'))).controller!.text, 'web');
    expect(find.text(actions), findsOneWidget, reason: 'every section again');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await settle(tester);
    expect(find.byKey(const ValueKey('palette-query')), findsNothing);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('with nothing typed: the hosts connected to last, then the actions and the snippets', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final now = DateTime.now();
    var db = await open(tester, connected: {
      'db': now.subtract(const Duration(hours: 3)),
      'web1': now.subtract(const Duration(minutes: 5)),
    });
    final recent = find.text(en.zestPaletteRecent.toUpperCase());
    expect(recent, findsOneWidget);
    expect(find.text(en.zestPaletteConnections.toUpperCase()), findsNothing);
    expect(top(tester, row('recent_web1')), lessThan(top(tester, row('recent_db'))), reason: 'the last one first');
    expect(find.text('mac-studio'), findsNothing, reason: 'the others are a word away (or @)');
    expect(top(tester, row('recent_db')), lessThan(top(tester, find.text(en.zestPaletteActions.toUpperCase()))));
    expect(find.text(en.zestPaletteSnippets.toUpperCase()), findsOneWidget);
    // When each was connected to, as before.
    expect(inRow('recent_web1', find.text(timeAgoShort(en, now.subtract(const Duration(minutes: 5))))), findsOneWidget);
    await done(tester, db);

    // Where none was connected to yet: every host, as before.
    db = await open(tester);
    expect(find.text(en.zestPaletteRecent.toUpperCase()), findsNothing);
    expect(find.text(en.zestPaletteConnections.toUpperCase()), findsOneWidget);
    expect(top(tester, row('host_build')), lessThan(top(tester, row('host_cache'))), reason: 'by name');
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('a screen reader: each row a button, the one in hand selected, each move said, the sections headings',
      (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final semantics = tester.ensureSemantics();
    final said = <String>[];
    tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, (message) async {
      final data = (message as Map)['data'];
      if (data is Map && data['message'] is String) said.add(data['message'] as String);
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockDecodedMessageHandler<dynamic>(SystemChannels.accessibility, null));
    final db = await open(tester);
    await type(tester, 'web');
    final first = tester.getSemantics(row('host_web1').first);
    expect(first, isSemantics(isButton: true, hasSelectedState: true, isSelected: true, hasTapAction: true));
    expect(first.label, allOf(contains('web-01'), contains(en.paletteOpenCount(2)), contains('deploy@192.168.10.21')));
    final second = tester.getSemantics(row('host_web2').first);
    expect(second, isSemantics(isButton: true, hasSelectedState: true, isSelected: false, hasTapAction: true));
    expect(second.label, contains('web-02'));
    expect(tester.getSemantics(find.text(en.zestPaletteActions.toUpperCase())), isSemantics(isHeader: true));
    // Moving with the keys says where it is, and for a host how to split.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(said.last, allOf(contains('web-02'), contains(en.broadcastToHostsIsOpen), contains('deploy@192.168.10.22'),
        contains('${en.hpanelOpenInSplit} Ctrl+Enter')));
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(said.last, '${en.paletteOpenInSftp('web-01')}, ${en.paletteOpenInSftpDesc}');
    // The count is said as it changes.
    final count = tester.getSemantics(find.byKey(const ValueKey('palette-count')));
    expect(count, isSemantics(isLiveRegion: true));
    expect(count.label.trim(), en.zestPaletteResults(5));
    semantics.dispose();
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets("the footer says the keys, Enter's word that of the row in hand", (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester);
    await type(tester, 'web');
    Finder footer(String key, String text) => find.descendant(of: find.byKey(ValueKey(key)), matching: find.text(text));
    expect(footer('palette-footer-move', en.paletteKeyMove), findsOneWidget);
    expect(footer('palette-footer-enter', en.hostsHomeMenuOpen), findsOneWidget);
    expect(footer('palette-footer-split', en.paletteKeySplit), findsOneWidget);
    expect(footer('palette-footer-esc', en.close), findsOneWidget);
    final filters = tester.widget<Text>(find.byKey(const ValueKey('palette-footer-filters'))).textSpan!.toPlainText();
    expect(filters, allOf(contains('> ${en.paletteFilterActions}'), contains('# ${en.paletteFilterSnippets}'),
        contains('@ ${en.paletteFilterHosts}')));
    // On an action: Enter runs it, and there is no split.
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await settle(tester);
    expect(footer('palette-footer-enter', en.paletteKeyRun), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-footer-split')), findsNothing);
    expect(inRow('sftp_web1', find.text(en.paletteKeyRun)), findsOneWidget, reason: 'the row in hand says it too');
    // Ctrl+Enter on an action does nothing (only a host has a split).
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await settle(tester);
    expect(did, isEmpty);
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  testWidgets('in a narrow window nothing is cut: the row in hand and the footer keep what has room', (tester) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
    final db = await open(tester, size: const Size(560, 800));
    await type(tester, 'web');
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('palette-footer-enter')), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-footer-esc')), findsOneWidget);
    expect(find.byKey(const ValueKey('palette-footer-filters')), findsNothing, reason: 'no room for them at 360');
    expect(find.text(en.hpanelOpenInSplit), findsNothing, reason: 'the row keeps its words; the footer says the keys');
    debugDefaultTargetPlatformOverride = null;
    await done(tester, db);
  });

  for (final locale in AppLocalizations.supportedLocales) {
    testWidgets('in $locale nothing is cut or overflows, the row in hand and the footer included', (tester) async {
      debugDefaultTargetPlatformOverride = TargetPlatform.windows;
      final l = lookupAppLocalizations(locale);
      final db = await open(tester, locale: locale, size: const Size(1280, 860));
      await type(tester, 'web');
      expect(tester.takeException(), isNull);
      expect(find.text(l.paletteOpenInSftp('web-01')), findsOneWidget);
      expect(find.byKey(const ValueKey('palette-footer-enter')), findsOneWidget);
      // At 1280 every key of the footer has room, in every language.
      expect(find.byKey(const ValueKey('palette-footer-split')), findsOneWidget);
      expect(find.byKey(const ValueKey('palette-footer-move')), findsOneWidget);
      // At the narrowest the palette is, nothing overflows either.
      await done(tester, db);
      final narrow = await open(tester, locale: locale, size: const Size(600, 700));
      await type(tester, 'web');
      expect(tester.takeException(), isNull);
      debugDefaultTargetPlatformOverride = null;
      await done(tester, narrow);
    });
  }

  group('marks', () {
    test('a whole match is marked wherever it stands, in any case', () {
      expect(wholeMatches('Web web WEB', 'web').map((r) => (r.start, r.end)), [(0, 3), (4, 7), (8, 11)]);
      expect(wholeMatches('web-01', ''), isEmpty);
      expect(wholeMatches('web-01', 'db'), isEmpty);
    });

    test('a fuzzy match marks its letters in their order, in runs, or nothing where one is missing', () {
      expect(fuzzyMatches('db-primary', 'dbpr').map((r) => (r.start, r.end)), [(0, 2), (3, 5)]);
      expect(fuzzyMatches('web-01', 'wbx'), isEmpty);
    });

    test('where a text holds it whole, a fuzzy match is marked nowhere; else in the best fuzzy text only', () {
      final whole = matchesIn([(text: 'web-01', fuzzy: true), (text: 'deploy@192.168.10.21', fuzzy: true)], 'web');
      expect(whole[0], hasLength(1));
      expect(whole[1], isEmpty);
      final fuzzy = matchesIn([(text: 'web-01', fuzzy: true), (text: 'what it does', fuzzy: false)], 'w01');
      expect(fuzzy[0], isNotEmpty);
      expect(fuzzy[1], isEmpty);
    });
  });
}
