import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/features/help/guides/guide_providers.dart';
import 'package:zestssh/features/help/guides/guide_repository.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/help_dock_provider.dart';
import 'package:zestssh/providers/help_status_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/help_dock.dart';
import 'package:zestssh/ui/screens/help/guide_reader_screen.dart';
import 'package:zestssh/ui/screens/help/guides_screen.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';

/// Help > Guides (3.0): the search over the guides, the reader that draws a
/// guide natively, its offline copy and error states, and the "?" that
/// opens a page's guide, on a computer (the Help panel) and on a phone (a
/// page of its own).
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late SharedPreferences prefs;
  late _MemoryCopies copies;
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    prefs = await SharedPreferences.getInstance();
    copies = _MemoryCopies();
  });

  const page = '''---
title: Networks and jump hosts
---

## In plain words

A **network** is a place you work from.

<script>alert("x")</script>

## Set it up

1. Open **Networks** in the side rail.
2. Press **New network**.

   ![Step 2: the Networks page](/guides/img/networks-and-jump-hosts/desktop-networks.webp)

3. See [Keys](/guides/keys/) and [the whitepaper](https://zestssh.com/whitepaper/whitepaper.pdf).

![A tracking pixel](https://tracker.example/pixel.gif)

[Run it](javascript:alert(1))
''';

  GuideRepository repoWith(MockClientHandler handler) => GuideRepository(
        client: MockClient(handler),
        copies: copies,
        timeout: const Duration(milliseconds: 300),
      );

  Widget app(Widget child, {required GuideRepository repo, Locale? locale, bool inPanel = true}) => ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          guideRepositoryProvider.overrideWithValue(repo),
          guidesInHelpPanelProvider.overrideWithValue(inPanel),
          cloudStatusProvider.overrideWith((_) async => CloudStatus.ok),
          appVersionLabelProvider.overrideWith((_) async => '3.0.0'),
        ],
        child: MaterialApp(
          locale: locale,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
          home: Scaffold(body: child),
        ),
      );

  AppLocalizations l10nOf(WidgetTester tester) => AppLocalizations.of(tester.element(find.byType(Scaffold).first))!;

  group('the guides list', () {
    testWidgets('"network" finds Networks and jump hosts, and nothing found says so', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 900));
      final opened = <String>[];
      await tester.pumpWidget(app(GuidesScreen(embedded: true, onOpen: opened.add), repo: repoWith((_) async => http.Response('', 500))));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);
      // Every guide, before anything is typed.
      expect(find.byKey(const ValueKey('guide-row-keys')), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'network');
      await tester.pumpAndSettle();
      final rows = find.byWidgetPredicate((w) => w.key is ValueKey<String> && (w.key as ValueKey<String>).value.startsWith('guide-row-'));
      expect((tester.widget(rows.first).key as ValueKey<String>).value, 'guide-row-networks-and-jump-hosts');
      expect(find.byKey(const ValueKey('guide-row-keys')), findsNothing);
      await tester.tap(find.byKey(const ValueKey('guide-row-networks-and-jump-hosts')));
      expect(opened, ['networks-and-jump-hosts']);

      await tester.enterText(find.byType(TextField), 'kubernetes');
      await tester.pumpAndSettle();
      expect(find.text(l10n.guidesNoMatch('kubernetes')), findsOneWidget);
      expect(find.byKey(const ValueKey('guides-all-docs')), findsOneWidget);
      // Where guides come from, and that opening one sends nothing about you.
      expect(find.text(l10n.guidesFromDocs), findsOneWidget);
    });

    testWidgets('in another language it says the guides are English', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 900));
      await tester.pumpWidget(app(GuidesScreen(embedded: true, onOpen: (_) {}),
          repo: repoWith((_) async => http.Response('', 500)), locale: const Locale('de')));
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).guidesEnglishOnly), findsOneWidget);
      expect(l10nOf(tester).guidesEnglishOnly, isNot(contains('English')));
    });

    testWidgets('in English it does not', (tester) async {
      await tester.binding.setSurfaceSize(const Size(500, 900));
      await tester.pumpWidget(app(GuidesScreen(embedded: true, onOpen: (_) {}), repo: repoWith((_) async => http.Response('', 500))));
      await tester.pumpAndSettle();
      expect(find.text(l10nOf(tester).guidesEnglishOnly), findsNothing);
    });
  });

  group('the reader', () {
    testWidgets('draws the guide natively: headings, steps, its picture from the docs site only, HTML as text',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2400));
      final asked = <Uri>[];
      final guides = <String>[];
      final outside = <Uri>[];
      await tester.pumpWidget(app(
        GuideReaderScreen(
          slug: 'networks-and-jump-hosts',
          embedded: true,
          onOpenGuide: guides.add,
          onOpenOutside: outside.add,
        ),
        repo: repoWith((req) async {
          asked.add(req.url);
          return http.Response(page, 200, headers: {'content-type': 'text/markdown; charset=utf-8'});
        }),
      ));
      await tester.pumpAndSettle();
      expect(asked, [Uri.parse('https://docs.zestssh.com/guides/networks-and-jump-hosts.md')]);

      expect(find.text('Networks and jump hosts'), findsOneWidget); // the title, from the index
      expect(find.text('In plain words'), findsOneWidget);
      expect(find.text('Set it up'), findsOneWidget);
      expect(find.text('1.'), findsOneWidget);
      expect(find.text('3.'), findsOneWidget);
      // HTML is the text it is; no web view exists to run it.
      expect(find.textContaining('<script>alert("x")</script>', findRichText: true), findsOneWidget);

      // The docs site's picture is loaded from there; the tracker's is not
      // loaded at all, and its words show instead.
      final images = tester.widgetList<Image>(find.byType(Image)).toList();
      final sources = [for (final i in images) (i.image as NetworkImage).url];
      expect(sources, ['https://docs.zestssh.com/guides/img/networks-and-jump-hosts/desktop-networks.webp']);
      expect(find.text('A tracking pixel'), findsOneWidget);
      // The picture is named by its step for a screen reader (and its words
      // show where it does not load, as here: a test's network answers 400).
      expect(
        find.byWidgetPredicate((w) => w is Semantics && w.properties.image == true &&
            w.properties.label == 'Step 2: the Networks page'),
        findsOneWidget,
      );

      // A link to another guide opens it in the reader; the web outside.
      await tester.tapOnText(find.textRange.ofSubstring('Keys'));
      expect(guides, ['keys']);
      await tester.tapOnText(find.textRange.ofSubstring('the whitepaper'));
      expect(outside, [Uri.parse('https://zestssh.com/whitepaper/whitepaper.pdf')]);
      // A script link goes nowhere.
      await tester.tapOnText(find.textRange.ofSubstring('Run it'));
      expect(outside, hasLength(1));
      expect(guides, ['keys']);

      // Open in browser opens the guide's web page.
      await tester.ensureVisible(find.byKey(const ValueKey('guide-open-browser-foot')));
      await tester.tap(find.byKey(const ValueKey('guide-open-browser-foot')));
      expect(outside.last, Uri.parse('https://docs.zestssh.com/guides/networks-and-jump-hosts/'));
    });

    testWidgets('offline with a copy kept: the copy, and a line that says so', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 2000));
      var online = true;
      final repo = repoWith((req) async {
        if (!online) throw const SocketException('offline');
        return http.Response(page, 200);
      });
      await repo.fetch('networks-and-jump-hosts');
      online = false;
      await tester.pumpWidget(app(
        GuideReaderScreen(slug: 'networks-and-jump-hosts', embedded: true, onOpenGuide: (_) {}),
        repo: repo,
      ));
      await tester.pumpAndSettle();
      expect(find.text('In plain words'), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-saved-copy')), findsOneWidget);
      expect(find.text(l10nOf(tester).guideSavedCopy), findsOneWidget);

      // Back online, Try again replaces the line with the fresh guide.
      online = true;
      await tester.tap(find.text(l10nOf(tester).guideTryAgain));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-saved-copy')), findsNothing);
      expect(find.text('In plain words'), findsOneWidget);
    });

    testWidgets('offline with no copy: what went wrong, ZS-1960, Try again, Open in browser, Copy details',
        (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 900));
      var online = false;
      await tester.pumpWidget(app(
        GuideReaderScreen(slug: 'keys', embedded: true, onOpenGuide: (_) {}, onOpenOutside: (_) {}),
        repo: repoWith((req) async {
          if (!online) throw const SocketException('Failed host lookup');
          return http.Response('## In plain words\n\nKeys.', 200);
        }),
      ));
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);
      final message = tester.widget<Text>(find.byKey(const ValueKey('guide-failed-message'))).data!;
      expect(message, startsWith(l10n.guideNotReached));
      expect(message, endsWith('(ZS-1960)'));
      expect(find.byKey(const ValueKey('guide-try-again')), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-failed-browser')), findsOneWidget);

      // Copy details puts a report on the clipboard that names the code and
      // what failed.
      String? copied;
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String;
        return null;
      });
      await tester.tap(find.text(l10n.desktopShellCopyDetails));
      await tester.pump();
      expect(copied, contains('Code: ZS-1960 (A guide could not be loaded)'));
      expect(copied, contains('Where: Help > Guides, the guide keys'));
      expect(copied, contains('the docs site could not be reached'));
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
      await tester.pump(const Duration(seconds: 3));

      online = true;
      await tester.tap(find.byKey(const ValueKey('guide-try-again')));
      await tester.pumpAndSettle();
      expect(find.text('Keys.'), findsOneWidget);
    });

    testWidgets('an answer that is no guide: ZS-1961', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 900));
      await tester.pumpWidget(app(
        GuideReaderScreen(slug: 'keys', embedded: true, onOpenGuide: (_) {}),
        repo: repoWith((req) async => http.Response('Not found', 404)),
      ));
      await tester.pumpAndSettle();
      final message = tester.widget<Text>(find.byKey(const ValueKey('guide-failed-message'))).data!;
      expect(message, '${l10nOf(tester).guideUnreadable} (ZS-1961)');
    });

    testWidgets('in another language the guide says it is English', (tester) async {
      await tester.binding.setSurfaceSize(const Size(600, 1600));
      await tester.pumpWidget(app(
        GuideReaderScreen(slug: 'keys', embedded: true, onOpenGuide: (_) {}),
        repo: repoWith((req) async => http.Response('## In plain words\n\nKeys.', 200)),
        locale: const Locale('zh'),
      ));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('guide-english-only')), findsOneWidget);
    });
  });

  group('the "?" of a page', () {
    testWidgets('on a computer it opens the guide in the Help panel', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1400, 900));
      late ProviderContainer container;
      await tester.pumpWidget(app(
        Consumer(builder: (context, ref, _) {
          container = ProviderScope.containerOf(context);
          return const Center(child: GuideTitle(feature: 'networks', title: Text('Networks')));
        }),
        repo: repoWith((_) async => http.Response('## Hi', 200)),
      ));
      await tester.pumpAndSettle();
      final button = find.byKey(const ValueKey('guide-help-networks'));
      expect(button, findsOneWidget);
      expect(tester.widget<IconButton>(button).tooltip, l10nOf(tester).guideHelpTooltip('Networks and jump hosts'));
      await tester.tap(button);
      await tester.pump();
      expect(container.read(helpDockProvider), HelpPage.guide);
      expect(container.read(helpDockGuideProvider), 'networks-and-jump-hosts');
    });

    testWidgets('on a phone it opens the guide as a page of its own', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 800));
      final router = GoRouter(routes: [
        GoRoute(
          path: '/',
          builder: (context, state) => Scaffold(
            appBar: AppBar(actions: const [GuideHelpButton(feature: 'alerts', size: 20)]),
          ),
        ),
        GoRoute(
          path: Routes.guide,
          builder: (context, state) => GuideReaderScreen(slug: state.extra! as String, onOpenGuide: (_) {}),
        ),
      ]);
      await tester.pumpWidget(ProviderScope(
        overrides: [
          sharedPreferencesProvider.overrideWithValue(prefs),
          guideRepositoryProvider.overrideWithValue(repoWith((req) async => http.Response('## In plain words\n\nAlerts.', 200))),
          guidesInHelpPanelProvider.overrideWithValue(false),
        ],
        child: MaterialApp.router(
          routerConfig: router,
          localizationsDelegates: AppLocalizations.localizationsDelegates,
          supportedLocales: AppLocalizations.supportedLocales,
        ),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guide-help-alerts')));
      await tester.pumpAndSettle();
      expect(find.byType(GuideReaderScreen), findsOneWidget);
      expect(find.text('Alerts.'), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-open-browser')), findsOneWidget);
    });

    testWidgets('a feature no guide names shows no "?"', (tester) async {
      await tester.pumpWidget(app(const GuideHelpButton(feature: 'no_such_feature'),
          repo: repoWith((_) async => http.Response('', 500))));
      expect(find.byType(IconButton), findsNothing);
    });
  });

  group('the Help panel', () {
    Widget dock(HelpPage start, GuideRepository repo) => app(
          Row(children: [
            const Expanded(child: SizedBox()),
            HelpDock(
              captureScreenshot: ({required bool redacted}) async => Uint8List(0),
              onCopyRedactedScreenshot: () {},
              onOpenShortcuts: () {},
              onAbout: () {},
            ),
          ]),
          repo: repo,
        );

    testWidgets('Guides heads the panel, opens the search, and a guide opens with Back to the list', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      await tester.pumpWidget(dock(HelpPage.home, repoWith((req) async => http.Response('## In plain words\n\nSFTP.', 200))));
      await tester.pumpAndSettle();
      final container = ProviderScope.containerOf(tester.element(find.byType(HelpDock)));
      container.read(helpDockProvider.notifier).state = HelpPage.home;
      await tester.pumpAndSettle();
      final l10n = l10nOf(tester);
      final guidesRow = find.byKey(const ValueKey('help-guides'));
      expect(guidesRow, findsOneWidget);
      expect(tester.getTopLeft(guidesRow).dy, lessThan(tester.getTopLeft(find.text(l10n.helpFaqImport)).dy));

      await tester.tap(guidesRow);
      await tester.pumpAndSettle();
      expect(container.read(helpDockProvider), HelpPage.guides);
      await tester.enterText(find.byType(TextField), 'upload');
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('guide-row-sftp')));
      await tester.pumpAndSettle();
      expect(container.read(helpDockProvider), HelpPage.guide);
      expect(container.read(helpDockGuideProvider), 'sftp');
      expect(find.text('SFTP.'), findsOneWidget);

      // Back returns to the list as it was left.
      await tester.tap(find.bySemanticsLabel(l10n.back));
      await tester.pumpAndSettle();
      expect(container.read(helpDockProvider), HelpPage.guides);
      expect(find.byKey(const ValueKey('guide-row-sftp')), findsOneWidget);
      expect(find.byKey(const ValueKey('guide-row-keys')), findsNothing);
    });
  });
}

/// The copies kept in memory: a widget test's clock runs no file I/O.
class _MemoryCopies implements GuideCopies {
  final Map<String, String> _kept = {};

  @override
  Future<SavedGuide?> read(String slug) async {
    final text = _kept[slug];
    return text == null ? null : SavedGuide(text, DateTime(2026, 10, 23));
  }

  @override
  Future<void> write(String slug, String markdown) async => _kept[slug] = markdown;
}
