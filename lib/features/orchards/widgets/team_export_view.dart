import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/features/orchards/devices/device_identity.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show RecordExport;
import 'package:zestssh/features/orchards/team/team_overview.dart' show shortMemberId;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/error_kind.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/l10n/time_text.dart';

// Event export (3.0) on the Rules page, under what the team
// records: whether the team's events are sent on to a system of its own,
// who set that up, and, on the device that sends, where to and how it is
// going. An owner sets it up from here, on the device that is to send, and
// any owner turns it off. Everyone else sees where things stand: what
// leaves the team's space is never hidden from its members.

/// Why sending did not go, in words.
String exportFailureText(ExportFailure failure, int? status, AppLocalizations l10n) => switch (failure) {
      ExportFailure.refused => l10n.exportFailRefused('${status ?? 0}'),
      ExportFailure.timeout => l10n.exportFailTimeout,
      ExportFailure.certificate => l10n.exportFailCertificate,
      ExportFailure.unreachable => l10n.exportFailUnreachable,
      ExportFailure.other => l10n.exportFailOther,
    };

/// How sending is going on the device that sends, in a sentence.
String exportStatusText(ExportStatus status, AppLocalizations l10n) {
  final when = DateFormat.yMMMd(l10n.localeName).add_jm();
  String at(int seconds) => when.formatPlain(DateTime.fromMillisecondsSinceEpoch(seconds * 1000));
  final failure = status.failure;
  if (failure != null) {
    return l10n.exportStatusFailed(at(status.failedAt ?? 0), exportFailureText(failure, status.failedStatus, l10n));
  }
  final sentAt = status.sentAt;
  return sentAt == null ? l10n.exportStatusNone : l10n.exportStatusSent(at(sentAt), status.sent);
}

