import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show ItemRules;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/byte_size.dart';
import 'package:zestssh/utils/host_address.dart';
import 'package:zestssh/l10n/time_text.dart';

// Team session logs on screen (3.0): on each Crate's row, owners
// switch them on or off after a yes that says what it means (who reads them,
// that everyone is told and sees it, what is and is not redacted, that
// turning off deletes them); everyone else sees that sessions there are
// logged; owners and those who manage the Crate open its logs, read one,
// copy it, and owners delete one.

String _member(WidgetRef ref, String orchardId, String uid) {
  final emails = ref.watch(teamRecordProvider(orchardId)).valueOrNull?.emails ?? const <String, String?>{};
  return Redactable.account(emails[uid] ?? shortMemberId(uid)).displayIn(ref);
}

String _size(int bytes) => formatByteSize(bytes, digits: SizeDigits.belowTen);

/// A Crate row's session logs: the owners' switch, what everyone else is
/// told, and the way to the logs for owners and managers.
class CrateSessionLogsLine extends ConsumerStatefulWidget {
  const CrateSessionLogsLine({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  /// Whether it shows anything for [crate] (owners always, everyone else
  /// while its sessions are logged): it opens the card's Records group then.
  static bool shows(WidgetRef ref, OrchardSummary orchard, CrateSummary crate) {
    final on = ref.watch(teamSessionLogCratesProvider(orchard.id)).valueOrNull?.contains(crate.id);
    if (on == null) return false;
    return (orchard.isOwner && orchard.active) || on;
  }

  @override
  ConsumerState<CrateSessionLogsLine> createState() => _CrateSessionLogsLineState();
}

class _CrateSessionLogsLineState extends ConsumerState<CrateSessionLogsLine> {
  bool _busy = false;

  /// Session logs on or off, after a yes; the Vaults window steps aside
  /// meanwhile.
  Future<void> _set(bool on) => overWindow(context, () => _setNow(on));

  Future<void> _setNow(bool on) async {
    final l10n = AppLocalizations.of(context)!;
    final name = crateDisplayName(widget.crate, l10n);
    // Turning them off deletes the logs kept so far: a red button.
    final go = await ZestConfirmDialog.show(
      context,
      // On: what a log may still hold is the one sentence that warns.
      tone: on ? ZestDialogTone.warning : ZestDialogTone.destructive,
      title: on ? l10n.crateSessionLogsOnTitle(name) : l10n.crateSessionLogsOffTitle(name),
      body: on ? l10n.vaultUiLogsOnLead : l10n.crateSessionLogsOffBody,
      bullets: on ? [l10n.vaultUiLogsOnTold] : null,
      warning: on ? l10n.vaultUiLogsOnRedact : null,
      confirmLabel: on ? l10n.crateSessionLogsTurnOn : l10n.crateSessionLogsTurnOff,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).setCrateSessionLogs(widget.orchard.id, widget.crate.id, on),
        summary: (what: l10n.stepUpSessionLogs(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.orchardChangeSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Session logs: not changed ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    final crate = widget.crate;
    final on = ref.watch(teamSessionLogCratesProvider(o.id)).valueOrNull?.contains(crate.id);
    if (on == null || !CrateSessionLogsLine.shows(ref, o, crate)) return const SizedBox.shrink();
    final owner = o.isOwner && o.active;
    final reads = on && o.active && crate.allows(CrateSwitches.manage);
    // The first rows of the card's Records group: the switch (or that they
    // are logged), and the way to the logs for those who read them.
    return VaultSettingGroup(
      title: l10n.vaultUiGroupRecords,
      rows: [
        // The switch at the end of the row, as every switch of the card is,
        // and the way to the logs under the words (the switch sat after View
        // logs).
        VaultSettingRow(
          label: l10n.crateSessionLogs,
          helper: l10n.vaultUiSessionLogsHelp,
          compact: true,
          details: [
            if (reads)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: vaultButton(
                  context,
                  key: ValueKey('crate-session-logs-open-${crate.id}'),
                  onPressed: () => overWindow(context, () => showCrateSessionLogs(context, o, crate)),
                  icon: LucideIcons.fileText,
                  label: l10n.vaultUiViewLogs,
                ),
              ),
          ],
          control: owner
              ? ZestSwitch(
                  key: ValueKey('crate-session-logs-${crate.id}'),
                  value: on,
                  onChanged: _busy ? null : (v) => _set(v),
                )
              : ZestStatusPill(
                  key: ValueKey('crate-sessions-logged-${crate.id}'),
                  kind: ZestStatusKind.warning,
                  icon: LucideIcons.eye,
                  label: l10n.crateSessionLogsOnNote,
                ),
        ),
      ],
    );
  }
}

/// [crate]'s session logs, for owners and those who manage it.
Future<void> showCrateSessionLogs(BuildContext context, OrchardSummary orchard, CrateSummary crate) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.scrollText,
    title: l10n.sessionLogsTitle(crateDisplayName(crate, l10n)),
    body: CrateSessionLogsView(orchard: orchard, crate: crate),
  );
}

class CrateSessionLogsView extends ConsumerStatefulWidget {
  const CrateSessionLogsView({super.key, required this.orchard, required this.crate});

