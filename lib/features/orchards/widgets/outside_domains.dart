import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show FixedRoles, RecordRules;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart' show addressDomain;
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart' show accessThrough, endOfDay, pickAccessEnd;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/utils/logger.dart';

// Members outside a team's address domains (people already in
// the team whose address is not in those domains). Left as they
// are they stay in the team, held back; with an end date they are let in until
// it passes, whoever gave it. An owner sees who, what happens, and decides for
// each: keep them as guests, with the date they have or another, remove them,
// or leave them held back; or not change the domains at all. Before saving a
// list of domains, and from Members for a list that stands.

/// What is to become of one member outside the domains.
enum OutsideChoice { guest, remove, hold }

/// What an owner decided.
sealed class OutsideAnswer {
  const OutsideAnswer();
}

/// Not to change the domains after all.
class OutsideKeepDomains extends OutsideAnswer {
  const OutsideKeepDomains();
}

/// Go on.
class OutsideDecided extends OutsideAnswer {
  const OutsideDecided({
    this.guests = const {},
    this.remove = const {},
    this.clear = const {},
    this.held = 0,
    this.stays = const {},
  });

  /// The end dates to write: given or moved, or kept where no owner gave them,
  /// so that an owner has now.
  final Map<String, int> guests;
  final Set<String> remove;

  /// Those whose end date goes, and with it what let them in.
  final Set<String> clear;

  /// How many are left held back, those in [clear] too.
  final int held;

  /// Everyone who stays as a guest and until when, written or not: for what
  /// "Confirm it's you" says.
  final Map<String, int> stays;

  bool get changesMembers => guests.isNotEmpty || remove.isNotEmpty || clear.isNotEmpty;
}

/// [domains] as a sentence names them: the first few, masked in recording mode.
String outsideDomainsWords(Set<String> domains, WidgetRef ref, AppLocalizations l10n) {
  final sorted = domains.toList()..sort();
  const shown = 3;
  return [
    for (final d in sorted.take(shown)) Redactable.host(d).displayIn(ref),
    if (sorted.length > shown) l10n.orchardRulesOutsideMore(sorted.length - shown),
  ].join(', ');
}

/// [people] as a line names them: the first few addresses, masked in recording
/// mode.
String outsidePeopleWords(List<OrchardPerson> people, WidgetRef ref, AppLocalizations l10n) {
  const shown = 3;
  return [
    for (final p in people.take(shown)) Redactable.account(p.email ?? p.name ?? p.uid).displayIn(ref),
    if (people.length > shown) l10n.orchardRulesOutsideMore(people.length - shown),
  ].join(', ');
}

/// Asks what is to become of [outside] under [domains]. [beforeSaving]: the
/// domains are not saved yet, and Do not change the domains is the way out; else
/// they stand, and [onChangeDomains] goes where they are changed. [proven]: the
/// domains the team proved, as far as they could be read: someone outside them
/// keeps an end date, so holding them back is not offered. Null where the person
/// went back.
Future<OutsideAnswer?> showOutsideDomains(
  BuildContext context, {
  required Set<String> domains,
  required OutsideDomains outside,
  required bool beforeSaving,
  Set<String> proven = const {},
  VoidCallback? onChangeDomains,
}) =>
    showZestModal<OutsideAnswer>(
      context: context,
      size: ZestModalSize.standard,
      barrierDismissible: false,
      child: OutsideDomainsDialog(
        domains: domains,
        outside: outside,
        beforeSaving: beforeSaving,
        proven: proven,
        onChangeDomains: onChangeDomains,
      ),
    );

