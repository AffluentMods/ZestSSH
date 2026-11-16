import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:zestssh/utils/windows_programs.dart';

import 'os_ssh_agent.dart';

/// Coarse state of the OS ssh-agent on this machine.
///
/// Drives the hardware-token dialog so we can show the right CTA
/// instead of dumping PowerShell snippets at the user.
enum AgentSetupState {
  /// Service is reachable AND has at least one identity loaded.
  /// The dialog can render the identity list immediately.
  runningWithKeys,

  /// Service is reachable but ssh-add hasn't been called for any
  /// keys yet. Show an "Add a key…" CTA.
  runningEmpty,

  /// Service exists in the registry / launchd but is currently
  /// stopped. We can flip it on with one button.
  installedStopped,

  /// OpenSSH client is not installed at all (Windows: optional
  /// feature is missing; Linux/macOS: extremely rare). Show a
  /// platform-specific install hint.
  notInstalled,

  /// Some other error - surface the underlying message.
  unknown,
}

/// Snapshot of the agent's current health, plus a free-form detail
/// string we can show inline if [state] is [AgentSetupState.unknown].
class AgentSetupReport {
  AgentSetupReport({required this.state, this.detail, this.identityCount = 0, this.pipeNotYours = false});
  final AgentSetupState state;
  final String? detail;
  final int identityCount;

  /// On Windows, the agent's pipe is served by another account's program
  /// ([AgentPipeNotYours]): nothing was asked of it.
  final bool pipeNotYours;
}

/// One-shot detector + service controller for the OS ssh-agent.
///
/// Pure side-effect-driven IO. No state of its own - every call goes
/// to the platform fresh. Caller decides how to surface results.
class SshAgentSetupService {
  SshAgentSetupService._();

  // ── Detection ───────────────────────────────────────────────────

  /// Probe the system. Order of operations:
  ///   1. Try to open the agent. If the connection succeeds, count
  ///      identities and return runningWithKeys / runningEmpty.
  ///   2. On failure, ask the platform whether the *service* exists.
  ///      If it does, the issue is "stopped" - we can fix it.
  ///   3. Otherwise, return notInstalled / unknown.
  static Future<AgentSetupReport> probe() async {
    // 1. happy path
    try {
      final agent = await OsSshAgent.open();
      try {
        final ids = await agent.listIdentities();
        return AgentSetupReport(
          state: ids.isEmpty
              ? AgentSetupState.runningEmpty
              : AgentSetupState.runningWithKeys,
          identityCount: ids.length,
        );
      } finally {
        await agent.close();
      }
    } on AgentPipeNotYours catch (e) {
      // Something answers, and it is not to be used: not a stopped service.
      return AgentSetupReport(state: AgentSetupState.unknown, detail: e.message, pipeNotYours: true);
    } catch (e) {
      // fall through to platform-specific diagnostics
      final detail = e.toString();
      final servicePresent = await _isServicePresent();
      if (servicePresent == _ServicePresence.absent) {
        return AgentSetupReport(
            state: AgentSetupState.notInstalled, detail: detail);
      }
      if (servicePresent == _ServicePresence.present) {
        return AgentSetupReport(
            state: AgentSetupState.installedStopped, detail: detail);
      }
      return AgentSetupReport(
          state: AgentSetupState.unknown, detail: detail);
    }
  }

  /// Ask the platform whether the agent *binary / service* is
  /// installed. Distinct from "is it running" - this returns
  /// "present" for a service that's defined but stopped.
  ///
  /// On Windows we double-check: a service-control entry alone isn't
  /// enough. The actual `ssh-agent.exe` binary must exist at
  /// `%SystemRoot%\System32\OpenSSH\ssh-agent.exe`. A user who
  /// removed the OpenSSH Client capability can leave a stale service
  /// entry behind, which `Start-Service` happily reports as starting
  /// while the binary fails to launch - that's exactly the
  /// "snackbar said success but nothing is running" trap.
  static Future<_ServicePresence> _isServicePresent() async {
    if (Platform.isWindows) {
      try {
        final result = await Process.run(windowsSystemProgram('sc.exe'), ['query', 'ssh-agent']);
        // 1060 = ERROR_SERVICE_DOES_NOT_EXIST → not installed.
        if (result.exitCode == 1060) return _ServicePresence.absent;
        // Service entry exists. Verify the binary is also present -
        // if it isn't, the user needs to (re)install the OpenSSH
        // Client capability, not click "Start".
        final sysRoot = Platform.environment['SystemRoot'] ?? r'C:\Windows';
        final binary = File('$sysRoot\\System32\\OpenSSH\\ssh-agent.exe');
        if (await binary.exists()) return _ServicePresence.present;
        return _ServicePresence.absent;
      } catch (_) {
        return _ServicePresence.unknown;
      }
    }
    if (Platform.isLinux || Platform.isMacOS) {
      try {
        final result = await Process.run('which', ['ssh-add']);
        return result.exitCode == 0
            ? _ServicePresence.present
            : _ServicePresence.absent;
      } catch (_) {
        return _ServicePresence.unknown;
      }
    }
    return _ServicePresence.unknown;
  }

