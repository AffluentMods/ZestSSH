import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/broadcast/host_checklist.dart';
import 'package:zestssh/features/hosts/host_list_layout.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart' hide ConnectionError;
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/ui/widgets/name_first_row.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/utils/error_report.dart';
import 'package:zestssh/utils/error_translator.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/utils/hidden_characters.dart';
import 'package:zestssh/utils/number_text.dart';

/// Opens "Run on hosts" (3.0): its setup, hosts and a command (or
/// [snippet]'s), then each host's result as it comes. Opened with no
/// snippet, a run that is going, or the last one, is shown as it stands.
/// [preselected] hosts are ticked in its setup (the Server monitor's Run snippet
/// on these).
Future<void> showRunOnHosts(BuildContext context, {Snippet? snippet, Set<String>? preselected}) => showZestModal<void>(
      context: context,
      size: ZestModalSize.large,
      child: RunOnHostsDialog(snippet: snippet, preselected: preselected),
    );

/// The hosts a free plan runs on at once: as many as it opens sessions.
int get runOnHostsFreeLimit => freeSessionLimit;

class RunOnHostsDialog extends ConsumerStatefulWidget {
  const RunOnHostsDialog({super.key, this.snippet, this.preselected});

  final Snippet? snippet;

  /// Ticked in its setup, which it opens to unless a run is going.
  final Set<String>? preselected;

  @override
  ConsumerState<RunOnHostsDialog> createState() => _RunOnHostsDialogState();
}

class _RunOnHostsDialogState extends ConsumerState<RunOnHostsDialog> {
  var _picked = <String>{};
  final _command = TextEditingController();

  /// The snippet the command came from, while it is as the snippet has it.
  Snippet? _snippet;

  /// Showing the setup (hosts and a command) rather than a run's results.
  late bool _settingUp;

  @override
  void initState() {
    super.initState();
    final last = ref.read(runOnHostsProvider);
    final snippet = widget.snippet;
    // A run that is going is shown as it stands, whatever opened this.
    final asked = widget.preselected;
    _settingUp = !(last?.running ?? false) && (snippet != null || asked != null || last == null);
    // Hosts handed over are a new run: the last command typed, ready to run on
    // them, is no question to ask of a list of hosts.
    _command.text = snippet?.command ?? (asked != null ? '' : last?.typed) ?? '';
    _snippet = snippet;
    if (last != null) _picked = {for (final h in last.hosts) h.host.id};
    // Kept while a run going is shown: New opens on the hosts asked for.
    if (asked != null) _picked = {...asked};
    _command.addListener(() {
      if (_snippet != null && _command.text != _snippet!.command) _snippet = null;
      setState(() {});
    });
  }

  @override
  void dispose() {
    _command.dispose();
    super.dispose();
  }

  Future<void> _start(List<Connection> hosts) async {
    final snippet = _snippet;
    final typed = _command.text;
    final ready = await commandReadyToRun(
      context,
      ref,
      command: typed,
      label: snippet?.label,
      confirmFirst: snippet?.confirmBeforeRun ?? false,
      doneLabel: AppLocalizations.of(context)!.snippetRunAction,
    );
    if (ready == null || !mounted) return;
    setState(() => _settingUp = false);
    unawaited(ref
        .read(runOnHostsProvider.notifier)
        .run(hosts, ready.command, typed: typed, secrets: ready.secrets, shown: ready.shown));
  }

  @override
  Widget build(BuildContext context) => _settingUp ? _setup(context) : _results(context);

