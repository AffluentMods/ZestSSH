
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/sftp_pins_provider.dart';
import 'package:zestssh/ui/screens/sftp/widgets/overwrite_conflict_dialog.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

/// Covers the conflict dialog's state-dependent behaviour: it is the shell
/// (the dialog rules of 3.4), the resolutions a list in its body and the main
/// button in the footer saying the one chosen; the recommended one follows
/// the OPERATION (Replace where the remote is readable, Skip where it is
/// not), "Replace if newer" is
/// offered only while more conflicts can follow and is disabled with a stated
/// reason when it cannot compare ages, and the counter's exact vs running
/// forms, with the remaining count named only when it is real.
Widget _host({ThemeData? theme}) => MaterialApp(
      theme: theme,
      localizationsDelegates: AppLocalizations.localizationsDelegates,
      supportedLocales: AppLocalizations.supportedLocales,
      home: const Scaffold(body: SizedBox.expand()),
    );

Future<void> _open(
  WidgetTester tester, {
  required OverwriteFileInfo source,
  required OverwriteFileInfo destination,
  int index = 1,
  int total = 1,
  bool totalIsExact = true,
  bool? applyToAllEnabled,
  ThemeData? theme,
  SftpTimeFormat timeFormat = SftpTimeFormat.h24,
}) async {
  // Tear the previous app down first. Pumping a structurally identical
  // MaterialApp UPDATES the live tree, so its Navigator (and any dialog still
  // open on it) would survive, and a finder's `.first` would then measure the
  // stale dialog underneath the new one.
  await tester.pumpWidget(const SizedBox.shrink());
  await tester.pumpWidget(_host(theme: theme));
  final ctx = tester.element(find.byType(Scaffold));
  // Not awaited: the future completes only when the user picks an action.
  OverwriteConflictDialog.show(
    ctx,
    source: source,
    destination: destination,
    index: index,
    total: total,
    sourceVerb: 'Uploading',
    totalIsExact: totalIsExact,
    applyToAllEnabled: applyToAllEnabled,
    timeFormat: timeFormat,
  );
  // Bounded: the dialog's open animation is ~150ms; never the 10-minute
  // default, which would hang the suite if anything ever animated forever.
  await tester.pumpAndSettle(const Duration(milliseconds: 100),
      EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
}

/// What the dialog's main button says.
String _primaryLabel(WidgetTester tester) => tester
    .widget<Text>(find.descendant(of: find.byKey(const ValueKey('overwrite-go')), matching: find.byType(Text)))
    .data!;

/// The resolution's row in the list.
InkWell _tile(WidgetTester tester, String action) => tester.widget<InkWell>(
    find.descendant(of: find.byKey(ValueKey('overwrite-choice-$action')), matching: find.byType(InkWell)));

/// The resolution chosen in the list (by its dot radio, the group's value).
String _chosen(WidgetTester tester) {
  final group = tester.widget<RadioGroup<OverwriteAction>>(find.byType(RadioGroup<OverwriteAction>));
  return group.groupValue?.name ?? '';
}

void main() {
  final local = OverwriteFileInfo(
      path: r'C:\Users\x\app.css', size: 9100, modified: DateTime(2026, 4, 24));
  final readableRemote = OverwriteFileInfo(
      path: '/home/x/app.css', size: 9300, modified: DateTime(2026, 4, 23));
  const unreadableRemote = OverwriteFileInfo(path: '/home/x/app.css');

  testWidgets(
      'multi-file readable: Replace is chosen, the main button says it, Keep both stays a choice',
      (tester) async {
    // total > 1 => a batch: the recommendation follows the operation, so
    // Replace leads.
    await _open(tester,
        source: local, destination: readableRemote, index: 1, total: 3);

    // The shell (the dialog rules of 3.4): one footer, the main button says
    // the resolution chosen, and the resolutions are a list in the body.
    expect(find.byType(ZestDialogShell), findsOneWidget);
    expect(find.byType(AlertDialog), findsNothing);
    expect(_primaryLabel(tester), 'Replace');
    expect(_chosen(tester), 'overwrite');
    // Keep both remains available, just not the bulk default.
    expect(find.byKey(const ValueKey('overwrite-choice-rename')), findsOneWidget);

    // "Replace if newer" can compare ages, so it is enabled and unexplained.
    expect(_tile(tester, 'newer').onTap, isNotNull);
    expect(find.textContaining('cannot be read'), findsNothing);

    // Counter reads under the title.
    expect(find.text('1 of 3'), findsOneWidget);
  });

  testWidgets('Enter does not replace the file: the main button does not take the keyboard while Replace is chosen '
      '(found in a security review)', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host());
    final ctx = tester.element(find.byType(Scaffold));
    OverwriteAction? answer;
    OverwriteConflictDialog.show(
      ctx,
      source: local,
      destination: readableRemote,
      index: 1,
      total: 1,
      sourceVerb: 'Uploading',
    ).then((r) => answer = r.action);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
    expect(_chosen(tester), 'overwrite');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 10));
    expect(answer, isNull, reason: 'nothing replaced');
    expect(find.byType(ZestDialogShell), findsOneWidget);
  });

  testWidgets(
      'single-file readable: Replace is chosen, Keep both stays a choice',
      (tester) async {
    // Readable remote, single file: Replace still leads. On a server you are
    // almost always updating the destination, so Replace is the default even
    // for a one-off; Keep both stays a choice.
    await _open(tester, source: local, destination: readableRemote);

    expect(_primaryLabel(tester), 'Replace');
    expect(find.byKey(const ValueKey('overwrite-choice-rename')), findsOneWidget);

    // One file: nothing follows for "Replace if newer" to be a rule for, and
    // Replace or Skip with both dates on screen already says the same.
    expect(find.text('Replace if newer'), findsNothing);
  });

  testWidgets('unreadable remote: Replace is still chosen, the file said Not readable, newer not offered on one file',
      (tester) async {
    await _open(tester, source: local, destination: unreadableRemote);

    // Replace is the default here too (an upload is there to update the
    // server's file); the server's side says it could not be read, and Skip
    // and Keep both stay choices.
    expect(_primaryLabel(tester), 'Replace');
    expect(_chosen(tester), 'overwrite');
    expect(find.byKey(const ValueKey('overwrite-choice-rename')), findsOneWidget);
    expect(find.byKey(const ValueKey('overwrite-choice-skip')), findsOneWidget);

    // A single file: no "Replace if newer", so no reason line for it either.
    expect(find.text('Replace if newer'), findsNothing);
    expect(find.textContaining('cannot be read'), findsNothing);

    // The remote meta states "Not readable".
    expect(find.text('Not readable'), findsOneWidget);
  });

  testWidgets('unreadable remote in a batch: newer shown but disabled, with the reason',
      (tester) async {
    await _open(tester,
        source: local, destination: unreadableRemote, index: 1, total: 3);

    expect(_tile(tester, 'newer').onTap, isNull);
    expect(find.textContaining('cannot be read'), findsOneWidget);
  });

  testWidgets('a choice in the list changes what the main button says and answers', (tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pumpWidget(_host());
    final ctx = tester.element(find.byType(Scaffold));
    OverwriteResolution? got;
    OverwriteConflictDialog.show(ctx, source: local, destination: readableRemote, index: 1, total: 3)
        .then((r) => got = r);
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('overwrite-choice-rename')));
    await tester.pump();
    expect(_primaryLabel(tester), 'Keep both');
    await tester.tap(find.byKey(const ValueKey('overwrite-go')));
    await tester.pumpAndSettle();
    expect(got?.action, OverwriteAction.rename);
    expect(find.byType(ZestDialogShell), findsNothing);

    OverwriteConflictDialog.show(ctx, source: local, destination: readableRemote, index: 1, total: 3)
        .then((r) => got = r);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Cancel all'));
    await tester.pumpAndSettle();
    expect(got?.action, OverwriteAction.cancel);
  });

  testWidgets('an exact total names the conflicts still to come', (tester) async {
    await _open(tester,
        source: local, destination: readableRemote, index: 1, total: 4);

    expect(find.text('1 of 4'), findsOneWidget);
    expect(find.text('Do this for the remaining 3 conflicts'), findsOneWidget);
    expect(find.text('Replace if newer'), findsOneWidget);
  });

  testWidgets('the last conflict of a batch offers no rule for the rest',
      (tester) async {
    await _open(tester,
        source: local, destination: readableRemote, index: 3, total: 3);

    expect(find.text('3 of 3'), findsOneWidget);
    expect(find.text('Replace if newer'), findsNothing);
    // Nothing is left to apply a choice to: the box is inert and names no
    // number.
    expect(find.text('Do this for the remaining conflicts'), findsOneWidget);
    final box = tester.widget<Checkbox>(find.byType(Checkbox));
    expect(box.onChanged, isNull);
  });

  testWidgets('an inexact total shows a running "Conflict N", never "N of M"',
      (tester) async {
    await _open(tester,
        source: local,
        destination: readableRemote,
        index: 5,
        total: 3,
        totalIsExact: false,
        applyToAllEnabled: true);

    expect(find.text('Conflict 5'), findsOneWidget);
    expect(find.text('5 of 3'), findsNothing);
    // Never a number worked out from a partial count: the generic wording,
    // and the box still works.
    expect(find.text('Do this for the remaining conflicts'), findsOneWidget);
    expect(tester.widget<Checkbox>(find.byType(Checkbox)).onChanged, isNotNull);
    expect(find.text('Replace if newer'), findsOneWidget);
  });

  testWidgets(
      'the first conflict of an inexact batch never reads "the remaining conflict"',
      (tester) async {
    // What the old top-level count produced: two existing folders counted as
    // "2", so the first prompt said "the remaining conflict" with more to go.
    await _open(tester,
        source: local,
        destination: readableRemote,
        index: 1,
        total: 2,
        totalIsExact: false,
        applyToAllEnabled: true);

    expect(find.text('Conflict 1'), findsOneWidget);
    expect(find.text('Do this for the remaining conflict'), findsNothing);
    expect(find.text('Do this for the remaining conflicts'), findsOneWidget);
  });

  testWidgets('a prompt past an exact total falls back to the running count',
      (tester) async {
    // A file that appeared after the scan: never "5 of 4".
    await _open(tester,
        source: local, destination: readableRemote, index: 5, total: 4);

    expect(find.text('Conflict 5'), findsOneWidget);
    expect(find.text('5 of 4'), findsNothing);
  });

  testWidgets('is a modal of its own width and the main button takes a tap',
      (tester) async {
    // A deliberately wide window: the shipped 1.9.8 regression stretched the
    // dialog to the whole window (a Row-with-Spacer in AlertDialog.actions) and
    // floated the note over the primary button, so it could not be clicked.
    tester.view.physicalSize = const Size(1400, 900);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);

    await _open(tester, source: local, destination: readableRemote);

    // The shell's standard width, nowhere near the 1400px window.
    final card = find.descendant(of: find.byType(Dialog), matching: find.byType(ConstrainedBox)).first;
    expect(tester.getSize(card).width, inInclusiveRange(560, 680));

    // The main button actually receives the tap and closes the dialog.
    // warnIfMissed would fire if anything painted over it, and the dialog would
    // stay up if the tap never reached the button.
    await tester.tap(find.byKey(const ValueKey('overwrite-go')));
    await tester.pumpAndSettle();
    expect(find.byType(ZestDialogShell), findsNothing);
  });

  testWidgets('file times follow the SFTP time format setting', (tester) async {
    final afternoon = OverwriteFileInfo(
        path: '/home/x/app.css', size: 9300, modified: DateTime(2026, 4, 23, 14, 5));
    await _open(tester, source: local, destination: afternoon);
    expect(find.textContaining('2026-04-23 14:05'), findsOneWidget);

    await _open(tester,
        source: local, destination: afternoon, timeFormat: SftpTimeFormat.h12);
    expect(find.textContaining('2026-04-23 2:05 PM'), findsOneWidget);
    expect(find.textContaining('14:05'), findsNothing);
  });
}
