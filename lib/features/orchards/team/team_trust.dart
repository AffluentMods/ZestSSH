import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show Clipboard, ClipboardData;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/core/theme/zest_colors.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show UnwatchedSession;
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/team/record_log.dart';
import 'package:zestssh/features/orchards/team/team_changes.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_overview.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/team/team_words.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/copy_details_button.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// How many changes the key log shows before "Show older changes".
const kTeamTrustPage = 100;

/// Saves [bytes] as [fileName] where the person chooses: its path, or null
/// when they did not (tests stand in). A computer asks where, then writes;
/// a phone hands the bytes to the system's own "save as".
typedef RecordLogSaver = Future<String?> Function({
  required String fileName,
  required Uint8List bytes,
  required String dialogTitle,
});

final recordLogSaverProvider = Provider<RecordLogSaver>((ref) => ({
      required String fileName,
      required Uint8List bytes,
      required String dialogTitle,
    }) async {
      if (!isDesktopPlatform) {
        return FilePicker.platform.saveFile(
          dialogTitle: dialogTitle,
          fileName: fileName,
          bytes: bytes,
          type: FileType.custom,
          allowedExtensions: const ['json'],
        );
      }
      final path = await FilePicker.platform.saveFile(
        dialogTitle: dialogTitle,
        fileName: fileName,
        type: FileType.custom,
        allowedExtensions: const ['json'],
        lockParentWindow: true,
      );
      if (path == null) return null;
      await File(path).writeAsBytes(bytes, flush: true);
      return path;
    });

/// The Trust page's key log (3.0, "key log"): every
/// entry of the Orchard's record, newest first, each checked by this device
/// when it arrived (signed by a member allowed to make the change, and
/// chained to the entry before), with the record's head for comparing with
/// a teammate. Each entry opens to what was signed; the whole record can be
/// checked again from its first entry, shown for key changes only, and saved
/// for an audit by owners and admins.
class TeamTrust extends ConsumerStatefulWidget {
  const TeamTrust({super.key, required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<TeamTrust> createState() => _TeamTrustState();
}

class _TeamTrustState extends ConsumerState<TeamTrust> {
  bool _keysOnly = false;
  int _shown = kTeamTrustPage;
  bool _checking = false;
  RecordCheck? _check;
  bool _saving = false;

  OrchardSummary get orchard => widget.orchard;

  bool get _audits => orchard.isOwner || orchard.role == FixedRoles.admin;

  Future<void> _checkAgain(TeamRecord record) async {
    setState(() {
      _checking = true;
      _check = null;
    });
    final result = await checkRecordAgain(orchard.id, record.entries, record.head);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _check = result;
    });
  }

