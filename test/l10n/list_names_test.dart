import 'dart:io';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/l10n/list_names.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/scheduled_task.dart';
import 'package:zestssh/models/workflow.dart';
import 'package:zestssh/services/backup/local_destination.dart';

/// The names the app shows for the entries of its lists are in the person's
/// language (3.0). The cursor shapes, the system's terminal
/// font, the kinds of host that are not a protocol, a workflow's steps and
/// what a failed one does next, a scheduled task's kinds and how often it
/// runs, and the backup place on the device itself were each kept in English
/// and shown as they were, whatever the language. The system's font was also
/// asked for as 'monospace', which Windows, macOS and iOS do not resolve: they
/// drew a proportional font in a terminal.
void main() {
  final all = [for (final locale in AppLocalizations.supportedLocales) lookupAppLocalizations(locale)];
  final de = lookupAppLocalizations(const Locale('de'));

  /// [value]'s name in each language, and its English name.
  void saidIn(String what, Iterable<(Object, String, String Function(AppLocalizations))> values,
      {Set<Object> ownNames = const {}}) {
    for (final (value, englishName, nameIn) in values) {
      final names = {for (final l10n in all) nameIn(l10n)};
      expect(names.every((n) => n.trim().isNotEmpty), isTrue, reason: '$what $value: a name in every language');
      if (ownNames.contains(value)) {
        expect(names, {englishName}, reason: '$what $value: its own name, as it is written');
      } else {
        expect(names.length, greaterThan(1), reason: '$what $value: said in each language, not in English alone');
      }
    }
  }

  test('a cursor shape, in words, with the shape after it', () {
    saidIn('cursor', [for (final v in TerminalCursorShape.values) (v, v.englishName, v.nameIn)]);
    expect(TerminalCursorShape.block.nameIn(de), '${de.cursorShapeBlock} █');
    expect(TerminalCursorShape.underline.nameIn(de), '${de.cursorShapeUnderline} _');
    expect(TerminalCursorShape.verticalBar.nameIn(de), '${de.cursorShapeBar} |');
  });

  test("a terminal font: its own name, and the system's in words", () {
    saidIn('font', [for (final v in TerminalFontFamily.values) (v, v.englishName, v.nameIn)],
        ownNames: {for (final v in TerminalFontFamily.values) if (v != TerminalFontFamily.system) v});
  });

  test("the system's terminal font is a monospace font the system has by its name", () {
    final expected = Platform.isWindows
        ? 'Consolas'
        : Platform.isMacOS || Platform.isIOS
            ? 'Menlo'
            : 'monospace';
    expect(TerminalFontFamily.system.fontFamily, expected);
    expect(TerminalFontFamily.jetBrainsMono.fontFamily, 'JetBrainsMono', reason: 'a bundled font by its own family');
  });

  test('a kind of host: a protocol by its name, the others in words', () {
    saidIn('protocol', [for (final v in ConnectionProtocol.values) (v, v.englishName, v.nameIn)], ownNames: {
      ConnectionProtocol.ssh,
      ConnectionProtocol.mosh,
      ConnectionProtocol.et,
      ConnectionProtocol.telnet,
      // FTPS (3.4) by its name; its implicit TLS in words.
      ConnectionProtocol.ftps,
      // A remote screen (4.0) by its protocol's name.
      ConnectionProtocol.vnc,
      ConnectionProtocol.rdp,
    });
  });

  test("a workflow's steps and what a failed one does next, as the editor offers them", () {
    saidIn('step', [for (final v in WorkflowStepType.values) (v, v.englishName, v.nameIn)]);
    saidIn('on failure', [for (final v in StepFailureAction.values) (v, v.englishName, v.nameIn)]);
    expect([for (final v in WorkflowStepType.values) v.nameIn(de)],
        [de.wfEditOptExecuteLabel, de.wfEditOptSnippetLabel, de.wfEditOptDelayLabel, de.wfEditOptNotifyLabel]);
    expect([for (final v in StepFailureAction.values) v.nameIn(de)],
        [de.wfEditSegAbort, de.wfEditSegContinue, de.wfEditSegGoTo]);
  });

  test("a scheduled task's kinds and how often it runs", () {
    saidIn('task', [for (final v in ScheduledTaskAction.values) (v, v.englishName, v.nameIn)]);
    saidIn('schedule', [for (final v in ScheduleType.values) (v, v.englishName, v.nameIn)]);
  });

  test("the backup place on the device itself, in the person's language", () {
    addTearDown(() => L10nGlobal.update(lookupAppLocalizations(const Locale('en'))));
    L10nGlobal.update(de);
    expect(LocalBackupDestination().displayName, de.backupLocalStorage);
  });

  test('no screen shows the English name of a list', () {
    // englishName is for the log: read by the models that keep it, the
    // services that log it, and the one place that names a product or a
    // protocol by it.
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      if (path.startsWith('lib/models/') || path.startsWith('lib/services/') || path == 'lib/l10n/list_names.dart') {
        continue;
      }
      final lines = file.readAsLinesSync();
      for (var i = 0; i < lines.length; i++) {
        if (lines[i].contains('englishName')) found.add('$path:${i + 1}');
      }
    }
    expect(found, isEmpty, reason: 'show nameIn(l10n) (lib/l10n/list_names.dart)');
  });
}
