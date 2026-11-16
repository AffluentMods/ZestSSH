import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Renaming "index.html" preselects "index" so typing replaces the name and
/// keeps the extension (Ctrl+A, or Cmd+A on a Mac, then selects it all).
/// Desktop platforms select a whole one-line field when it gains focus,
/// which used to undo this there, so every platform is pinned.
void main() {
  const everywhere = TargetPlatformVariant({
    TargetPlatform.windows,
    TargetPlatform.macOS,
    TargetPlatform.linux,
    TargetPlatform.android,
    TargetPlatform.iOS,
  });

  Future<TextSelection> open(
      WidgetTester tester, String name, ZestFieldSelect select) async {
    await tester.pumpWidget(ProviderScope(
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Builder(
          builder: (context) => Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () => showZestInputDialog(
                  context: context,
                  title: 'Rename',
                  initialValue: name,
                  confirmLabel: 'Rename',
                  selectOnFocus: select,
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return selection(tester);
  }

  testWidgets('a file name: only the part before the extension',
      (tester) async {
    expect(await open(tester, 'index.html', ZestFieldSelect.stem),
        const TextSelection(baseOffset: 0, extentOffset: 5));
  }, variant: everywhere);

  testWidgets('select all still selects the whole name', (tester) async {
    await open(tester, 'index.html', ZestFieldSelect.stem);
    final modifier = defaultTargetPlatform == TargetPlatform.macOS ||
            defaultTargetPlatform == TargetPlatform.iOS
        ? LogicalKeyboardKey.metaLeft
        : LogicalKeyboardKey.controlLeft;
    await tester.sendKeyDownEvent(modifier);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(modifier);
    await tester.pump();
    expect(selection(tester), const TextSelection(baseOffset: 0, extentOffset: 10));
  }, variant: TargetPlatformVariant.desktop());

  testWidgets('only the last extension stays out', (tester) async {
    expect(await open(tester, 'backup.tar.gz', ZestFieldSelect.stem),
        const TextSelection(baseOffset: 0, extentOffset: 10));
  }, variant: everywhere);

  testWidgets('a dotfile or a name with no extension: all of it',
      (tester) async {
    expect(await open(tester, '.bashrc', ZestFieldSelect.stem),
        const TextSelection(baseOffset: 0, extentOffset: 7));
    await tester.pumpWidget(const SizedBox());
    expect(await open(tester, 'Makefile', ZestFieldSelect.stem),
        const TextSelection(baseOffset: 0, extentOffset: 8));
  }, variant: everywhere);

  testWidgets('the other preselections hold too', (tester) async {
    expect(await open(tester, 'notes.txt', ZestFieldSelect.all),
        const TextSelection(baseOffset: 0, extentOffset: 9));
    await tester.pumpWidget(const SizedBox());
    expect(await open(tester, 'notes.txt', ZestFieldSelect.end),
        const TextSelection.collapsed(offset: 9));
  }, variant: everywhere);
}

TextSelection selection(WidgetTester tester) =>
    tester.widget<TextField>(find.byType(TextField)).controller!.selection;