  Future<void> _save(TeamRecord record) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _saving = true);
    try {
      final now = DateTime.now();
      final document = recordLogDocument(orchard.id, record.entries, record.head, savedAt: now);
      final path = await ref.read(recordLogSaverProvider)(
        fileName: recordLogFileName(orchard.id, now),
        bytes: Uint8List.fromList(utf8.encode(document)),
        dialogTitle: l10n.teamTrustSave,
      );
      if (path == null || !mounted) return;
      // Saved: the button is free again behind the note that says where.
      setState(() => _saving = false);
      if (isDesktopPlatform) {
        await showFileSavedDialog(
          context,
          title: l10n.teamTrustSaved,
          message: l10n.teamTrustSavedBody(record.entries.length),
          path: path,
        );
      } else {
        showTopSnackBar(context, l10n.teamTrustSaved, isSuccess: true);
      }
    } catch (e) {
      if (mounted) showTopSnackBar(context, l10n.teamTrustSaveFailed, isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final me = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull?.me;
    return switch (ref.watch(teamRecordProvider(orchard.id))) {
      AsyncData(:final value) => _body(context, l10n, value, me),
      AsyncError() => Text(l10n.teamRecordLoadFailed,
          style: TextStyle(fontSize: 13, color: ZestColors.textSecondary)),
      _ => const Padding(
          padding: EdgeInsets.all(24),
          child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
        ),
    };
  }

  Widget _body(BuildContext context, AppLocalizations l10n, TeamRecord record, String? me) {
    String nameOf(String? uid) {
      if (uid == null) return '';
      return Redactable.account(record.emails[uid] ?? shortMemberId(uid)).displayIn(ref);
    }

    String changeText(TeamChange c) => teamChangeText(
          c,
          l10n,
          nameOf: nameOf,
          crateName: (id) => teamCrateName(orchard, id, l10n),
          roleName: (id) => orchardRoleLabel(id, l10n, names: orchardRoleNames(ref, orchard.id)),
        );

    final entryOf = {for (final e in record.entries) e.seq: e};
    final locale = Localizations.localeOf(context).toLanguageTag();
    final now = DateTime.now();
    final listed = [
      for (final c in record.changes.reversed)
        if (!_keysOnly || isKeyChange(c)) c,
    ];
    final visible = listed.take(_shown).toList();

    void open(TeamChange c) {
      final entry = entryOf[c.seq];
      if (entry == null) return;
      showRecordEntryDetails(
        context,
        orchardId: orchard.id,
        entry: entry,
        words: changeText(c),
        signer: c.by == me ? l10n.teamYou : nameOf(c.by),
        seen: teamSeenLabel(record.firstSeen[c.seq], l10n, locale, now),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _HeadCard(
          head: recordHeadWords(record.head),
          entries: record.changes.length,
          checking: _checking,
          onCheck: () => _checkAgain(record),
        ),
        if (_check case final check?) ...[
          const SizedBox(height: 10),
          _CheckResult(check: check, orchardId: orchard.id, keptHead: record.head),
        ],
        const SizedBox(height: 16),
        Wrap(
          spacing: 12,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          children: [
            SegmentedButton<bool>(
              key: const ValueKey('team-trust-filter'),
              showSelectedIcon: false,
              style: const ButtonStyle(visualDensity: VisualDensity.compact),
              segments: [
                ButtonSegment(value: false, label: Text(l10n.teamTrustFilterAll)),
                ButtonSegment(value: true, label: Text(l10n.teamTrustFilterKeys)),
              ],
              selected: {_keysOnly},
              onSelectionChanged: (s) => setState(() {
                _keysOnly = s.single;
                _shown = kTeamTrustPage;
              }),
            ),
            if (_audits)
              OutlinedButton.icon(
                key: const ValueKey('team-trust-save'),
                onPressed: _saving || record.entries.isEmpty ? null : () => _save(record),
                style: _smallButton(),
                icon: _saving
                    ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
                    : const Icon(LucideIcons.download, size: 14),
                label: Text(l10n.teamTrustSave),
              ),
          ],
        ),
        const SizedBox(height: 10),
        Container(
          decoration: BoxDecoration(
            color: ZestColors.bgSurface,
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: ZestColors.borderSubtle),
          ),
          clipBehavior: Clip.antiAlias,
          // A phone: each entry on two lines, its words first.
          child: LayoutBuilder(builder: (context, constraints) {
            final narrow = constraints.maxWidth < kTeamNarrowWidth;
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (!narrow) _TableHead(l10n: l10n),
                for (final (i, c) in visible.indexed) ...[
                  if (i > 0 || !narrow) Divider(height: 1, thickness: 1, color: ZestColors.borderSubtle),
                  _LogRow(
                    key: ValueKey('team-trust-${c.seq}'),
                    seq: c.seq,
                    words: changeText(c),
                    signer: c.by == me ? l10n.teamYou : nameOf(c.by),
                    keysVersion: l10n.teamTrustKeysVersion(c.byKeyVersion),
                    seen: teamSeenLabel(record.firstSeen[c.seq], l10n, locale, now),
                    narrow: narrow,
                    onTap: entryOf.containsKey(c.seq) ? () => open(c) : null,
                    openLabel: l10n.teamTrustEntryTitle(c.seq),
                  ),
                ],
              ],
            );
          }),
        ),
        if (listed.length > visible.length) ...[
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              key: const ValueKey('team-trust-older'),
              onPressed: () => setState(() => _shown += kTeamTrustPage),
              child: Text(l10n.teamTrustShowOlder(listed.length - visible.length)),
            ),
          ),
        ],
        const SizedBox(height: 12),
        Text(
          l10n.teamTrustNoTimes,
          style: TextStyle(fontSize: 11.5, height: 1.45, color: ZestColors.textMuted),
        ),
      ],
    );
  }
}

