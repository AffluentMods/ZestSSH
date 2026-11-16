// An automation API key is shown once, when it is made, and only its hash is
// kept (show-once, as GitHub and Stripe tokens
// are). What was there: the key itself was kept in secure storage
// ('automation_api_keys', AutomationApiKey.key) and could be shown and copied
// again from its row, on a phone and on a computer, and the automation wizard
// put the key it was given into its examples. Now the store keeps each key's
// SHA-256 and its last 4 characters, a store from before is written again at
// once without the keys, the one place a key is shown is the dialog that
// opens as it is made, rows show only its last 4 characters and copy nothing,
// a scheduled run is checked by its key's id (its launch token is what
// proves it), and the wizard's examples carry a key made on its page, or
// YOUR_KEY.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart' show defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/widgets/triggers_view.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/automation_api_key.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/workflow_provider.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';
import 'package:zestssh/ui/screens/settings/automation_settings_screen.dart';
import 'package:zestssh/utils/secret_clipboard.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(true);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

const _store = 'automation_api_keys';
// Made up for this test; shaped as the app's own keys are.
const _legacyKey = 'LegacyKeyMadeUpForThisTestOnly0123456789abcdWXYZ';

String _hex(String s) => sha256.convert(utf8.encode(s)).toString();

/// A key's record as versions before show-once kept it: the key itself.
Map<String, Object?> _legacy({String id = 'k-old', String key = _legacyKey, DateTime? expiresAt}) => {
      'id': id,
      'label': 'old phone',
      'key': key,
      'createdAt': DateTime(2026, 9, 1).toIso8601String(),
      if (expiresAt != null) 'expiresAt': expiresAt.toIso8601String(),
    };

Future<String?> _stored() => const FlutterSecureStorage().read(key: _store);

