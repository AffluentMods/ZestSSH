import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/hosts/local_terminal.dart';
import 'package:zestssh/features/snippets/state/snippet_usage_provider.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/services/ssh_service.dart' show ShellOneOff, SshService;
import 'package:zestssh/ui/screens/desktop/widgets/shell_questions.dart';
import 'package:zestssh/ui/screens/snippets/widgets/snippet_variable_dialog.dart';
import 'package:zestssh/ui/widgets/connection_picker_dialog.dart' show ConnectionPickerResult;
import 'package:zestssh/ui/widgets/dangerous_command_dialog.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/command_text.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// What reads a snippet's list of a host's own (`$[DOCKER]`, `$[TMUX]`) on
/// [session]'s host: a command run beside its shell on its connection, where
/// its shell can ([ShellOneOff], an SSH session's). Null otherwise, and the
/// list is typed in (a computer's palette, Inspector and library had none to
/// give, so every such list said there was no session; 3.0, found while
/// comparing the five versions).
CommandExecutor? listOptionsFrom(SessionState? session) {
  final shell = session?.session?.shell;
  return shell is ShellOneOff ? (command) => (shell as ShellOneOff).runOnce(command) : null;
}

/// Types [snippet] at [terminal]'s prompt: the one way every surface runs a
/// snippet (the command palette and the Inspector).
///
/// Variables are filled in first: the person is asked for those without a
/// default, and defaults are used silently; a list of the host's own is read
/// with [listOptions]. Then the risky-command check (when it is on) or the
/// snippet's own "confirm before running" asks. Nothing is typed when the
/// person cancels any of them. The command is typed, and entered too when the
/// person has "Press Enter after pasting a snippet" on ([typePickedSnippet];
/// on a computer that setting did nothing, 3.0 docs check). Returns true when
/// it was typed.
Future<bool> runSnippetIn(
  BuildContext context,
  WidgetRef ref,
  Snippet snippet,
  Terminal terminal, {
  CommandExecutor? listOptions,
}) async {
  // The setting is read from the app's container: [ref]'s widget (the
  // palette) may be closed by the time the questions are answered.
  final container = ProviderScope.containerOf(context, listen: false);
  final ready = await commandReadyToRun(
    context,
    ref,
    command: snippet.command,
    label: snippet.label,
    confirmFirst: snippet.confirmBeforeRun,
    listOptions: listOptions,
  );
  if (ready == null) return false;
  // One Enter per line end: a snippet written on Windows ends its lines in
  // two characters, and each of them is Enter to a shell.
  typePickedSnippet(container.read, terminal, ready.command, secrets: ready.secrets);
  return true;
}

