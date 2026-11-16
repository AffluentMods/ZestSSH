import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/services/sudo_file_ops.dart';
import 'package:zestssh/services/sudo_runner.dart';

/// A host's exec channel for Retry with sudo (3.4): what was run as root,
/// the password each was given, and what sudo answers. [password] is the
/// right one: any other is refused as sudo refuses it.
class FakeSudoHost {
  FakeSudoHost({this.password = 'hunter2'});

  final String password;

  /// Every command line run, in order.
  final commands = <String>[];

  /// What each was given on its standard input.
  final stdins = <String>[];

  /// Files sent to /tmp for an upload (their paths on this device), and the
  /// files in /tmp removed again.
  final putFrom = <String>[];
  final removed = <String>[];

  /// What `cat` prints, for a download.
  List<int> printed = const [];

  /// What the host says instead of running, whatever the password (no
  /// sudo, sudo wants a terminal); null to check the password.
  ({int exitCode, String said})? refuses;

  /// A command that holds this fails as root with what is said.
  final failing = <String, String>{};

  SudoFileOps ops() => SudoFileOps(
    runner: SudoRunner(exec),
    putTemp: (local) async {
      putFrom.add(local);
      return '/tmp/.zestssh-edit-${putFrom.length}';
    },
    removeTemp: (temp) async => removed.add(temp),
  );

  Future<SudoExecResult> exec(
    String command, {
    required Uint8List stdin,
    StreamConsumer<List<int>>? stdoutTo,
    required Duration idle,
  }) async {
    commands.add(command);
    final given = utf8.decode(stdin);
    stdins.add(given);
    SudoExecResult answer(int code, String said) => (exitCode: code, stderr: Uint8List.fromList(utf8.encode(said)));
    late SudoExecResult result;
    if (refuses != null) {
      result = answer(refuses!.exitCode, refuses!.said);
    } else if (given != '$password\n') {
      result = answer(1, 'Sorry, try again.\nsudo: no password was provided\nsudo: 1 incorrect password attempt\n');
    } else {
      final fails = failing.entries.where((e) => command.contains(e.key)).firstOrNull;
      result = fails == null ? answer(0, '') : answer(1, fails.value);
    }
    if (stdoutTo != null) await Stream<List<int>>.value(result.exitCode == 0 ? printed : const []).pipe(stdoutTo);
    return result;
  }
}
