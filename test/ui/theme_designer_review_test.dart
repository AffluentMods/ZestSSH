import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/theme_sync_provider.dart';
import 'package:zestssh/theme/terminal_scheme_import.dart';
import 'package:zestssh/theme/terminal_themes.dart';
import 'package:zestssh/theme/themes/all_themes.dart';
import 'package:zestssh/ui/screens/desktop/widgets/theme_designer_view.dart';

class _Plan extends StateNotifier<bool> implements ProStatusNotifier {
  _Plan(super.pro);

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Keeps what the page asked of the picker, and picks nothing.
class _Picker extends FilePicker {
  FileType? type;
  List<String>? extensions;
  var asked = 0;

  @override
  Future<FilePickerResult?> pickFiles({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    bool allowCompression = false,
    int compressionQuality = 0,
    bool allowMultiple = false,
    bool withData = false,
    bool withReadStream = false,
    bool lockParentWindow = false,
    bool readSequential = false,
  }) async {
    asked++;
    this.type = type;
    extensions = allowedExtensions;
    return null;
  }
}

/// The theme designer, after a review: its App |
/// Terminal switch shows the hand, Import scheme says what it reads and its
/// picker shows only those files, and the Live preview is the window a theme
/// makes, with a terminal in it (it was a card and a search box).
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  Future<ProviderContainer> pump(WidgetTester tester, {int tab = 0, String app = 'graphite', bool synced = true}) async {
    tester.view.physicalSize = const Size(1200, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    SharedPreferences.setMockInitialValues({'app_theme_id': app, 'themes_synced': synced});
    final prefs = await SharedPreferences.getInstance();
    final container = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(prefs),
      isProProvider.overrideWith((ref) => _Plan(true)),
    ]);
    addTearDown(container.dispose);
    await tester.pumpWidget(UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        localizationsDelegates: AppLocalizations.localizationsDelegates,
        supportedLocales: AppLocalizations.supportedLocales,
        locale: const Locale('en'),
        home: Scaffold(body: ThemeDesignerView(initialTab: tab, onClose: () {})),
      ),
    ));
    await tester.pumpAndSettle();
    return container;
  }

  MouseCursor cursorAt(WidgetTester tester, Offset at) {
    final result = HitTestResult();
    tester.binding.hitTestInView(result, at, tester.view.viewId);
    for (final entry in result.path) {
      final target = entry.target;
      if (target is RenderMouseRegion && target.cursor != MouseCursor.defer) return target.cursor;
    }
    return SystemMouseCursors.basic;
  }

  testWidgets('the App | Terminal switch shows the hand on both sides', (tester) async {
    await pump(tester);
    for (final i in [0, 1]) {
      final segment = find.byKey(ValueKey('theme-designer-tab-$i'));
      expect(segment, findsOneWidget);
      expect(cursorAt(tester, tester.getCenter(segment)), SystemMouseCursors.click);
    }
    await tester.tap(find.byKey(const ValueKey('theme-designer-tab-1')));
    await tester.pumpAndSettle();
    expect(find.text(en.customThemeBuilderImportScheme), findsOneWidget, reason: 'the switch still switches');
  });

  group('the Live preview', () {
    testWidgets('is the window: tabs, the side rail, a session, a terminal; no search box or card of its own',
        (tester) async {
      await pump(tester);
      final preview = find.byKey(const ValueKey('theme-preview'));
      expect(preview, findsOneWidget);
      Finder inside(Finder f) => find.descendant(of: preview, matching: f);
      expect(inside(find.text('web-01')), findsWidgets);
      expect(inside(find.text(en.narrowSidebarHosts)), findsOneWidget);
      expect(inside(find.text(en.narrowSidebarKeys)), findsOneWidget);
      expect(inside(find.text(en.sessionInfoStatusConnected)), findsOneWidget);
      expect(inside(find.text('Production server')), findsNothing);
      expect(inside(find.textContaining('deploy@web-01')), findsWidgets, reason: 'a terminal, with a prompt');
    });

    Color? terminalBackground(WidgetTester tester) => tester
        .widget<Container>(find.byKey(const ValueKey('theme-preview-terminal')))
        .color;

    testWidgets('shows the terminal that goes with the theme: its pair while matched, the one in use when not',
        (tester) async {
      await pump(tester, app: 'dracula');
      expect(terminalBackground(tester), TerminalThemes.all[TerminalThemes.dracula]!.background);
      await tester.pumpWidget(const SizedBox());
      await pump(tester, app: 'dracula', synced: false);
      expect(terminalBackground(tester), TerminalThemes.all[TerminalThemes.defaultId]!.background);
    });

    testWidgets('picks up a colour as it is edited: the chrome is in the theme being designed', (tester) async {
      await pump(tester, app: 'midnight');
      final preview = tester.widget<Container>(find.byKey(const ValueKey('theme-preview')));
      expect((preview.decoration! as BoxDecoration).color, BuiltInThemes.getById('midnight').colorScheme.background);
      expect(terminalBackground(tester), TerminalThemes.all[TerminalThemes.midnight]!.background);
    });
  });

  group('Import scheme', () {
    testWidgets('its "?" says which files it reads', (tester) async {
      await pump(tester, tab: 1);
      final help = find.byKey(const ValueKey('import-scheme-help'));
      expect(help, findsOneWidget);
      final message = tester.widget<Tooltip>(help).message!;
      for (final kind in ['.json', '.itermcolors', '.Xresources', '.xrdb']) {
        expect(message, contains(kind));
      }
    });

    testWidgets('on a computer the picker shows only the files it reads', (tester) async {
      final picker = _Picker();
      FilePicker.platform = picker;
      await pump(tester, tab: 1);
      await tester.tap(find.text(en.customThemeBuilderImportScheme));
      await tester.pumpAndSettle();
      expect(picker.asked, 1);
      if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
        expect(picker.type, FileType.custom);
        expect(picker.extensions, kTerminalSchemeFileExtensions);
      }
    });

    testWidgets('on a computer Any file picks from every file: a scheme in a file named `colors` can be chosen', (tester) async {
      final picker = _Picker();
      FilePicker.platform = picker;
      await pump(tester, tab: 1);
      final any = find.byKey(const ValueKey('import-scheme-any-file'));
      if (!(Platform.isWindows || Platform.isLinux || Platform.isMacOS)) {
        expect(any, findsNothing);
        return;
      }
      expect(find.text(en.customThemeBuilderImportAnyFile), findsOneWidget);
      await tester.tap(any);
      await tester.pumpAndSettle();
      expect(picker.asked, 1);
      expect(picker.type, FileType.any);
      expect(picker.extensions, isNull);
    });

    test('the help names every kind of file the filter lets through, in every language', () {
      for (final locale in AppLocalizations.supportedLocales) {
        final help = lookupAppLocalizations(locale).customThemeBuilderImportSchemeHelp;
        for (final kind in {
          '.json',
          '.itermcolors',
          for (final e in kTerminalSchemeFileExtensions)
            if (e.startsWith('X') || e == 'xrdb') '.$e',
        }) {
          expect(help, contains(kind), reason: '$locale $kind');
        }
      }
    });

    test('the filter leaves out nothing the import reads', () {
      expect(parseTerminalScheme('*.background: #101010\n*.foreground: #eeeeee\n*.color0: #000000\n*.color5: #ff00ff\n'),
          isNotNull,
          reason: 'X resources');
      expect(kTerminalSchemeFileExtensions, containsAll(<String>['json', 'itermcolors', 'xrdb', 'Xresources', 'Xdefaults']));
    });
  });

  testWidgets("the designer's Import shows only theme files", (tester) async {
    final picker = _Picker();
    FilePicker.platform = picker;
    await pump(tester);
    final import = find.text(en.themeDesignImportEllipsis);
    await tester.ensureVisible(import);
    await tester.pumpAndSettle();
    await tester.tap(import);
    await tester.pumpAndSettle();
    expect(picker.asked, 1);
    expect(picker.type, FileType.custom);
    expect(picker.extensions, containsAll(<String>['zestheme', 'json']));
  });

  test('every built-in app theme has a terminal theme to match', () {
    for (final theme in BuiltInThemes.all) {
      expect(kAppToTerminalThemeId[theme.id], isNotNull, reason: theme.id);
    }
  });
}
