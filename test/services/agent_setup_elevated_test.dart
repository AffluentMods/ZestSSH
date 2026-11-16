import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/hardware_token/ssh_agent_setup.dart';
import 'package:zestssh/utils/windows_programs.dart';

/// Start agent, on Windows (found in a security
/// review): what ran as administrator was a script in %TEMP%, with its log
/// beside it, which any program of the person's could change while the
/// prompt was up. Now the commands go to the elevated PowerShell whole, in
/// its command line, nothing is written for it, and what happened is read
/// from the agent and the service. No test here reaches this machine's agent
/// or runs anything: every program is answered by the test.
void main() {
  late List<(String, List<String>, Map<String, String>?)> ran;
  late Future<ProcessResult> Function(String exe, List<String> args) answer;
  late bool agentUp;

  setUp(() {
    ran = [];
    agentUp = true;
    answer = (exe, args) async => ProcessResult(1, 0, '', '');
    SshAgentSetupService.debugRun = (exe, args, environment) {
      ran.add((exe, args, environment));
      return answer(exe, args);
    };
    SshAgentSetupService.debugAgentAnswers = () async {
      if (!agentUp) throw const SocketException('no agent');
      return true;
    };
  });

  tearDown(() {
    SshAgentSetupService.debugRun = null;
    SshAgentSetupService.debugAgentAnswers = null;
  });

  String decoded(String encoded) {
    final bytes = base64.decode(encoded);
    final units = [for (var i = 0; i < bytes.length; i += 2) bytes[i] | (bytes[i + 1] << 8)];
    return String.fromCharCodes(units);
  }

  test("the commands are PowerShell's own, encoded as -EncodedCommand takes them", () {
    const script = "Start-Service -Name 'a’b' # 中文";
    expect(decoded(encodePowerShellCommand(script)), script);
    expect(SshAgentSetupService.elevatedAgentCommands, contains('Set-Service -Name ssh-agent -StartupType Automatic'));
    expect(SshAgentSetupService.elevatedAgentCommands, contains('Start-Service -Name ssh-agent'));
  });

  test('the elevated PowerShell is given its commands whole, by its full path, and nothing is written for it',
      () async {
    final before = Directory.systemTemp.listSync().map((e) => e.path).toSet();
    expect(await SshAgentSetupService.startService(), isNull);
    final written = Directory.systemTemp
        .listSync()
        .map((e) => e.path)
        .where((p) => !before.contains(p) && p.contains('zestssh-agent-setup'))
        .toList();
    expect(written, isEmpty, reason: 'no script and no log in the temporary folder');

    final (exe, args, environment) = ran.single;
    expect(exe, windowsPowerShell);
    final command = args.last;
    expect(command, contains(r'-FilePath $env:ZEST_POWERSHELL'));
    expect(command, contains(r"'-EncodedCommand',$env:ZEST_COMMAND"));
    expect(command, contains('-Verb RunAs -Wait'));
    expect(command, isNot(contains("'-File'")), reason: 'no script file');
    expect(environment!['ZEST_POWERSHELL'], windowsPowerShell);
    expect(decoded(environment['ZEST_COMMAND']!), SshAgentSetupService.elevatedAgentCommands);
  }, skip: !Platform.isWindows);

  test("ssh-add is OpenSSH's beside the service, by its full path, else one on PATH by its full path", () async {
    final inBox = '$windowsRoot\\System32\\OpenSSH\\ssh-add.exe';
    final expected = windowsSshAdd();
    // Another ssh-add on PATH (Git's, say) is not taken before OpenSSH's.
    final other = Directory.systemTemp.createTempSync('zest_ssh_add_');
    addTearDown(() => other.deleteSync(recursive: true));
    final decoy = File('${other.path}\\ssh-add.exe')..writeAsStringSync('');
    if (File(inBox).existsSync()) {
      expect(expected, inBox);
      expect(windowsSshAdd(path: other.path), inBox);
    } else {
      expect(windowsSshAdd(path: other.path), decoy.path);
    }
    final said = await SshAgentSetupService.addKey(r'C:\keys\id_ed25519');
    if (expected == null) {
      expect(said, contains('Could not find ssh-add'));
      expect(ran, isEmpty);
    } else {
      expect(said, isNull);
      expect(ran.single.$1, expected);
      expect(ran.single.$2, [r'C:\keys\id_ed25519']);
    }
  }, skip: !Platform.isWindows);

  test('a refused prompt is said as such; an agent that does not answer, with what the service says', () async {
    answer = (exe, args) async => ProcessResult(1, 1, '', 'Start-Process : This command cannot be run due to the '
        'error: The operation was canceled by the user.');
    expect(await SshAgentSetupService.startService(), contains('You cancelled the UAC prompt'));

    agentUp = false;
    answer = (exe, args) async => exe == windowsSystemProgram('sc.exe')
        ? ProcessResult(1, 0, args.first == 'query' ? 'STATE              : 1  STOPPED' : 'START_TYPE         : 4   DISABLED', '')
        : ProcessResult(1, 0, '', '');
    final said = await SshAgentSetupService.startService();
    expect(said, contains('The agent did not start'));
    expect(said, contains('STOPPED'));
    expect(said, contains('DISABLED'));
    expect(ran.where((r) => r.$1 == windowsSystemProgram('sc.exe')).map((r) => r.$2.first), ['query', 'qc']);
  }, skip: !Platform.isWindows);
}