class TeamExportPanel extends ConsumerStatefulWidget {
  const TeamExportPanel({super.key, required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<TeamExportPanel> createState() => _TeamExportPanelState();
}

class _TeamExportPanelState extends ConsumerState<TeamExportPanel> {
  bool _busy = false;

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final exporter = ref.read(orchardEventExporterProvider);
    setState(() => _busy = true);
    try {
      final standing = await exporter.standing(widget.orchard.id);
      final key = await exporter.keyHere(widget.orchard.id);
      final to = standing.destination;
      if (key == null || to == null || !mounted) return;
      final delivery = await exporter.sendTest(widget.orchard.id, to, key);
      if (!mounted) return;
      final failure = delivery.failure;
      showTopSnackBar(
        context,
        failure == null
            ? l10n.exportTestSent('${delivery.status}')
            : l10n.exportTestFailed(exportFailureText(failure, delivery.status, l10n)),
        isSuccess: failure == null,
        isError: failure != null,
      );
    } catch (e) {
      AppLogger.info('Event export: the test event was not sent (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _copyKey(String key) async {
    final l10n = AppLocalizations.of(context)!;
    // The key events are signed with is public, handed to whoever runs the
    // receiving system: it stays on the clipboard (it was taken off after
    // 45 s, as a secret is, found in a docs check).
    await Clipboard.setData(ClipboardData(text: key));
    if (mounted) showTopSnackBar(context, l10n.exportKeyCopied, isSuccess: true);
  }

  Future<void> _turnOff(bool here) async {
    final l10n = AppLocalizations.of(context)!;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    final go = await ZestConfirmDialog.show(
      context,
      // It stops what was sent on: red, with the warning sign.
      tone: ZestDialogTone.destructive,
      title: l10n.exportTurnOffTitle(name),
      body: [l10n.exportTurnOffBody, if (here) l10n.exportTurnOffBodyHere].join('\n\n'),
      confirmLabel: l10n.exportTurnOff,
    );
    if (go != true || !mounted) return;
    setState(() => _busy = true);
    try {
      final done = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardEventExporterProvider).turnOff(widget.orchard.id),
        summary: (what: l10n.stepUpExportOff(name), effects: const []),
      );
      if (!done || !mounted) return;
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.exportTurnedOff, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Event export: not turned off (${errorKind(e)})');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final o = widget.orchard;
    final standing = ref.watch(exportStandingProvider(o.id)).valueOrNull;
    final emails = ref.watch(teamRecordProvider(o.id)).valueOrNull?.emails ?? const <String, String?>{};
    final on = standing?.on ?? false;
    final help = TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary);
    final line = TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textPrimary);
    final record = standing?.record;
    final by = record == null
        ? ''
        : Redactable.account(emails[record.by] ?? shortMemberId(record.by)).displayIn(ref);
    final mine = record != null && ref.watch(teamPeopleProvider(o.id)).valueOrNull?.me == record.by;
    // Sending from here and not getting through: the state says so (it read
    // "On" while every event failed).
    final failure = standing != null && standing.sendsHere && standing.destination != null
        ? standing.status.failure
        : null;
    return TeamCard(
      key: const ValueKey('team-export'),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TeamCardHeader(
            icon: LucideIcons.send,
            title: l10n.exportTitle,
            // Its last two words on one line, as in the line on which device
            // sends the events ("on." and "it." were alone on theirs
            // before).
            body: noOrphan(l10n.exportIntro),
            trailing: standing == null
                ? null
                : ZestStatusPill(
                    key: ValueKey('team-export-state-${on ? 'on' : 'off'}'),
                    kind: !on
                        ? ZestStatusKind.neutral
                        : failure != null
                            ? ZestStatusKind.critical
                            : ZestStatusKind.healthy,
                    label: !on
                        ? l10n.exportStateOff
                        : failure != null
                            ? l10n.teamAdminExportFailing
                            : l10n.exportStateOn,
                  ),
          ),
          if (standing != null) ...[
            const SizedBox(height: 16),
            if (record == null) ...[
              Text(l10n.exportOffNote, key: const ValueKey('team-export-off'), style: line),
              const SizedBox(height: 6),
              if (!standing.isOwner)
                Text(l10n.exportOwnersOnly, key: const ValueKey('team-export-owners-only'), style: help)
              else if (!standing.activityOn)
                Text(l10n.exportNeedsActivity, key: const ValueKey('team-export-needs-activity'), style: help)
              else ...[
                const SizedBox(height: 6),
                Align(
                  alignment: AlignmentDirectional.centerStart,
                  child: teamButton(
                    key: const ValueKey('team-export-set-up'),
                    kind: TeamButtonKind.primary,
                    icon: LucideIcons.send,
                    label: l10n.exportSetUp,
                    onPressed: _busy ? null : () => showExportSetup(context, ref, o),
                  ),
                ),
              ],
            ] else if (!standing.isOwner)
              // A member: what leaves the team, said plainly in a note.
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: ZestTokens.surfaceRaisedAlt,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: ZestTokens.borderSubtle),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Icon(LucideIcons.info, size: 16, color: ZestTokens.textSecondary),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(l10n.exportOnForMembers(by), key: const ValueKey('team-export-on-member'), style: line),
                    ),
                  ],
                ),
              )
            else ...[
              Text(
                noOrphan(standing.sendsHere
                    ? l10n.exportSendsHere
                    : mine
                        ? l10n.exportSendsElsewhereOwn
                        : l10n.exportSendsElsewhere(by)),
                key: ValueKey('team-export-${standing.sendsHere ? 'here' : mine ? 'own' : 'other'}'),
                style: line,
              ),
              if (standing.destination case final to?) ...[
                const SizedBox(height: 8),
                Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                TeamKeyValue(
                  label: l10n.exportAddressLabel,
                  value: Redactable.host(to.url.host).displayIn(ref),
                  valueKey: const ValueKey('team-export-to'),
                  mono: true,
                ),
                if (failure == null) ...[
                  Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                  TeamKeyValue(
                    label: l10n.teamAdminExportDelivery,
                    value: exportStatusText(standing.status, l10n),
                    valueKey: const ValueKey('team-export-status-ok'),
                  ),
                  Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
                ] else ...[
                  const SizedBox(height: 8),
                  _FailureAlert(
                    text: exportStatusText(standing.status, l10n),
                    details: [
                      l10n.exportTitle,
                      l10n.exportTo(to.url.host),
                      exportStatusText(standing.status, l10n),
                      if (standing.status.failedStatus case final code?) 'HTTP $code',
                    ].join('\n'),
                  ),
                ],
              ],
              const SizedBox(height: 16),
              _actions(standing, record, o, l10n),
            ],
          ],
        ],
      ),
    );
  }

  /// What can be done where it is on: the everyday ones together at the
  /// start, turning it off apart in red at the end; on a phone each across
  /// the width, one under the other (they wrapped into a ragged staircase).
  Widget _actions(ExportStanding standing, RecordExport record, OrchardSummary o, AppLocalizations l10n) {
    final everyday = <Widget>[
      if (standing.sendsHere) ...[
        teamButton(
          key: const ValueKey('team-export-test'),
          icon: LucideIcons.send,
          label: l10n.exportSendTest,
          onPressed: _busy ? null : _test,
        ),
        teamButton(
          key: const ValueKey('team-export-change'),
          icon: LucideIcons.pencil,
          label: l10n.exportChangeAddress,
          onPressed: _busy ? null : () => showExportSetup(context, ref, o, change: standing.destination),
        ),
      ] else
        teamButton(
          key: const ValueKey('team-export-move'),
          icon: LucideIcons.arrowDownToLine,
          label: l10n.exportMoveHere,
          onPressed: _busy ? null : () => showExportSetup(context, ref, o, takesOver: true),
        ),
      teamButton(
        key: const ValueKey('team-export-copy-key'),
        icon: LucideIcons.copy,
        label: l10n.exportCopyKey,
        onPressed: () => _copyKey(record.keyText),
      ),
    ];
    final off = teamButton(
      key: const ValueKey('team-export-turn-off'),
      kind: TeamButtonKind.danger,
      icon: LucideIcons.powerOff,
      label: l10n.exportTurnOff,
      onPressed: _busy ? null : () => _turnOff(standing.sendsHere),
    );
    return LayoutBuilder(builder: (context, box) {
      if (box.maxWidth < kTeamNarrow) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            for (final b in [...everyday, off]) ...[b, const SizedBox(height: 8)],
          ],
        );
      }
      return Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            child: Wrap(spacing: 8, runSpacing: 8, children: everyday),
          ),
          const SizedBox(width: 12),
          off,
        ],
      );
    });
  }
}