/// Every text painted or held for editing on screen.
List<String> _textsOnScreen(WidgetTester tester) => [
      for (final w in tester.allWidgets)
        if (w is Text)
          w.data ?? w.textSpan?.toPlainText() ?? ''
        else if (w is SelectableText)
          w.data ?? w.textSpan?.toPlainText() ?? ''
        else if (w is RichText)
          w.text.toPlainText()
        else if (w is EditableText)
          w.controller.text,
    ];

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final en = lookupAppLocalizations(const Locale('en'));

  group('the store', () {
    setUp(() => SharedPreferences.setMockInitialValues(const {}));

    Future<AutomationKeysNotifier> load(Map<String, String> values) async {
      FlutterSecureStorage.setMockInitialValues(values);
      final n = AutomationKeysNotifier(const FlutterSecureStorage());
      await n.ready;
      return n;
    }

    test('a store from before show-once loads, its keys still work, and the keys leave it at once', () async {
      final n = await load({
        _store: jsonEncode([
          _legacy(),
          _legacy(id: 'k-two', key: 'AnotherMadeUpLegacyKeyForThisTest9876543210qrst'),
        ]),
      });
      expect(n.state.map((k) => k.id), ['k-old', 'k-two']);
      expect(n.state.first.hash, _hex(_legacyKey));
      expect(n.state.first.hint, 'WXYZ');
      expect(n.state.first.displayHint, '•••• WXYZ');

      final stored = (await _stored())!;
      expect(stored, isNot(contains(_legacyKey)));
      expect(stored, isNot(contains('AnotherMadeUpLegacyKeyForThisTest9876543210qrst')));
      for (final e in jsonDecode(stored) as List) {
        final m = e as Map<String, dynamic>;
        expect(m.containsKey('key'), isFalse);
        expect(m.keys, containsAll(<String>['id', 'label', 'hash', 'hint', 'createdAt']));
        expect(m['hash'], matches(RegExp(r'^[0-9a-f]{64}$')));
      }

      expect(n.validateAndMarkUsed(_legacyKey), isTrue);
      expect(n.isValidKey('AnotherMadeUpLegacyKeyForThisTest9876543210qrst'), isTrue);
      expect(n.keyForValue(_legacyKey)!.id, 'k-old');
    });

    test('a store already without keys is read as it is and not written again', () async {
      final record = AutomationApiKey.fromSecret(
          id: 'k-1', label: 'tasker', secret: 'zk_made-up-key-for-this-test', createdAt: DateTime(2026, 10, 1));
      final json = AutomationApiKey.encodeList([record]);
      final n = await load({_store: json});
      expect(await _stored(), json);
      expect(n.validateAndMarkUsed('zk_made-up-key-for-this-test'), isTrue);
    });

    test('a key made is returned once beside its record, which keeps only its hash and last 4 characters', () async {
      final n = await load({});
      final made = n.createKey('deploy', expiresAt: DateTime.now().add(const Duration(days: 30)));
      expect(made.secret, hasLength(48));
      expect(made.key.hash, _hex(made.secret));
      expect(made.key.hint, made.secret.substring(44));
      await Future<void>.delayed(Duration.zero);
      final stored = (await _stored())!;
      expect(stored, isNot(contains(made.secret)));
      expect(stored, contains(made.key.hash));

      expect(n.validateAndMarkUsed(made.secret), isTrue);
      expect(n.state.single.lastUsedAt, isNotNull);
      expect(n.keyForValue(made.secret)!.id, made.key.id);
      expect(n.isValidKey('${made.secret}x'), isFalse);
      expect(n.isValidKey(made.key.hash), isFalse, reason: 'the hash is not a key');
      expect(n.isValidKey(made.key.hint), isFalse);
      // Renamed, it is the same key.
      n.renameKey(made.key.id, 'deploy 2');
      expect(n.state.single.label, 'deploy 2');
      expect(n.validateAndMarkUsed(made.secret), isTrue);
    });

    test('the lockout is as it was: five wrong keys lock, a right key still passes and clears it', () async {
      final n = await load({});
      final made = n.createKey('deploy');
      for (var i = 0; i < 5; i++) {
        expect(n.validateAndMarkUsed('wrong-$i'), isFalse);
      }
      await Future<void>.delayed(Duration.zero);
      final locked = jsonDecode((await const FlutterSecureStorage().read(key: 'automation_rate_limit'))!) as Map;
      expect(locked['failedAttempts'], 5);
      expect(locked['lockedUntil'], isNotNull);
      // Locked: a wrong key is not counted again.
      expect(n.isValidKey('wrong-again'), isFalse);
      await Future<void>.delayed(Duration.zero);
      expect((jsonDecode((await const FlutterSecureStorage().read(key: 'automation_rate_limit'))!) as Map)['failedAttempts'], 5);
      // A valid key always passes first.
      expect(n.validateAndMarkUsed(made.secret), isTrue);
      await Future<void>.delayed(Duration.zero);
      final cleared = jsonDecode((await const FlutterSecureStorage().read(key: 'automation_rate_limit'))!) as Map;
      expect(cleared['failedAttempts'], 0);
      expect(cleared.containsKey('lockedUntil'), isFalse);
    });

    test("a scheduled run's key is checked by its id: there, not expired, and marked used", () async {
      final n = await load({
        _store: jsonEncode([
          _legacy(),
          _legacy(id: 'k-gone', key: 'ExpiredMadeUpLegacyKeyForThisTest555555555', expiresAt: DateTime(2026, 1, 1)),
        ]),
      });
      expect(n.validateIdAndMarkUsed('k-old'), isTrue);
      expect(n.keyForId('k-old')!.lastUsedAt, isNotNull);
      expect(n.validateIdAndMarkUsed('k-gone'), isFalse, reason: 'expired');
      expect(n.validateIdAndMarkUsed('k-none'), isFalse, reason: 'not there');
      n.deleteKey('k-old');
      expect(n.validateIdAndMarkUsed('k-old'), isFalse, reason: 'revoked');
    });
  });

  group('the dispatcher', () {
    late AppDatabase db;
    late ProviderContainer container;

    setUp(() async {
      final at = DateTime(2026, 10, 16);
      FlutterSecureStorage.setMockInitialValues({
        _store: jsonEncode([
          _legacy(id: 'k-1'),
          {
            ...AutomationApiKey.fromSecret(
                    id: 'k-2', label: 'web only', secret: 'zk_one-host-key', createdAt: at, scopeConnectionId: 'h-web')
                .toJson(),
          },
          _legacy(id: 'k-3', key: 'ExpiredMadeUpLegacyKeyForThisTest555555555', expiresAt: DateTime(2026, 1, 1)),
        ]),
      });
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      db = AppDatabase.forTesting(NativeDatabase.memory());
      container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
      ]);
      container.read(databaseSessionProvider.notifier).seed(db);
      container.read(automationProvider.notifier).setEnabled(true);
      // A workflow that is off: a run let in is written to history as not run.
      await container.read(workflowsProvider.notifier).addWorkflow(Workflow(
            id: 'w-none',
            name: 'Nightly',
            enabled: false,
            createdAt: at,
            steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, connectionId: 'c1', command: 'uptime')],
          ));
    });

    tearDown(() async {
      container.dispose();
      await db.close();
    });

    Future<AutomationBlocked?> ask(Map<String, dynamic> request) async {
      await container.read(automationProvider.notifier).handleAutomation(request);
      return container.read(automationProvider).blocked;
    }

    test("a scheduler's run names its key by id; the key itself is never needed for it", () async {
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'api_key_id': 'k-1'}),
          isNot(AutomationBlocked.keyNotKnown));
      expect(container.read(automationKeysProvider).firstWhere((k) => k.id == 'k-1').lastUsedAt, isNotNull);
    });

    test('an expired or unknown id is refused, and a key for one host keeps to it by id too', () async {
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'api_key_id': 'k-3'}), AutomationBlocked.keyNotKnown);
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'api_key_id': 'k-none'}),
          AutomationBlocked.keyNotKnown);
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'api_key_id': 'k-2'}), AutomationBlocked.otherHost);
    });

    test('a link still presents the key itself; a wrong one with an id beside it is not let in by the id', () async {
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'key': _legacyKey}),
          isNot(AutomationBlocked.keyNotKnown));
      expect(await ask({'action': 'workflow', 'workflow_id': 'w-none', 'key': 'wrong', 'api_key_id': 'k-1'}),
          AutomationBlocked.keyNotKnown);
    });
  });

  group('on screen', () {
    String? clipboard;

    setUp(() {
      clipboard = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform,
          (call) async {
        switch (call.method) {
          case 'Clipboard.setData':
            clipboard = (call.arguments as Map)['text'] as String?;
            return null;
          case 'Clipboard.getData':
            return clipboard == null ? null : <String, Object?>{'text': clipboard};
        }
        return null;
      });
    });

    tearDown(() async {
      await SecretClipboard.clear();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
    });

    Future<ProviderContainer> pump(WidgetTester tester, Widget page, {Map<String, String> secure = const {}}) async {
      tester.view.physicalSize = const Size(1400, 2400);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      FlutterSecureStorage.setMockInitialValues(Map.of(secure));
      SharedPreferences.setMockInitialValues(const {});
      final prefs = await SharedPreferences.getInstance();
      final db = AppDatabase.forTesting(NativeDatabase.memory());
      addTearDown(() => tester.runAsync(db.close));
      final c = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(prefs),
        isProProvider.overrideWith((ref) => _Pro()),
      ]);
      addTearDown(c.dispose);
      c.read(databaseSessionProvider.notifier).seed(db);
      c.read(automationEnabledProvider.notifier).set(true);
      await tester.runAsync(() => c.read(automationKeysProvider.notifier).ready);
      await tester.pumpWidget(UncontrolledProviderScope(
        container: c,
        child: MaterialApp(
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          locale: const Locale('en'),
          home: Scaffold(body: page),
        ),
      ));
      await tester.pumpAndSettle();
      return c;
    }

    /// In the dialog that shows a key once: the key, copied, then put away.
    Future<String> takeFromOnceDialog(WidgetTester tester, ProviderContainer c) async {
      final shown = find.byKey(const ValueKey('api-key-once-secret'));
      expect(shown, findsOneWidget);
      final secret = tester.widget<SelectableText>(shown).data!;
      expect(find.text(en.triggersViewSaveKeyExplainer), findsOneWidget);
      final record = c.read(automationKeysProvider).last;
      expect(record.hash, _hex(secret));
      await tester.tap(find.byKey(const ValueKey('api-key-once-copy')));
      await tester.pumpAndSettle();
      expect(clipboard, secret);
      // Done only once the person says it is saved: in the footer, the
      // dialog's main button (3.4), off until then; Escape leaves it.
      final done = find.byKey(const ValueKey('api-key-once-done'));
      expect(find.descendant(of: done, matching: find.text(en.done)), findsOneWidget);
      await tester.tap(done);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(shown, findsOneWidget, reason: 'not closed before the key is said to be saved');
      await tester.tap(find.text(en.triggersViewConfirmSavedKey));
      await tester.pump();
      await tester.tap(done);
      await tester.pumpAndSettle();
      expect(shown, findsNothing);
      // The clipboard is cleared 45 seconds later, as every secret copied is.
      await tester.pump(const Duration(seconds: 46));
      expect(clipboard, isEmpty);
      await tester.pumpAndSettle();
      return secret;
    }

    testWidgets("a computer's API keys: a key made is shown once, and its row shows its last 4 characters and copies nothing",
        (tester) async {
      final c = await pump(tester, const TriggersView(), secure: {_store: jsonEncode([_legacy()])});
      // The key from before: its last 4 characters, never the key.
      expect(find.text('•••• WXYZ'), findsOneWidget);
      expect(_textsOnScreen(tester).where((t) => t.contains(_legacyKey)), isEmpty);

      await tester.tap(find.text(en.zestAutoCreateApiKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'deploy box');
      await tester.tap(find.byKey(const ValueKey('create-api-key-go')));
      await tester.pumpAndSettle();
      final secret = await takeFromOnceDialog(tester, c);

      expect(_textsOnScreen(tester).where((t) => t.contains(secret)), isEmpty, reason: 'shown once, in its dialog');
      expect(find.text('•••• ${secret.substring(44)}'), findsOneWidget);
      expect(find.text(en.triggersViewCopyToClipboard), findsNothing);
      // No row has a Copy (with no workflows there is no deep link to copy).
      expect(find.byTooltip(en.copy), findsNothing);
      expect(find.byWidgetPredicate((w) => w is Tooltip && w.message == en.triggersViewRevokeTooltip), findsNWidgets(2));
      expect(await tester.runAsync(_stored), isNot(contains(secret)));
      // API keys and deep links, and no Webhooks "Coming soon" over nothing
      // (removed after a 3.0 docs review).
      // (Section labels are drawn in capitals.)
      expect(find.text(en.zestAutoSectionApiKeys.toUpperCase()), findsOneWidget);
      expect(find.text(en.zestAutoSectionDeepLinks.toUpperCase()), findsOneWidget);
      expect(find.text('WEBHOOKS'), findsNothing);
      expect(find.textContaining(RegExp('webhook|coming soon', caseSensitive: false)), findsNothing);
    });

    testWidgets("a phone's API keys: a key made is shown once, and tapping a key's card copies nothing", (tester) async {
      final c = await pump(tester, const AutomationSettingsScreen(), secure: {_store: jsonEncode([_legacy()])});
      await tester.tap(find.text(en.settingsMobApiKeys));
      await tester.pumpAndSettle();
      expect(find.text('•••• WXYZ'), findsOneWidget);
      expect(_textsOnScreen(tester).where((t) => t.contains(_legacyKey)), isEmpty);

      await tester.tap(find.byTooltip(en.settingsMobCreateApiKey));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'shortcuts');
      // The shell's main button, in its footer (3.4: it was a FilledButton).
      await tester.tap(find.byKey(const ValueKey('zest-dialog-primary')));
      await tester.pumpAndSettle();
      final secret = await takeFromOnceDialog(tester, c);

      expect(_textsOnScreen(tester).where((t) => t.contains(secret)), isEmpty);
      clipboard = null;
      await tester.tap(find.text('shortcuts'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('•••• ${secret.substring(44)}'));
      await tester.pumpAndSettle();
      expect(clipboard, isNull, reason: 'a card copies nothing');
      expect(find.byKey(const ValueKey('api-key-once-secret')), findsNothing);
    });

    testWidgets("the wizard's examples carry YOUR_KEY, or a key made on its page and shown once", (tester) async {
      final c = await pump(tester, const AutomationWizardScreen(), secure: {_store: jsonEncode([_legacy()])});
      await tester.runAsync(() => c.read(workflowsProvider.notifier).addWorkflow(Workflow(
            id: 'wf-1',
            name: 'Nightly',
            createdAt: DateTime(2026, 10, 1),
            steps: const [WorkflowStep(id: 's1', type: WorkflowStepType.execute, connectionId: 'c1', command: 'uptime')],
          )));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.autoWizWorkflowTitle));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.next));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Nightly'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(en.next));
      await tester.pumpAndSettle();

      // A key from before cannot be put in: the placeholder, and words to paste a key there.
      expect(find.text(en.autoWizKeyPlaceholderNote(automationKeyPlaceholder)), findsOneWidget);
      expect(find.text('zestssh://workflow?key=$automationKeyPlaceholder&name=Nightly'), findsOneWidget);
      expect(_textsOnScreen(tester).where((t) => t.contains(_legacyKey)), isEmpty);
      expect(find.byKey(const ValueKey('auto-wiz-credential-warning')), findsNothing, reason: 'nothing secret in them');

      await tester.tap(find.text(en.autoWizMakeKeyForThis));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'MacroDroid');
      await tester.tap(find.text(en.create).last);
      await tester.pumpAndSettle();
      final secret = await takeFromOnceDialog(tester, c);

      expect(find.text('zestssh://workflow?key=$secret&name=Nightly'), findsOneWidget);
      expect(find.text(en.autoWizKeyMadeHere('MacroDroid')), findsOneWidget);
      // Where a leaked key goes: on a phone in Settings, Automation, API
      // keys; on a computer under Automation, API keys (it said "in
      // Settings" on both).
      final phone = defaultTargetPlatform == TargetPlatform.android || defaultTargetPlatform == TargetPlatform.iOS;
      expect(find.text(phone ? en.autoWizCredentialWarningPhone : en.autoWizCredentialWarning), findsOneWidget);
      expect(find.text(phone ? en.autoWizCredentialWarning : en.autoWizCredentialWarningPhone), findsNothing);
      expect(find.text(en.autoWizMakeKeyForThis), findsNothing);
      expect(c.read(automationKeysProvider).map((k) => k.label), ['old phone', 'MacroDroid']);
    }, variant: const TargetPlatformVariant({TargetPlatform.android, TargetPlatform.windows}));
  });

  test('the words: a key is shown once, nothing says it can be copied again or taken from Settings', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      expect(t.autoWizKeyPlaceholderNote('YOUR_KEY'), contains('YOUR_KEY'));
      expect(t.autoWizKeyMadeHere('Tasker'), contains('Tasker'));
      expect(t.wfEditTriggerHelp, contains('YOUR_KEY'));
      expect(t.zestAutoDeepLinksExplainer, contains('YOUR_KEY'));
      if (locale.languageCode != 'en') {
        for (final pair in [
          (t.triggersViewSaveKeyExplainer, en.triggersViewSaveKeyExplainer),
          (t.triggersViewCreateKeyExplainer, en.triggersViewCreateKeyExplainer),
          (t.autoWizKeyPlaceholderNote('YOUR_KEY'), en.autoWizKeyPlaceholderNote('YOUR_KEY')),
          (t.autoWizMakeKeyForThis, en.autoWizMakeKeyForThis),
        ]) {
          expect(pair.$1, isNot(pair.$2), reason: '$locale');
        }
      }
    }
    expect(en.triggersViewCreateKeyExplainer, isNot(contains('can be copied again from its row')));
    expect(en.triggersViewSaveKeyExplainer, isNot(contains('We do retain it')));
    expect(en.triggersViewSaveKeyExplainer, contains('only time'));
    expect(en.wfEditTriggerHelp, isNot(contains('from Settings')));
  });
}
