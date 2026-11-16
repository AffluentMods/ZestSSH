import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/features/orchards/crypto/orchard_crypto.dart' show kMaxAccessNoteLength;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart';
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';

// Access on request (3.0), on screen: a member asks for a Crate, or
// for more in one they open, for a set time; whoever manages it gives it
// (picking the Crate when the member could not name it), or declines; and
// what was given can be ended before its time. The Team page lists what
// waits and what runs (team_overview.dart) and opens these.

/// How long access is asked for or given, as offered.
const List<Duration> kAccessDurations = [
  Duration(hours: 1),
  Duration(hours: 2),
  Duration(hours: 4),
  Duration(hours: 8),
  Duration(days: 1),
  Duration(days: 3),
  Duration(days: 7),
  Duration(days: 30),
];

/// The time picked when nothing says otherwise.
const Duration kDefaultAccessDuration = Duration(hours: 2);

/// [d] in words: whole days, else whole hours, else minutes.
String accessDurationText(Duration d, AppLocalizations l10n) {
  final seconds = d.inSeconds;
  if (seconds % 86400 == 0) return l10n.settingsMobExpiryDays(seconds ~/ 86400);
  if (seconds % 3600 == 0) return l10n.settingsInlineHoursOption(seconds ~/ 3600);
  return l10n.settingsInlineMinutesOption((seconds / 60).ceil());
}

/// What a request asks for, on one line: the Crate, how far, for how long.
String accessRequestSummary(AccessRequestView r, OrchardSummary orchard, AppLocalizations l10n) => [
      r.crateId == null ? l10n.accessCrateInNote : teamAccessCrateName(orchard, r.crateId, l10n),
      crateLevelName(r.level, l10n),
      accessDurationText(r.duration, l10n),
    ].join(l10n.listSeparator);

/// What someone holds until a set time, on one line: the Crate, how far
/// when it is more in a Crate they open anyway, and until when.
String timedAccessSummary(TimedAccess t, OrchardSummary orchard, AppLocalizations l10n, {DateTime? now}) => [
      teamAccessCrateName(orchard, t.crateId, l10n),
      if (!t.wholeCrate) crateLevelName(t.level, l10n),
      l10n.accessUntil(accessTimeText(t.until, l10n, now: now)),
    ].join(l10n.listSeparator);

/// A Crate's name as this device has it, or "a Crate you can't open".
String teamAccessCrateName(OrchardSummary orchard, String? crateId, AppLocalizations l10n) {
  final crate = orchard.crates.where((c) => c.id == crateId).firstOrNull;
  return crate == null ? l10n.teamCrateClosed : crateDisplayName(crate, l10n);
}

/// What went wrong with a request for access or with giving it, in words a
/// person can act on. [nameOf] names a member by account id.
String accessErrorMessage(Object error, AppLocalizations l10n, {String Function(String uid)? nameOf}) {
  if (error is OrchardServerException) {
    switch (error.code) {
      case 'request-limit':
        return l10n.accessErrorRequestLimit;
      case 'access-not-needed':
        return l10n.accessErrorNotNeeded;
      case 'access-until-passed':
        return l10n.accessErrorPassed;
      case 'access-too-long':
        return l10n.accessErrorTooLong;
    }
  }
  return orchardChangeErrorMessage(error, l10n, nameOf: nameOf);
}

/// The Crates of [orchard] in which this account could be given more than
/// it has, each with the levels above its own that can be asked for.
Map<String, List<CrateLevel>> accessMoreChoices(OrchardSummary orchard) {
  const askable = [CrateLevel.connect, CrateLevel.use, CrateLevel.edit];
  final out = <String, List<CrateLevel>>{};
  for (final c in orchard.crates) {
    if (c.ownersOnly) continue;
    final mine = levelOf(c.switches) ?? CrateLevel.connect;
    final above = [
      for (final l in askable)
        if (l.index > mine.index) l,
    ];
    if (above.isNotEmpty) out[c.id] = above;
  }
  return out;
}

// ── Asking ──────────────────────────────────────────────────────────────

/// "Ask for access": for more in a Crate this account opens, or for one it
/// cannot open (and so cannot name: a note says which). True when a request
/// was sent.
Future<bool> showAskAccess(BuildContext context, WidgetRef ref, OrchardSummary orchard) async {
  final l10n = AppLocalizations.of(context)!;
  final sent = await showZestModal<bool>(
    context: context,
    size: ZestModalSize.standard,
    child: _AskAccessDialog(orchard: orchard),
  );
  if (sent != true || !context.mounted) return false;
  ref.read(accessRequestsVersionProvider.notifier).state++;
  showTopSnackBar(context, l10n.accessAskSent);
  return true;
}