/// Makes what was [decided] so for [orchard], with [rules] where they go with
/// it: a recent sign-in first where the server wants one ([withRecentSignIn]),
/// then new keys for what the people removed held, and the keys they could use
/// kept as those to change next. False where the person backed out. What stops
/// it is thrown: with nothing changed, or [OutsideSettleStopped] with how far it
/// came, once what the removals so far call for is done.
Future<bool> applyOutsideDomains(
  BuildContext context,
  WidgetRef ref,
  OrchardSummary orchard,
  OutsideDecided decided, {
  required OrchardPeople people,
  RecordRules? rules,
  required StepUpSummary summary,
}) async {
  final service = ref.read(orchardServiceProvider);
  final version = ref.read(orchardListVersionProvider.notifier);
  // What they could use, from the record as it stands before.
  final before = <String, OrchardExposure>{};
  for (final uid in decided.remove) {
    try {
      before[uid] = await service.exposure(orchard.id, uid, asOf: people.record);
    } catch (e) {
      AppLogger.warning('Team members: what they could use was not worked out ($e)');
    }
  }
  if (!context.mounted) return false;
  OutsideSettleStopped? stopped;
  final done = await withRecentSignIn(
    context,
    ref,
    () async {
      try {
        await service.settleOutsideDomains(orchard.id,
            rules: rules, guests: decided.guests, clear: decided.clear, remove: decided.remove);
      } on OutsideSettleStopped catch (e) {
        stopped = e;
      }
    },
    summary: summary,
  );
  if (!done) return false;
  final gone = stopped?.removed ?? decided.remove;
  if (gone.isNotEmpty) {
    // What they could use is kept here first: it needs no server, and what
    // stopped the removals may well stop the new keys.
    for (final e in before.entries) {
      if (!gone.contains(e.key)) continue;
      try {
        await service.keepChangeNext(orchard.id, e.key, e.value);
      } catch (e) {
        AppLogger.warning('Team members: the keys to change next were not kept ($e)');
      }
    }
    try {
      if (await service.keysWaiting(orchard.id)) await service.rotateDue(orchard.id);
    } catch (e) {
      // What the record says stands: the keys wait, and the Overview says so.
      AppLogger.warning('Team members: new keys after a removal not made yet ($e)');
    }
  }
  version.state++;
  final left = stopped;
  if (left != null) throw left;
  return true;
}

/// What [decided] does, for "Confirm it's you".
List<String> outsideEffects(OutsideDecided decided, BuildContext context, AppLocalizations l10n) {
  final byEnd = <int, int>{};
  for (final end in decided.stays.values) {
    byEnd[end] = (byEnd[end] ?? 0) + 1;
  }
  return [
    for (final e in byEnd.entries) l10n.orchardOutsideEffectGuests(e.value, accessThrough(e.key, context)),
    if (decided.remove.isNotEmpty) l10n.orchardOutsideEffectRemoved(decided.remove.length),
    if (decided.held > 0) l10n.orchardOutsideEffectHeld(decided.held),
  ];
}

class OutsideDomainsDialog extends ConsumerStatefulWidget {
  const OutsideDomainsDialog({
    super.key,
    required this.domains,
    required this.outside,
    required this.beforeSaving,
    this.proven = const {},
    this.onChangeDomains,
  });

  final Set<String> domains;
  final OutsideDomains outside;
  final bool beforeSaving;
  final Set<String> proven;
  final VoidCallback? onChangeDomains;

  @override
  ConsumerState<OutsideDomainsDialog> createState() => _OutsideDomainsDialogState();
}

class _OutsideDomainsDialogState extends ConsumerState<OutsideDomainsDialog> {
  late final List<OrchardPerson> _people = [
    ...widget.outside.held,
    ...widget.outside.unknown,
    ...widget.outside.guests,
  ];

  /// Each member's choice: where they stand now, until the person says.
  late final Map<String, OutsideChoice> _choices = {
    for (final p in _people) p.uid: p.endsAt == null ? OutsideChoice.hold : OutsideChoice.guest,
  };

  /// When the access of those who have no end date yet ends, if they are kept:
  /// thirty days on, until the person says.
  late int _until = endOfDay(DateTime.now().add(const Duration(days: 30)));

  /// The end date of each who has one, as the person leaves it.
  late final Map<String, int> _dates = {
    for (final p in widget.outside.guests)
      if (p.endsAt != null) p.uid: p.endsAt!,
  };

  /// What [p] may be, as this account may change them: an owner of the team
  /// can be neither guest nor removed here, and someone with an end date who is
  /// outside the proven domains keeps one.
  List<OutsideChoice> _choicesOf(OrchardPerson p) => [
        if (p.actions.endDate) OutsideChoice.guest,
        if (p.actions.remove) OutsideChoice.remove,
        if (p.endsAt == null ||
            (p.actions.endDate && (widget.proven.isEmpty || widget.proven.contains(addressDomain(p.email)))))
          OutsideChoice.hold,
      ];

  void _setAll(OutsideChoice choice) => setState(() {
        for (final p in _people) {
          if (_choicesOf(p).contains(choice)) _choices[p.uid] = choice;
        }
      });

  /// Someone with no end date yet is kept as a guest: they get [_until].
  bool get _anyNewGuest => _people.any((p) => p.endsAt == null && _choices[p.uid] == OutsideChoice.guest);

  bool get _anyGuest => _choices.values.contains(OutsideChoice.guest);

  /// Whether going on writes anything: a date no owner gave, kept, counts.
  bool get _anyChange => _decided().changesMembers;