/// [command] made ready to run (a snippet's, or one typed; 3.0, Run on hosts
/// as well): its variables filled in first (the person is asked for those
/// without a default, and defaults are used silently, [label] naming what
/// they are for); then the risky-command check (when it is on), or, where
/// [confirmFirst] (a snippet's own "confirm before running"), a question.
/// Null when the person cancels any of them. With the command, the masked
/// values filled into it (`${VAR:secret}`), and the command as it is shown with
/// them out of sight: what every question here shows, and a run on hosts, whose
/// team's log they stay out of as well. The variables' last button says
/// [doneLabel] ("Paste" where none is given). A list of the host's own is
/// read with [listOptions], where there is one host to read it on. With
/// [literal] (a command run again from History: a shell line, typed as it
/// is) there are no variables: `${HOME}` and `$[...]` go to the shell as
/// written, and only the risky-command check or the question is asked.
Future<({String command, List<String> secrets, String shown})?> commandReadyToRun(
  BuildContext context,
  WidgetRef ref, {
  required String command,
  String? label,
  bool confirmFirst = false,
  String? doneLabel,
  CommandExecutor? listOptions,
  bool literal = false,
}) async {
  // Captured before any await: the caller's context may be a popup that is
  // gone by the time a dialog returns.
  final navigator = Navigator.of(context, rootNavigator: true);
  final l10n = AppLocalizations.of(context)!;
  final protectionOn = ref.read(dangerousCommandProtectionProvider);
  final settingsUpdater = ref.read(settingsUpdaterProvider);

  final toPrompt = literal ? const <ParsedVariable>[] : variablesToPrompt(command);
  final Map<String, String> values;
  if (literal) {
    values = const {};
  } else if (toPrompt.isNotEmpty) {
    final asked = await showVariableInputDialog(
      context: navigator.context,
      variables: parseVariablesWithOptions(command).map((v) => v.name).toList(),
      snippetLabel: label ?? '',
      command: command,
      executeCommand: listOptions,
      doneLabel: doneLabel,
    );
    if (asked == null) return null;
    values = asked;
  } else {
    values = defaultSeedValues(command);
  }
  final secrets = literal ? const <String>[] : maskedValuesIn(command, values);
  final shown = literal ? command : resolveVariablesShown(command, values);
  if (!literal) command = resolveVariables(command, values);

  final dangers = protectionOn
      ? DangerousCommandService.checkFilled(command)
      : const <DangerousCommandMatch>[];
  // The app may have closed its windows while a dialog was open.
  final dialogContext = navigator.context;
  if (!dialogContext.mounted) return null;
  if (dangers.isNotEmpty) {
    final result = await showDangerousCommandDialog(
      dialogContext,
      command: shown,
      runs: command,
      matches: dangers,
    );
    if (result.dontAskAgain) {
      await settingsUpdater.setDangerousCommandProtection(false);
    }
    if (!result.proceed) return null;
  } else if (confirmFirst) {
    final ok = await ZestConfirmDialog.show(
      dialogContext,
      tone: ZestDialogTone.neutral,
      title: l10n.snippetRunConfirmTitle,
      body: l10n.snippetRunConfirmBody,
      bullets: [commandForQuestion(shown)],
      confirmLabel: l10n.snippetRunAction,
    );
    if (ok != true) return null;
  }
  return (command: command, secrets: secrets, shown: shown);
}

/// Types [command], a snippet picked from the list inside a session, at
/// [terminal]'s prompt, and enters it when the person has "Press Enter after
/// pasting a snippet" on. [read] is the caller's `ref.read`. [secrets], the masked
/// values filled into it, are told to the session first: what asks before a
/// broadcast goes on, and what keeps its history, go by what they read off the
/// terminal, and the broadcast's question showed them in clear.
void typePickedSnippet(
  T Function<T>(ProviderListenable<T> provider) read,
  Terminal terminal,
  String command, {
  List<String> secrets = const [],
}) {
  if (secrets.isNotEmpty) read(activeSessionsProvider.notifier).noteFilledSecrets(terminal, secrets);
  terminal.textInput(read(autoExecuteSnippetsProvider)
      ? CommandText.entered(command)
      : CommandText.typed(command));
}

/// The host a snippet's [metadata] names as its default ("Default host" in
/// its editor), among [hosts]: null when it names none, or one deleted since.
ConnectionWithDetails? defaultHostOf(List<ConnectionWithDetails> hosts, String? metadata) {
  final id = parseSnippetMetadata(metadata).defaultConnectionId;
  if (id == null || id.isEmpty) return null;
  for (final h in hosts) {
    if (h.connection.id == id) return h;
  }
  return null;
}

/// A session of [connectionId] a command can be typed into without surprise:
/// connected, SSH, and shown (never a hidden one, or a mosh, serial or local
/// one nobody is looking at, nor one that is files only, with no shell).
/// Null when there is none.
SessionState? liveSshSessionOf(Map<String, SessionState> sessions, String connectionId) {
  for (final s in sessions.values) {
    final shell = s.session?.shell;
    if (s.connectionId == connectionId &&
        s.status == SessionStatus.connected &&
        (shell?.isEncryptedSsh ?? false) &&
        !(shell is SshService && shell.filesOnly) &&
        !s.isHidden) {
      return s;
    }
  }
  return null;
}

