import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show revealAsksAgainNow;
import 'package:zestssh/features/orchards/move/item_transfer.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ActivityKind;
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart' show CrateSwitches;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart' show confirmItIsYou;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart' show crateDisplayName, orchardDisplayName;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';

// The one place picker (3.4, "like 1Password you quickly pick which vault, if
// you have write access"): Move to... and Copy to... for hosts, keys,
// snippets and port forwards, on one item or a selection, and the linked
// items' question, in one dialog that changes in place (the dialog rules: no
// dialog over a dialog).

/// Moves and copies items for this app: your own database, and each team's
/// as it opens on this device.
final itemTransferProvider = Provider<ItemTransfer>((ref) => ItemTransfer(
      tree: ref.watch(treeDatabaseProvider),
      openTeam: (id) => ref.read(orchardDatabasesProvider.notifier).open(id),
      storage: ref.watch(secureStorageProvider),
      // A key that leaves its team is an export of it, in the team's activity
      // (where the team records activity), as a key written to a file is.
      onKeyLeftTeam: (team, {required key, required label, crateId}) => noteActivityIn(
          ref.read(orchardServiceProvider), team, ActivityKind.export,
          itemKind: 'key', itemKey: key, name: label, crateId: crateId),
    ));

/// A place the picker lists: Personal, or a vault of a team.
@immutable
class PlaceChoice {
  const PlaceChoice({required this.place, required this.name, this.team, this.ownersOnly = false});

  final SavePlace place;

  /// The vault's name, or Personal's.
  final String name;

  /// The team's name; null for Personal.
  final String? team;
  final bool ownersOnly;

  /// As a sentence names it: "Acme / Production", or "Personal".
  String get title => team == null ? name : '$team / $name';
}

/// Every place this account can add to: Personal, then each vault of its
/// teams where its role lets it add (a team that is active, a vault open on
/// this device), teams and vaults by name. Where it may not add, a vault is
/// not listed at all.
List<PlaceChoice> savePlaces(WidgetRef ref, AppLocalizations l10n, {bool watch = true}) {
  final teams = kOrchardsEnabled
      ? (watch ? ref.watch(orchardSummariesProvider) : ref.read(orchardSummariesProvider)).valueOrNull ?? const <OrchardSummary>[]
      : const <OrchardSummary>[];
  return [
    PlaceChoice(place: const SavePlace.personal(), name: l10n.treeSelectorPersonal),
    for (final team in teams)
      if (team.active)
        for (final crate in [...team.crates]..sort((a, b) => crateDisplayName(a, l10n).toLowerCase().compareTo(crateDisplayName(b, l10n).toLowerCase())))
          if (crate.canAdd && !crate.closedOffline)
            PlaceChoice(
              place: SavePlace.vault(team.id, crate.id),
              name: crateDisplayName(crate, l10n),
              team: orchardDisplayName(team.name, l10n),
              ownersOnly: crate.ownersOnly,
            ),
  ];
}

/// Where the items [keys] of [kind] on screen are: Personal, or their vaults.
Set<SavePlace> placesOf(WidgetRef ref, String kind, Iterable<String> keys) {
  final space = ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return {const SavePlace.personal()};
  final team = ref.read(activeOrchardProvider).valueOrNull;
  final crates = ref.read(itemCratesProvider(kind)).valueOrNull ?? const {};
  return {
    for (final k in keys)
      if ((crates[k] ?? team?.defaultCrateId) case final crate?) SavePlace.vault(space.orchardId, crate),
  };
}

/// The place new items of the space on screen go to: Personal, or the vault
/// picked for new items.
SavePlace defaultSavePlace(WidgetRef ref) {
  final space = ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) return const SavePlace.personal();
  final crate = ref.read(activeOrchardProvider).valueOrNull?.defaultCrateId;
  return crate == null ? const SavePlace.personal() : SavePlace.vault(space.orchardId, crate);
}