  OutsideDecided _decided() {
    final guests = <String, int>{};
    final stays = <String, int>{};
    final remove = <String>{};
    final clear = <String>{};
    var held = 0;
    for (final p in _people) {
      switch (_choices[p.uid]!) {
        case OutsideChoice.guest:
          final end = _dates[p.uid] ?? _until;
          stays[p.uid] = end;
          if (end != p.endsAt || !p.endChosenByOwner) guests[p.uid] = end;
        case OutsideChoice.remove:
          remove.add(p.uid);
        case OutsideChoice.hold:
          held++;
          if (p.endsAt != null) clear.add(p.uid);
      }
    }
    return OutsideDecided(guests: guests, remove: remove, clear: clear, held: held, stays: stays);
  }

  Future<void> _pickUntil(AppLocalizations l10n) async {
    final picked = await pickAccessEnd(context, title: l10n.orchardOutsideEndTitle, current: _until, requireEnd: true);
    final at = picked?.endsAt;
    if (at != null && mounted) setState(() => _until = at);
  }

  Future<void> _pickDate(OrchardPerson p, AppLocalizations l10n) async {
    final picked = await pickAccessEnd(context, title: l10n.orchardOutsideEndTitle, current: _dates[p.uid], requireEnd: true);
    final at = picked?.endsAt;
    if (at != null && mounted) setState(() => _dates[p.uid] = at);
  }

  Future<void> _go(AppLocalizations l10n) async {
    final decided = _decided();
    // Removing people asks, as for one person (Members), and says who.
    if (decided.remove.isNotEmpty) {
      final who = [
        for (final p in _people)
          if (decided.remove.contains(p.uid)) p,
      ];
      final sure = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: l10n.orchardOutsideRemoveTitle(who.length),
        body: '${outsidePeopleWords(who, ref, l10n)}. ${l10n.orchardRemoveBody}',
        confirmLabel: l10n.orchardRemoveConfirm,
      );
      if (sure != true || !mounted) return;
    }
    Navigator.of(context).pop(decided);
  }

  String _choiceWord(OutsideChoice c, AppLocalizations l10n) => switch (c) {
        OutsideChoice.guest => l10n.orchardOutsideKeepGuest,
        OutsideChoice.remove => l10n.orchardOutsideRemove,
        OutsideChoice.hold => l10n.orchardOutsideHold,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final body = TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary);
    final outside = widget.outside;
    return ZestDialogShell(
      size: ZestModalSize.standard,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.atSign,
      title: l10n.orchardOutsideTitle(_people.length, outsideDomainsWords(widget.domains, ref, l10n)),
      body: Column(
        key: const ValueKey('outside-domains'),
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (outside.held.isNotEmpty || outside.unknown.isNotEmpty)
            Text(l10n.orchardRulesOutsideBody, key: const ValueKey('outside-happens'), style: body),
          if (outside.guests.isNotEmpty) ...[
            if (outside.held.isNotEmpty || outside.unknown.isNotEmpty) const SizedBox(height: 6),
            Text(l10n.orchardOutsideGuestsBody, key: const ValueKey('outside-guests-body'), style: body),
          ],
          const SizedBox(height: 12),
          if (_people.length > 1) ...[
            Wrap(
              key: const ValueKey('outside-all'),
              spacing: 4,
              runSpacing: 2,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: [
                Text(l10n.orchardOutsideAll, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary)),
                for (final c in OutsideChoice.values)
                  TextButton(
                    key: ValueKey('outside-all-${c.name}'),
                    onPressed: () => _setAll(c),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      minimumSize: const Size(0, 26),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: Text(_choiceWord(c, l10n), style: const TextStyle(fontSize: 12.5)),
                  ),
              ],
            ),
            const SizedBox(height: 6),
          ],
          for (final p in _people)
            _OutsideRow(
              key: ValueKey('outside-${p.uid}'),
              person: p,
              choice: _choices[p.uid]!,
              choices: _choicesOf(p),
              wordOf: (c) => _choiceWord(c, l10n),
              onChanged: (c) => setState(() => _choices[p.uid] = c),
              date: _dates[p.uid],
              onChangeDate: () => _pickDate(p, l10n),
            ),
          if (_anyNewGuest) ...[
            const SizedBox(height: 10),
            Container(
              key: const ValueKey('outside-until'),
              padding: const EdgeInsetsDirectional.fromSTEB(12, 8, 8, 8),
              decoration: BoxDecoration(
                color: ZestTokens.surfaceRaisedAlt,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: ZestTokens.borderSubtle),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Wrap(
                    spacing: 10,
                    runSpacing: 4,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    alignment: WrapAlignment.spaceBetween,
                    children: [
                      Text(l10n.orchardOutsideGuestsUntil(accessThrough(_until, context)),
                          key: const ValueKey('outside-until-date'),
                          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      TextButton.icon(
                        key: const ValueKey('outside-until-change'),
                        onPressed: () => _pickUntil(l10n),
                        icon: const Icon(LucideIcons.calendar, size: 14),
                        label: Text(l10n.orchardOutsideGuestsChange, style: const TextStyle(fontSize: 12.5)),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(l10n.orchardOutsideGuestNote, style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
                ],
              ),
            ),
          ] else if (_anyGuest) ...[
            const SizedBox(height: 10),
            Text(l10n.orchardOutsideGuestNote,
                key: const ValueKey('outside-guest-note'), style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
          ],
        ],
      ),
      primaryKey: const ValueKey('outside-go'),
      primaryAction: (
        label: widget.beforeSaving ? l10n.orchardRulesSave : l10n.orchardOutsideApply,
        icon: LucideIcons.check,
        onPressed: widget.beforeSaving || _anyChange ? () => _go(l10n) : null,
      ),
      secondaryKey: const ValueKey('outside-no-change'),
      secondaryAction: widget.beforeSaving
          ? (label: l10n.orchardOutsideNoChange, onPressed: () => Navigator.of(context).pop(const OutsideKeepDomains()))
          : (label: l10n.cancel, onPressed: () => Navigator.of(context).pop()),
      tertiaryKey: const ValueKey('outside-back'),
      tertiaryAction: widget.beforeSaving
          ? (label: l10n.orchardRulesKeepEditing, onPressed: () => Navigator.of(context).pop())
          : widget.onChangeDomains == null
              ? null
              : (
                  label: l10n.orchardOutsideChangeDomains,
                  onPressed: () {
                    Navigator.of(context).pop();
                    widget.onChangeDomains!();
                  },
                ),
    );
  }
}

