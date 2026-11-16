import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// A yes/no question is the app's own confirm dialog (3.0).
/// Twenty-five of them were plain dialogs built in place, each with its own
/// colours and buttons: a title, a sentence, a button for no and one for
/// yes. They ask through ZestConfirmDialog now, which is a sheet on a phone
/// and closes on Escape like every other question of the app. This reads the
/// code and holds that no question of that plain shape is written again.
void main() {
  /// Every `showDialog<bool>` in lib whose dialog is a plain AlertDialog with
  /// a title, one sentence and buttons that pop true and false: as
  /// "file:line".
  List<String> plainQuestions() {
    final found = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      final path = file.path.replaceAll('\\', '/');
      if (!path.endsWith('.dart') || path.contains('/generated/')) continue;
      final lines = file.readAsStringSync().replaceAll('\r\n', '\n').split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('showDialog<bool>(')) continue;
        final indent = lines[i].length - lines[i].trimLeft().length;
        // The call's own text: up to the line that closes it.
        var end = i + 1;
        while (end < lines.length &&
            !(lines[end].length - lines[end].trimLeft().length == indent && lines[end].trimLeft().startsWith(')'))) {
          end++;
        }
        final call = lines.sublist(i, end + 1 > lines.length ? lines.length : end + 1).join('\n');
        final plain = call.contains('=> AlertDialog(') &&
            RegExp(r'content:\s*(const\s+)?Text\(').hasMatch(call) &&
            RegExp(r'title:\s*(const\s+)?Text\(').hasMatch(call) &&
            call.contains(', true)') &&
            !RegExp(r'TextField|TextFormField|StatefulBuilder|ListView|Checkbox|barrierDismissible').hasMatch(call);
        if (plain) found.add('$path:${i + 1}');
      }
    }
    return found..sort();
  }

  test('no yes/no question is a plain dialog built in place', () {
    expect(
      plainQuestions(),
      isEmpty,
      reason: 'ask with ZestConfirmDialog.show(context, tone: ..., title: ..., body: ..., confirmLabel: ...)',
    );
  });

  /// Every AlertDialog in [files] that is a title, one sentence and buttons,
  /// whatever it returns and however it is built (a question that acts in its
  /// button, one closed with `.pop(true)`, a notice with only OK, one built in
  /// a block): as "file:line". Ten of these were left by the check above,
  /// which looks for one shape alone (3.0).
  List<String> plainDialogs(Map<String, String> files) {
    final found = <String>[];
    for (final MapEntry(key: path, value: text) in files.entries) {
      final lines = text.replaceAll('\r\n', '\n').split('\n');
      for (var i = 0; i < lines.length; i++) {
        if (!lines[i].contains('AlertDialog(')) continue;
        final indent = lines[i].length - lines[i].trimLeft().length;
        var end = i + 1;
        while (end < lines.length &&
            !(lines[end].length - lines[end].trimLeft().length == indent && lines[end].trimLeft().startsWith(')'))) {
          end++;
        }
        final dialog = lines.sublist(i, end + 1 > lines.length ? lines.length : end + 1).join('\n');
        final head = dialog.split('actions:').first;
        final plain = RegExp(r'content:\s*(const\s+)?Text\(').hasMatch(head) &&
            !RegExp(r'TextField|TextFormField|StatefulBuilder|ListView|Checkbox|Column\(|Radio|Switch|Row\(').hasMatch(head);
        if (plain) found.add('$path:${i + 1}');
      }
    }
    return found..sort();
  }

  Map<String, String> libFiles() => {
        for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
          if (file.path.endsWith('.dart') && !file.path.replaceAll('\\', '/').contains('/generated/'))
            file.path.replaceAll('\\', '/'): file.readAsStringSync(),
      };

  test('no question or notice of a title, one sentence and buttons is a plain dialog built in place', () {
    expect(plainDialogs(libFiles()), isEmpty,
        reason: "ask or tell with ZestConfirmDialog.show (a notice: showCancel: false), the app's own dialog");
  });

  test('the wider check finds each shape where it is written', () {
    // (Held against this file's own words, which no app code reads.)
    const samples = {
      'acts in its button': '''
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.someTitle),
        content: Text(l10n.someSentence),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: Text(l10n.cancel)),
          FilledButton(onPressed: () { doIt(); Navigator.pop(ctx); }, child: Text(l10n.delete)),
        ],
      ),
    );
''',
      'built in a block': '''
    final answer = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final title = l10n.someTitle;
        return AlertDialog(
          title: Text(title),
          content: Text(body),
          actions: [
            FilledButton(onPressed: () => Navigator.of(ctx).pop(true), child: Text(l10n.delete)),
          ],
        );
      },
    );
''',
    };
    for (final MapEntry(key: what, value: text) in samples.entries) {
      expect(plainDialogs({what: text}), hasLength(1), reason: what);
    }
    // A dialog with a field is not of the plain shape.
    expect(plainDialogs({'a field': '''
      builder: (ctx) => AlertDialog(
        title: Text(l10n.someTitle),
        content: TextField(controller: c),
        actions: [],
      ),
'''}), isEmpty);
  });

  test('the check itself finds a plain question where one is written', () {
    // (Held against this file's own words, which no app code reads.)
    const sample = '''
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(l10n.someTitle),
        content: Text(l10n.someSentence),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(l10n.cancel)),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(l10n.delete)),
        ],
      ),
    );
''';
    expect(sample.contains('=> AlertDialog('), isTrue);
    expect(RegExp(r'content:\s*(const\s+)?Text\(').hasMatch(sample), isTrue);
    expect(sample.contains(', true)'), isTrue);
  });
}