  final OrchardSummary orchard;
  final CrateSummary crate;

  @override
  ConsumerState<CrateSessionLogsView> createState() => _CrateSessionLogsViewState();
}

class _CrateSessionLogsViewState extends ConsumerState<CrateSessionLogsView> {
  final _entries = <TeamSessionLogEntry>[];
  TeamSessionLogPage? _last;
  Object? _error;
  bool _loading = false;

  @override
  void initState() {
    super.initState();
    unawaited(_more());
  }

  Future<void> _more() async {
    setState(() => _loading = true);
    try {
      final page = await ref
          .read(orchardServiceProvider)
          .teamSessionLogs(widget.orchard.id, widget.crate.id, before: _last?.before);
      if (!mounted) return;
      setState(() {
        _entries.addAll(page.entries);
        _last = page;
        _error = null;
      });
    } catch (e) {
      AppLogger.info('Session logs: not read ($e)');
      if (mounted) setState(() => _error = e);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    if (error != null && _entries.isEmpty) {
      return Text(orchardChangeErrorMessage(error, l10n),
          key: const ValueKey('session-logs-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final last = _last;
    if (last == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    final when = DateFormat.yMMMd(l10n.localeName).add_jm();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (_entries.isEmpty)
          Text(l10n.teamSessionLogsEmpty,
              key: const ValueKey('session-logs-empty'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary)),
        for (final e in _entries)
          Container(
            key: ValueKey('session-log-${e.id}'),
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
            decoration: BoxDecoration(
              border: Border.all(color: AppColors.v3BorderSubtle),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(LucideIcons.terminal, size: 15, color: AppColors.v3TextSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        l10n.sessionLogRowTitle(_member(ref, widget.orchard.id, e.header.uid),
                            Redactable.host(e.header.label.isEmpty ? e.header.host : e.header.label).displayIn(ref)),
                        style: TextStyle(fontSize: 12.5, color: AppColors.v3TextPrimary),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        [
                          when.formatPlain(e.header.startedAt.toLocal()),
                          _size(e.bytes),
                          if (!e.closed) l10n.sessionLogNotClosed,
                        ].join(' · '),
                        style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                      ),
                      // Kept on its device for a while (it could not reach
                      // ZestSSH Cloud): when the server took it, and why
                      // that is later than the session.
                      if (e.receivedLater)
                        Tooltip(
                          message: l10n.sessionLogReceivedLaterHint,
                          child: Text(
                            l10n.sessionLogReceivedLater(when.formatPlain(e.receivedAt.toLocal())),
                            key: ValueKey('session-log-later-${e.id}'),
                            style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary),
                          ),
                        ),
                    ],
                  ),
                ),
                TextButton(
                  key: ValueKey('session-log-open-${e.id}'),
                  onPressed: () async {
                    final deleted = await showSessionLogText(context, widget.orchard, widget.crate, e);
                    if (deleted == true && mounted) setState(() => _entries.removeWhere((x) => x.id == e.id));
                  },
                  child: Text(l10n.sessionLogOpen),
                ),
              ],
            ),
          ),
        if (last.unreadable > 0)
          Text(l10n.activityUnreadable(last.unreadable),
              key: const ValueKey('session-logs-unreadable'), style: TextStyle(fontSize: 11.5, color: AppColors.v3Warning)),
        if (last.more)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('session-logs-older'),
              onPressed: _loading ? null : _more,
              child: Text(l10n.crateChangesOlder),
            ),
          ),
      ],
    );
  }
}

/// One session log's text: selectable, copied in one tap, deleted by an
/// owner. True when it was deleted.
Future<bool?> showSessionLogText(
    BuildContext context, OrchardSummary orchard, CrateSummary crate, TeamSessionLogEntry entry) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.large,
    tone: ZestDialogTone.info,
    icon: LucideIcons.fileText,
    title: entry.header.label.isEmpty ? entry.header.host : entry.header.label,
    subtitle: '${entry.header.user == null ? '' : '${entry.header.user}@'}${hostWithPort(entry.header.host, entry.header.port)}',
    body: SessionLogTextView(orchard: orchard, crate: crate, entry: entry),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

class SessionLogTextView extends ConsumerStatefulWidget {
  const SessionLogTextView({super.key, required this.orchard, required this.crate, required this.entry});