ButtonStyle _smallButton() => OutlinedButton.styleFrom(
      visualDensity: VisualDensity.compact,
      foregroundColor: ZestColors.textPrimary,
      side: BorderSide(color: ZestColors.borderStrong),
      textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12.5, fontWeight: FontWeight.w500),
    );

/// The record's head, how many entries were checked, and the buttons to
/// copy the head and check every entry again.
class _HeadCard extends StatelessWidget {
  const _HeadCard({required this.head, required this.entries, required this.checking, required this.onCheck});

  final String head;
  final int entries;
  final bool checking;
  final VoidCallback onCheck;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final words = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          l10n.teamTrustChecked(entries),
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
        ),
        const SizedBox(height: 3),
        Text(
          l10n.teamTrustCheckedBody,
          style: TextStyle(fontSize: 12, height: 1.45, color: ZestColors.textSecondary),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Text(l10n.teamTrustHead, style: TextStyle(fontSize: 12, color: ZestColors.textTertiary)),
            const SizedBox(width: 8),
            Flexible(
              child: SelectableText(
                head,
                key: const ValueKey('team-trust-head-words'),
                style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12.5, color: ZestColors.textPrimary),
              ),
            ),
          ],
        ),
      ],
    );
    final buttons = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        OutlinedButton.icon(
          key: const ValueKey('team-trust-copy'),
          onPressed: () {
            Clipboard.setData(ClipboardData(text: head));
            showTopSnackBar(context, l10n.teamTrustHeadCopied, isSuccess: true);
          },
          style: _smallButton(),
          icon: const Icon(LucideIcons.copy, size: 14),
          label: Text(l10n.teamTrustCopyHead),
        ),
        OutlinedButton.icon(
          key: const ValueKey('team-trust-check'),
          onPressed: checking ? null : onCheck,
          style: _smallButton(),
          icon: checking
              ? const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6))
              : const Icon(LucideIcons.shieldCheck, size: 14),
          label: Text(checking ? l10n.teamTrustChecking : l10n.teamTrustCheckAgain),
        ),
      ],
    );
    return Container(
      key: const ValueKey('team-trust-head'),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: ZestColors.statusSuccess.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.statusSuccess.withValues(alpha: 0.35)),
      ),
      child: LayoutBuilder(builder: (context, constraints) {
        final icon = Padding(
          padding: const EdgeInsets.only(top: 1),
          child: Icon(LucideIcons.shieldCheck, size: 18, color: ZestColors.statusSuccess),
        );
        // A phone: the buttons under the words, so they keep the width.
        final narrow = constraints.maxWidth < kTeamNarrowWidth;
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            icon,
            const SizedBox(width: 12),
            Expanded(
              child: narrow
                  ? Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [words, const SizedBox(height: 10), buttons],
                    )
                  : words,
            ),
            if (!narrow) ...[
              const SizedBox(width: 12),
              ConstrainedBox(constraints: const BoxConstraints(maxWidth: 260), child: buttons),
            ],
          ],
        );
      }),
    );
  }
}

/// What checking every entry again found: all of it holds, or where it
/// stops holding, with the details to copy.
class _CheckResult extends StatelessWidget {
  const _CheckResult({required this.check, required this.orchardId, required this.keptHead});

  final RecordCheck check;
  final String orchardId;
  final Uint8List keptHead;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (check.holds) {
      return Row(
        key: const ValueKey('team-trust-check-ok'),
        children: [
          Icon(LucideIcons.checkCircle2, size: 15, color: ZestColors.statusSuccess),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              l10n.teamTrustCheckOk(check.entries),
              style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestColors.textPrimary),
            ),
          ),
        ],
      );
    }
    final details = [
      'Orchard: $orchardId',
      'Entry: ${check.failedSeq}',
      'Reason: ${check.reason}',
      'Entries that hold: ${check.entries}',
      'Head kept here: ${hexOf(keptHead)}',
      'Head the entries lead to: ${hexOf(check.head)}',
    ].join('\n');
    return Container(
      key: const ValueKey('team-trust-check-failed'),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: ZestColors.statusError.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestColors.statusError.withValues(alpha: 0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.shieldAlert, size: 16, color: ZestColors.statusError),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  l10n.teamTrustCheckFailed(check.failedSeq ?? 0),
                  style: TextStyle(fontSize: 12.5, height: 1.45, fontWeight: FontWeight.w600, color: ZestColors.textPrimary),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          SelectableText(
            check.reason ?? '',
            style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textSecondary),
          ),
          const SizedBox(height: 4),
          CopyDetailsButton(detail: details, label: l10n.desktopShellCopyDetails),
        ],
      ),
    );
  }
}