  // ── Control ─────────────────────────────────────────────────────

  /// Try to start the agent. Returns null on success; on failure
  /// returns a human-readable error string the dialog can show.
  ///
  /// On Windows: the agent's service is set to start with Windows and
  /// started, by a PowerShell run as administrator (`Start-Process -Verb
  /// RunAs`), its commands handed to it whole in its command line
  /// (-EncodedCommand, [encodePowerShellCommand]). Nothing it runs or writes
  /// is a file: it was a script in %TEMP%, with a log beside it, which any
  /// program of the person's could change while the prompt was up and so
  /// run as administrator (found in a security
  /// review of the client). What happened is read afterwards from the agent itself, and
  /// where it does not answer, from the service.
  ///
  /// On Linux/macOS: there's no single "start the agent" command
  /// that works across all configurations. We surface a clear error
  /// so the dialog can show platform-specific instructions instead.
  static Future<String?> startService() async {
    if (!Platform.isWindows) {
      return 'Auto-start is only implemented on Windows. On Linux / '
          'macOS, run `eval \$(ssh-agent -s)` in your shell startup '
          'file so the agent is available to GUI apps.';
    }

    try {
      final launcher = await _run(
        windowsPowerShell,
        [
          '-NoProfile',
          '-NonInteractive',
          '-Command',
          // Both from the environment, read as text: nothing in them is
          // taken for code here.
          r"Start-Process -FilePath $env:ZEST_POWERSHELL -ArgumentList '-NoProfile','-NonInteractive','-EncodedCommand',$env:ZEST_COMMAND -Verb RunAs -Wait",
        ],
        environment: {
          'ZEST_POWERSHELL': windowsPowerShell,
          'ZEST_COMMAND': encodePowerShellCommand(elevatedAgentCommands),
        },
      );

      // Elevate via `Start-Process -Verb RunAs -Wait`: Windows won't let the
      // parent read an elevated child's exit code across the UAC boundary
      // (`$p.ExitCode` returns null, which PowerShell coerces to 0), so the
      // launcher says only whether the prompt was refused.
      final stderr = (launcher.stderr as String).trim();
      if (stderr.contains('canceled') || stderr.contains('cancelled')) {
        return 'You cancelled the UAC prompt. Click "Start agent" '
            'again and approve it to enable the service.';
      }

      // The SCM can lie: a service can be in "Running" state while its
      // primary thread has already exited (binary missing, immediate crash,
      // etc.). The ONLY way to know for sure is to talk to the named pipe.
      // Poll up to 3 seconds.
      Object? lastError;
      for (var i = 0; i < 15; i++) {
        try {
          if (await _agentAnswers()) return null; // real success - the pipe is up
        } catch (e) {
          lastError = e;
        }
        await Future.delayed(const Duration(milliseconds: 200));
      }

      // The agent does not answer: what the service says, and what the
      // launcher said, as plain text.
      final service = await _serviceSays();
      return 'The agent did not start: its socket is still unreachable '
          'after 3 seconds. Possible causes:\n'
          '  • The elevated PowerShell could not set the service to start '
          'or start it (a policy, or the service disabled by an '
          'administrator)\n'
          '  • OpenSSH Client feature is not actually installed '
          '(the service entry exists but `ssh-agent.exe` is missing). '
          'Verify with: Get-WindowsCapability -Online -Name OpenSSH.Client*\n'
          '  • Antivirus or endpoint-protection software is blocking '
          'the named pipe\n'
          '  • A non-OpenSSH service named `ssh-agent` is registered '
          'and starting in its place\n\n'
          'Last connection error: ${lastError ?? '(none)'}\n\n'
          'The service says:\n${service.isEmpty ? '(nothing)' : service}'
          '${stderr.isEmpty ? '' : '\n\nPowerShell said:\n${sanitizeLogForDisplay(stderr)}'}';
    } on ProcessException catch (e) {
      return 'Could not invoke PowerShell: ${e.message}';
    } catch (e) {
      return 'Failed to start agent: $e';
    }
  }

  /// What the elevated PowerShell runs: the agent's service set to start
  /// with Windows, and started.
  static const elevatedAgentCommands = r'''
$ErrorActionPreference = 'Stop'
Set-Service -Name ssh-agent -StartupType Automatic
Start-Service -Name ssh-agent
''';

  /// The service's state and how it starts (`sc.exe query` and `qc`), as
  /// plain text; empty where it cannot be read.
  static Future<String> _serviceSays() async {
    final out = StringBuffer();
    for (final ask in const ['query', 'qc']) {
      try {
        final r = await _run(windowsSystemProgram('sc.exe'), [ask, 'ssh-agent']);
        out.writeln((r.stdout as String).trim());
      } catch (_) {
        // Nothing more to say.
      }
    }
    return sanitizeLogForDisplay(out.toString()).trim();
  }