  Widget _setup(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final all = ref.watch(connectionsWithDetailsProvider).valueOrNull ?? const <ConnectionWithDetails>[];
    final isPro = ref.watch(isProProvider);
    final snippets = ref.watch(snippetsProvider).valueOrNull ?? const <Snippet>[];
    // (Not a host that cannot be ticked, whatever handed it over.)
    final hosts = [
      for (final c in all)
        if (_picked.contains(c.connection.id) && noRunOnHostsReason(c.connection, l10n) == null) c.connection,
    ];
    final overLimit = !isPro && hosts.length > runOnHostsFreeLimit;
    final ready = hosts.isNotEmpty && _command.text.trim().isNotEmpty;
    final running = ref.watch(runOnHostsProvider)?.running ?? false;
    // A phone's sheet scrolls as one: with the keyboard up there is no height
    // for a list of its own under the command.
    final sheet = ZestSheetScope.of(context);
    final checklist = HostChecklist(
      picked: _picked,
      onChanged: (picked) => setState(() => _picked = picked),
      keyPrefix: 'run',
      autofocus: false,
      place: HostListPlace.runOnHosts,
      unavailable: noRunOnHostsReason,
      quickPicks: true,
      minListHeight: 160,
    );

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.listChecks,
      title: l10n.runOnHostsTitle,
      subtitle: l10n.runOnHostsSubtitle,
      bodyScrolls: sheet,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  l10n.runOnHostsCommand,
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: ZestColors.textSecondary),
                ),
              ),
              if (snippets.isNotEmpty)
                PopupMenuButton<Snippet>(
                  key: const ValueKey('run-snippet'),
                  tooltip: l10n.runOnHostsFromSnippet,
                  onSelected: (s) {
                    _command.text = s.command;
                    _snippet = s;
                  },
                  itemBuilder: (_) => [
                    for (final s in snippets)
                      PopupMenuItem<Snippet>(
                        value: s,
                        child: Text(s.label, maxLines: 1, overflow: TextOverflow.ellipsis),
                      ),
                  ],
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(LucideIcons.code2, size: 14, color: ZestColors.accentInk),
                        const SizedBox(width: 6),
                        Text(l10n.runOnHostsFromSnippet, style: TextStyle(fontSize: 12, color: ZestColors.accentInk)),
                      ],
                    ),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 6),
          TextField(
            key: const ValueKey('run-command'),
            controller: _command,
            minLines: 2,
            maxLines: 6,
            style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5),
            decoration: InputDecoration(isDense: true, hintText: l10n.runOnHostsCommandHint),
          ),
          const SizedBox(height: 14),
          if (sheet) checklist else Flexible(child: checklist),
          const SizedBox(height: 8),
          if (overLimit)
            _Note(
              key: const ValueKey('run-limit'),
              icon: LucideIcons.info,
              color: ZestColors.statusWarning,
              text: l10n.runOnHostsLimit(runOnHostsFreeLimit),
            )
          else if (!ready)
            _Note(
              key: const ValueKey('run-pick'),
              icon: LucideIcons.info,
              color: ZestColors.textTertiary,
              text: l10n.runOnHostsPickOne,
            ),
        ],
      ),
      primaryAction: (
        label: l10n.runOnHostsRun(hosts.length),
        icon: LucideIcons.play,
        onPressed: ready && !overLimit && !running ? () => _start(hosts) : null,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
    );
  }

  Widget _results(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final run = ref.watch(runOnHostsProvider);
    if (run == null) return _setup(context);
    final notifier = ref.read(runOnHostsProvider.notifier);
    final through = run.hosts.where((h) => h.over).length;

    return ZestDialogShell(
      size: ZestModalSize.large,
      tone: ZestDialogTone.info,
      icon: LucideIcons.listChecks,
      title: l10n.runOnHostsTitle,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            key: const ValueKey('run-command-shown'),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: ZestColors.bgContent,
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: ZestColors.borderDefault, width: 0.5),
            ),
            child: Text(
              visibleCommand(run.commandShown),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, color: ZestColors.textPrimary),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: Text(
                  run.running
                      ? l10n.runOnHostsProgress(through, run.hosts.length)
                      : l10n.runOnHostsSummary(run.succeeded, run.notWell),
                  key: const ValueKey('run-summary'),
                  style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: ZestColors.textSecondary),
                ),
              ),
              TextButton.icon(
                key: const ValueKey('run-copy'),
                onPressed: () => Clipboard.setData(ClipboardData(text: runOnHostsReport(run, l10n))),
                icon: const Icon(LucideIcons.copy, size: 14),
                label: Text(l10n.runOnHostsCopyAll, style: const TextStyle(fontSize: 12)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final h in run.hosts) HostRunRow(key: ValueKey('run-row-${h.host.id}'), run: h),
        ],
      ),
      primaryAction: run.running
          ? (label: l10n.runOnHostsStop, icon: LucideIcons.square, onPressed: notifier.stop)
          : (
              label: l10n.runOnHostsAgain,
              icon: LucideIcons.rotateCcw,
              onPressed: run.notWell > 0 ? () => unawaited(notifier.again()) : null,
            ),
      secondaryAction: run.running ? null : (label: l10n.runOnHostsNew, onPressed: () => setState(() => _settingUp = true)),
      tertiaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop()),
    );
  }
}

