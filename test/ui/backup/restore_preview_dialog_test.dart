import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/sync_data_service.dart';
import 'package:zestssh/ui/screens/backup/restore_preview.dart';

/// The question asked before a backup is restored says what it would do
/// (found in a security review).
void main() {
  late SharedPreferences prefs;

  setUp(() async {
    SharedPreferences.setMockInitialValues(const {});
    prefs = await SharedPreferences.getInstance();
  });

  /// Opens the question for [preview]; its answer lands in the returned list.
  Future<(AppLocalizations, List<RestoreChoice?>)> open(WidgetTester tester, RestorePreview preview) async {
    final answers = <RestoreChoice?>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => answers.add(await showRestorePreview(context, preview)),
              child: const Text('restore'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('restore'));
    await tester.pumpAndSettle();
    final l10n = AppLocalizations.of(tester.element(find.byType(Scaffold)))!;
    return (l10n, answers);
  }

  testWidgets('what it holds, what it replaces, and each host that does something by itself, with what it does',
      (tester) async {
    final (l10n, answers) = await open(
        tester,
        const RestorePreview(hosts: 6, keys: 1, snippets: 2, other: 3, replaces: 1, acting: [
          ('agent-2', {HostActsAlone.runsCommand, HostActsAlone.forwardsAgent}),
          ('watch-3', {HostActsAlone.monitored}),
          ('snippet-6', {HostActsAlone.runsSnippet}),
        ]));

    expect(find.text(l10n.backupRestoreTitle), findsOneWidget);
    for (final (label, n) in [
      (l10n.narrowSidebarHosts, '6'),
      (l10n.narrowSidebarKeys, '1'),
      (l10n.snippetsTitle, '2'),
      (l10n.backupRestoreOther, '3'),
    ]) {
      final row = find.ancestor(of: find.text(label), matching: find.byType(Row)).first;
      expect(find.descendant(of: row, matching: find.text(n)), findsOneWidget, reason: label);
    }
    expect(find.text(l10n.backupRestoreReplaces(1)), findsOneWidget);
    expect(find.text(l10n.backupRestoreActing), findsOneWidget);
    expect(find.text('agent-2'), findsOneWidget);
    expect(find.text('watch-3'), findsOneWidget);
    expect(find.text('snippet-6'), findsOneWidget);
    expect(find.text(l10n.backupRestoreRunsCommand), findsOneWidget);
    expect(find.text(l10n.backupRestoreForwardsAgent), findsOneWidget);
    expect(find.text(l10n.backupRestoreMonitored), findsOneWidget);
    expect(find.text(l10n.backupRestoreRunsSnippet), findsOneWidget);

    // The question scrolls where the screen is too short for it.
    await tester.ensureVisible(find.byKey(const ValueKey('restore-preview-go')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('restore-preview-go')));
    await tester.pumpAndSettle();
    expect(answers.single?.takeSettings, isEmpty);
  });

  testWidgets('Cancel restores nothing; nothing replaced and no host acting is not said', (tester) async {
    final (l10n, answers) =
        await open(tester, const RestorePreview(hosts: 2, keys: 0, snippets: 0, other: 0, replaces: 0, acting: []));
    expect(find.text(l10n.backupRestoreActing), findsNothing);
    expect(find.text(l10n.backupRestoreReplaces(0)), findsNothing);
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(answers.single, isNull);
  });

  testWidgets('a local shell says it runs on this device; Compatibility mode and variables are named', (tester) async {
    final (l10n, _) = await open(
        tester,
        const RestorePreview(hosts: 3, keys: 0, snippets: 0, other: 0, replaces: 0, acting: [
          ('Prod DB', {HostActsAlone.runsHere}),
          ('old-router', {HostActsAlone.compatibilityMode}),
          ('with-vars', {HostActsAlone.setsVariables}),
          ('with-forward', {HostActsAlone.startsForward}),
        ]));
    expect(find.text(l10n.backupRestoreStartsForward), findsOneWidget);
    expect(find.text(l10n.backupRestoreRunsHere), findsOneWidget);
    expect(find.text(l10n.backupRestoreCompatibility), findsOneWidget);
    expect(find.text(l10n.backupRestoreSetsVariables), findsOneWidget);
  });

  group('safety settings it would turn down', () {
    const preview = RestorePreview(
      hosts: 1,
      keys: 0,
      snippets: 0,
      other: 0,
      replaces: 0,
      acting: [],
      weakens: ['ask_before_trusting_keys', 'dangerous_command_protection', 'notify_security_alerts', 'osc52_clipboard', 'snippet_destructive_confirm'],
    );

    Future<void> go(WidgetTester tester) async {
      final go = find.byKey(const ValueKey('restore-preview-go'));
      await tester.ensureVisible(go);
      await tester.pumpAndSettle();
      await tester.tap(go);
      await tester.pumpAndSettle();
    }

    testWidgets('each says what it does, none is ticked, and Restore keeps them all as they are', (tester) async {
      final (l10n, answers) = await open(tester, preview);
      expect(find.text(l10n.backupWeakensTitle), findsOneWidget);
      for (final words in [
        l10n.backupWeakensAskBeforeTrusting,
        l10n.backupWeakensDangerousCommands,
        l10n.backupWeakensSecurityAlerts,
        l10n.backupWeakensClipboard,
        l10n.backupWeakensSnippetConfirm,
      ]) {
        expect(find.text(words), findsOneWidget);
      }
      for (final key in preview.weakens) {
        expect(tester.widget<CheckboxListTile>(find.byKey(ValueKey('restore-preview-weakens-$key'))).value, isFalse, reason: key);
      }
      await go(tester);
      expect(answers.single?.takeSettings, isEmpty);
    });

    testWidgets('one ticked comes; Select all takes them all, for a person\'s own backup on a new device', (tester) async {
      final (l10n, answers) = await open(tester, preview);
      final clipboard = find.byKey(const ValueKey('restore-preview-weakens-osc52_clipboard'));
      await tester.ensureVisible(clipboard);
      await tester.pumpAndSettle();
      await tester.tap(clipboard);
      await tester.pumpAndSettle();
      final all = find.byKey(const ValueKey('restore-preview-weakens-all'));
      expect(find.descendant(of: all, matching: find.text(l10n.sshImportSelectAll)), findsOneWidget);
      await tester.ensureVisible(all);
      await tester.pumpAndSettle();
      await tester.tap(all);
      await tester.pumpAndSettle();
      expect(find.descendant(of: all, matching: find.text(l10n.sshImportDeselectAll)), findsOneWidget);
      await go(tester);
      expect(answers.single?.takeSettings, preview.weakens.toSet());
    });

    testWidgets('one ticked alone comes alone', (tester) async {
      final (_, answers) = await open(tester, preview);
      final clipboard = find.byKey(const ValueKey('restore-preview-weakens-osc52_clipboard'));
      await tester.ensureVisible(clipboard);
      await tester.pumpAndSettle();
      await tester.tap(clipboard);
      await tester.pumpAndSettle();
      await go(tester);
      expect(answers.single?.takeSettings, {'osc52_clipboard'});
    });

    testWidgets('nothing it would turn down: nothing of this is said', (tester) async {
      final (l10n, _) = await open(tester, const RestorePreview(hosts: 1, keys: 0, snippets: 0, other: 0, replaces: 0, acting: []));
      expect(find.text(l10n.backupWeakensTitle), findsNothing);
    });
  });

  // Found in a security review.
  group('host keys this device has not confirmed', () {
    final preview = RestorePreview(hosts: 1, keys: 0, snippets: 0, other: 0, replaces: 0, acting: const [], hostKeys: [
      const RestoreHostKey('bastion.example.com:22'),
      const RestoreHostKey('[2001:db8::7]:2222', via: 'jump.example.com:22'),
      for (var i = 0; i < 9; i++) RestoreHostKey('host-$i.example.com:22'),
    ]);

    Future<void> tapKey(WidgetTester tester, String key) async {
      final f = find.byKey(ValueKey(key));
      await tester.ensureVisible(f);
      await tester.pumpAndSettle();
      await tester.tap(f);
      await tester.pumpAndSettle();
    }

    testWidgets('are named, so many of them, and not taken unless ticked', (tester) async {
      final (l10n, answers) = await open(tester, preview);
      expect(find.text(l10n.backupRestoreHostKeys), findsOneWidget);
      expect(find.text('bastion.example.com:22'), findsOneWidget);
      expect(find.text('[2001:db8::7]:2222'), findsOneWidget);
      // Through a jump host, it says which; a direct one says none.
      expect(find.text(l10n.pfPageVia('jump.example.com:22')), findsOneWidget);
      expect(find.byKey(const ValueKey('restore-preview-host-key-via-bastion.example.com:22')), findsNothing);
      expect(find.text('host-${kRestorePreviewHostsNamed - 3}.example.com:22'), findsOneWidget);
      expect(find.text('host-${kRestorePreviewHostsNamed - 2}.example.com:22'), findsNothing);
      expect(find.text('+${11 - kRestorePreviewHostsNamed}'), findsOneWidget);
      expect(tester.widget<CheckboxListTile>(find.byKey(const ValueKey('restore-preview-host-keys-take'))).value, isFalse);
      await tapKey(tester, 'restore-preview-go');
      expect(answers.single?.takeHostKeys, isFalse);
    });

    testWidgets('ticked, they come: a person\'s own backup on a new device', (tester) async {
      final (l10n, answers) = await open(tester, preview);
      await tapKey(tester, 'restore-preview-host-keys-take');
      expect(find.text(l10n.backupRestoreTrustHostKeys), findsOneWidget);
      await tapKey(tester, 'restore-preview-go');
      expect(answers.single?.takeHostKeys, isTrue);
    });

    testWidgets('none: nothing of this is said', (tester) async {
      final (l10n, _) = await open(tester, const RestorePreview(hosts: 1, keys: 0, snippets: 0, other: 0, replaces: 0, acting: []));
      expect(find.text(l10n.backupRestoreHostKeys), findsNothing);
      expect(find.byKey(const ValueKey('restore-preview-host-keys-take')), findsNothing);
    });
  });

  testWidgets('a host label is shown with what would hide or reorder it, and only so many are named', (tester) async {
    final (_, _) = await open(
        tester,
        RestorePreview(hosts: 12, keys: 0, snippets: 0, other: 0, replaces: 0, acting: [
          ('web\u202Egnp.1', {HostActsAlone.runsCommand}),
          for (var i = 0; i < 11; i++) ('host-$i', {HostActsAlone.monitored}),
        ]));
    expect(find.text(r'web\u202egnp.1'), findsOneWidget);
    expect(find.text('host-${kRestorePreviewHostsNamed - 2}'), findsOneWidget);
    expect(find.text('host-${kRestorePreviewHostsNamed - 1}'), findsNothing);
    expect(find.text('+${12 - kRestorePreviewHostsNamed}'), findsOneWidget);
  });
}