  /// Whether the agent answers on its pipe.
  static Future<bool> _agentAnswers() async {
    final instead = debugAgentAnswers;
    if (instead != null) return instead();
    final agent = await OsSshAgent.open();
    await agent.close();
    return true;
  }

  /// [Process.run], or what a test puts in its place.
  static Future<ProcessResult> _run(String executable, List<String> args, {Map<String, String>? environment}) {
    final instead = debugRun;
    if (instead != null) return instead(executable, args, environment);
    return Process.run(executable, args, environment: environment);
  }

  /// Run in place of [Process.run] by [startService] and [addKey], in a test.
  @visibleForTesting
  static Future<ProcessResult> Function(String executable, List<String> args, Map<String, String>? environment)?
      debugRun;

  /// Asked in place of the agent's pipe by [startService], in a test (one
  /// never reaches this machine's agent).
  @visibleForTesting
  static Future<bool> Function()? debugAgentAnswers;

  /// Run `ssh-add <pemPath>`. Returns null on success; otherwise the
  /// stderr text from ssh-add (typically "wrong passphrase",
  /// "permissions too open", etc.).
  ///
  /// On Windows / macOS this prompts the user for a passphrase in a
  /// platform-native way (Windows: a console window briefly appears;
  /// macOS: Keychain prompt). We don't pipe `passphrase` through
  /// stdin because that's both insecure (visible in `ps`) and prone
  /// to encoding bugs.
  static Future<String?> addKey(String pemPath) async {
    try {
      // On Windows the one beside the agent's service (OpenSSH in System32),
      // else one on PATH, by its full path: never one in the current folder.
      final sshAdd = Platform.isWindows ? windowsSshAdd() : 'ssh-add';
      if (sshAdd == null) {
        return 'Could not find ssh-add. Is OpenSSH installed?';
      }
      final result = await _run(sshAdd, [pemPath]);
      if (result.exitCode == 0) return null;
      final err = (result.stderr as String).trim();
      return err.isEmpty
          ? 'ssh-add exited with code ${result.exitCode}'
          : err;
    } on ProcessException catch (e) {
      return 'Could not invoke ssh-add: ${e.message}. Is OpenSSH '
          'installed and on PATH?';
    }
  }

  /// Open the OS settings page where the user can install OpenSSH
  /// (Windows only - Linux/macOS users who don't have ssh-add are
  /// rare enough that we just point them at their package manager).
  ///
  /// Returns null on success / a description on failure.
  static Future<String?> openInstallSettings() async {
    if (!Platform.isWindows) {
      return 'On Linux: install via your package manager (apt install '
          'openssh-client, dnf install openssh-clients, …).\n'
          'On macOS: ssh-add is bundled with the OS - if it is '
          'missing, your installation is unusual.';
    }
    try {
      // Direct deep-link to the Optional Features page.
      await Process.run(windowsSystemProgram('cmd.exe'),
          ['/c', 'start', 'ms-settings:optionalfeatures']);
      return null;
    } on ProcessException catch (e) {
      return 'Could not open Settings: ${e.message}';
    }
  }
}

/// Internal - three-way "does the service binary even exist"
enum _ServicePresence { present, absent, unknown }

/// Windows' ssh-add: OpenSSH's in System32, else one on [path] (PATH by
/// default), by its full path; null where there is none.
String? windowsSshAdd({String? path}) {
  final inBox = '$windowsRoot\\System32\\OpenSSH\\ssh-add.exe';
  if (File(inBox).existsSync()) return inBox;
  return findOnPath('ssh-add.exe', path: path);
}

/// [script] as PowerShell's -EncodedCommand takes it: its UTF-16LE bytes,
/// in base64.
String encodePowerShellCommand(String script) {
  final bytes = <int>[];
  for (final unit in script.codeUnits) {
    bytes
      ..add(unit & 0xFF)
      ..add(unit >> 8);
  }
  return base64.encode(bytes);
}

/// Strip terminal escape sequences and other control characters
/// from a program's output before showing it in a dialog: displayed as-is,
/// they can scramble the dialog or smuggle ANSI in for terminal-aware
/// renderers.
String sanitizeLogForDisplay(String? raw) {
  if (raw == null) return '';
  // Strip ESC + CSI sequences and non-printable controls except
  // \r and \n which we keep so multi-line logs still wrap cleanly.
  final cleaned = raw.replaceAll(
    RegExp(r'\x1B\[[0-?]*[ -/]*[@-~]|[\x00-\x08\x0B\x0C\x0E-\x1F\x7F]'),
    '',
  );
  // Truncate to keep the dialog small.
  return cleaned.length > 4000 ? cleaned.substring(0, 4000) : cleaned;
}