/// Events that do not get through, said at once: why and since when, with
/// the details to copy for whoever runs the receiver.
class _FailureAlert extends StatelessWidget {
  const _FailureAlert({required this.text, required this.details});

  final String text;
  final String details;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final red = ZestTokens.statusCritical;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 6),
      decoration: BoxDecoration(
        color: red.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: red.withValues(alpha: 0.32)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(padding: const EdgeInsets.only(top: 1), child: Icon(LucideIcons.alertCircle, size: 16, color: red)),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(l10n.teamAdminExportNotGettingThrough,
                    style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                const SizedBox(height: 2),
                Text(text,
                    key: const ValueKey('team-export-status-failed'),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary)),
                const SizedBox(height: 2),
                Transform.translate(offset: const Offset(-8, 0), child: CopyDetailsButton(detail: details)),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Sets event export up on this device for [orchard]: where the events go,
/// a test, and turning it on. With [change] (where they go now, on the
/// device that sends) it only changes where they go. [takesOver] says that
/// another device sends now.
Future<void> showExportSetup(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard, {
  ExportDestination? change,
  bool takesOver = false,
}) {
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: ExportSetupForm(orchard: orchard, change: change, takesOver: takesOver),
  );
}

class ExportSetupForm extends ConsumerStatefulWidget {
  const ExportSetupForm({super.key, required this.orchard, this.change, this.takesOver = false});

  final OrchardSummary orchard;
  final ExportDestination? change;
  final bool takesOver;

  @override
  ConsumerState<ExportSetupForm> createState() => _ExportSetupFormState();
}