/// What Move to... and Copy to... can offer for [keys] of [kind] on screen,
/// before anything is read: Copy where some place besides theirs takes items
/// and the items may leave for it; Move where, besides, this account may
/// delete them where they are. The dialog works out each item exactly.
({bool move, bool copy}) transferOffer(WidgetRef ref, String kind, List<String> keys) {
  if (!kOrchardsEnabled || keys.isEmpty) return (move: false, copy: false);
  final l10n = lookupAppLocalizations(const Locale('en'));
  final places = savePlaces(ref, l10n, watch: false);
  final here = placesOf(ref, kind, keys);
  final space = ref.read(activeSpaceProvider);
  if (space is! OrchardSpace) {
    final any = places.any((p) => !here.contains(p.place));
    return (move: any, copy: any);
  }
  final team = ref.read(activeOrchardProvider).valueOrNull;
  if (team == null) return (move: false, copy: false);
  final mayLeave = team.isOwner && !team.rules.noExport;
  final elsewhere = places.any((p) =>
      !(here.length == 1 && here.contains(p.place)) && (p.place.orchardId == team.id || mayLeave));
  final crates = {for (final c in team.crates) c.id: c};
  final mine = [for (final p in here) ?crates[p.crateId]];
  final reveal = kind != TransferKinds.key || mine.any((c) => c.allows(CrateSwitches.reveal));
  final copy = elsewhere && reveal && mine.any((c) => !c.closedOffline);
  return (
    move: copy && mine.any((c) => c.allows(CrateSwitches.delete) || c.allows(CrateSwitches.add)),
    copy: copy,
  );
}

/// [count] items of [kind], as a sentence counts them ("3 hosts").
String transferWhat(AppLocalizations l10n, String kind, int count) => switch (kind) {
      TransferKinds.key => l10n.transferWhatKeys(count),
      TransferKinds.snippet => l10n.transferWhatSnippets(count),
      TransferKinds.forward => l10n.transferWhatForwards(count),
      _ => l10n.transferWhatHosts(count),
    };

/// Why an item did not go, in the person's words.
String transferWhy(AppLocalizations l10n, TransferRefusal reason, {String? link}) => switch (reason) {
      TransferRefusal.alreadyThere => l10n.transferHere,
      TransferRefusal.notFound => l10n.transferWhyNotFound,
      TransferRefusal.closedOffline => l10n.transferWhyClosed,
      TransferRefusal.mayNotRemove => l10n.transferWhyMayNotRemove,
      TransferRefusal.mayNotAdd => l10n.transferWhyMayNotAdd,
      TransferRefusal.ownersOnly => l10n.transferWhyOwnersOnly,
      TransferRefusal.teamKeepsItems => l10n.transferWhyTeamKeeps,
      TransferRefusal.keySecretsHidden => l10n.transferWhySecretsHidden,
      TransferRefusal.keyBelongsToVault => l10n.transferWhyBelongsToVault,
      TransferRefusal.localShellNotInTeam => l10n.transferWhyLocalShell,
      TransferRefusal.needsItsHost => l10n.transferWhyNeedsHost,
      TransferRefusal.linkFailed => l10n.transferWhyLinkFailed(Redactable.freeText(link ?? '?').display),
      TransferRefusal.writeRefused => l10n.transferWhyRefused,
      TransferRefusal.failed => l10n.transferWhyFailed,
    };

Redactable _redactable(String kind, String label) => switch (kind) {
      TransferKinds.host => Redactable.host(label),
      TransferKinds.key => Redactable.keyName(label),
      'network' => Redactable.network(label),
      _ => Redactable.freeText(label),
    };

/// Move to... or Copy to... ([mode]) for [keys] of [kind] in the space on
/// screen: the place picker, then (where needed) what the items use that the
/// place does not have, then the doing, all in one dialog that changes in
/// place. [kept]: items the screen knows may not go (a key its vault signs
/// certificates with). [to]: the place, picked already (an editor's Move or
/// copy menu, 4.0): the dialog starts at what follows the picker, and Back
/// still goes to it. Says what was done; resolves with it, or with null
/// where nothing was (closed before).
Future<TransferResult?> showMoveCopyDialog(
  BuildContext context,
  WidgetRef ref, {
  required String kind,
  required List<String> keys,
  required TransferMode mode,
  Map<String, TransferRefusal> kept = const {},
  PlaceChoice? to,
}) async {
  if (keys.isEmpty) return null;
  final from = ref.read(activeSpaceProvider);
  final here = placesOf(ref, kind, keys);
  final outcome = await showZestModal<_Outcome>(
    context: context,
    size: ZestModalSize.compact,
    child: _TransferDialog(kind: kind, keys: keys, mode: mode, kept: kept, from: from, here: here, to: to),
  );
  if (outcome == null) return null;
  if (context.mounted && outcome.result.done > 0 && outcome.quiet) {
    final l10n = AppLocalizations.of(context)!;
    final what = transferWhat(l10n, kind, outcome.result.done);
    final place = Redactable.freeText(outcome.place.title).display;
    showTopSnackBar(
      context,
      mode == TransferMode.move ? l10n.transferMovedToast(what, place) : l10n.transferCopiedToast(what, place),
      isSuccess: true,
    );
  }
  return outcome.result;
}

