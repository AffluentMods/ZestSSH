import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/screens/sftp/widgets/sftp_breadcrumb_bar.dart';

/// The path bar of a file pane: which folders of a long path it shows, and
/// the list behind its "…" (the list had the
/// folder nearest to the current one at the bottom).
void main() {
  Future<List<String>> pumpBar(WidgetTester tester, String path) async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final went = <String>[];
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(width: 600, child: SftpBreadcrumbBar(path: path, onNavigate: went.add)),
          ),
        ),
      ),
    ));
    return went;
  }

  /// The folders the open list names, from its top to its bottom, as the
  /// screen has them (not as the code lists them).
  List<String> listed(WidgetTester tester, List<String> names) {
    final byHeight = {for (final n in names) n: tester.getCenter(find.text(n)).dy};
    final sorted = names.toList()..sort((a, b) => byHeight[a]!.compareTo(byHeight[b]!));
    // No two on one line: a list, top to bottom.
    expect(byHeight.values.toSet().length, names.length);
    return sorted;
  }

  List<String?> values(WidgetTester tester) =>
      tester.widgetList<PopupMenuItem<String>>(find.byType(PopupMenuItem<String>)).map((i) => i.value).toList();

  testWidgets('the list behind "…" has the folder nearest to the current one at the top, and each goes to its folder',
      (tester) async {
    final went = await pumpBar(tester, '/srv/www/site/static/img/icons');
    // Shown: the root and the last two. The four between them are behind "…".
    for (final shown in ['/', 'img', 'icons']) {
      expect(find.text(shown), findsOneWidget);
    }
    for (final hidden in ['srv', 'www', 'site', 'static']) {
      expect(find.text(hidden), findsNothing);
    }

    await tester.tap(find.text('…'));
    await tester.pumpAndSettle();
    expect(listed(tester, ['srv', 'www', 'site', 'static']), ['static', 'site', 'www', 'srv']);
    expect(values(tester), ['/srv/www/site/static', '/srv/www/site', '/srv/www', '/srv']);

    await tester.tap(find.text('site'));
    await tester.pumpAndSettle();
    expect(went, ['/srv/www/site']);
    expect(find.byType(PopupMenuItem<String>), findsNothing, reason: 'the list closes on a choice');

    // The one at the top is the folder just above what the bar shows.
    await tester.tap(find.text('…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('static'));
    await tester.pumpAndSettle();
    expect(went, ['/srv/www/site', '/srv/www/site/static']);

    // And the one at the bottom is the folder just under the root.
    await tester.tap(find.text('…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('srv'));
    await tester.pumpAndSettle();
    expect(went.last, '/srv');
  });

  testWidgets('a path on a Windows drive: the same order, and each goes to its folder on that drive', (tester) async {
    final went = await pumpBar(tester, r'C:\Users\alex\Projects\web\static\img');
    for (final shown in ['C:', 'static', 'img']) {
      expect(find.text(shown), findsOneWidget);
    }
    await tester.tap(find.text('…'));
    await tester.pumpAndSettle();
    expect(listed(tester, ['Users', 'alex', 'Projects', 'web']), ['web', 'Projects', 'alex', 'Users']);
    expect(values(tester), [
      r'C:\Users\alex\Projects\web',
      r'C:\Users\alex\Projects',
      r'C:\Users\alex',
      r'C:\Users',
    ]);
    await tester.tap(find.text('alex'));
    await tester.pumpAndSettle();
    expect(went, [r'C:\Users\alex']);
  });

  testWidgets('the shortest path that hides anything hides two folders; a path of four parts or fewer hides nothing',
      (tester) async {
    var went = await pumpBar(tester, '/srv/www/site/static');
    for (final shown in ['/', 'site', 'static']) {
      expect(find.text(shown), findsOneWidget);
    }
    await tester.tap(find.text('…'));
    await tester.pumpAndSettle();
    expect(listed(tester, ['srv', 'www']), ['www', 'srv']);
    expect(values(tester), ['/srv/www', '/srv']);
    await tester.tap(find.text('www'));
    await tester.pumpAndSettle();
    expect(went, ['/srv/www']);

    went = await pumpBar(tester, '/srv/www/site');
    expect(find.text('…'), findsNothing);
    for (final shown in ['/', 'srv', 'www', 'site']) {
      expect(find.text(shown), findsOneWidget);
    }
    // A folder above the current one goes there; the current one is no button.
    await tester.tap(find.text('www'));
    await tester.pump();
    await tester.tap(find.text('site'));
    await tester.pump();
    expect(went, ['/srv/www']);
  });
}
