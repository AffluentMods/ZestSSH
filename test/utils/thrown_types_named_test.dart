import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

/// Nothing in the app names a type by what the program calls it (3.0; the
/// SSH core's audit, the app's half of what it found of names).
///
/// A build made for release has its names obfuscated: it has another name
/// for nearly every type. Whatever asked the program for a type's name
/// (`runtimeType`), or printed a thing that writes no text of its own
/// ("Instance of" and that name), said the right name in every test and
/// "aB" in every released app.
///
/// Read from the files: what a released build says cannot be looked at
/// from a test (zest_ssh_core's ssh_errors_said_test.dart builds a program
/// with its names obfuscated and shows what it does to such a name).
void main() {
  final classes = _classesOfLib();
  final byName = <String, List<_Class>>{};
  for (final c in classes) {
    byName.putIfAbsent(c.name, () => []).add(c);
  }

  /// The classes of the app that [c] names as [name]: the one of its own
  /// file where there is one, as a private class is.
  List<_Class> called(String name, _Class c) {
    final all = byName[name] ?? const <_Class>[];
    final here = [for (final other in all) if (other.file == c.file) other];
    return here.isNotEmpty ? here : all;
  }

  /// What the language throws: a class of the app that is one of these, as
  /// it is declared or through others of the app's, is something that is
  /// thrown.
  const thrownKinds = {
    'Exception', 'Error', 'StateError', 'ArgumentError', 'RangeError', 'FormatException', 'IOException', //
    'UnsupportedError', 'UnimplementedError', 'TimeoutException', 'SocketException', 'HttpException', //
    'FileSystemException', 'TlsException', 'AssertionError', 'TypeError',
  };

  /// Whether what [c] is made from leads to something [found] is true of,
  /// through the app's own classes.
  bool leadsTo(_Class c, bool Function(String name, List<_Class> ours) found, [Set<_Class> seen = const {}]) {
    if (seen.contains(c)) return false;
    return c.above.any((name) {
      final ours = called(name, c);
      return found(name, ours) || ours.any((above) => leadsTo(above, found, {...seen, c}));
    });
  }

  // Made from one of the SSH core's errors: those keep the core's name for themselves, which is how they print.
  final coreName = RegExp(r'^(SSH|Sftp)\w*(Error|Exception)$');
  bool ofTheCore(_Class c) => leadsTo(c, (name, ours) => ours.isEmpty && coreName.hasMatch(name));
  bool thrown(_Class c) => leadsTo(c, (name, ours) => ours.isEmpty && thrownKinds.contains(name));

  final ours = [
    for (final c in classes)
      if (thrown(c) && !ofTheCore(c)) c,
  ];

  test('the classes of the app that are thrown are found', () {
    expect(ours.length, greaterThan(90));
    expect(
        ours.map((c) => c.name), containsAll(['OrchardServerException', 'StaleCrateKey', 'SyncKeysMismatchException']));
    // (And the two that are made from the SSH core's errors are told from them.)
    expect(classes.where(ofTheCore).map((c) => c.name), unorderedEquals(['HostKeyNotAccepted', 'AgentSignInAborted', 'FidoSignInAborted']));
  });

  test('each spells out what its type is called, by its own name', () {
    for (final c in ours) {
      expect(
        RegExp(r"String get typeName => '(\w+)';").allMatches(c.body).map((m) => m[1]),
        [c.name],
        reason: '${c.name} (${c.file}) is thrown and does not spell out its own name, once: add\n'
            '  @override\n  String get typeName => \'${c.name}\';\n'
            'and have it implement HasTypeName (lib/utils/type_name.dart), unless a class it is made from does',
      );
      expect(
        c.head.contains('HasTypeName') ||
            leadsTo(c, (name, ours) => ours.any((above) => above.head.contains('HasTypeName'))),
        isTrue,
        reason: '${c.name} (${c.file}) spells out a name that nothing can ask it for: it is no HasTypeName',
      );
    }
  });

  test('each writes a text of its own, or is made from something that does: none prints "Instance of" and what '
      'the program calls it', () {
    bool says(_Class c, [Set<_Class> seen = const {}]) {
      if (seen.contains(c)) return false;
      if (c.body.contains(RegExp(r'\bString toString\(\)'))) return true;
      final from = c.extended;
      if (from == null) return false;
      final above = called(from, c);
      // (What is not the app's and can be extended here writes its own text: a TimeoutException.)
      return above.isEmpty || above.any((a) => says(a, {...seen, c}));
    }

    for (final c in ours) {
      expect(says(c), isTrue, reason: '${c.name} (${c.file}) is thrown and writes no toString()');
    }
  });

  test('whatever the app throws by name is among them', () {
    // `throw X.y(` is a constructor of X's, or a static builder of X's
    // (SyncFailure.storeAnswered): that throws what it builds, which is
    // then what has to be an Exception or an Error.
    final throws = RegExp(r'\bthrow (?:const )?([A-Z]\w*)(?:\.(\w+))?\(');
    final named = <(String, String?)>{};
    for (final (_, text) in _filesOfLib()) {
      named.addAll(throws.allMatches(text).map((m) => (m[1]!, m[2])));
    }
    expect(named.map((n) => n.$1).toSet().length, greaterThan(80));
    expect(named, contains(('SyncFailure', 'storeAnswered')), reason: 'a static builder is read as one');
    for (final (name, member) in named) {
      for (final c in byName[name] ?? const <_Class>[]) {
        final builder = member == null ? null : RegExp('\\bstatic ([A-Z]\\w*) $member\\(').firstMatch(c.body);
        if (builder != null) {
          final built = builder[1]!;
          expect(byName[built]?.any((b) => thrown(b) || ofTheCore(b)) ?? thrownKinds.contains(built), isTrue,
              reason: '$name.$member (${c.file}) builds a $built, which is no Exception and no Error');
          continue;
        }
        expect(thrown(c) || ofTheCore(c), isTrue,
            reason: '$name (${c.file}) is thrown and is no Exception and no Error: nothing holds it to a name of '
                'its own');
      }
    }
  });

  test('nothing asks the program what a type is called, but to see whether two things are of one type', () {
    final sameType = RegExp(r'''^[^'"]*\bruntimeType [!=]= [\w.]*\bruntimeType\b[^'"]*$''');
    var compared = 0;
    for (final (file, text) in _filesOfLib()) {
      for (final line in text.split('\n')) {
        if (!line.contains('runtimeType') || line.trimLeft().startsWith('//')) continue;
        expect(sameType.hasMatch(line), isTrue,
            reason: '$file: "${line.trim()}" asks the program for the name of a type. A released build has another '
                'name for nearly every type: use errorKind() (lib/utils/error_kind.dart), or spell the name out');
        compared++;
      }
    }
    expect(compared, 2, reason: 'the two places that compare types (the file panes)');
  });

  test('the lines that named an error by what the program calls its type name it by its kind', () {
    // Each as it stands in its file, and how often.
    const lines = <String, Map<String, int>>{
      'lib/app.dart': {
        r"AppLogger.warning('Ticket poller not started: ${errorKind(e)}');": 1,
        r"AppLogger.warning('Secrets at rest not sealed: ${errorKind(e)}');": 1,
        // (It said the error as thrown, with the folder's path.)
        r"AppLogger.warning('The temporary folder was not read (${errorKind(e)})');": 1,
        // (3.2: the seen systems' icons kept on hosts at each start.)
        r"AppLogger.warning('Keeping the seen system icons failed: ${errorKind(e)}');": 1,
        // (A profile that has just opened: what stopped halfway is finished.)
        r"AppLogger.warning('After a profile opened: ${errorKind(e)}');": 1,
        // (The question about guest data at an account's first sign-in.)
        r"AppLogger.warning('The question about guest data: ${errorKind(e)}');": 1,
        // (WorkManager's jobs with no task cancelled at each opening, Android.)
        r"AppLogger.warning('Scheduled jobs with no task were left for now (${errorKind(e)})');": 1,
        // (3.3.3: data elsewhere on a Mac that was not brought back.)
        r"AppLogger.warning('Data elsewhere was not brought back (${errorKind(e)})');": 1,
      },
      'lib/features/feedback/feedback_service.dart': {
        r"AppLogger.warning('Feedback send error: ${errorKind(e)}');": 1,
        r"AppLogger.warning('Could not keep the ticket: ${errorKind(e)}');": 1,
      },
      'lib/features/orchards/export/event_exporter.dart': {
        r"AppLogger.info('Event export: a request failed (${errorKind(e)})');": 1,
        r"AppLogger.info('Event export: how far it got was not noted (${errorKind(e)})');": 1,
        r"AppLogger.info('Event export: the rounds did not finish (${errorKind(e)})');": 1,
        r"AppLogger.info('Event export: a round did not finish (${errorKind(e)})');": 1,
        r"AppLogger.info('Event export: the activity was not read (${errorKind(e)})');": 2,
      },
      'lib/features/orchards/orchard_service.dart': {
        r"AppLogger.info('Orchards: the events left to send did not go (${errorKind(e)})');": 1,
        // (A device drops a team only on its record's signed removal.)
        r'''AppLogger.warning("Orchards: the removal of this device could not be checked in the team's record (${errorKind(e)})");''':
            1,
        // (The device of someone joining, left out where the record refuses it.)
        r"AppLogger.warning('Orchards: the device of someone joining was not approved with them (${errorKind(e)})');": 1,
        // (A team the server stops listing leaves only on a record checked here.)
        r'''AppLogger.info("Orchards: the team's record could not say whether this account is out of it (${errorKind(e)})");''':
            1,
        // (What an invitation offered, kept on the device that made it.)
        r"AppLogger.warning('Orchards: what an invitation offers was not kept here (${errorKind(e)})');": 1,
        r"AppLogger.info('Orchards: what an invitation offered was not dropped here (${errorKind(e)})');": 1,
      },
      'lib/features/orchards/sync/crate_sync_engine.dart': {
        // (One version that throws is held back, and every other item syncs.)
        r"AppLogger.warning('Orchard sync: a version of an item was held back, to be read again (${errorKind(error)})');":
            1,
        r"AppLogger.warning('Orchard sync: the answer to a change was not handled; it waits (${errorKind(e)})');": 1,
      },
      'lib/features/orchards/setup/setup_command_host.dart': {
        r"AppLogger.warning('Setup file: the command failed (${errorKind(e)})');": 1,
        r"AppLogger.info('Setup file: ZestSSH Cloud was not reached (${errorKind(e)})');": 1,
      },
      'lib/features/orchards/setup/setup_reader.dart': {
        r"AppLogger.info('Setup file: ZestSSH Cloud was not reached (${errorKind(e)})');": 1,
        r"AppLogger.info('Setup file: the Orchard did not sync first (${errorKind(e)})');": 1,
        r"AppLogger.info('Setup file: the invitations could not be read (${errorKind(e)})');": 1,
      },
      'lib/features/orchards/team/team_setup.dart': {
        r"AppLogger.warning('Setup file: not saved (${errorKind(e)})');": 1,
        r"AppLogger.warning('Setup file: could not be opened (${errorKind(e)})');": 1,
        r"AppLogger.warning('Setup file: the Orchard could not be read (${errorKind(e)})');": 1,
        r"AppLogger.warning('Setup file: applying stopped (${errorKind(e)})');": 1,
      },
      'lib/features/orchards/widgets/team_export_view.dart': {
        r"AppLogger.info('Event export: the test event was not sent (${errorKind(e)})');": 2,
        r"AppLogger.warning('Event export: not turned off (${errorKind(e)})');": 1,
        r"AppLogger.warning('Event export: the address was not changed (${errorKind(e)})');": 1,
        r"AppLogger.warning('Event export: not turned on (${errorKind(e)})');": 1,
      },
      'lib/features/tickets/ticket_poller.dart': {r"AppLogger.warning('Ticket check failed: ${errorKind(e)}');": 1},
      'lib/features/tickets/ticket_service.dart': {
        r"AppLogger.warning('Ticket call not delivered: ${errorKind(e)}');": 1,
        // (3.4: a screenshot the person attached, read back with the token.)
        r"AppLogger.warning('Ticket screenshot not read: ${errorKind(e)}');": 1,
      },
      // (3.4: everyone's reports and +1.)
      'lib/features/tickets/public_reports.dart': {
        r"AppLogger.warning('Vote device id not read: ${errorKind(e)}');": 1,
        r"AppLogger.warning('Report votes not read: ${errorKind(e)}');": 1,
        r"AppLogger.warning('Report vote not delivered: ${errorKind(e)}');": 1,
      },
      'lib/services/sync_service.dart': {
        r"'If this persists, try restoring from a backup. (${errorKind(e)})',": 1,
      },
      'lib/services/automation_service.dart': {
        r"AppLogger.warning('Webhook to ${webhookNamed(uri)} failed: ${errorKind(e)}');": 1,
      },
    };
    var all = 0;
    for (final MapEntry(key: file, value: wanted) in lines.entries) {
      final text = File(file).readAsStringSync();
      for (final MapEntry(key: line, value: times) in wanted.entries) {
        expect(line.allMatches(text).length, times, reason: '$file: $line');
        all += times;
      }
      // And nothing else there names an error's kind.
      expect('errorKind('.allMatches(text).length, wanted.values.reduce((a, b) => a + b), reason: file);
    }
    expect(all, 46);
  });
}

