import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/ui/widgets/desktop_drop_target.dart';

/// A file dropped on Import a file was also typed into the live terminals
/// behind the dialog: every drop target hears every drop, on screen or not. A
/// local path typed into a remote shell is what must never happen, so a drop
/// target listens only while its page is the one in front. These go through
/// the plugin's own channel, as the window sends them.

Future<void> _event(WidgetTester tester, String method, Object? arguments) async {
  final message = const StandardMethodCodec().encodeMethodCall(MethodCall(method, arguments));
  await tester.binding.defaultBinaryMessenger.handlePlatformMessage('desktop_drop', message, (_) {});
  await tester.pump();
}

const _middle = <double>[400, 300];

Future<void> _drop(WidgetTester tester, String path) async {
  await _event(tester, 'entered', _middle);
  await _event(tester, 'updated', _middle);
  await _event(tester, 'performOperation', [path]);
}

void main() {
  late List<List<String>> terminal;
  late List<List<String>> dialog;
  late BuildContext page;

  setUp(() {
    terminal = [];
    dialog = [];
  });

  Future<void> pumpPage(WidgetTester tester) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: DesktopDropTarget(
          onFilesDropped: terminal.add,
          child: Builder(builder: (context) {
            page = context;
            return const SizedBox.expand(child: Text('terminal'));
          }),
        ),
      ),
    ));
  }

  Future<void> showTheDialog(WidgetTester tester) async {
    showDialog<void>(
      context: page,
      builder: (_) => Center(
        child: SizedBox(
          width: 300,
          height: 300,
          child: Material(
            child: DesktopDropTarget(onFilesDropped: dialog.add, child: const SizedBox.expand(child: Text('dialog'))),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  testWidgets('a page in front has the drop', (tester) async {
    await pumpPage(tester);
    await _drop(tester, r'C:\demo\notes.txt');
    expect(terminal, [
      [r'C:\demo\notes.txt']
    ]);
  });

  testWidgets('under a dialog: the dialog has the drop, and nothing reaches what is behind it; it comes back after', (tester) async {
    await pumpPage(tester);
    await showTheDialog(tester);
    await _drop(tester, r'C:\demo\hosts.csv');
    expect(dialog, [
      [r'C:\demo\hosts.csv']
    ]);
    expect(terminal, isEmpty, reason: 'a local path typed into a remote shell');

    Navigator.of(page).pop();
    await tester.pumpAndSettle();
    await _drop(tester, r'C:\demo\notes.txt');
    expect(terminal, [
      [r'C:\demo\notes.txt']
    ]);
    expect(dialog, hasLength(1));
  });

  testWidgets('under a page in front of it: nothing', (tester) async {
    await pumpPage(tester);
    Navigator.of(page).push(MaterialPageRoute<void>(builder: (_) => const Scaffold(body: Text('another page'))));
    await tester.pumpAndSettle();
    await _drop(tester, r'C:\demo\hosts.csv');
    expect(terminal, isEmpty);
  });

  testWidgets('a dialog that opens during a drag: the page lets go of it, and shows no drop hint', (tester) async {
    await pumpPage(tester);
    final l10n = lookupAppLocalizations(const Locale('en'));
    await _event(tester, 'entered', _middle);
    await _event(tester, 'updated', _middle);
    expect(find.text(l10n.dropFilesHint), findsOneWidget);
    await showTheDialog(tester);
    expect(tester.takeException(), isNull);
    // (The page keeps its state: what the page's drop target showed is gone.)
    expect(find.descendant(of: find.byType(Scaffold).first, matching: find.text(l10n.dropFilesHint)), findsNothing);
    await _event(tester, 'performOperation', [r'C:\demo\hosts.csv']);
    expect(terminal, isEmpty);
  });

  testWidgets('a drag that leaves shows no hint, and drops nothing', (tester) async {
    await pumpPage(tester);
    final l10n = lookupAppLocalizations(const Locale('en'));
    await _event(tester, 'entered', _middle);
    await _event(tester, 'exited', null);
    expect(find.text(l10n.dropFilesHint), findsNothing);
    expect(terminal, isEmpty);
  });

  // The Keys page takes a key file (4.0): its own words while one is dragged
  // over it, and nothing at all where this account may not add a key.
  Future<void> pumpTarget(WidgetTester tester, {required bool enabled}) async {
    tester.view.physicalSize = const Size(800, 600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      locale: const Locale('en'),
      home: Scaffold(
        body: DesktopDropTarget(
          enabled: enabled,
          hint: 'Drop a key file to add it',
          onFilesDropped: terminal.add,
          child: const SizedBox.expand(child: Text('keys')),
        ),
      ),
    ));
  }

  testWidgets('a target with its own words says them while files are dragged over it', (tester) async {
    await pumpTarget(tester, enabled: true);
    final l10n = lookupAppLocalizations(const Locale('en'));
    await _event(tester, 'entered', _middle);
    await _event(tester, 'updated', _middle);
    expect(find.text('Drop a key file to add it'), findsOneWidget);
    expect(find.text(l10n.dropFilesHint), findsNothing);
    await _event(tester, 'performOperation', [r'C:\demo\id_ed25519']);
    expect(terminal, [
      [r'C:\demo\id_ed25519']
    ]);
    expect(find.text('Drop a key file to add it'), findsNothing);
  });

  testWidgets('a target that is off takes nothing and lights nothing', (tester) async {
    await pumpTarget(tester, enabled: false);
    await _drop(tester, r'C:\demo\id_ed25519');
    expect(find.text('Drop a key file to add it'), findsNothing);
    expect(terminal, isEmpty);
  });
}