/// "Save in" (3.4) for a new item an editor captured ([captureNewItem]): saves
/// it at [to], asking first, in a dialog, about what it uses that [to] does
/// not have (where it uses any). Resolves with what was done, or null where
/// the question was closed (nothing was saved).
Future<TransferResult?> saveDraftIn(
  BuildContext context,
  WidgetRef ref, {
  required ItemDraft draft,
  required SavePlace to,
}) async {
  final transfer = ref.read(itemTransferProvider);
  final plan = await transfer.planDraft(from: ref.read(activeSpaceProvider), draft: draft, to: to);
  if (plan.links.isEmpty || !context.mounted) return transfer.run(plan);
  final l10n = AppLocalizations.of(context)!;
  final place = savePlaces(ref, l10n, watch: false).where((p) => p.place == to).firstOrNull;
  final outcome = await showZestModal<_Outcome>(
    context: context,
    size: ZestModalSize.compact,
    child: _TransferDialog.planned(plan: plan, place: place ?? PlaceChoice(place: to, name: '?')),
  );
  return outcome?.result;
}

/// How the dialog closed after doing something: [quiet] where all of it
/// went (the caller says so in a line), else it was shown in the dialog.
class _Outcome {
  const _Outcome(this.result, this.place, {required this.quiet});

  final TransferResult result;
  final PlaceChoice place;
  final bool quiet;
}

enum _Step { pick, planning, review, working, result }

class _TransferDialog extends ConsumerStatefulWidget {
  const _TransferDialog({
    required this.kind,
    required this.keys,
    required this.mode,
    required this.kept,
    required this.from,
    required this.here,
    this.to,
  })  : planned = null,
        place = null;

  /// The links question alone, for a plan already made ("Save in").
  _TransferDialog.planned({required TransferPlan plan, required PlaceChoice this.place})
      : planned = plan,
        kind = plan.kind,
        keys = const [],
        mode = plan.mode,
        kept = const {},
        from = plan.from,
        here = const {},
        to = null;

  final String kind;
  final List<String> keys;
  final TransferMode mode;
  final Map<String, TransferRefusal> kept;
  final Space from;
  final Set<SavePlace> here;
  final TransferPlan? planned;
  final PlaceChoice? place;

  /// The place picked before the dialog opened, if one was.
  final PlaceChoice? to;

  @override
  ConsumerState<_TransferDialog> createState() => _TransferDialogState();
}

class _TransferDialogState extends ConsumerState<_TransferDialog> {
  late _Step _step = widget.planned == null ? _Step.pick : _Step.review;
  String _query = '';
  late PlaceChoice? _place = widget.place;
  late TransferPlan? _plan = widget.planned;
  final _choices = <LinkRef, LinkChoice>{};
  TransferResult? _result;
  bool _failedToPlan = false;

  bool get _draft => widget.planned != null;
  bool get _move => widget.mode == TransferMode.move;