class _AskAccessDialog extends ConsumerStatefulWidget {
  const _AskAccessDialog({required this.orchard});

  final OrchardSummary orchard;

  @override
  ConsumerState<_AskAccessDialog> createState() => _AskAccessDialogState();
}

class _AskAccessDialogState extends ConsumerState<_AskAccessDialog> {
  late final Map<String, List<CrateLevel>> _more = accessMoreChoices(widget.orchard);
  late bool _other = _more.isEmpty;
  late String? _crateId = _more.keys.firstOrNull;
  CrateLevel _level = CrateLevel.use;

  /// The person picked the level themselves: it is kept while it can be
  /// asked for.
  bool _levelPicked = false;
  Duration _duration = kDefaultAccessDuration;
  final _note = TextEditingController();
  bool _busy = false;
  String? _error;
  String? _noteError;

  @override
  void initState() {
    super.initState();
    _settleLevel();
  }

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  List<CrateLevel> get _levels =>
      _other ? const [CrateLevel.connect, CrateLevel.use, CrateLevel.edit] : _more[_crateId] ?? const [];

  /// Keeps the level one that can be asked for here: the one the person
  /// picked while it can be, else Use, else the least there is to ask for.
  void _settleLevel() {
    final levels = _levels;
    if (levels.isEmpty || (_levelPicked && levels.contains(_level))) return;
    _levelPicked = false;
    _level = levels.contains(CrateLevel.use) ? CrateLevel.use : levels.first;
  }

  Future<void> _send() async {
    final l10n = AppLocalizations.of(context)!;
    final note = _note.text.trim();
    if (_other && note.isEmpty) {
      setState(() => _noteError = l10n.accessAskNoteNeeded);
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
      _noteError = null;
    });
    try {
      await ref.read(orchardServiceProvider).requestAccess(
            widget.orchard.id,
            crateId: _other ? null : _crateId,
            level: _level,
            duration: _duration,
            note: note.isEmpty ? null : note,
          );
      if (mounted) Navigator.of(context).pop(true);
    } catch (e) {
      AppLogger.warning('Orchards: asking for access failed ($e)');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = accessErrorMessage(e, l10n);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final help = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary);
    final levels = _levels;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.keyRound,
      title: l10n.accessAskAction,
      subtitle: l10n.accessAskSubtitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_more.isNotEmpty)
            RadioGroup<bool>(
              groupValue: _other,
              onChanged: (v) {
                if (_busy || v == null) return;
                setState(() {
                  _other = v;
                  _noteError = null;
                  _settleLevel();
                });
              },
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _RadioRow(key: const ValueKey('access-ask-more'), value: false, label: l10n.accessAskMore),
                  _RadioRow(key: const ValueKey('access-ask-other'), value: true, label: l10n.accessAskOther),
                ],
              ),
            ),
          if (_other) ...[
            const SizedBox(height: 8),
            Text(l10n.accessAskOtherHelp, key: const ValueKey('access-ask-other-help'), style: help),
          ] else ...[
            const SizedBox(height: 16),
            ZestFieldLabel(l10n.accessFieldCrate),
            const SizedBox(height: 6),
            ZestSelect<String>(
              key: const ValueKey('access-ask-crate'),
              value: _crateId,
              onChanged: _busy
                  ? null
                  : (v) => setState(() {
                        _crateId = v;
                        _settleLevel();
                      }),
              items: [for (final id in _more.keys) ZestSelectItem(id, teamAccessCrateName(widget.orchard, id, l10n))],
            ),
          ],
          const SizedBox(height: 16),
          ZestFieldLabel(l10n.accessFieldLevel),
          const SizedBox(height: 6),
          ZestSelect<CrateLevel>(
            key: const ValueKey('access-ask-level'),
            value: levels.contains(_level) ? _level : null,
            onChanged: _busy
                ? null
                : (v) => setState(() {
                      _level = v;
                      _levelPicked = true;
                    }),
            items: [for (final l in levels) ZestSelectItem(l, crateLevelName(l, l10n))],
          ),
          const SizedBox(height: 16),
          ZestFieldLabel(l10n.accessFieldDuration),
          const SizedBox(height: 6),
          _DurationPicker(
            key: const ValueKey('access-ask-duration'),
            value: _duration,
            enabled: !_busy,
            onChanged: (d) => setState(() => _duration = d),
          ),
          const SizedBox(height: 16),
          ZestTextField(
            key: const ValueKey('access-ask-note'),
            controller: _note,
            label: l10n.accessFieldNote,
            hintText: _other ? l10n.accessNoteHintOther : l10n.accessNoteHintMore,
            errorText: _noteError,
            maxLength: kMaxAccessNoteLength,
            // As tall and edged as the choices above it.
            likeSelect: true,
            // The choice above comes first: on a phone, a field that takes
            // the focus scrolls it away and brings the keyboard up at once.
            autofocus: false,
            onSubmit: _busy ? null : _send,
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Text(_error!,
                key: const ValueKey('access-ask-error'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
          ],
        ],
      ),
      primaryAction: (label: l10n.accessAskSend, onPressed: _busy ? null : _send, icon: LucideIcons.send),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
    );
  }
}

