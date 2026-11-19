import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/widgets/os_icon.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/widgets/host_card.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart' show HostEditorSection;
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/connection/connection_edit_screen.dart';
import 'package:zestssh/ui/widgets/zest_button_group.dart';
import 'package:zestssh/ui/widgets/zest_close_button.dart';
import 'package:zestssh/ui/widgets/zest_pane_footer.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

/// A design review of the host editor on a computer:
/// the host's icon as its card draws it, the preview the real card, Delete
/// away from close, the note's words, and only the rows that do something
/// for the host's protocol (no Zlib; Connect via and Keepalive for SSH alone;
/// Compatibility mode for Serial too).

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  late AppDatabase db;

  Future<void> settle(WidgetTester tester) async {
    for (var i = 0; i < 6; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  /// The docked editor of host [id] (web: SSH, seen as Ubuntu; mosh; serial).
  Future<void> open(WidgetTester tester, String id, {HostEditorSection? section}) async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(
        const MethodChannel('dev.fluttercommunity.plus/connectivity'), (call) async => ['wifi']);
    messenger.setMockStreamHandler(const EventChannel('dev.fluttercommunity.plus/connectivity_status'),
        MockStreamHandler.inline(onListen: (arguments, events) {}));
    tester.view.physicalSize = const Size(1300, 1000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'os_kind_web': 'ubuntu'});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final now = DateTime.utc(2026, 10, 22);
    await db.into(db.connectionGroups).insert(ConnectionGroupsCompanion.insert(id: 'g', name: 'Lab', createdAt: now));
    for (final (cid, label, protocol) in [('web', 'web-01', 'ssh'), ('mo', 'mosh-01', 'mosh'), ('se', 'serial-01', 'serial'), ('tn', 'telnet-01', 'telnet'), ('et', 'et-01', 'et'), ('vn', 'desk-01', 'vnc'), ('ft', 'files-01', 'ftps')]) {
      await db.into(db.connections).insert(ConnectionsCompanion.insert(
            id: cid,
            label: label,
            host: '192.168.10.21',
            port: const Value(22),
            protocol: Value(protocol),
            groupId: const Value('g'),
            createdAt: now,
            updatedAt: now,
          ));
    }
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      databaseProvider.overrideWithValue(db),
      treeDatabaseProvider.overrideWithValue(db),
      isProProvider.overrideWith((ref) => _Pro(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ConnectionEditScreen(inDialog: true, connectionId: id, initialSection: section, onClose: () {})),
      ),
    ));
    await settle(tester);
    Object? ex;
    while ((ex = tester.takeException()) != null) {
      expect(ex.toString(), contains('overflowed'));
    }
  }

  Future<void> finish(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    await tester.pump(const Duration(minutes: 1));
  }

  Future<void> tab(WidgetTester tester, String label) async {
    await tester.tap(find.text(label).first);
    await settle(tester);
  }

  testWidgets('the icon is the one its card draws, in the header, the icon field and the preview', (tester) async {
    await open(tester, 'web');
    for (final key in ['host-edit-head-icon', 'host-edit-field-icon']) {
      final icon = tester.widget<HostIcon>(find.descendant(of: find.byKey(ValueKey(key)), matching: find.byType(HostIcon)));
      expect(icon.osId, 'ubuntu', reason: key);
    }
    final preview = find.byKey(const ValueKey('host-edit-preview'));
    final card = tester.widget<HostCard>(find.descendant(of: preview, matching: find.byType(HostCard)));
    expect(card.data.osId, 'ubuntu');
    await finish(tester);
  });

  testWidgets('the preview is the real card: no group chip, no "· SSH"', (tester) async {
    await open(tester, 'web');
    final preview = find.byKey(const ValueKey('host-edit-preview'));
    expect(find.descendant(of: preview, matching: find.byType(HostCard)), findsOneWidget);
    final card = tester.widget<HostCard>(find.descendant(of: preview, matching: find.byType(HostCard)));
    expect(card.data.showGroupChip, isFalse);
    expect(card.data.subtitle, isNot(contains('SSH')));
    expect(find.descendant(of: preview, matching: find.textContaining('· SSH')), findsNothing);
    expect(find.descendant(of: preview, matching: find.text('Lab')), findsNothing);
    await finish(tester);
  });

  testWidgets('Delete is not beside close: it is in Advanced, red, and asks first', (tester) async {
    await open(tester, 'web');
    expect(find.byTooltip(en.delete), findsNothing, reason: 'no trash beside the close X');
    await tab(tester, en.connectionEditRailAdvanced);
    expect(find.byKey(const ValueKey('host-edit-delete-section')), findsOneWidget);
    await tester.ensureVisible(find.byKey(const ValueKey('host-edit-delete')));
    await tester.tap(find.byKey(const ValueKey('host-edit-delete')));
    await settle(tester);
    expect(find.text(en.connectionDeleteTitle), findsOneWidget);
    await tester.tap(find.text(en.cancel).last);
    await settle(tester);
    await finish(tester);
  });

  testWidgets('the note says where it is shown, now that cards are one size', (tester) async {
    await open(tester, 'web');
    expect(en.zestHostNoteHelp, isNot(contains('large')));
    expect(find.text(en.zestHostNoteHelp), findsOneWidget);
    await finish(tester);
  });

  testWidgets('no Zlib switch: it did nothing', (tester) async {
    await open(tester, 'web');
    await tab(tester, en.connectionEditRailNetwork);
    expect(find.text('Zlib compression'), findsNothing);
    await finish(tester);
  });

  testWidgets('Connect via and Keepalive for SSH, not for Mosh, Eternal Terminal, Telnet or Serial, which use neither', (tester) async {
    await open(tester, 'web');
    await tab(tester, en.connectionEditRailNetwork);
    expect(find.text(en.connectionConnectVia), findsWidgets);
    expect(find.text(en.settingsKeepaliveInterval), findsOneWidget);
    await finish(tester);
    for (final id in ['mo', 'se', 'tn', 'et']) {
      await open(tester, id);
      await tab(tester, en.connectionEditRailNetwork);
      expect(find.text(en.connectionConnectVia), findsNothing, reason: id);
      expect(find.text(en.settingsKeepaliveInterval), findsNothing, reason: id);
      await finish(tester);
    }
  });

  // Found in a security review.
  testWidgets('Connect via offers only hosts signed in to over SSH: no remote screen, FTPS, Telnet or Serial host',
      (tester) async {
    await open(tester, 'web');
    await tab(tester, en.connectionEditRailNetwork);
    final select = tester.widget<ZestSelect<String?>>(find.byWidgetPredicate(
        (w) => w is ZestSelect<String?> && w.hint == en.connectionConnectViaHint,
        skipOffstage: false));
    expect({for (final i in select.items) i.value}, {null, 'mo', 'et'}, reason: 'Direct, Mosh and Eternal Terminal');
    await finish(tester);
  });

  testWidgets('Compatibility mode for a Serial host too, whose SSH leg uses it', (tester) async {
    await open(tester, 'se');
    await tab(tester, en.connectionEditRailAuth);
    expect(find.byKey(const ValueKey('host-edit-compat-serial')), findsOneWidget);
    expect(find.text(en.connectionEditCompatibilityModeLabel), findsOneWidget);
    await finish(tester);
  });

  // The switch says plainly that it is not recommended and for old servers only, and
  // what it allows stays in the warning colour while it is on.
  testWidgets('Compatibility mode reads as for old servers only and not recommended; its note is in the warning '
      'colour while it is on', (tester) async {
    await open(tester, 'web');
    await tab(tester, en.connectionEditRailAuth);
    expect(find.text('Compatibility mode (old servers only)'), findsOneWidget);
    final note = find.text(en.connectionEditCompatibilityModeNote);
    expect(note, findsOneWidget);
    expect(en.connectionEditCompatibilityModeNote, startsWith('Not recommended.'));
    expect(en.connectionEditCompatibilityModeNote, contains('key exchange groups of 1024 bits'));
    Color? colourOfNote() => tester.widget<Text>(note).style?.color;
    // Off: as every other note.
    final forwardNote = tester.widget<Text>(find.text(en.connectionEditForwardAgentNote)).style?.color;
    expect(colourOfNote(), forwardNote);
    await tester.ensureVisible(find.text(en.connectionEditCompatibilityModeLabel));
    await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
    await settle(tester);
    // On: the warning colour.
    expect(colourOfNote(), ZestTokens.statusWarning);
    expect(colourOfNote(), isNot(forwardNote));
    await tester.tap(find.text(en.connectionEditCompatibilityModeLabel));
    await settle(tester);
    expect(colourOfNote(), forwardNote);
    await finish(tester);
  });

  testWidgets('opened on a section, that section is in front (for a caller that sends the person to one thing)',
      (tester) async {
    await open(tester, 'web', section: HostEditorSection.network);
    final stack = tester.widget<IndexedStack>(find.byType(IndexedStack).first);
    expect(stack.index, HostEditorSection.network.index);
    await finish(tester);
    await open(tester, 'web');
    expect(tester.widget<IndexedStack>(find.byType(IndexedStack).first).index, 0, reason: 'Basic where none is named');
    await finish(tester);
  });
  testWidgets('the footer: the two tests as one group at the left, Save alone at the right, no Cancel; the '
      "header's close is red and named Close", (tester) async {
    await open(tester, 'web');
    final reach = find.byKey(const ValueKey('host-edit-test-reachability'));
    final full = find.byKey(const ValueKey('host-edit-test-full'));
    expect(reach, findsOneWidget);
    expect(full, findsOneWidget);
    expect(find.descendant(of: reach, matching: find.text(en.zestHostTestReachability)), findsOneWidget);
    expect(find.descendant(of: full, matching: find.text(en.zestHostTestFull)), findsOneWidget);
    expect(find.descendant(of: find.byType(ZestPaneFooter), matching: find.byType(ZestButtonGroup)), findsOneWidget);
    // At the editor's usual width, side by side, and Save to their right.
    expect(tester.getCenter(reach).dy, moreOrLessEquals(tester.getCenter(full).dy));
    expect(tester.getRect(find.text(en.connectionSaveChanges)).left, greaterThan(tester.getRect(full).right));
    expect(find.descendant(of: find.byType(ZestPaneFooter), matching: find.text(en.cancel)), findsNothing);
    expect(find.descendant(of: find.byType(ZestPaneFooter), matching: find.text('Cancel')), findsNothing);
    final close = find.byKey(const ValueKey('host-edit-close'));
    expect(tester.widget(close), isA<ZestCloseButton>());
    expect(find.byTooltip(en.close), findsWidgets);
    final glyph = tester.widget<Icon>(find.descendant(of: close, matching: find.byType(Icon)));
    expect(glyph.color, ZestTokens.statusCritical);
    expect(tester.getSize(close).width, greaterThanOrEqualTo(32));
    await finish(tester);
  });
}