/// Runs [command] on [host], from a computer's snippet library and editor
/// (Run on…, or the snippet's default host; 3.0 docs check).
///
/// It is made ready as everywhere a snippet runs ([commandReadyToRun]): its
/// variables asked for where they have no default, then the risky-command
/// check or, where [confirmFirst], the snippet's own question. Where the host
/// has a live session it is entered there. Where it has none, a session is
/// opened to it as Connect opens one (Telnet asked about first, the free
/// plan's limit said), shown in front, and the command is entered there once
/// it is connected (it was copied to the clipboard, and nothing ran). A run
/// of a saved snippet ([snippetId]) is counted once it is sent or waits for
/// its session. Returns true then. With [literal] (a command run again from
/// History) it has no variables: it goes to the host exactly as written,
/// still checked for a risky command.
Future<bool> runCommandOnHost(
  BuildContext context,
  WidgetRef ref, {
  required ConnectionWithDetails host,
  required String command,
  String? label,
  bool confirmFirst = false,
  String? snippetId,
  bool literal = false,
}) async {
  final l10n = AppLocalizations.of(context)!;
  // Captured before any await: the library or editor that asked may be gone
  // by the time its session connects (the sessions are brought to the front).
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  final container = ProviderScope.containerOf(context, listen: false);
  final connection = host.connection;
  // A host's name in a notice is painted: it goes through the host rule.
  final name = Redactable.host(connection.label.isNotEmpty ? connection.label : connection.host).display;

  // A host that is SFTP only has no shell to run it in: said, and nothing
  // is opened.
  final noTerminal = noTerminalReason(connection, l10n);
  if (noTerminal != null) {
    showTopSnackBar(rootContext, noTerminal, isWarning: true);
    return false;
  }

  final live = liveSshSessionOf(container.read(activeSessionsProvider), connection.id);
  if (live == null && connection.protocol == 'telnet') {
    if (!await confirmUnencryptedConnection(rootContext)) return false;
  }
  if (!rootContext.mounted) return false;
  final ready = await commandReadyToRun(
    rootContext,
    ref,
    command: command,
    label: label,
    confirmFirst: confirmFirst,
    doneLabel: l10n.zestSnippetsRunButton,
    listOptions: listOptionsFrom(live),
    literal: literal,
  );
  if (ready == null) return false;
  final toastContext = rootContext;
  final sessions = container.read(activeSessionsProvider.notifier);
  final bytes = Uint8List.fromList(utf8.encode(CommandText.entered(ready.command)));

  // The live session may have closed while a question was open.
  final stillLive = live == null ? null : liveSshSessionOf(container.read(activeSessionsProvider), connection.id);
  if (stillLive != null) {
    sessions.sendInput(stillLive.session!.id, bytes);
    if (snippetId != null) container.read(snippetUsageProvider.notifier).recordRun(snippetId);
    if (toastContext.mounted) {
      showTopSnackBar(toastContext, l10n.zestSnippetsRunSent(name), duration: const Duration(seconds: 2));
    }
    return true;
  }

  final sessionId = sessions.startSession(connection);
  if (sessionId == null) {
    if (toastContext.mounted) {
      showTopSnackBar(toastContext, l10n.desktopShellFreeTierLimit(freeSessionLimit), isError: true);
    }
    return false;
  }
  container.read(workTabsProvider.notifier).onSessionCreated(sessionId);
  container.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  container.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
  if (snippetId != null) container.read(snippetUsageProvider.notifier).recordRun(snippetId);
  if (toastContext.mounted) {
    showTopSnackBar(toastContext, l10n.docCheckSnippetOpening(name), duration: const Duration(seconds: 3));
  }
  unawaited(enterWhenConnected(container, sessionId, bytes).then((sent) {
    if (!sent && toastContext.mounted) {
      showTopSnackBar(toastContext, l10n.docCheckSnippetNotRun(name), isWarning: true);
    }
  }));
  return true;
}