/// The durations offered, with [value] among them when it is another.
class _DurationPicker extends StatelessWidget {
  const _DurationPicker({super.key, required this.value, required this.enabled, required this.onChanged});

  final Duration value;
  final bool enabled;
  final ValueChanged<Duration> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final offered = {...kAccessDurations, value}.toList()..sort();
    return ZestSelect<Duration>(
      value: value,
      onChanged: enabled ? onChanged : null,
      items: [for (final d in offered) ZestSelectItem(d, accessDurationText(d, l10n))],
    );
  }
}

/// One choice of a radio group: the radio at the content's edge, its words
/// beside it, the whole row a 40 pixel target.
class _RadioRow extends StatelessWidget {
  const _RadioRow({super.key, required this.value, required this.label});

  final bool value;
  final String label;

  @override
  Widget build(BuildContext context) {
    final group = RadioGroup.maybeOf<bool>(context);
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => group?.onChanged(value),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 40),
        child: Row(
          children: [
            SizedBox(
              width: 20,
              height: 20,
              child: Radio<bool>(
                value: value,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                visualDensity: VisualDensity.compact,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary))),
          ],
        ),
      ),
    );
  }
}

// ── Giving ──────────────────────────────────────────────────────────────

/// "Give access": answers [request] (with the Crate picked when it names
/// none, or declined), or gives someone a Crate for a set time unasked.
/// [people] is the Orchard's record as this device has it.
Future<void> showGiveAccess(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard,
  OrchardPeople people, {
  AccessRequestView? request,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final done = await showZestModal<String>(
    context: context,
    size: ZestModalSize.standard,
    child: _GiveAccessDialog(orchard: orchard, people: people, request: request),
  );
  if (done == null || !context.mounted) return;
  // (The requests are read again with the Orchards: one step for both.)
  ref.read(orchardListVersionProvider.notifier).state++;
  showTopSnackBar(context, done.isEmpty ? l10n.accessDeclined : done);
}

class _GiveAccessDialog extends ConsumerStatefulWidget {
  const _GiveAccessDialog({required this.orchard, required this.people, this.request});

  final OrchardSummary orchard;
  final OrchardPeople people;
  final AccessRequestView? request;

  @override
  ConsumerState<_GiveAccessDialog> createState() => _GiveAccessDialogState();
}

class _GiveAccessDialogState extends ConsumerState<_GiveAccessDialog> {
  OrchardRecord get _record => widget.people.record;
  String get _me => widget.people.me;

  /// The members this account could give something to: active, below
  /// admin, ranked below it (so never itself).
  late final List<OrchardPerson> _members = [
    for (final m in widget.people.members)
      if (m.status == MemberStatus.active &&
          m.role != FixedRoles.owner &&
          m.role != FixedRoles.admin &&
          _record.rankOf(_me) > _record.rankOfRole(m.role))
        m,
  ];

  /// The Crates this account can give: those it manages for good. (A
  /// request that names its Crate reaches only someone who manages it.)
  late final List<String> _crates = OrchardAccess.accessCratesFor(_record, _me);

  late String? _uid = widget.request?.uid ?? (_members.length == 1 ? _members.single.uid : null);
  late String? _crateId = widget.request?.crateId ?? (_crates.length == 1 ? _crates.single : null);
  late CrateLevel _level = widget.request?.level ?? CrateLevel.use;
  late Duration _duration = widget.request?.duration ?? kDefaultAccessDuration;
  bool _busy = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    _settleLevel();
  }

  String _nameOf(String uid) {
    final email = widget.people.members.where((m) => m.uid == uid).firstOrNull?.email;
    return Redactable.account(email ?? uid).displayIn(ref);
  }

  /// The levels this account can give in the Crate picked: those whose
  /// switches it has itself, never manage.
  List<CrateLevel> get _levels {
    final crate = _record.crates[_crateId];
    if (crate == null) return const [CrateLevel.connect, CrateLevel.use, CrateLevel.edit];
    return [
      for (final l in levelsWithin(_record.switchesOf(_me, crate.id), crate.allow))
        if (l != CrateLevel.manage) l,
    ];
  }

  void _settleLevel() {
    final levels = _levels;
    if (levels.isEmpty || levels.contains(_level)) return;
    // The most this account can give, up to what was asked.
    _level = levels.lastWhere((l) => l.index <= _level.index, orElse: () => levels.first);
  }

  /// Their role has no user name on a Crate that signs people in with
  /// certificates: they would open it and not connect.
  bool get _noCertificate {
    final ca = _record.crates[_crateId]?.ca;
    final role = _record.members[_uid]?.role;
    return ca != null && ca.on && role != null && (ca.principals[role]?.isEmpty ?? true);
  }

  DateTime get _ends => DateTime.now().add(_duration);

  Future<void> _give() async {
    final l10n = AppLocalizations.of(context)!;
    final uid = _uid;
    final crateId = _crateId;
    if (uid == null || crateId == null) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    final until = accessTimeText(_ends.millisecondsSinceEpoch ~/ 1000, l10n);
    final name = _nameOf(uid);
    try {
      final gave = await withRecentSignIn(
        context,
        ref,
        () => ref.read(orchardServiceProvider).giveAccess(
              widget.orchard.id,
              uid: uid,
              crateId: crateId,
              level: _level,
              duration: _duration,
              requestId: widget.request?.id,
            ),
        summary: (
          what: l10n.accessStepUpWhat(name, teamAccessCrateName(widget.orchard, crateId, l10n)),
          effects: [l10n.accessStepUpEffect(until)],
        ),
      );
      if (!mounted) return;
      if (gave) {
        Navigator.of(context).pop(l10n.accessGiven(name, until));
      } else {
        setState(() => _busy = false);
      }
    } catch (e) {
      AppLogger.warning('Orchards: giving access failed ($e)');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = accessErrorMessage(e, l10n, nameOf: _nameOf);
        });
      }
    }
  }

  Future<void> _decline() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await ref.read(orchardServiceProvider).declineAccessRequest(widget.orchard.id, widget.request!.id);
      if (mounted) Navigator.of(context).pop('');
    } catch (e) {
      AppLogger.warning('Orchards: declining a request for access failed ($e)');
      if (mounted) {
        setState(() {
          _busy = false;
          _error = accessErrorMessage(e, l10n);
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final help = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary);
    final request = widget.request;
    final levels = _levels;
    final ready = _uid != null && _crateId != null && levels.contains(_level);
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.info,
      icon: LucideIcons.keyRound,
      title: request?.uid != null ? l10n.accessGiveTitle(_nameOf(request!.uid!)) : l10n.accessGiveTitleAnyone,
      subtitle: request == null ? l10n.accessGiveHint : accessRequestSummary(request, widget.orchard, l10n),
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (request?.note != null) ...[
            // Their note, quoted: a bar at its start and the quieter ink, so
            // it reads as what they wrote and not as a field to type in.
            Container(
              key: const ValueKey('access-give-note'),
              padding: const EdgeInsets.fromLTRB(12, 2, 0, 2),
              decoration: BoxDecoration(
                border: Border(left: BorderSide(color: ZestTokens.borderStrong, width: 2)),
              ),
              child: Text(request!.note!, style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary)),
            ),
            const SizedBox(height: 16),
          ] else if (request?.noteUnread ?? false) ...[
            Text(l10n.accessRequestNoteUnread, key: const ValueKey('access-give-note-unread'), style: help),
            const SizedBox(height: 16),
          ],
          if (request == null) ...[
            ZestFieldLabel(l10n.accessFieldMember),
            const SizedBox(height: 6),
            ZestSelect<String>(
              key: const ValueKey('access-give-member'),
              value: _uid,
              onChanged: _busy ? null : (v) => setState(() => _uid = v),
              items: [for (final m in _members) ZestSelectItem(m.uid, _nameOf(m.uid))],
            ),
            const SizedBox(height: 16),
          ],
          ZestFieldLabel(l10n.accessFieldCrate),
          const SizedBox(height: 6),
          ZestSelect<String>(
            key: const ValueKey('access-give-crate'),
            value: _crateId,
            hint: l10n.accessGivePickCrate,
            // Named by the request: theirs to give or not, not to change.
            onChanged: _busy || request?.crateId != null
                ? null
                : (v) => setState(() {
                      _crateId = v;
                      _settleLevel();
                    }),
            items: [for (final id in _crates) ZestSelectItem(id, teamAccessCrateName(widget.orchard, id, l10n))],
          ),
          const SizedBox(height: 16),
          ZestFieldLabel(l10n.accessFieldLevel),
          const SizedBox(height: 6),
          ZestSelect<CrateLevel>(
            key: const ValueKey('access-give-level'),
            value: levels.contains(_level) ? _level : null,
            onChanged: _busy ? null : (v) => setState(() => _level = v),
            items: [for (final l in levels) ZestSelectItem(l, crateLevelName(l, l10n))],
          ),
          const SizedBox(height: 16),
          ZestFieldLabel(l10n.accessFieldDuration),
          const SizedBox(height: 6),
          _DurationPicker(
            key: const ValueKey('access-give-duration'),
            value: _duration,
            enabled: !_busy,
            onChanged: (d) => setState(() => _duration = d),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.accessGiveEnds(accessTimeText(_ends.millisecondsSinceEpoch ~/ 1000, l10n)),
            key: const ValueKey('access-give-ends'),
            style: TextStyle(fontSize: 12.5, color: ZestTokens.textSecondary),
          ),
          if (_level != CrateLevel.connect) ...[
            const SizedBox(height: 12),
            Text(l10n.accessGiveRevealNote, key: const ValueKey('access-give-reveal-note'), style: help),
          ],
          if (_noCertificate) ...[
            const SizedBox(height: 8),
            Text(l10n.accessGiveNoCertificate,
                key: const ValueKey('access-give-no-certificate'), style: help.copyWith(color: ZestTokens.statusWarning)),
          ],
          if (_error != null) ...[
            const SizedBox(height: 10),
            Text(_error!,
                key: const ValueKey('access-give-error'),
                style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.statusCritical)),
          ],
        ],
      ),
      primaryAction: (label: l10n.accessGiveAction, onPressed: _busy || !ready ? null : _give, icon: LucideIcons.check),
      secondaryAction: (label: l10n.cancel, onPressed: _busy ? null : () => Navigator.of(context).pop()),
      tertiaryAction: request == null ? null : (label: l10n.accessDecline, onPressed: _busy ? null : _decline),
      tertiaryDanger: true,
    );
  }
}