class _TableHead extends StatelessWidget {
  const _TableHead({required this.l10n});

  final AppLocalizations l10n;

  @override
  Widget build(BuildContext context) {
    final th = TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, letterSpacing: 0.8, color: ZestColors.textMuted);
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 14, 8),
      child: Row(
        children: [
          SizedBox(width: 52, child: Text('#', style: th)),
          Expanded(child: Text(l10n.teamTrustColChange.toUpperCase(), style: th)),
          SizedBox(
            width: 200,
            child: Padding(
              padding: const EdgeInsets.only(left: 12),
              child: Text(l10n.teamTrustColBy.toUpperCase(), style: th),
            ),
          ),
          SizedBox(width: 96, child: Text(l10n.teamTrustColSigned.toUpperCase(), style: th, textAlign: TextAlign.right)),
          SizedBox(width: 128, child: Text(l10n.teamTrustColSeen.toUpperCase(), style: th, textAlign: TextAlign.right)),
        ],
      ),
    );
  }
}

/// One entry of the log, opening to what was signed.
class _LogRow extends StatelessWidget {
  const _LogRow({
    super.key,
    required this.seq,
    required this.words,
    required this.signer,
    required this.keysVersion,
    required this.seen,
    required this.narrow,
    required this.onTap,
    required this.openLabel,
  });

  final int seq;
  final String words;
  final String signer;
  final String keysVersion;
  final String seen;
  final bool narrow;
  final VoidCallback? onTap;
  final String openLabel;

  @override
  Widget build(BuildContext context) {
    final number = Text(
      '$seq',
      style: TextStyle(
        fontFamily: 'JetBrainsMono',
        fontSize: 11.5,
        height: narrow ? 1.6 : null,
        color: ZestColors.textMuted,
        fontFeatures: const [FontFeature.tabularFigures()],
      ),
    );
    final Widget row = narrow
        ? Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 10),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                SizedBox(width: 34, child: number),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(words, style: TextStyle(fontSize: 13, height: 1.35, color: ZestColors.textPrimary)),
                      const SizedBox(height: 3),
                      Text(
                        [signer, keysVersion, seen].join(' · '),
                        key: ValueKey('team-trust-seen-$seq'),
                        style: TextStyle(fontSize: 12, height: 1.35, color: ZestColors.textTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          )
        : Padding(
            padding: const EdgeInsets.fromLTRB(14, 9, 14, 9),
            child: Row(
              children: [
                SizedBox(width: 52, child: number),
                Expanded(
                  child: Text(words, style: TextStyle(fontSize: 13, height: 1.35, color: ZestColors.textPrimary)),
                ),
                SizedBox(
                  width: 200,
                  child: Padding(
                    padding: const EdgeInsets.only(left: 12),
                    child: Text(
                      signer,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 12, color: ZestColors.textSecondary),
                    ),
                  ),
                ),
                SizedBox(
                  width: 96,
                  child: Text(
                    keysVersion,
                    textAlign: TextAlign.right,
                    style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, color: ZestColors.textTertiary),
                  ),
                ),
                SizedBox(
                  width: 128,
                  child: Text(
                    seen,
                    key: ValueKey('team-trust-seen-$seq'),
                    textAlign: TextAlign.right,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 12, color: ZestColors.textTertiary),
                  ),
                ),
              ],
            ),
          );
    if (onTap == null) return row;
    return Semantics(
      button: true,
      label: openLabel,
      child: InkWell(onTap: onTap, child: row),
    );
  }
}