class _ExportSetupFormState extends ConsumerState<ExportSetupForm> {
  late final _address = TextEditingController(text: widget.change?.url.toString() ?? '');
  late final _headerName = TextEditingController(text: widget.change?.headerName ?? '');
  late final _headerValue = TextEditingController(text: widget.change?.headerValue ?? '');
  late ExportFormat _format = widget.change?.format ?? ExportFormat.lines;

  /// The key a new set-up signs with: made once, so the test event and the
  /// events after it carry the same one.
  DeviceIdentity? _key;
  String? _addressError;
  String? _headerError;
  ({bool ok, String text})? _tested;
  bool _busy = false;

  /// Turned on: the key is shown, to be handed to the receiver.
  String? _doneKey;

  /// Asking whether to turn it on (the dialog's second step).
  bool _confirming = false;

  @override
  void dispose() {
    _address.dispose();
    _headerName.dispose();
    _headerValue.dispose();
    super.dispose();
  }

  /// What was typed as a destination, or null with what is wrong said.
  ExportDestination? _destination(AppLocalizations l10n) {
    final address = ExportDestination.address(_address.text).problem;
    final header = ExportDestination.header(_headerName.text, _headerValue.text);
    setState(() {
      _addressError = switch (address) {
        null => null,
        ExportAddressProblem.empty => l10n.exportAddressNeeded,
        ExportAddressProblem.notAnAddress => l10n.exportAddressInvalid,
        ExportAddressProblem.notSecure => l10n.exportAddressNotSecure,
      };
      _headerError = switch (header) {
        null => null,
        ExportHeaderProblem.half => l10n.exportHeaderHalf,
        ExportHeaderProblem.name => l10n.exportHeaderNameInvalid,
        ExportHeaderProblem.value => l10n.exportHeaderValueInvalid,
      };
    });
    return ExportDestination.of(_address.text, _format, headerName: _headerName.text, headerValue: _headerValue.text);
  }

  Future<DeviceIdentity> _signingKey() async {
    final exporter = ref.read(orchardEventExporterProvider);
    if (widget.change != null) return (await exporter.keyHere(widget.orchard.id))!;
    return _key ??= await exporter.newKey();
  }