/// A class of lib/ as its file declares it.
class _Class {
  _Class(this.name, this.file, this.head, this.body);

  final String name;
  final String file;

  /// From "class" to its opening brace.
  final String head;

  /// From its opening brace to the closing one.
  final String body;

  String get _flat => head.replaceAll(RegExp(r'\s+'), ' ').replaceAll(RegExp(r'\s*\{$'), '');

  List<String> _after(String word, String until) {
    final list = RegExp('\\b$word\\s+([\\w.<>, ]+?)(?=$until)').firstMatch(_flat)?[1] ?? '';
    return [
      for (final name in list.split(','))
        if (name.trim().isNotEmpty) name.trim().split('<').first,
    ];
  }

  /// The class it extends, if it extends one.
  String? get extended => _after('extends', r'\s+with\b|\s+implements\b|$').firstOrNull;

  /// Everything it extends, mixes in and implements.
  List<String> get above => [
        ..._after('extends', r'\s+with\b|\s+implements\b|$'),
        ..._after('with', r'\s+implements\b|$'),
        ..._after('implements', r'$'),
      ];
}

/// The files of lib/ that are written by hand, each with its text (line ends as "\n").
List<(String, String)> _filesOfLib() => [
      for (final file in Directory('lib').listSync(recursive: true).whereType<File>())
        if (file.path.endsWith('.dart') && !file.path.endsWith('.g.dart'))
          (file.path.replaceAll('\\', '/'), file.readAsStringSync().replaceAll('\r\n', '\n')),
    ];

/// Every class declared at the top of a file of lib/. A class ends at the
/// first line after its head that is a closing brace in the first column,
/// as the formatter writes it.
List<_Class> _classesOfLib() {
  final head = RegExp(r'^(?:abstract |final |sealed |base |interface |mixin )*class (\w+)[^{;]*\{', multiLine: true);
  return [
    for (final (file, text) in _filesOfLib())
      for (final m in head.allMatches(text))
        _Class(
          m[1]!,
          file,
          m[0]!,
          text.substring(
            m.end - 1,
            switch (text.indexOf('\n}\n', m.end - 1)) { -1 => text.length, final end => end + 2 },
          ),
        ),
  ];
}