/// What stopped a host's part, in the person's words: as a connection that
/// failed says it (what it was, what happened, and what may help), or that
/// its command had not ended in time. Names in it are masked while
/// recording, as where a session says the same.
({String title, String description, String? tip}) hostRunFailureSaid(HostRun h, AppLocalizations l10n) {
  final failure = h.failure;
  if (failure is RunTookTooLong) {
    return (title: l10n.runOnHostsFailed, description: l10n.runOnHostsTookTooLong(failure.limit.inMinutes), tip: null);
  }
  final said = ConnectionError.translate(connectionFailureText(failure ?? ''), host: h.host.host, port: h.host.port);
  return (title: said.title, description: Redactable.freeText(said.description).display, tip: said.tip);
}

/// A run as text: for "Copy all results", each host with how it ended and
/// what it printed. Masked values are left hidden, and so are hosts' names and
/// addresses while recording.
String runOnHostsReport(HostsRun run, AppLocalizations l10n) {
  final out = StringBuffer('\$ ${run.commandShown}\n');
  for (final h in run.hosts) {
    final name = h.host.label.isNotEmpty ? h.host.label : h.host.host;
    out.write('\n== ${Redactable.host(name).display} (${Redactable.host(h.host.host).display}): ${hostRunStateWords(h, l10n)}\n');
    if (h.state == HostRunState.failed) {
      final said = hostRunFailureSaid(h, l10n);
      out.write('${said.title}: ${said.description}\n');
    }
    if (h.output.isNotEmpty) out.write(h.output.endsWith('\n') ? h.output : '${h.output}\n');
    if (h.errors.isNotEmpty) out.write('-- ${l10n.runOnHostsErrors} --\n${h.errors.endsWith('\n') ? h.errors : '${h.errors}\n'}');
  }
  return out.toString();
}

/// One host's part in a run, as a row: where it stands, in [words] (a run
/// on hosts' own where none are given), and whether it ended well ([ok]:
/// [HostRun.succeeded] where not given); opened, what it printed, or why it
/// failed. (Installing a key on hosts shows its hosts so too.)
class HostRunRow extends StatefulWidget {
  const HostRunRow({super.key, required this.run, this.words, this.ok});

  final HostRun run;
  final String Function(HostRun h, AppLocalizations l10n)? words;
  final bool Function(HostRun h)? ok;

  @override
  State<HostRunRow> createState() => _HostRunRowState();
}

