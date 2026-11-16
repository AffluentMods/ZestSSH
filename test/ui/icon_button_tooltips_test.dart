import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/theme/app_theme.dart';
import 'package:zestssh/ui/screens/terminal/widgets/password_prompt_dialog.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';

/// Every icon button of the app says what it does (3.0): a
/// tooltip is what a screen reader reads out for a button that has only an
/// icon, and what a computer shows on hover. Forty-four had none: the
/// buttons that clear a search, close a panel, go back, delete, show or hide
/// a password, make the terminal's text smaller or larger. Two more had
/// theirs through a Tooltip around them; each carries its own now, once.
void main() {
  /// The IconButtons of [files] whose call names no tooltip, and those that
  /// name one inside a Tooltip around them (read out twice), as "file:line".
  List<String> withoutTooltip(Map<String, String> files) {
    final found = <String>[];
    final start = RegExp(r'\bIconButton(\.filled|\.outlined|\.filledTonal)?\(');
    for (final MapEntry(key: path, value: text) in files.entries) {
      final lines = text.replaceAll('\r\n', '\n').split('\n');
      for (var i = 0; i < lines.length; i++) {
        final m = start.firstMatch(lines[i]);
        if (m == null) continue;
        // The call, up to the bracket that closes it.
        final call = StringBuffer();
        var depth = 0;
        for (var j = i; j < lines.length && j < i + 60; j++) {
          final part = j == i ? lines[i].substring(m.start) : lines[j];
          call.writeln(part);
          depth += '('.allMatches(part).length - ')'.allMatches(part).length;
          if (depth <= 0) break;
        }
        final wrapped = lines[i].trimLeft().startsWith('child: IconButton') &&
            [for (var k = i - 1; k >= 0 && k >= i - 3; k--) lines[k]].any((l) => l.contains('Tooltip('));
        if (!call.toString().contains('tooltip:') || wrapped) found.add('$path:${i + 1}');
      }
    }
    return found..sort();
  }

  test('every icon button says what it does', () {
    final files = {
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
          file.path.replaceAll('\\', '/'): file.readAsStringSync(),
    };
    expect(files, isNotEmpty);
    expect(withoutTooltip(files), isEmpty, reason: "give it a tooltip in the person's language");
  });

  final en = lookupAppLocalizations(const Locale('en'));

  testWidgets("a password's show and hide button says what pressing it does, in each state", (tester) async {
    SharedPreferences.setMockInitialValues(const {});
    final prefs = await SharedPreferences.getInstance();
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        theme: AppTheme.dark(),
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () => showDialog<void>(
                  context: context,
                  builder: (_) => PasswordPromptDialog(
                      request: PasswordPromptRequest(
                          host: 'web-01.example.com',
                          username: 'deploy',
                          completer: Completer<PasswordPromptResult?>()))),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final toggle = find.byWidgetPredicate((w) => w is IconButton && (w.tooltip == en.zestDialogShow || w.tooltip == en.zestDialogHide));
    expect(tester.widget<IconButton>(toggle).tooltip, en.zestDialogShow, reason: 'hidden: it shows');
    await tester.tap(toggle);
    await tester.pumpAndSettle();
    expect(tester.widget<IconButton>(toggle).tooltip, en.zestDialogHide, reason: 'shown: it hides');
  });

  testWidgets("a list's search field: its clear button is named", (tester) async {
    final controller = TextEditingController(text: 'web');
    addTearDown(controller.dispose);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: Scaffold(body: ZestListSearchField(controller: controller, hintText: 'Search', onChanged: (_) {})),
    ));
    await tester.pump();
    expect(find.byTooltip(en.emptyClearSearch), findsOneWidget);
  });

  test('the check itself finds a button with no tooltip and one with two, and not one with one', () {
    const without = '''
      IconButton(
        icon: const Icon(LucideIcons.x),
        onPressed: close,
      ),
''';
    const withOne = '''
      IconButton(
        tooltip: l10n.close,
        icon: const Icon(LucideIcons.x),
        onPressed: close,
      ),
''';
    const twice = '''
      Tooltip(
        message: l10n.close,
        child: IconButton(
          tooltip: l10n.close,
          icon: const Icon(LucideIcons.x),
          onPressed: close,
        ),
      ),
''';
    expect(withoutTooltip({'a': without}), ['a:1']);
    expect(withoutTooltip({'b': withOne}), isEmpty);
    expect(withoutTooltip({'c': twice}), ['c:3']);
  });
}