/// One member outside the domains: their address, when their access ends where
/// it does, and what is to become of them; an owner, for whom nothing can be
/// chosen, says so.
class _OutsideRow extends ConsumerWidget {
  const _OutsideRow({
    super.key,
    required this.person,
    required this.choice,
    required this.choices,
    required this.wordOf,
    required this.onChanged,
    this.date,
    required this.onChangeDate,
  });

  final OrchardPerson person;
  final OutsideChoice choice;
  final List<OutsideChoice> choices;
  final String Function(OutsideChoice) wordOf;
  final ValueChanged<OutsideChoice> onChanged;

  /// Their end date, as the person leaves it; null for none.
  final int? date;
  final VoidCallback onChangeDate;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final small = TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary);
    final ends = date;
    final who = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        RedactedText(
          Redactable.account(person.email ?? person.name ?? person.uid),
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary),
        ),
        if (person.email == null)
          Text(l10n.orchardOutsideAddressUnknown, key: ValueKey('outside-unknown-${person.uid}'), style: small),
        if (ends != null)
          Wrap(
            spacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: [
              Text(l10n.orchardMemberEndsOn(accessThrough(ends, context)),
                  key: ValueKey('outside-ends-${person.uid}'), style: small),
              if (choice == OutsideChoice.guest)
                TextButton(
                  key: ValueKey('outside-date-${person.uid}'),
                  onPressed: onChangeDate,
                  style: TextButton.styleFrom(
                    padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                    minimumSize: const Size(0, 24),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  child: Text(l10n.orchardOutsideGuestsChange, style: const TextStyle(fontSize: 12)),
                ),
            ],
          ),
      ],
    );
    final owner = person.role == FixedRoles.owner;
    return Container(
      padding: const EdgeInsetsDirectional.fromSTEB(12, 6, 8, 6),
      margin: const EdgeInsets.only(bottom: 6),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: LayoutBuilder(builder: (context, box) {
        final select = owner || choices.length < 2
            ? Text(l10n.orchardOutsideOwner, key: ValueKey('outside-fixed-${person.uid}'), style: small)
            : ZestSelect<OutsideChoice>(
                key: ValueKey('outside-choice-${person.uid}'),
                value: choice,
                onChanged: onChanged,
                items: [for (final c in choices) ZestSelectItem(c, wordOf(c))],
              );
        // Under the address where the two do not fit side by side.
        if (box.maxWidth < 440) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [who, const SizedBox(height: 6), select],
          );
        }
        return Row(
          children: [
            Expanded(child: who),
            const SizedBox(width: 12),
            SizedBox(width: 208, child: select),
          ],
        );
      }),
    );
  }
}
