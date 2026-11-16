import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/screens/automation/automation_guide_screen.dart';
import 'package:zestssh/ui/screens/automation/automation_wizard_screen.dart';

/// What the app tells Tasker to send, held to what the Android app takes.
///
/// The wizard said to send a broadcast, which no part of the app receives;
/// the guide gave its extras as key=value lines and without the key, which
/// every request needs; both gave a batch's hosts as an extra MainActivity
/// did not read; and MainActivity read every extra as text, where Tasker
/// sends one that reads as a number as an Integer (found in
/// a security review). Android's code does not run here: what it
/// reads and the actions its activity takes are read from its source.
void main() {
  final activity =
      File('android/app/src/main/kotlin/com/affluentlabs/zestssh/MainActivity.kt').readAsStringSync();
  final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();

  // The extras MainActivity reads for an automation, by name.
  final read = {for (final m in RegExp(r'extraText\(intent, "(\w+)"\)').allMatches(activity)) m.group(1)!};
  // The activity's element in the manifest, and the automation actions it takes.
  final element = manifest
      .split('<activity')
      .firstWhere((part) => part.contains('android:name=".MainActivity"'))
      .split('</activity>')
      .first;
  final actions = {
    for (final m in RegExp(r'<action android:name="com\.affluentlabs\.zestssh\.(\w+)"').allMatches(element)) m.group(1)!,
  };

  /// [line]'s extra, as `Extra: name:value`, or null for a line of another kind.
  (String, String)? extraOf(String line) {
    final m = RegExp(r'^\s*Extra: (\w+):(.*)$').firstMatch(line);
    return m == null ? null : (m.group(1)!, m.group(2)!);
  }

  bool readByTheApp(String name) => read.contains(name) || (name.startsWith('var_') && name.length > 4);

  test('what is read is what the source says', () {
    expect(actions, {'CONNECT', 'OPEN', 'EXECUTE', 'SNIPPET', 'BATCH', 'WORKFLOW'});
    expect(read, containsAll(['key', 'connection_id', 'command', 'timeout', 'connections', 'snippet_name']));
    // No receiver of the app takes these actions: a broadcast reaches nothing.
    final receivers = manifest.split('<receiver').skip(1).map((part) => part.split('</receiver>').first);
    expect(receivers.where((part) => part.contains('com.affluentlabs.zestssh.')), isEmpty);
    // Snippet variables, by their prefix.
    expect(activity, contains('key.startsWith("var_") && key.length > 4'));
  });

  test("the wizard's intent goes to the activity, with only extras it reads, the key among them", () {
    for (final action in ['execute', 'snippet', 'batch', 'connect', 'workflow']) {
      final text = taskerIntentText(
        action: action,
        key: 'k3yForTasker',
        connection: 'web-1',
        connections: ['web-1', 'db-1'],
        command: 'uptime',
        timeout: 30,
        filters: {'grep': 'load', 'head': '5', 'tail': '2', 'callback': 'https://hooks.example.com/zest'},
        snippet: 'Deploy',
        variables: {'branch': 'main'},
        workflow: 'Nightly',
      );
      final lines = text.split('\n');
      expect(lines.take(3), [
        'Action: com.affluentlabs.zestssh.${action.toUpperCase()}',
        'Package: com.affluentlabs.zestssh',
        'Target: Activity',
      ], reason: action);
      expect(actions, contains(action.toUpperCase()));
      final extras = [for (final line in lines.skip(3)) extraOf(line)];
      expect(extras, everyElement(isNotNull), reason: '$action: every other line is an extra, as Tasker takes it');
      final names = [for (final e in extras) e!.$1];
      expect(names.where((n) => !readByTheApp(n)), isEmpty, reason: '$action: extras the app does not read');
      expect(names.first, 'key', reason: action);
      expect(extras.first!.$2, 'k3yForTasker');
    }

    Map<String, String> extrasOf(String text) => {
          for (final line in text.split('\n'))
            if (extraOf(line) case (final name, final value)) name: value,
        };
    expect(extrasOf(taskerIntentText(action: 'batch', connections: ['web-1', 'db-1'], command: 'uptime')),
        {'connections': 'web-1,db-1', 'command': 'uptime', 'parallel': 'true'});
    expect(
        extrasOf(taskerIntentText(
            action: 'execute', connection: 'web-1', command: 'df -h', filters: {'head': '5', 'callback': 'https://hooks.example.com/zest'})),
        {'connection_id': 'web-1', 'command': 'df -h', 'head': '5', 'callback': 'https://hooks.example.com/zest'});
    expect(extrasOf(taskerIntentText(action: 'snippet', connection: 'web-1', snippet: 'Deploy', variables: {'branch': 'main'})),
        {'connection_id': 'web-1', 'snippet_name': 'Deploy', 'var_branch': 'main'});
    expect(extrasOf(taskerIntentText(action: 'workflow', key: 'k', workflow: 'Nightly')), {'key': 'k', 'workflow_name': 'Nightly'});
    // Without a key chosen, none is written; nothing is said twice.
    expect(extrasOf(taskerIntentText(action: 'connect', connection: 'web-1')), {'connection_id': 'web-1'});
  });

  test("the guide's intents are every action the activity takes, each with the key and extras it reads", () {
    final blocks = <String, List<String>>{};
    String? current;
    for (final line in taskerGuideIntents.split('\n')) {
      final action = RegExp(r'^com\.affluentlabs\.zestssh\.(\w+)$').firstMatch(line)?.group(1);
      if (action != null) {
        current = action;
        blocks[action] = [];
      } else if (current != null && line.trim().isNotEmpty && !line.startsWith('#')) {
        blocks[current]!.add(line);
      }
    }
    expect(blocks.keys.toSet(), actions);
    for (final MapEntry(key: action, value: lines) in blocks.entries) {
      final names = [for (final line in lines) extraOf(line)?.$1];
      expect(names, everyElement(isNotNull), reason: '$action: $lines');
      expect(names.first, 'key', reason: action);
      expect(names.where((n) => !readByTheApp(n!)), isEmpty, reason: action);
    }
    expect(blocks['BATCH']!.map(extraOf).map((e) => e!.$1), contains('connections'));
  });

  test("the guide's steps say the target and the form Tasker takes, in every language", () {
    final files = Directory('lib/l10n').listSync().whereType<File>().where((f) => f.path.endsWith('.arb')).toList();
    expect(files, hasLength(12));
    for (final file in files) {
      final strings = jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
      expect(strings.values.whereType<String>().where((v) => v.contains('Broadcast Receiver')), isEmpty,
          reason: file.path);
      expect(strings['autoGuideTaskerStep4'], contains('Activity'), reason: file.path);
      final step3 = strings['autoGuideTaskerStep3'] as String;
      expect(step3, contains('\n  key:<'), reason: file.path);
      expect(step3, contains('\n  connection_id:MyServer\n  command:uptime'), reason: file.path);
      expect(step3, isNot(contains('=MyServer')), reason: file.path);
    }
  });

  test('an extra is read as text whatever type Tasker sends it as', () {
    // The helper every automation extra goes through.
    expect(activity, contains('intent.extras?.get(name)?.toString()'));
    // Typed reads are left to the app's own scheduler's extras alone.
    final typed = {
      for (final m in RegExp(r'get(String|Int|Boolean)Extra\("(\w+)"').allMatches(activity)) m.group(2)!,
    };
    // (The task's id rides with them, and is read only with the token.)
    expect(typed, {'api_key_id', 'scheduled_launch_token', 'scheduled_task_id'});
    // A batch's hosts as "connections", or as "connection_ids" as the guide
    // and the docs said.
    expect(activity, matches(RegExp(r'extraText\(intent, "connections"\)\s*\?: extraText\(intent, "connection_ids"\)')));
    // Counts and switches from their text.
    for (final name in ['timeout', 'head', 'tail']) {
      expect(activity, contains('extraText(intent, "$name")?.toIntOrNull()'), reason: name);
    }
    expect(activity, contains('extraText(intent, "parallel")?.toBooleanStrictOrNull()'));
  });
}