  final OrchardSummary orchard;
  final CrateSummary crate;
  final TeamSessionLogEntry entry;

  @override
  ConsumerState<SessionLogTextView> createState() => _SessionLogTextViewState();
}

class _SessionLogTextViewState extends ConsumerState<SessionLogTextView> {
  TeamSessionLogText? _text;
  Object? _error;

  @override
  void initState() {
    super.initState();
    unawaited(() async {
      try {
        final text =
            await ref.read(orchardServiceProvider).teamSessionLogText(widget.orchard.id, widget.crate.id, widget.entry);
        if (mounted) setState(() => _text = text);
      } catch (e) {
        AppLogger.info('Session logs: a log was not read ($e)');
        if (mounted) setState(() => _error = e);
      }
    }());
  }

  Future<void> _delete() async {
    final l10n = AppLocalizations.of(context)!;
    final go = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.sessionLogDeleteTitle,
      body: l10n.sessionLogDeleteBody,
      confirmLabel: l10n.sessionLogDelete,
    );
    if (go != true || !mounted) return;
    try {
      await ref.read(orchardServiceProvider).deleteTeamSessionLog(widget.crate.id, widget.entry.id);
      if (!mounted) return;
      showTopSnackBar(context, l10n.sessionLogDeleted, isSuccess: true);
      Navigator.of(context).pop(true);
    } catch (e) {
      AppLogger.warning('Session logs: a log was not deleted ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final error = _error;
    if (error != null) {
      return Text(orchardChangeErrorMessage(error, l10n),
          key: const ValueKey('session-log-error'), style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary));
    }
    final text = _text;
    if (text == null) {
      return const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 1.8))),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (!text.complete)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(l10n.sessionLogIncomplete,
                key: const ValueKey('session-log-incomplete'),
                style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3Warning)),
          ),
        Container(
          constraints: const BoxConstraints(maxHeight: 420),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: AppColors.v3BorderSubtle.withValues(alpha: 0.25),
            borderRadius: BorderRadius.circular(8),
          ),
          child: SingleChildScrollView(
            child: SelectableText(
              text.text,
              key: const ValueKey('session-log-text'),
              style: const TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.45),
            ),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          children: [
            OutlinedButton.icon(
              key: const ValueKey('session-log-copy'),
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: text.text));
                if (context.mounted) showTopSnackBar(context, l10n.sessionLogCopied, isSuccess: true);
              },
              icon: const Icon(LucideIcons.copy, size: 14),
              label: Text(l10n.sessionLogCopy),
            ),
            if (widget.orchard.isOwner && widget.orchard.active)
              TextButton.icon(
                key: const ValueKey('session-log-delete'),
                onPressed: _delete,
                icon: const Icon(LucideIcons.trash2, size: 14),
                label: Text(l10n.sessionLogDelete),
              ),
          ],
        ),
      ],
    );
  }
}

/// Whether sessions to the host [connectionId] on screen are logged for its
/// team: its Crate logs sessions, as this device's record says.
bool hostSessionsLogged(WidgetRef ref, String connectionId) {
  final rules = ItemRules.of(ref, 'host');
  final orchard = rules.orchard;
  if (orchard == null) return false;
  final crateId = rules.crates[connectionId] ?? orchard.defaultCrateId;
  final logging = ref.watch(teamSessionLogCratesProvider(orchard.id)).valueOrNull;
  return crateId != null && (logging?.contains(crateId) ?? false);
}

/// Before connecting: a host whose sessions are logged says so, in a line
/// on its panel ([compact] false) or a small mark on its card.
class HostSessionsLoggedNote extends ConsumerWidget {
  const HostSessionsLoggedNote({super.key, required this.connectionId, this.compact = false});

  final String connectionId;
  final bool compact;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    if (!hostSessionsLogged(ref, connectionId)) return const SizedBox.shrink();
    final l10n = AppLocalizations.of(context)!;
    if (compact) {
      return Tooltip(
        message: l10n.hostSessionsLogged,
        child: Icon(LucideIcons.eye, key: ValueKey('host-logged-mark-$connectionId'), size: 13, color: AppColors.v3Warning),
      );
    }
    return Padding(
      key: ValueKey('host-logged-note-$connectionId'),
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 1),
            child: Icon(LucideIcons.eye, size: 13, color: AppColors.v3Warning),
          ),
          const SizedBox(width: 6),
          Expanded(
            child: Tooltip(
              message: l10n.sessionLoggedTooltip,
              child: Text(l10n.hostSessionsLogged,
                  style: TextStyle(fontSize: 12, height: 1.4, color: AppColors.v3TextSecondary)),
            ),
          ),
        ],
      ),
    );
  }
}