  Future<void> _test() async {
    final l10n = AppLocalizations.of(context)!;
    final to = _destination(l10n);
    if (to == null) return;
    setState(() {
      _busy = true;
      _tested = null;
    });
    try {
      final delivery =
          await ref.read(orchardEventExporterProvider).sendTest(widget.orchard.id, to, await _signingKey());
      if (!mounted) return;
      final failure = delivery.failure;
      setState(() => _tested = (
            ok: failure == null,
            text: failure == null
                ? l10n.exportTestSent('${delivery.status}')
                : l10n.exportTestFailed(exportFailureText(failure, delivery.status, l10n)),
          ));
    } catch (e) {
      AppLogger.info('Event export: the test event was not sent (${errorKind(e)})');
      if (mounted) setState(() => _tested = (ok: false, text: orchardChangeErrorMessage(e, l10n)));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _save() async {
    final l10n = AppLocalizations.of(context)!;
    final to = _destination(l10n);
    if (to == null) return;
    final exporter = ref.read(orchardEventExporterProvider);
    if (widget.change != null) {
      setState(() => _busy = true);
      try {
        await exporter.changeDestination(widget.orchard.id, to);
        if (!mounted) return;
        showTopSnackBar(context, l10n.exportSaved, isSuccess: true);
        Navigator.of(context).pop();
      } catch (e) {
        AppLogger.warning('Event export: the address was not changed (${errorKind(e)})');
        if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
      } finally {
        if (mounted) setState(() => _busy = false);
      }
      return;
    }
    // Asked first, as a step of this dialog (it opened a second dialog
    // over this one, two sheets on a phone).
    setState(() => _confirming = true);
  }

  /// Turns it on, after the person said yes to what everyone is told.
  Future<void> _turnOn() async {
    final l10n = AppLocalizations.of(context)!;
    final to = _destination(l10n);
    if (to == null) {
      setState(() => _confirming = false);
      return;
    }
    final exporter = ref.read(orchardEventExporterProvider);
    final name = orchardDisplayName(widget.orchard.name, l10n);
    setState(() => _busy = true);
    try {
      final key = await _signingKey();
      if (!mounted) return;
      final done = await withRecentSignIn(
        context,
        ref,
        () => exporter.setUp(widget.orchard.id, to, key),
        summary: (what: l10n.stepUpExportOn(name), effects: const []),
      );
      if (!mounted) return;
      if (!done) {
        // Not signed in again: back to the form, nothing turned on.
        setState(() => _confirming = false);
        return;
      }
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, l10n.exportTurnedOn, isSuccess: true);
      setState(() {
        _confirming = false;
        _doneKey = key.key;
      });
    } catch (e) {
      AppLogger.warning('Event export: not turned on (${errorKind(e)})');
      if (mounted) {
        setState(() => _confirming = false);
        showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final doneKey = _doneKey;
    final name = orchardDisplayName(widget.orchard.name, l10n);
    void close() => Navigator.of(context).pop();
    if (_confirming) {
      // The yes, in this dialog: Back to the form, or Turn on.
      return ZestDialogShell(
        size: ZestModalSize.standard,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.send,
        title: l10n.exportConfirmTitle(name),
        subtitle: name,
        onClose: _busy ? () {} : null,
        body: Text(l10n.exportConfirmBody,
            key: const ValueKey('export-confirm'),
            style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
        primaryKey: const ValueKey('export-confirm-on'),
        primaryAction: (label: l10n.exportTurnOn, icon: LucideIcons.send, onPressed: _busy ? null : _turnOn),
        secondaryKey: const ValueKey('export-back'),
        secondaryAction: (label: l10n.back, onPressed: _busy ? null : () => setState(() => _confirming = false)),
      );
    }
    return ZestDialogShell(
      size: ZestModalSize.standard,
      // Turned on: done, a green tick.
      tone: doneKey != null ? ZestDialogTone.success : ZestDialogTone.info,
      icon: LucideIcons.send,
      // The title says what, the line under it whose (as every team dialog).
      title: widget.change == null ? l10n.exportTitle : l10n.exportChangeTitle,
      subtitle: name,
      onClose: _busy ? () {} : null,
      body: doneKey != null ? _done(l10n, doneKey) : _form(l10n),
      primaryKey: ValueKey(doneKey != null ? 'export-done-close' : 'export-save'),
      primaryAction: doneKey != null
          ? (label: l10n.done, icon: null, onPressed: close)
          : (
              label: widget.change != null ? l10n.save : l10n.exportTurnOn,
              icon: null,
              onPressed: _busy ? null : _save,
            ),
      secondaryKey: ValueKey(doneKey != null ? 'export-done-copy' : 'export-cancel'),
      secondaryAction: doneKey != null
          ? (
              label: l10n.exportCopyKey,
              onPressed: () async {
                await Clipboard.setData(ClipboardData(text: doneKey));
                if (context.mounted) showTopSnackBar(context, l10n.exportKeyCopied, isSuccess: true);
              },
            )
          : (label: l10n.cancel, onPressed: _busy ? null : close),
      tertiaryKey: const ValueKey('export-test'),
      tertiaryAction: doneKey != null ? null : (label: l10n.exportSendTest, onPressed: _busy ? null : _test),
    );
  }

  TextStyle get _help => TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary);
  static const _mono = TextStyle(fontSize: 12.5, fontFamily: 'JetBrainsMono');

  /// Turned on: the key the receiver checks the events by.
  Widget _done(AppLocalizations l10n, String doneKey) => Column(
        key: const ValueKey('export-done'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestFieldLabel(l10n.exportKeyTitle),
          const SizedBox(height: 6),
          // The key in a code box, as a key is shown elsewhere.
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            decoration: BoxDecoration(
              color: Theme.of(context).inputDecorationTheme.fillColor,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: SelectableText(doneKey, key: const ValueKey('export-done-key'), style: _mono),
          ),
          const SizedBox(height: 6),
          Text(l10n.exportKeyHelp, style: _help),
        ],
      );

  Widget _form(AppLocalizations l10n) {
    final help = _help;
    final tested = _tested;
    final phone = teamOnPhone(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.exportSetupIntro, style: help.copyWith(fontSize: 12.5)),
        if (widget.takesOver) ...[
          const SizedBox(height: 10),
          TeamCallout(
            tone: TeamTone.warning,
            icon: LucideIcons.alertTriangle,
            title: l10n.exportMoveNote,
            titleKey: const ValueKey('export-move-note'),
          ),
        ],
        const SizedBox(height: 16),
        ZestFieldLabel(l10n.exportAddressLabel),
        const SizedBox(height: 6),
        TeamField(
          fieldKey: const ValueKey('export-address'),
          controller: _address,
          enabled: !_busy,
          mono: true,
          keyboardType: TextInputType.url,
          hint: 'https://logs.example.com/ingest',
          wrong: _addressError != null,
        ),
        // What is wrong in place of the help, at the same edge.
        TeamFieldNote(help: l10n.exportAddressHelp, problem: _addressError),
        // How the test event went, here under the address it went to.
        if (tested != null) ...[
          const SizedBox(height: 8),
          _TestResult(ok: tested.ok, text: tested.text),
        ],
        const SizedBox(height: 16),
        ZestFieldLabel(l10n.exportFormatLabel),
        const SizedBox(height: 6),
        // One choice of two: a segmented control, the theme's.
        SizedBox(
          width: double.infinity,
          child: SegmentedButton<ExportFormat>(
            key: const ValueKey('export-format'),
            showSelectedIcon: false,
            style: ButtonStyle(
              minimumSize: WidgetStatePropertyAll(Size(0, phone ? 44 : 34)),
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              visualDensity: VisualDensity.standard,
            ),
            segments: [
              ButtonSegment(
                value: ExportFormat.lines,
                label: Text(l10n.exportFormatLines, key: ValueKey('export-format-${ExportFormat.lines.id}')),
              ),
              ButtonSegment(
                value: ExportFormat.array,
                label: Text(l10n.exportFormatArray, key: ValueKey('export-format-${ExportFormat.array.id}')),
              ),
            ],
            selected: {_format},
            onSelectionChanged: _busy ? null : (picked) => setState(() => _format = picked.single),
          ),
        ),
        const SizedBox(height: 6),
        Text(l10n.exportFormatHelp, style: help),
        const SizedBox(height: 16),
        ZestFieldLabel(l10n.exportHeaderLabel),
        const SizedBox(height: 6),
        TeamField(
          fieldKey: const ValueKey('export-header-name'),
          controller: _headerName,
          enabled: !_busy,
          mono: true,
          hint: l10n.exportHeaderNameHint,
          wrong: _headerError != null,
        ),
        const SizedBox(height: 8),
        TeamField(
          fieldKey: const ValueKey('export-header-value'),
          controller: _headerValue,
          enabled: !_busy,
          mono: true,
          obscure: true,
          hint: l10n.exportHeaderValueHint,
          wrong: _headerError != null,
        ),
        TeamFieldNote(help: l10n.exportHeaderHelp, problem: _headerError),
        const SizedBox(height: 16),
        Text(l10n.exportWhatIsSent, key: const ValueKey('export-what'), style: help),
      ],
    );
  }
}

/// The test event's outcome under the address: a green check and what the
/// receiver said, or in red why it was not taken, with its details to copy.
class _TestResult extends StatelessWidget {
  const _TestResult({required this.ok, required this.text});

  final bool ok;
  final String text;

  @override
  Widget build(BuildContext context) {
    final color = ok ? ZestTokens.statusHealthy : ZestTokens.statusCritical;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Icon(ok ? LucideIcons.checkCircle2 : LucideIcons.alertCircle, size: 16, color: color),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(text,
                  key: ValueKey('export-tested-${ok ? 'ok' : 'failed'}'),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ok ? ZestTokens.textPrimary : color)),
              if (!ok) Transform.translate(offset: const Offset(-8, 0), child: CopyDetailsButton(detail: text)),
            ],
          ),
        ),
      ],
    );
  }
}