  @override
  void initState() {
    super.initState();
    // A place picked already: planned at once, as a pick in the list is.
    final to = widget.to;
    if (to != null && widget.planned == null) {
      _place = to;
      _step = _Step.planning;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _pick(to);
      });
    }
  }

  Future<void> _pick(PlaceChoice choice) async {
    setState(() {
      _place = choice;
      _step = _Step.planning;
      _failedToPlan = false;
    });
    TransferPlan plan;
    try {
      plan = await ref.read(itemTransferProvider).plan(
            from: widget.from,
            kind: widget.kind,
            keys: widget.keys,
            to: choice.place,
            mode: widget.mode,
            kept: widget.kept,
          );
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _step = _Step.pick;
        _failedToPlan = true;
      });
      return;
    }
    if (!mounted) return;
    _plan = plan;
    _choices.clear();
    if (plan.links.isEmpty && plan.problems.isEmpty && plan.leftBehind == 0) {
      await _run();
    } else {
      setState(() => _step = _Step.review);
    }
  }

  Future<void> _run() async {
    final plan = _plan;
    if (plan == null) return;
    // A key whose vault asks again before its secrets leave the device asks
    // here, before any of it goes.
    if (plan.from is OrchardSpace && !await _keysMayGo(plan)) {
      if (mounted) setState(() => _step = _Step.review);
      return;
    }
    if (!mounted) return;
    setState(() => _step = _Step.working);
    final result = await ref.read(itemTransferProvider).run(plan, choices: {
      for (final l in plan.links) l.ref: _choices[l.ref] ?? l.suggested,
    });
    if (!mounted) return;
    final quiet = result.failed.isEmpty && result.copiedInstead.isEmpty;
    if (quiet) {
      Navigator.of(context).pop(_Outcome(result, _place!, quiet: true));
      return;
    }
    setState(() {
      _result = result;
      _step = _Step.result;
    });
  }

  /// Whether the keys that leave their vault may: where a vault asks again
  /// before its secrets are shown or leave the device, the person confirms it
  /// is them first.
  Future<bool> _keysMayGo(TransferPlan plan) async {
    final keys = [
      if (plan.kind == TransferKinds.key) ...plan.readyKeys,
      for (final l in plan.links)
        if (l.ref.kind == LinkKind.key && (_choices[l.ref] ?? l.suggested) != LinkChoice.leave) l.ref.key,
    ];
    var asks = false;
    for (final k in keys) {
      if (await revealAsksAgainNow(ref, k)) asks = true;
    }
    if (!asks || !mounted) return mounted;
    return confirmItIsYou(context, ref);
  }

  void _close() => Navigator.of(context).pop(
        _result == null ? null : _Outcome(_result!, _place!, quiet: false),
      );

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return switch (_step) {
      _Step.pick || _Step.planning => _pickShell(l10n),
      _Step.review || _Step.working => _reviewShell(l10n),
      _Step.result => _resultShell(l10n),
    };
  }

  // ── Where to ────────────────────────────────────────────────────────────

  Widget _pickShell(AppLocalizations l10n) {
    final what = transferWhat(l10n, widget.kind, widget.keys.length);
    final places = savePlaces(ref, l10n);
    final q = _query.trim().toLowerCase();
    final shown = [
      for (final p in places)
        if (q.isEmpty || p.title.toLowerCase().contains(q)) p,
    ];
    final busy = _step == _Step.planning;
    // The place every item is in already: shown, not offered.
    final here = widget.here.length == 1 ? widget.here.single : null;
    final any = places.any((p) => p.place != here);
    String? lastTeam;
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: _move ? LucideIcons.folderInput : LucideIcons.copyPlus,
      title: _move ? l10n.transferMoveTitle(what) : l10n.transferCopyTitle(what),
      subtitle: l10n.transferPickSubtitle,
      maxWidth: 480,
      maxHeight: 620,
      bodyKey: const ValueKey('transfer-pick'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const Padding(padding: EdgeInsets.only(bottom: 10), child: LinearProgressIndicator(minHeight: 2)),
          if (_failedToPlan) ...[
            ZestCallout(l10n.transferWhyFailed),
            const SizedBox(height: 10),
          ],
          // A search where there are more places than a glance takes in.
          if (places.length > 7) ...[
            TextField(
              key: const ValueKey('transfer-search'),
              autofocus: true,
              onChanged: (v) => setState(() => _query = v),
              style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
              decoration: InputDecoration(
                isDense: true,
                hintText: l10n.transferSearch,
                prefixIcon: Icon(LucideIcons.search, size: 15, color: AppColors.v3TextTertiary),
                border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
              ),
            ),
            const SizedBox(height: 10),
          ],
          if (!any)
            Text(l10n.transferNoPlaces,
                style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary)),
          for (final p in shown) ...[
            if (p.team != null && p.team != lastTeam) _TeamHeader((lastTeam = p.team)!),
            _PlaceRow(
              key: ValueKey('transfer-place-${p.place.orchardId ?? 'personal'}-${p.place.crateId ?? ''}'),
              choice: p,
              here: p.place == here,
              hereLabel: l10n.transferHere,
              onTap: busy || p.place == here ? null : () => _pick(p),
            ),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: busy ? null : () => Navigator.of(context).pop()),
    );
  }

  // ── What they use, and what cannot go ───────────────────────────────────

  Widget _reviewShell(AppLocalizations l10n) {
    final plan = _plan!;
    final place = _place!;
    final what = transferWhat(l10n, plan.kind, plan.readyCount);
    final placeName = Redactable.freeText(place.title).display;
    final busy = _step == _Step.working;
    final problems = plan.problems;
    final bodyStyle = TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary);
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: _draft ? LucideIcons.link : (_move ? LucideIcons.folderInput : LucideIcons.copyPlus),
      title: _draft
          ? l10n.transferSaveInTitle(placeName)
          : (_move ? l10n.transferReviewMove(what, placeName) : l10n.transferReviewCopy(what, placeName)),
      maxWidth: 520,
      maxHeight: 660,
      bodyKey: const ValueKey('transfer-review'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (busy) const Padding(padding: EdgeInsets.only(bottom: 10), child: LinearProgressIndicator(minHeight: 2)),
          if (plan.links.isNotEmpty) ...[
            Text(l10n.transferLinksIntro(placeName), style: bodyStyle),
            const SizedBox(height: 10),
            for (final link in plan.links)
              _LinkRow(
                key: ValueKey('transfer-link-${link.ref.kind.name}-${link.ref.key}'),
                link: link,
                choice: _choices[link.ref] ?? link.suggested,
                enabled: !busy,
                onChanged: (c) => setState(() => _choices[link.ref] = c),
              ),
            const SizedBox(height: 4),
            Text(l10n.transferLeaveSays, style: bodyStyle.copyWith(fontSize: 12, color: AppColors.v3TextTertiary)),
          ],
          if (plan.leftBehind > 0) ...[
            const SizedBox(height: 12),
            ZestCallout(l10n.transferLeftBehind(plan.leftBehind)),
          ],
          if (problems.isNotEmpty) ...[
            const SizedBox(height: 12),
            _ProblemList(
              key: const ValueKey('transfer-problems'),
              title: l10n.transferCannotGo(problems.length),
              problems: problems,
            ),
          ],
        ],
      ),
      tertiaryAction: _draft || busy ? null : (label: l10n.back, onPressed: () => setState(() => _step = _Step.pick)),
      secondaryAction: (label: l10n.cancel, onPressed: busy ? null : () => Navigator.of(context).pop()),
      primaryAction: (
        label: _draft ? l10n.save : (_move ? l10n.transferMoveButton(what) : l10n.transferCopyButton(what)),
        icon: null,
        onPressed: busy || plan.readyCount == 0 ? null : _run,
      ),
      primaryKey: const ValueKey('transfer-go'),
    );
  }

  // ── How it went, where not all of it did ───────────────────────────────

  Widget _resultShell(AppLocalizations l10n) {
    final result = _result!;
    final plan = _plan!;
    final total = result.done + result.failed.length;
    final bodyStyle = TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary);
    return ZestDialogShell(
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.info,
      title: _draft
          ? l10n.transferWhyFailed
          : (_move ? l10n.transferMovedSome(result.done, total) : l10n.transferCopiedSome(result.done, total)),
      maxWidth: 520,
      maxHeight: 620,
      bodyKey: const ValueKey('transfer-result'),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (result.failed.isNotEmpty) _ProblemList(title: l10n.transferStayed, problems: result.failed),
          if (result.copiedInstead.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text(
              l10n.transferCopiedInstead(result.copiedInstead.map((n) => Redactable.freeText(n).display).join(', ')),
              style: bodyStyle,
            ),
          ],
          if (plan.kind == TransferKinds.forward && result.failed.any((f) => f.reason == TransferRefusal.needsItsHost)) ...[
            const SizedBox(height: 12),
            Text(l10n.transferLinkForForward, style: bodyStyle),
          ],
        ],
      ),
      primaryAction: (label: l10n.done, icon: null, onPressed: _close),
      primaryKey: const ValueKey('transfer-done'),
      onClose: _close,
    );
  }
}