// ── Ending, withdrawing ─────────────────────────────────────────────────

/// Asks, then ends what [access] gives before its time: by whoever manages
/// the Crate ([name] is the member), or by the member themselves. True when
/// it ended.
Future<bool> endTimedAccess(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard,
  TimedAccess access, {
  required String name,
  required bool mine,
}) async {
  final l10n = AppLocalizations.of(context)!;
  final crate = teamAccessCrateName(orchard, access.crateId, l10n);
  final go = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.destructive,
    icon: LucideIcons.timerOff,
    subtitle: orchardDisplayName(orchard.name, l10n),
    primaryDanger: true,
    // Its last two words on one line ("now?" was alone on the second
    // before).
    title: noOrphan(mine ? l10n.accessGiveUpTitle(crate) : l10n.accessEndTitle(name, crate)),
    body: Text(mine ? l10n.accessGiveUpBody : l10n.accessEndBody,
        style: TextStyle(fontSize: 13, height: 1.45, color: ZestTokens.textSecondary)),
    primaryAction: (
      label: mine ? l10n.accessGiveUp : l10n.accessEndConfirm,
      onPressed: () => Navigator.of(context).pop(true),
      icon: LucideIcons.timerOff,
    ),
    secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
  );
  if (go != true || !context.mounted) return false;
  try {
    await ref.read(orchardServiceProvider).endAccess(orchard.id, uid: access.uid, crateId: access.crateId);
  } catch (e) {
    AppLogger.warning('Orchards: ending access failed ($e)');
    if (context.mounted) showTopSnackBar(context, accessErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  }
  if (!context.mounted) return true;
  ref.read(orchardListVersionProvider.notifier).state++;
  showTopSnackBar(context, l10n.accessEnded);
  return true;
}

/// Withdraws this account's own request. True when it is gone.
Future<bool> withdrawAccessRequest(BuildContext context, WidgetRef ref, OrchardSummary orchard, String requestId) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    await ref.read(orchardServiceProvider).withdrawAccessRequest(orchard.id, requestId);
  } catch (e) {
    AppLogger.warning('Orchards: withdrawing a request for access failed ($e)');
    if (context.mounted) showTopSnackBar(context, accessErrorMessage(e, l10n), isError: true, details: '$e');
    return false;
  }
  if (!context.mounted) return true;
  ref.read(accessRequestsVersionProvider.notifier).state++;
  showTopSnackBar(context, l10n.accessWithdrawn);
  return true;
}
