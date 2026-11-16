import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';

/// Every icon that is tapped says what it does (3.0), as
/// every icon button does (icon_button_tooltips_test.dart): twenty-one icons
/// drawn with an InkWell or a GestureDetector of their own said nothing to a
/// screen reader and showed nothing on hover: the close of a computer's tab,
/// the clear buttons of four lists' searches, the close of a notice and of a workspace's dialog, the
/// remove of a chip, a tag and a threshold, the clear of a snippet's choice,
/// the help of a snippet's variables, the cancel of a phone's file transfer,
/// the delete of a tmux session and of a saved theme, the expand and
/// collapse of a folder among the files to send, the show and hide of a
/// secret field, and the icon of a group, which opens the icons to choose
/// from. Each has a
/// Tooltip around it now, in the person's language.
void main() {
  /// Wrappers a tap's label may sit above: they draw nothing a screen reader
  /// reads.
  const passThrough = {
    'MouseRegion', 'Padding', 'SizedBox', 'Center', 'Material', 'Container', 'Expanded', 'Flexible', 'Align',
    'Opacity', 'AnimatedOpacity', 'Positioned', 'Focus', 'ClipRRect', 'AnimatedContainer', 'Transform',
    // The keyboard's side of a control (a Tab stop, Enter and Space): it
    // says nothing itself (the 4.0 accessibility pass's close buttons).
    'FocusableActionDetector', 'ZestHover',
  };

  /// What may stay as it is, and why.
  const left = {
    // These two put a Tooltip of the tooltip they are given around what they
    // build (each use gives one, or sits in a menu button that says itself).
    'lib/ui/screens/desktop/widgets/session_slide_panel.dart#_HoverIconButtonState',
    'lib/ui/screens/tmux/tmux_workspace.dart#_StripIconButtonState',
  };

  /// The tapped icons of [files] with nothing that says what they do, as
  /// "file:line".
  List<String> unlabelled(Map<String, String> files) {
    final found = <String>[];
    final tapHead = RegExp(r'\b(InkWell|GestureDetector|InkResponse)\(');
    final iconChild = RegExp(
        r'child:\s*(const\s+)?((Padding|Center|SizedBox|Container)\([^()]*?(\([^()]*\)[^()]*?)*child:\s*(const\s+)?)?Icon\(');
    final said = RegExp(r'Text\(|Semantics\(|semanticLabel|Tooltip\(|tooltip:');
    for (final MapEntry(key: path, value: source) in files.entries) {
      final text = source.replaceAll('\r\n', '\n');
      for (final m in tapHead.allMatches(text)) {
        final open = m.end - 1;
        var k = open + 1;
        for (var depth = 1; depth > 0 && k < text.length; k++) {
          if (text[k] == '(') depth++;
          if (text[k] == ')') depth--;
        }
        final call = text.substring(m.start, k);
        if (!call.contains('onTap') || !iconChild.hasMatch(call) || said.hasMatch(call)) continue;
        // Up through the wrappers around it, to a Tooltip or a Semantics.
        var at = m.start;
        var labelled = false;
        for (var level = 0; level < 6; level++) {
          var depth = 0;
          var i = at - 1;
          for (; i >= 0; i--) {
            if (text[i] == ')') depth++;
            if (text[i] == '(') {
              if (depth == 0) break;
              depth--;
            }
          }
          if (i < 0) break;
          final name = RegExp(r'([A-Za-z_][A-Za-z0-9_.]*)\s*$').firstMatch(text.substring(0, i))?.group(1) ?? '';
          final bare = name.split('.').first;
          if (bare == 'Tooltip' || bare == 'Semantics') {
            labelled = true;
            break;
          }
          if (!passThrough.contains(bare)) break;
          at = i - name.length;
        }
        if (labelled) continue;
        final owner = RegExp(r'class\s+(\w+)').allMatches(text.substring(0, m.start)).lastOrNull?.group(1);
        if (left.contains('$path#$owner')) continue;
        found.add('$path:${'\n'.allMatches(text.substring(0, m.start)).length + 1}');
      }
    }
    return found..sort();
  }

  test('every icon that is tapped says what it does', () {
    final files = <String, String>{};
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      files[path] = file.readAsStringSync();
    }
    expect(files, isNotEmpty);
    expect(unlabelled(files), isEmpty, reason: "a Tooltip around it, in the person's language");
  });

  test('the check itself: an icon tapped bare is found; one in a Tooltip or a Semantics, through wrappers, is not', () {
    const bare = '''
      GestureDetector(
        onTap: clear,
        child: Icon(LucideIcons.x, size: 12),
      ),
''';
    const inTooltip = '''
      Tooltip(message: l10n.close, child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          onTap: close,
          child: const Padding(padding: EdgeInsets.all(2), child: Icon(LucideIcons.x)),
        ),
      )),
''';
    const inSemantics = '''
      Semantics(
        label: l10n.micStart,
        button: true,
        child: Material(
          color: fill,
          child: InkWell(onTap: listen, child: Icon(LucideIcons.mic)),
        ),
      ),
''';
    expect(unlabelled({'a': bare}), ['a:1']);
    expect(unlabelled({'b': inTooltip}), isEmpty);
    expect(unlabelled({'c': inSemantics}), isEmpty);
  });

  testWidgets("a secret field's show and hide says what pressing it does, in each state", (tester) async {
    final en = lookupAppLocalizations(const Locale('en'));
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    final controller = TextEditingController(text: 'hunter2');
    addTearDown(controller.dispose);
    await tester.pumpWidget(ProviderScope(
      overrides: [sharedPreferencesProvider.overrideWithValue(prefs)],
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        home: Scaffold(body: ZestField(label: 'Token', controller: controller, obscureText: true)),
      ),
    ));
    await tester.pumpAndSettle();
    expect(find.byTooltip(en.zestDialogShow), findsOneWidget, reason: 'hidden: it shows');
    await tester.tap(find.byTooltip(en.zestDialogShow));
    await tester.pumpAndSettle();
    expect(find.byTooltip(en.zestDialogHide), findsOneWidget, reason: 'shown: it hides');
  });
}