class _TeamHeader extends StatelessWidget {
  const _TeamHeader(this.name);

  final String name;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 4),
        child: Row(
          children: [
            Icon(LucideIcons.users, size: 13, color: AppColors.v3TextTertiary),
            const SizedBox(width: 6),
            Expanded(
              child: RedactedText(
                Redactable.freeText(name),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                    fontSize: 11.5, fontWeight: FontWeight.w600, letterSpacing: 0.3, color: AppColors.v3TextTertiary),
              ),
            ),
          ],
        ),
      );
}

class _PlaceRow extends StatefulWidget {
  const _PlaceRow({super.key, required this.choice, required this.here, required this.hereLabel, required this.onTap});

  final PlaceChoice choice;
  final bool here;
  final String hereLabel;
  final VoidCallback? onTap;

  @override
  State<_PlaceRow> createState() => _PlaceRowState();
}

class _PlaceRowState extends State<_PlaceRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final c = widget.choice;
    final enabled = widget.onTap != null;
    final fg = widget.here ? AppColors.v3TextTertiary : AppColors.v3TextPrimary;
    final icon = c.team == null ? LucideIcons.user : (c.ownersOnly ? LucideIcons.lock : LucideIcons.package);
    return MouseRegion(
      cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Semantics(
        button: true,
        enabled: enabled,
        child: GestureDetector(
          onTap: widget.onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            constraints: const BoxConstraints(minHeight: 40),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: _hover && enabled ? AppColors.v3TextPrimary.withValues(alpha: 0.05) : Colors.transparent,
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(icon, size: 15, color: widget.here ? AppColors.v3TextTertiary : AppColors.v3TextSecondary),
                const SizedBox(width: 10),
                Expanded(
                  child: RedactedText(
                    Redactable.freeText(c.name),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, color: fg),
                  ),
                ),
                if (widget.here)
                  Text(widget.hereLabel, style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary))
                else
                  Icon(LucideIcons.chevronRight, size: 14, color: AppColors.v3TextTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// One linked item and what to do with it: Move it too, Copy it, Leave it.
class _LinkRow extends StatelessWidget {
  const _LinkRow({super.key, required this.link, required this.choice, required this.enabled, required this.onChanged});

  final TransferLink link;
  final LinkChoice choice;
  final bool enabled;
  final ValueChanged<LinkChoice> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final (icon, kindName, kind) = switch (link.ref.kind) {
      LinkKind.key => (LucideIcons.key, l10n.transferLinkKey, TransferKinds.key),
      LinkKind.host => (LucideIcons.server, l10n.transferLinkHost, TransferKinds.host),
      LinkKind.network => (LucideIcons.wifi, l10n.transferLinkNetwork, 'network'),
      LinkKind.snippet => (LucideIcons.code, l10n.transferLinkSnippet, TransferKinds.snippet),
    };
    final notes = [
      if (link.usedElsewhere > 0) l10n.transferLinkUsedElsewhere(link.usedElsewhere),
      if (link.neededByForward) l10n.transferLinkForForward,
      if (link.refusal != null) transferWhy(l10n, link.refusal!),
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: Container(
        padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Icon(icon, size: 15, color: AppColors.v3TextSecondary),
                const SizedBox(width: 8),
                Text(kindName, style: TextStyle(fontSize: 12, color: AppColors.v3TextTertiary)),
                const SizedBox(width: 8),
                Expanded(
                  child: RedactedText(
                    _redactable(kind, link.label),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary),
                  ),
                ),
              ],
            ),
            for (final n in notes)
              Padding(
                padding: const EdgeInsets.only(top: 4, left: 23),
                child: Text(n, style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.v3TextTertiary)),
              ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final (c, label) in [
                  (LinkChoice.move, l10n.transferLinkMove),
                  (LinkChoice.copy, l10n.transferLinkCopy),
                  (LinkChoice.leave, l10n.transferLinkLeave),
                ])
                  _ChoiceChip(
                    key: ValueKey('transfer-link-${link.ref.kind.name}-${link.ref.key}-${c.name}'),
                    label: label,
                    selected: choice == c,
                    onTap: enabled && link.choices.contains(c) ? () => onChanged(c) : null,
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _ChoiceChip extends StatelessWidget {
  const _ChoiceChip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final enabled = onTap != null;
    final accent = AppColors.v3AccentPrimary;
    return Semantics(
      button: true,
      selected: selected,
      enabled: enabled,
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 6),
            decoration: BoxDecoration(
              color: selected ? accent.withValues(alpha: 0.12) : Colors.transparent,
              borderRadius: BorderRadius.circular(7),
              border: Border.all(color: selected ? accent.withValues(alpha: 0.6) : AppColors.v3BorderSubtle),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (selected) ...[
                  Icon(LucideIcons.check, size: 13, color: AppColors.v3TextPrimary),
                  const SizedBox(width: 5),
                ],
                Text(
                  label,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                    color: enabled ? AppColors.v3TextPrimary : AppColors.v3TextTertiary.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// What did not go, or cannot, each with why.
class _ProblemList extends StatelessWidget {
  const _ProblemList({super.key, required this.title, required this.problems});

  final String title;
  final List<TransferProblem> problems;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(title, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
        const SizedBox(height: 6),
        for (final p in problems)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.only(top: 2),
                  child: Icon(LucideIcons.minusCircle, size: 13, color: AppColors.v3TextTertiary),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(_redactable(p.kind, p.label), style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary)),
                      Text(
                        transferWhy(l10n, p.reason, link: p.link),
                        style: TextStyle(fontSize: 12, height: 1.35, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