/// One entry of the record, as it was signed: what it changed, who signed it
/// and with which keys, its hash and the one it links to, its signature, and
/// the body exactly as signed; copied whole in one tap.
Future<void> showRecordEntryDetails(
  BuildContext context, {
  required String orchardId,
  required RecordEntry entry,
  required String words,
  required String signer,
  required String seen,
}) {
  final l10n = AppLocalizations.of(context)!;
  final json = const JsonEncoder.withIndent('  ').convert(recordEntryJson(orchardId, entry));
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.fileSignature,
    title: l10n.teamTrustEntryTitle(entry.seq),
    subtitle: words,
    body: _EntryDetails(orchardId: orchardId, entry: entry, signer: signer, seen: seen),
    primaryAction: (
      label: l10n.teamTrustEntryCopy,
      icon: LucideIcons.copy,
      onPressed: () {
        Clipboard.setData(ClipboardData(text: json));
        showTopSnackBar(context, l10n.teamTrustEntryCopied, isSuccess: true);
      },
    ),
    secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
  );
}

class _EntryDetails extends StatelessWidget {
  const _EntryDetails({required this.orchardId, required this.entry, required this.signer, required this.seen});

  final String orchardId;
  final RecordEntry entry;
  final String signer;
  final String seen;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    String body;
    try {
      body = const JsonEncoder.withIndent('  ').convert(jsonDecode(entry.bodyJson));
    } catch (_) {
      body = entry.bodyJson;
    }
    final mono = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 11.5, height: 1.45, color: ZestColors.textPrimary);
    // Each name a step quieter than its value, every line spaced alike (the
    // names read as their values did, and a line with a copy button stood
    // further from its neighbours).
    Widget line(String key, String label, Widget value) => Padding(
          key: ValueKey('team-trust-entry-$key'),
          padding: const EdgeInsets.only(bottom: 10),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              ZestFieldLabel(label, key: ValueKey('team-trust-entry-$key-label'), color: ZestColors.textTertiary),
              const SizedBox(height: 3),
              value,
            ],
          ),
        );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        // A session that ran with nobody watching: what was reported of it.
        if (entry.type == RecordTypes.sessionUnwatched)
          _UnwatchedReport(orchardId: orchardId, entry: entry, line: line),
        line('by', l10n.teamTrustEntrySignedBy,
            Text('$signer · ${l10n.teamTrustKeysVersion(entry.byKeyVersion)}',
                style: TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textPrimary))),
        line('type', l10n.teamTrustEntryType, SelectableText(entry.type, style: mono)),
        // Long values on one line each, cut in their middle, whole in the
        // tooltip and on the clipboard (they ran to the edge unbroken).
        line('hash', l10n.teamTrustEntryHash, _LongValue(hexOf(entry.hash(orchardId)))),
        line('prev', l10n.teamTrustEntryPrev,
            entry.prev.isEmpty
                ? Text(l10n.teamTrustEntryFirst, style: TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textSecondary))
                : _LongValue(hexOf(entry.prev))),
        line('signature', l10n.teamTrustEntrySignature, _LongValue(base64Encode(entry.signature))),
        line('seen', l10n.teamTrustEntrySeen,
            Text(seen, style: TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textSecondary))),
        line(
          'body',
          l10n.teamTrustEntryBody,
          // What was signed: a box of its own at most 200 high, scrolled
          // inside it with its edges fading where more waits (it ran into
          // the footer).
          Container(
            key: const ValueKey('team-trust-entry-body-box'),
            constraints: const BoxConstraints(maxHeight: 200),
            decoration: BoxDecoration(
              color: ZestColors.surfaceRaisedAlt,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: ZestColors.borderSubtle),
            ),
            child: ZestScrollFade(
              child: SingleChildScrollView(
                padding: const EdgeInsets.all(10),
                child: SelectableText(body, style: mono),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// A long value (a hash, a signature) on one line in the code font, cut in
/// its middle where it does not fit, whole in its tooltip, with a button
/// that copies all of it.
class _LongValue extends StatelessWidget {
  const _LongValue(this.value);

  final String value;

  /// [value] in at most [chars] characters: its start and its end, with an
  /// ellipsis between them.
  static String cut(String value, int chars) {
    if (value.length <= chars || chars < 9) return value;
    final keep = chars - 1;
    final head = (keep + 1) ~/ 2;
    return '${value.substring(0, head)}\u2026${value.substring(value.length - (keep - head))}';
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    const style = TextStyle(fontFamily: 'JetBrainsMono', fontSize: 12, height: 1.4);
    return Row(
      children: [
        Expanded(
          child: LayoutBuilder(builder: (context, box) {
            // How many characters of the code font fit on the line, at the
            // size the text is drawn (the person's text size with it); the
            // painter is only for measuring, and let go at once.
            final painter = TextPainter(
              text: const TextSpan(text: '0', style: style),
              textDirection: TextDirection.ltr,
              textScaler: MediaQuery.textScalerOf(context),
            )..layout();
            final fits = (box.maxWidth / painter.width).floor();
            painter.dispose();
            return Tooltip(
              message: value,
              child: Text(
                cut(value, fits),
                maxLines: 1,
                overflow: TextOverflow.clip,
                softWrap: false,
                style: style.copyWith(color: ZestColors.textPrimary),
              ),
            );
          }),
        ),
        const SizedBox(width: 4),
        // No taller than a line of text, so its line is spaced as the others.
        SizedBox(
          width: 28,
          height: 20,
          child: IconButton(
            tooltip: l10n.copy,
            padding: EdgeInsets.zero,
            iconSize: 14,
            onPressed: () {
              Clipboard.setData(ClipboardData(text: value));
              showTopSnackBar(context, l10n.teamAdminValueCopied, isSuccess: true);
            },
            icon: Icon(LucideIcons.copy, size: 14, color: ZestColors.textSecondary),
          ),
        ),
      ],
    );
  }
}

/// What a member reported of a session that ran with nobody watching (3.0,
/// the outage work): when, and, where this device holds the Crate's key it
/// was sealed with, the host, their reason and how ZestSSH Cloud stood. On
/// a device that cannot open it, that is said.
class _UnwatchedReport extends ConsumerStatefulWidget {
  const _UnwatchedReport({required this.orchardId, required this.entry, required this.line});

  final String orchardId;
  final RecordEntry entry;
  final Widget Function(String key, String label, Widget value) line;

  @override
  ConsumerState<_UnwatchedReport> createState() => _UnwatchedReportState();
}

class _UnwatchedReportState extends ConsumerState<_UnwatchedReport> {
  late final Future<UnwatchedSession?> _read =
      ref.read(unwatchedSessionReaderProvider)(widget.orchardId, widget.entry);

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final said = TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textPrimary);
    return FutureBuilder<UnwatchedSession?>(
      future: _read,
      builder: (context, read) {
        final session = read.data;
        if (session == null) return const SizedBox.shrink();
        final report = session.report;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            widget.line('unwatched-when', l10n.unwatchedEntryWhen, Text(accessTimeText(session.at, l10n), style: said)),
            if (report == null)
              widget.line(
                  'unwatched-sealed',
                  l10n.unwatchedEntryReason,
                  Text(l10n.unwatchedEntrySealed,
                      style: TextStyle(fontSize: 13, height: 1.4, color: ZestColors.textSecondary)))
            else ...[
              widget.line('unwatched-host', l10n.unwatchedEntryHost,
                  RedactedText(Redactable.host(report.host), style: said)),
              widget.line('unwatched-reason', l10n.unwatchedEntryReason, SelectableText(report.reason, style: said)),
              widget.line('unwatched-service', l10n.unwatchedEntryService,
                  Text(unwatchedReachWords(report.reach, l10n), style: said)),
            ],
          ],
        );
      },
    );
  }
}

/// The record's head as six groups of four hex digits: enough to compare
/// aloud, and the same on every app that sees the same history.
String recordHeadWords(Uint8List head) {
  final hex = [for (final b in head) b.toRadixString(16).padLeft(2, '0')].join();
  if (hex.isEmpty) return '';
  final short = hex.length > 24 ? hex.substring(0, 24) : hex;
  return [for (var i = 0; i < short.length; i += 4) short.substring(i, i + 4 > short.length ? short.length : i + 4)]
      .join(' ');
}