class _HostRunRowState extends State<HostRunRow> {
  var _open = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final h = widget.run;
    final id = h.host.id;
    final (icon, color) = switch (h.state) {
      HostRunState.waiting => (LucideIcons.clock, ZestColors.textTertiary),
      HostRunState.signingIn || HostRunState.running => (LucideIcons.loader, ZestColors.accentInk),
      HostRunState.done when (widget.ok?.call(h) ?? h.succeeded) => (LucideIcons.checkCircle2, ZestColors.statusSuccess),
      HostRunState.done => (LucideIcons.alertTriangle, ZestColors.statusWarning),
      HostRunState.failed => (LucideIcons.xCircle, ZestColors.statusError),
      HostRunState.stopped => (LucideIcons.minusCircle, ZestColors.textTertiary),
    };
    final failed = h.state == HostRunState.failed ? hostRunFailureSaid(h, l10n) : null;
    final took = h.took;
    final canOpen = h.over && h.state != HostRunState.stopped;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        InkWell(
          key: ValueKey('run-open-$id'),
          borderRadius: BorderRadius.circular(6),
          onTap: canOpen ? () => setState(() => _open = !_open) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Row(
              children: [
                Icon(icon, size: 15, color: color),
                const SizedBox(width: 8),
                HostGlyph(host: h.host, size: 20),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      NameFirstRow(
                        name: Redactable.host(h.host.label.isNotEmpty ? h.host.label : h.host.host),
                        nameStyle: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w500, color: ZestColors.textPrimary),
                        address: Redactable.address(h.host.port == 22 ? h.host.host : hostWithPort(h.host.host, h.host.port)),
                        addressStyle: TextStyle(fontSize: 11.5, fontFamily: 'JetBrainsMono', color: ZestColors.textTertiary),
                      ),
                      // Why it failed, without opening it.
                      if (failed != null)
                        Text(
                          failed.title,
                          key: ValueKey('run-why-$id'),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: ZestColors.statusError),
                        ),
                    ],
                  ),
                ),
                if (h.logged) ...[
                  const SizedBox(width: 8),
                  Tooltip(
                    message: l10n.runOnHostsLoggedTooltip,
                    child: Container(
                      key: ValueKey('run-logged-$id'),
                      padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
                      decoration: BoxDecoration(
                        color: ZestColors.accentInk.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: Text(
                        l10n.sessionLoggedChip,
                        style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: ZestColors.accentInk),
                      ),
                    ),
                  ),
                ],
                const SizedBox(width: 10),
                Text(
                  (widget.words ?? hostRunStateWords)(h, l10n),
                  key: ValueKey('run-state-$id'),
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color),
                ),
                if (took != null && h.over) ...[
                  const SizedBox(width: 10),
                  Text(
                    l10n.runOnHostsSeconds(formatDecimal(took.inMilliseconds / 1000, l10n: l10n)),
                    style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
                  ),
                ],
                if (canOpen) ...[
                  const SizedBox(width: 6),
                  Icon(_open ? LucideIcons.chevronUp : LucideIcons.chevronDown, size: 14, color: ZestColors.textTertiary),
                ],
              ],
            ),
          ),
        ),
        if (_open && canOpen)
          Padding(
            key: ValueKey('run-details-$id'),
            padding: const EdgeInsetsDirectional.fromSTEB(55, 0, 4, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (failed != null) ...[
                  Text(failed.description, style: TextStyle(fontSize: 12, height: 1.4, color: ZestColors.textSecondary)),
                  if (failed.tip case final tip?) ...[
                    const SizedBox(height: 4),
                    Text(tip, style: TextStyle(fontSize: 12, height: 1.4, color: ZestColors.textTertiary)),
                  ],
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CopyDetailsButton(
                      detail: ErrorReport.build(what: failed.description, where: 'Run on hosts: a host', error: h.failure),
                    ),
                  ),
                ],
                if (h.state == HostRunState.done && h.output.isEmpty && h.errors.isEmpty)
                  Text(l10n.runOnHostsNothingPrinted, style: TextStyle(fontSize: 12, color: ZestColors.textTertiary)),
                if (h.output.isNotEmpty) _Printed(key: ValueKey('run-output-$id'), title: l10n.runOnHostsOutput, text: h.output),
                if (h.errors.isNotEmpty) _Printed(key: ValueKey('run-errors-$id'), title: l10n.runOnHostsErrors, text: h.errors),
                if (h.cut)
                  Padding(
                    padding: const EdgeInsets.only(top: 6),
                    child: Text(
                      l10n.runOnHostsCut(kRunOutputKept ~/ 1024),
                      style: TextStyle(fontSize: 11.5, color: ZestColors.textTertiary),
                    ),
                  ),
              ],
            ),
          ),
        Divider(height: 1, color: ZestColors.borderDefault),
      ],
    );
  }
}

/// What a host printed (or printed as errors), to read and select.
class _Printed extends StatelessWidget {
  const _Printed({super.key, required this.title, required this.text});

  final String title;
  final String text;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(top: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(title, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: ZestColors.textTertiary)),
            const SizedBox(height: 4),
            Container(
              constraints: const BoxConstraints(maxHeight: 240),
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: ZestColors.bgContent,
                borderRadius: BorderRadius.circular(6),
              ),
              child: SingleChildScrollView(
                child: SelectableText(
                  text,
                  style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textPrimary),
                ),
              ),
            ),
          ],
        ),
      );
}

class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.color, required this.text});

  final IconData icon;
  final Color color;
  final String text;

  @override
  Widget build(BuildContext context) => Row(
        children: [
          Icon(icon, size: 14, color: color),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: TextStyle(fontSize: 12, color: color))),
        ],
      );
}