/// Runs [command] in a new terminal on this device ([openLocalTerminalWith]),
/// the first choice of a snippet's Run on... where the device has a shell of
/// its own ([localTerminalOnThisDevice]).
///
/// It is made ready as a run on a host is ([commandReadyToRun]): its
/// variables asked for where they have no default (a list of a host's own is
/// typed in: there is no host to read it on), then the risky-command check or,
/// where [confirmFirst], the snippet's own question. Only then is the
/// terminal opened, so a run cancelled leaves none behind. It is the person's
/// own whichever space is on screen, shown in front, and the command is
/// entered once it is connected. Where the free plan's limit of open sessions
/// is reached nothing opens, and that is said. A run of a saved snippet
/// ([snippetId]) is counted once its terminal is opened. True then.
Future<bool> runCommandInLocalTerminal(
  BuildContext context,
  WidgetRef ref, {
  required String command,
  String? label,
  bool confirmFirst = false,
  String? snippetId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  final container = ProviderScope.containerOf(context, listen: false);
  final name = l10n.hostsToolbarTerminal;
  final ready = await commandReadyToRun(
    rootContext,
    ref,
    command: command,
    label: label,
    confirmFirst: confirmFirst,
    doneLabel: l10n.zestSnippetsRunButton,
  );
  if (ready == null) return false;
  final toastContext = rootContext;
  final sessionId = openLocalTerminalWith(container.read, l10n);
  if (sessionId == null) {
    if (toastContext.mounted) {
      showTopSnackBar(toastContext, l10n.desktopShellFreeTierLimit(freeSessionLimit), isError: true);
    }
    return false;
  }
  container.read(workTabsProvider.notifier).onSessionCreated(sessionId);
  container.read(sidebarSectionProvider.notifier).state = SidebarSection.sessions;
  container.read(v3ActiveSessionTabProvider.notifier).state = sessionId;
  if (snippetId != null) container.read(snippetUsageProvider.notifier).recordRun(snippetId);
  if (toastContext.mounted) {
    showTopSnackBar(toastContext, l10n.docCheckSnippetOpening(name), duration: const Duration(seconds: 3));
  }
  final bytes = Uint8List.fromList(utf8.encode(CommandText.entered(ready.command)));
  unawaited(enterWhenConnected(container, sessionId, bytes).then((sent) {
    if (!sent && toastContext.mounted) {
      showTopSnackBar(toastContext, l10n.docCheckSnippetNotRun(name), isWarning: true);
    }
  }));
  return true;
}

/// What a snippet's Run on... picked ([result]), run there: this device's own
/// terminal ([runCommandInLocalTerminal]) or a host ([runCommandOnHost]).
/// Nothing where nothing was picked. True when it was sent or waits for its
/// session.
Future<bool> runCommandOnPicked(
  BuildContext context,
  WidgetRef ref,
  ConnectionPickerResult result, {
  required String command,
  String? label,
  bool confirmFirst = false,
  String? snippetId,
}) async {
  if (!context.mounted) return false;
  if (result.localTerminal) {
    return runCommandInLocalTerminal(context, ref,
        command: command, label: label, confirmFirst: confirmFirst, snippetId: snippetId);
  }
  final host = result.connection;
  if (host == null) return false;
  return runCommandOnHost(context, ref,
      host: host, command: command, label: label, confirmFirst: confirmFirst, snippetId: snippetId);
}

/// Sends [bytes] to the session [sessionId] once it is connected. True when
/// they were sent; false when it ended (an error, a disconnect, closed) or
/// did not connect within [timeout] (a password prompt left open). The
/// app's own work on a new connection (its environment variables, its
/// startup command and snippet) goes first: they are typed as it connects,
/// the bytes [settle] later.
Future<bool> enterWhenConnected(
  ProviderContainer container,
  String sessionId,
  Uint8List bytes, {
  Duration timeout = const Duration(minutes: 3),
  Duration settle = const Duration(milliseconds: 500),
}) {
  final done = Completer<bool>();
  ProviderSubscription<Map<String, SessionState>>? sub;
  Timer? timer;
  var connected = false;
  void finish(bool sent) {
    if (done.isCompleted) return;
    timer?.cancel();
    sub?.close();
    done.complete(sent);
  }

  void check(Map<String, SessionState> all) {
    if (connected) return;
    final s = all[sessionId];
    if (s == null || s.status == SessionStatus.error || s.status == SessionStatus.disconnected) {
      finish(false);
      return;
    }
    if (s.status != SessionStatus.connected || s.session == null) return;
    connected = true;
    timer?.cancel();
    timer = Timer(settle, () {
      final now = container.read(activeSessionsProvider)[sessionId];
      if (now == null || now.status != SessionStatus.connected) {
        finish(false);
        return;
      }
      container.read(activeSessionsProvider.notifier).sendInput(sessionId, bytes);
      finish(true);
    });
  }

  sub = container.listen<Map<String, SessionState>>(activeSessionsProvider, (_, next) => check(next));
  timer = Timer(timeout, () => finish(false));
  check(container.read(activeSessionsProvider));
  return done.future;
}

/// The session open in the app now (the computer's session tab in front),
/// while it is connected: where the Snippets page's Run goes when the
/// snippet names no default host. Null when there is none.
SessionState? currentSessionOf(T Function<T>(ProviderListenable<T> provider) read) {
  final id = read(v3ActiveSessionTabProvider);
  final s = id == null ? null : read(activeSessionsProvider)[id];
  if (s == null || s.status != SessionStatus.connected || s.session == null) return null;
  return s;
}

/// The sessions open to hosts, as [read] finds them, that a command can be
/// typed into, the last used first: where the Snippets page's Run goes when
/// the person is not in a session (it said "No
/// session is open" with three session tabs open, the Snippets page not being
/// one of them). Not one hidden, nor one that is files only, with no shell.
List<SessionState> openSessionsByUse(T Function<T>(ProviderListenable<T> provider) read) {
  final used = read(hostUseProvider);
  final open = [
    for (final s in read(activeSessionsProvider).values)
      if (s.status == SessionStatus.connected &&
          s.session != null &&
          s.connectionId != null &&
          !s.isHidden &&
          !(s.session!.shell is SshService && (s.session!.shell as SshService).filesOnly))
        s,
  ];
  DateTime at(SessionState s) => used[s.connectionId] ?? s.session!.startedAt;
  return open..sort((a, b) => at(b).compareTo(at(a)));
}

/// Runs [command] in the session [sessionId] (the Snippets page's "Run in
/// the session you're in"): made ready as everywhere ([commandReadyToRun]:
/// its variables asked, the dangerous-command check or, where
/// [confirmFirst], its own question), then entered there. A saved snippet's
/// run ([snippetId]) is counted. True when it was sent.
Future<bool> runCommandInSession(
  BuildContext context,
  WidgetRef ref, {
  required String sessionId,
  required String command,
  String? label,
  bool confirmFirst = false,
  String? snippetId,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final rootContext = Navigator.of(context, rootNavigator: true).context;
  final container = ProviderScope.containerOf(context, listen: false);
  final session = container.read(activeSessionsProvider)[sessionId];
  if (session == null) return false;
  // A remote screen (4.0) has no shell to run it in.
  if (container.read(activeSessionsProvider.notifier).isScreen(sessionId)) {
    showTopSnackBar(rootContext, l10n.hostScreenNoTerminal, isWarning: true);
    return false;
  }
  // A session that is files only has no shell to run it in.
  if (container.read(activeSessionsProvider.notifier).isFilesOnly(sessionId)) {
    showTopSnackBar(
        rootContext,
        container.read(activeSessionsProvider.notifier).isFtps(sessionId)
            ? l10n.sessionFilesOnlyLineFtps
            : l10n.sessionFilesOnlyLine,
        isWarning: true);
    return false;
  }
  final ready = await commandReadyToRun(
    rootContext,
    ref,
    command: command,
    label: label,
    confirmFirst: confirmFirst,
    doneLabel: l10n.zestSnippetsRunButton,
    listOptions: listOptionsFrom(session),
  );
  if (ready == null) return false;
  final now = container.read(activeSessionsProvider)[sessionId];
  if (now == null || now.status != SessionStatus.connected) return false;
  container
      .read(activeSessionsProvider.notifier)
      .sendInput(sessionId, Uint8List.fromList(utf8.encode(CommandText.entered(ready.command))));
  if (snippetId != null) container.read(snippetUsageProvider.notifier).recordRun(snippetId);
  if (rootContext.mounted) {
    final name = now.connectionLabel.isNotEmpty ? now.connectionLabel : (now.host ?? '');
    showTopSnackBar(rootContext, l10n.snippetPageSent(Redactable.host(name).display),
        duration: const Duration(seconds: 2));
  }
  return true;
}
