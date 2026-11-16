import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/features/orchards/members/member_directory.dart';
import 'package:zestssh/features/orchards/members/vault_access.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show newRecordKindsOn;
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/team/team_providers.dart'
    show teamMemberPanelProvider, teamReviewPanelProvider, teamReviewToOpenProvider;
import 'package:zestssh/features/orchards/rules/orchard_rules.dart' show addressDomain, domainRuleHolds;
import 'package:zestssh/features/orchards/widgets/outside_domains.dart';
import 'package:zestssh/features/orchards/widgets/fingerprint_view.dart';
import 'package:zestssh/features/orchards/widgets/join_review.dart' show InviteView, JoinReviewPanel, WaitingBanner, teamInvitesProvider;
import 'package:zestssh/features/orchards/widgets/member_devices_view.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/member_vault_access.dart';
import 'package:zestssh/features/orchards/widgets/orchard_exposure.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/orchard_roles.dart' show confirmNewRecordKinds;
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';
import 'package:zestssh/features/orchards/widgets/team_delete_dialog.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/settings_providers.dart' show recordingModeProvider;
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/utils/platform_utils.dart';

/// An Orchard's members (3.0): each one's role and standing
/// from the Orchard's record, how far this device trusts their keys, and
/// what this account may change about them; this account's own fingerprint
/// to read out, stepping down and leaving; for those who may invite, the
/// invitations too. Suspending or removing someone asks for a recent
/// sign-in and then lists what they could use.
Future<void> showOrchardMembers(BuildContext context, WidgetRef ref, String orchardId) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.users,
    title: l10n.orchardMembers,
    body: OrchardMembersView(orchardId: orchardId),
    primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
  );
}

class OrchardMembersView extends ConsumerStatefulWidget {
  const OrchardMembersView({
    super.key,
    required this.orchardId,
    this.onLeft,
    this.onOpenRules,
    this.inviteInHeader = false,
    this.pageLayout = false,
  });

  final String orchardId;

  /// The page around it has the Invite button (the Team page's header).
  final bool inviteInHeader;

  /// The Team page's layout (3.0): the list scrolls on its own,
  /// and a click opens the member's panel beside it (their role, access end,
  /// Crate access, verification and what may change). The dialog keeps the
  /// one column.
  final bool pageLayout;

  /// After this account leaves the Orchard. Null closes the dialog it sits
  /// in; the Team page moves on (the Orchard is gone).
  final VoidCallback? onLeft;

  /// Opens the Rules page (to change the address domains); null where there
  /// is none to open.
  final VoidCallback? onOpenRules;

  @override
  ConsumerState<OrchardMembersView> createState() => _OrchardMembersViewState();
}

enum _Act { check, role, vaults, endDate, owner, suspend, resume, remove, exposure, devices, stepDown, leave }

class _OrchardMembersViewState extends ConsumerState<OrchardMembersView> {
  OrchardPeople? _people;

  /// Why nothing could be shown (no members on this device, and none read).
  ({Object error, StackTrace stack})? _failed;

  /// Why what is shown is this device's and not brought up to date (the
  /// refresh failed; the members are read from the record here).
  ({Object error, StackTrace stack})? _stale;

  /// A load is on its way (Retry waits for it): the first from the start.
  bool _loading = true;
  String? _busyUid;

  /// The Members page's filter (page layout), and whether it shows only
  /// those waiting to join.
  final _filter = TextEditingController();
  bool _waitingOnly = false;

  /// Moves on whenever the members are read again or a change starts or
  /// ends: what is open over the list (Vault access, on a phone) is built
  /// from them again.
  final _revision = ValueNotifier<int>(0);

  @override
  void dispose() {
    _filter.dispose();
    _revision.dispose();
    super.dispose();
  }

  /// The member open in the panel (page layout), kept where the Team page's
  /// header reads it.
  set _selectedUid(String? uid) => ref.read(teamMemberPanelProvider(widget.orchardId).notifier).state = uid;

  @override
  void initState() {
    super.initState();
    _load(refresh: true);
  }

  /// Reads the members, with [refresh] after bringing the team up to date
  /// first. A refresh that fails is no reason to show nothing: the members
  /// are read from the record on this device, with a notice that they are
  /// not up to date ([_stale]). Only when there is nothing here either is
  /// the page the error alone ([_failed]).
  Future<void> _load({required bool refresh}) async {
    final service = ref.read(orchardServiceProvider);
    if (!_loading && mounted) setState(() => _loading = true);
    ({Object error, StackTrace stack})? stale;
    if (refresh) {
      try {
        await service.refresh();
      } catch (e, st) {
        AppLogger.warning('Orchard members: the team could not be brought up to date ($e)');
        stale = (error: e, stack: st);
      }
    }
    try {
      final people = await service.people(widget.orchardId);
      if (!mounted) return;
      _revision.value++;
      setState(() {
        if (stale != null && people.record.seq == 0) {
          // Nothing on this device to show in its place.
          _people = null;
          _failed = stale;
          _stale = null;
        } else {
          _people = people;
          _failed = null;
          if (refresh) _stale = stale;
        }
      });
    } catch (e, st) {
      AppLogger.warning('Orchard members: $e');
      if (mounted) setState(() => _failed = (error: e, stack: st));
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  /// What failed, said the app's way inside the page ([TeamLoadProblem]).
  Widget _problem(({Object error, StackTrace stack}) p, AppLocalizations l10n, {required bool stale}) =>
      TeamLoadProblem(
        title: stale ? l10n.teamMembersFromDevice : l10n.orchardMembersLoadFailed,
        error: p.error,
        stack: p.stack,
        where: stale ? 'Team members: bringing the team up to date' : 'Team members: reading them',
        stale: stale,
        onRetry: _loading ? null : () => _load(refresh: true),
      );

  String _name(OrchardPerson p) => p.email ?? p.uid;

  /// How [p] shows in a list: their
  /// name first with the address under it, or the address alone; masked in
  /// recording mode, where no picture shows either.
  ({String primary, String? secondary, String? picture}) _face(OrchardPerson p) {
    final picture = ref.watch(recordingModeProvider) ? null : p.picture;
    final address = Redactable.account(_name(p)).displayIn(ref);
    final name = p.name;
    if (name == null) return (primary: address, secondary: null, picture: picture);
    return (primary: Redactable.account(name).displayIn(ref), secondary: address, picture: picture);
  }

  OrchardSummary? get _orchard =>
      ref.read(orchardSummariesProvider).valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull;

  String _roleLabel(String role, AppLocalizations l10n) =>
      orchardRoleLabel(role, l10n, names: {for (final r in _people?.roles ?? const <OrchardRoleView>[]) r.id: r.name});

  Future<void> _check(OrchardPerson member) async {
    final l10n = AppLocalizations.of(context)!;
    final trust = member.trust;
    final fingerprint = trust?.pending?.fingerprint ?? trust?.fingerprint;
    if (trust == null || fingerprint == null) return;
    final name = _name(member);
    final matched = await ZestDialogShell.showModal<bool>(
      context,
      size: ZestModalSize.standard,
      tone: trust.hardStop ? ZestDialogTone.warning : ZestDialogTone.info,
      icon: trust.hardStop ? LucideIcons.shieldAlert : LucideIcons.fingerprint,
      title: l10n.orchardVerifyTitle(name),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // New keys their old ones did not vouch for: the one sentence that
          // warns, in amber.
          if (trust.hardStop) ...[
            ZestCallout(l10n.orchardKeyChangedBody(name), icon: LucideIcons.shieldAlert),
            const SizedBox(height: 12),
          ],
          Text(l10n.orchardVerifyBody(name),
              style: TextStyle(fontSize: 13, height: 1.45, color: AppColors.v3TextSecondary)),
          const SizedBox(height: 14),
          // Both people's words: one call checks both (3.0).
          CompareCodes(
            key: const ValueKey('member-fingerprint'),
            theirs: fingerprint,
            name: name,
            mine: _people?.members.where((m) => m.isMe).firstOrNull?.trust?.fingerprint,
            // A code that matches is as good as both saying so.
            onScanMatch: () => Navigator.of(context).pop(true),
          ),
        ],
      ),
      primaryAction: (
        label: l10n.orchardVerifyMatch,
        onPressed: () => Navigator.of(context).pop(true),
        icon: LucideIcons.check,
      ),
      secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.of(context).pop(false)),
    );
    if (matched != true || !mounted) return;
    setState(() => _busyUid = member.uid);
    try {
      await ref.read(orchardServiceProvider).verifyMember(widget.orchardId, member.uid);
      if (!mounted) return;
      showTopSnackBar(context, l10n.orchardVerifyDone(name), isSuccess: true);
      await _load(refresh: false);
    } catch (e) {
      AppLogger.warning('Orchard members: the check was not saved ($e)');
      if (mounted) showTopSnackBar(context, l10n.orchardVerifyFailed, isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  /// Makes a change about [uid] and says [done]; true when it went
  /// through. A change that may take access away ([revokes]) is followed by
  /// new keys for what it left waiting, as far as this account may replace
  /// them. When the server wants a recent sign-in first (any change to who
  /// is in the Orchard or what they may do), the person signs in again
  /// and it runs once more.
  Future<bool> _change(String uid, Future<void> Function(OrchardService service) change, String done,
      {bool revokes = false, required StepUpSummary summary}) async {
    final l10n = AppLocalizations.of(context)!;
    final service = ref.read(orchardServiceProvider);
    setState(() => _busyUid = uid);
    try {
      if (!await withRecentSignIn(context, ref, () => change(service), summary: summary) || !mounted) return false;
      var left = const <String>[];
      if (revokes && await service.keysWaiting(widget.orchardId)) {
        left = await service.rotateDue(widget.orchardId);
      }
      if (!mounted) return true;
      showTopSnackBar(context, done, isSuccess: true);
      if (left.isNotEmpty) showTopSnackBar(context, l10n.orchardKeysReplaceLater, isWarning: true);
      ref.read(orchardListVersionProvider.notifier).state++;
      await _load(refresh: false);
      return true;
    } catch (e) {
      AppLogger.warning('Orchard members: a change was not made ($e)');
      if (mounted) {
        showTopSnackBar(context, orchardChangeErrorMessage(e, l10n, nameOf: _nameOf), isError: true, details: '$e');
      }
      return false;
    } finally {
      if (mounted) setState(() => _busyUid = null);
    }
  }

  /// What [p] could use as [record] gives it to them, or null when it
  /// could not be worked out.
  Future<OrchardExposure?> _exposureOf(OrchardPerson p, OrchardRecord record) async {
    try {
      return await ref.read(orchardServiceProvider).exposure(widget.orchardId, p.uid, asOf: record);
    } catch (e) {
      AppLogger.warning('Orchard members: what they could use was not worked out ($e)');
      return null;
    }
  }

  Future<void> _showExposure(OrchardPerson p, OrchardExposure exposure, {bool kept = false}) {
    final crates = {for (final c in _orchard?.crates ?? const <CrateSummary>[]) c.id: c.name};
    return showOrchardExposure(context,
        name: _name(p), exposure: exposure, crateName: (id) => crates[id], nameOf: _nameOf, kept: kept);
  }

  /// They lost access: what they could use is kept as the keys to change
  /// next (the Team page's Overview lists it until each is marked), then
  /// shown.
  Future<void> _lostAccess(OrchardPerson p, OrchardExposure before) async {
    var kept = false;
    try {
      await ref.read(orchardServiceProvider).keepChangeNext(widget.orchardId, p.uid, before);
      kept = before.reveal.isNotEmpty || before.connect.isNotEmpty;
      ref.read(orchardListVersionProvider.notifier).state++;
    } catch (e) {
      AppLogger.warning('Orchard members: the keys to change next were not kept ($e)');
    }
    if (mounted) await _showExposure(p, before, kept: kept);
  }

  String _nameOf(String uid) {
    final p = _people?.members.where((m) => m.uid == uid).firstOrNull;
    return p == null ? uid : _name(p);
  }

  /// [uid]'s Vault access as the record here has it, with a
  /// select for each vault this account may change; null for someone no
  /// longer listed.
  Widget? _vaultAccessFor(String uid, AppLocalizations l10n) {
    final people = _people;
    final person = people?.members.where((m) => m.uid == uid).firstOrNull;
    final member = people?.record.members[uid];
    if (people == null || person == null || member == null) return null;
    final record = people.record;
    final orchard = _orchard;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    return ValueListenableBuilder<bool>(
      valueListenable: newRecordKindsOn,
      builder: (context, on, _) => MemberVaultAccess(
        key: ValueKey('vault-access-$uid'),
        role: member.role,
        record: record,
        rows: vaultAccessOf(record, people.me, uid, limitsOn: on),
        crateName: (c) => Redactable.group(_crateName(orchard, c, l10n)).displayIn(ref),
        // What they were given until a set time on top, with when it
        // ends: what they may do there now.
        timed: {
          for (final c in record.crates.values)
            if (!c.ownersOnly && record.switchesAt(uid, c.id, now).length != record.switchesOf(uid, c.id).length)
              c.id: [
                vaultSwitchesName(record.switchesAt(uid, c.id, now), c, l10n),
                l10n.accessUntil(accessTimeText(member.timed[c.id]!.until, l10n)),
              ].join(l10n.listSeparator),
        },
        onPick: _busyUid != null ? null : (c, pick) => _pickVault(person, c, pick),
      ),
    );
  }

  /// Sets [p]'s access to one vault: extra access, a limit, or
  /// both, as the record needs. Taking the vault away asks first; the first
  /// change of a new kind in a team is an owner's, after the question about
  /// older versions. What they could see there and no longer can is kept in
  /// Change next, worked out from the record before the change.
  Future<void> _pickVault(OrchardPerson p, String crateId, VaultPick pick) async {
    final l10n = AppLocalizations.of(context)!;
    final people = _people;
    if (people == null || _busyUid != null) return;
    final record = people.record;
    final changes = vaultPickChanges(record, p.uid, {crateId: pick});
    if (changes.isEmpty) return;
    final name = _name(p);
    final vault = _crateName(_orchard, crateId, l10n);
    if (changes.any((c) => RecordTypes.newKinds.contains(c.type)) &&
        !await confirmNewRecordKinds(context, record, owner: record.isOwner(people.me))) {
      return;
    }
    if (!mounted) return;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    final had = record.switchesAt(p.uid, crateId, now);
    final has = vaultRecordAfter(record, p.uid, {crateId: pick}).switchesAt(p.uid, crateId, now);
    final takesAway = had.isNotEmpty && has.isEmpty;
    final hides = had.contains(CrateSwitches.reveal) && !has.contains(CrateSwitches.reveal);
    if (takesAway &&
        !await _confirm(ZestDialogTone.destructive, l10n.vaultNoAccessTitle(vault, name), l10n.vaultNoAccessBody(name),
            l10n.vaultNoAccessConfirm)) {
      return;
    }
    // What they could use there, from the record as it stands before.
    final before = takesAway || hides ? await _exposureOf(p, record) : null;
    if (!mounted) return;
    final lost = before == null
        ? null
        : OrchardExposure(
            reveal: [
              for (final k in before.reveal)
                if (k.crateId == crateId) k,
            ],
            connect: [
              if (takesAway)
                for (final k in before.connect)
                  if (k.crateId == crateId) k,
            ],
            closed: const {},
          );
    _revision.value++;
    final done = await _change(
      p.uid,
      (s) => s.setVaultAccess(widget.orchardId, p.uid, {crateId: pick}),
      l10n.orchardChangeSaved,
      revokes: takesAway,
      summary: (
        what: l10n.stepUpVaultAccess(name, vault, vaultPickName(pick, l10n)),
        effects: [if (takesAway) l10n.stepUpEffectKeysIfLost],
      ),
    );
    if (mounted) _revision.value++;
    if (done && lost != null && !lost.isEmpty && mounted) await _lostAccess(p, lost);
  }

  /// Whether this account compared [p]'s current keys: only such members can
  /// be made an Owner or Admin (3.0).
  static bool _verifiedByMe(OrchardPerson p) =>
      p.trust != null && p.trust!.verifiedByMe && !p.trust!.hardStop && p.trust!.fingerprint != null;

  /// Before making [p] an Owner: compare codes first when this account has
  /// not. True when they are verified now.
  Future<bool> _compareFirst(OrchardPerson p) async {
    if (_verifiedByMe(p)) return true;
    final l10n = AppLocalizations.of(context)!;
    final name = _name(p);
    if (!await _confirm(ZestDialogTone.info, l10n.orchardPromoteCompareTitle(name), l10n.orchardPromoteCompareBody,
        l10n.orchardCompareCodes)) {
      return false;
    }
    await _check(p);
    if (!mounted) return false;
    final now = _people?.members.where((m) => m.uid == p.uid).firstOrNull;
    return now != null && _verifiedByMe(now);
  }

  Future<void> _act(_Act act, OrchardPerson p) async {
    final l10n = AppLocalizations.of(context)!;
    final people = _people;
    if (people == null) return;
    final name = _name(p);
    final orchardName = orchardDisplayName(_orchard?.name, l10n);
    final crates = _orchard?.crates ?? const <CrateSummary>[];
    switch (act) {
      case _Act.check:
        await _check(p);
      case _Act.role:
        // Owner is one of the roles to pick (it
        // was a button of its own at the bottom).
        final ownerToo = p.actions.makeOwner;
        final picked = await pickMemberRole(context,
            name: name,
            current: p.role,
            // Admin only for members this account compared.
            locked: _verifiedByMe(p) ? const {} : {FixedRoles.admin},
            lockedNote: l10n.orchardPromoteCompareNote,
            roles: [
          if (ownerToo)
            (id: FixedRoles.owner, label: l10n.orchardRoleOwner, summary: l10n.orchardRolePickOwnerHint),
          for (final id in p.actions.roles)
            (
              id: id,
              label: _roleLabel(id, l10n),
              summary: id == FixedRoles.admin
                  ? (people.record.adminRole == null
                      ? l10n.orchardRoleAdminSummary
                      : roleSummary(people.record.adminRole!.crates, crates, l10n))
                  : roleSummary(people.record.roles[id]?.crates ?? const {}, crates, l10n),
            ),
        ]);
        if (picked == null || !mounted) return;
        if (picked == FixedRoles.owner) return _act(_Act.owner, p);
        await _change(p.uid, (s) => s.setMemberRole(widget.orchardId, p.uid, picked),
            l10n.orchardMemberRoleChanged(name, _roleLabel(picked, l10n)),
            revokes: true,
            summary: (what: l10n.stepUpRole(name, _roleLabel(picked, l10n)), effects: [l10n.stepUpEffectKeysIfLost]));
      case _Act.vaults:
        // On a phone, the panel's table over the list; each pick is made
        // at once, as in the panel.
        await ZestDialogShell.showModal<void>(
          context,
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.package,
          title: l10n.memberPanelCrates,
          subtitle: name,
          body: ValueListenableBuilder<int>(
            valueListenable: _revision,
            builder: (context, _, _) => _vaultAccessFor(p.uid, l10n) ?? const SizedBox.shrink(),
          ),
          primaryAction: (label: l10n.close, onPressed: () => Navigator.of(context).pop(), icon: null),
        );
      case _Act.endDate:
        // Outside the team's domains it is what lets them in: a guest's end
        // date is moved, never taken away.
        final picked = await pickAccessEnd(context,
            title: l10n.orchardEndDateTitle(name),
            current: p.endsAt,
            requireEnd: _isOutsideDomains(p));
        if (picked == null || !mounted) return;
        await _change(p.uid, (s) => s.setMemberEndsAt(widget.orchardId, p.uid, picked.endsAt), l10n.orchardChangeSaved,
            summary: (what: l10n.stepUpEndDate(name), effects: const []));
      case _Act.owner:
        if (!await _compareFirst(p) || !mounted) return;
        final stepDown = await confirmMakeOwner(context, name: name);
        if (stepDown == null || !mounted) return;
        await _change(p.uid, (s) => s.makeOwner(widget.orchardId, p.uid, stepDown: stepDown),
            l10n.orchardMadeOwnerToast(name),
            summary: (what: l10n.stepUpOwner(name), effects: [if (stepDown) l10n.stepUpEffectYouAdmin]));
      case _Act.suspend:
        if (!await _confirm(ZestDialogTone.neutral, l10n.orchardSuspendTitle(name), l10n.orchardSuspendBody,
            l10n.orchardSuspendConfirm)) {
          return;
        }
        // What they could use, from the record as it stands before.
        final before = await _exposureOf(p, people.record);
        if (!mounted) return;
        if (await _change(p.uid, (s) => s.suspendMember(widget.orchardId, p.uid), l10n.orchardSuspendedToast(name),
                revokes: true,
                summary: (
                  what: l10n.stepUpSuspend(name, orchardName),
                  effects: [l10n.stepUpEffectCutOff(name), l10n.stepUpEffectKeysReplaced],
                )) &&
            before != null &&
            !before.isEmpty &&
            mounted) {
          await _lostAccess(p, before);
        }
      case _Act.resume:
        if (!await _confirm(ZestDialogTone.info, l10n.orchardResumeTitle(name), l10n.orchardResumeBody,
            l10n.orchardResumeConfirm)) {
          return;
        }
        await _change(p.uid, (s) => s.resumeMember(widget.orchardId, p.uid), l10n.orchardResumedToast(name),
            summary: (what: l10n.stepUpResume(name), effects: [l10n.stepUpEffectKeysBack]));
      case _Act.remove:
        if (!await _confirm(ZestDialogTone.destructive, l10n.orchardRemoveTitle(name), l10n.orchardRemoveBody,
            l10n.orchardRemoveConfirm)) {
          return;
        }
        final before = await _exposureOf(p, people.record);
        if (!mounted) return;
        if (await _change(p.uid, (s) => s.removeMember(widget.orchardId, p.uid), l10n.orchardRemovedToast(name),
                revokes: true,
                summary: (
                  what: l10n.stepUpRemove(name, orchardName),
                  effects: [
                    l10n.stepUpEffectCutOff(name),
                    l10n.stepUpEffectKeysReplaced,
                    l10n.stepUpEffectDevicesForget,
                  ],
                )) &&
            before != null &&
            !before.isEmpty &&
            mounted) {
          await _lostAccess(p, before);
        }
      case _Act.exposure:
        final exposure = await _exposureOf(p, people.record);
        if (!mounted) return;
        if (exposure == null) {
          showTopSnackBar(context, l10n.orchardMembersLoadFailed, isError: true);
          return;
        }
        await _showExposure(p, exposure);
      case _Act.devices:
        final orchard = _orchard;
        if (orchard == null) return;
        await showMemberDevices(context, ref, orchard, uid: p.uid, name: name, isMe: p.isMe);
      case _Act.stepDown:
        if (!await _confirm(ZestDialogTone.warning, l10n.orchardStepDownTitle, l10n.orchardStepDownLead,
            l10n.orchardStepDownConfirm,
            warning: l10n.orchardStepDownWarning)) {
          return;
        }
        await _change(p.uid, (s) => s.stepDown(widget.orchardId), l10n.orchardSteppedDownToast,
            summary: (what: l10n.stepUpStepDown, effects: const []));
      case _Act.leave:
        final orchard = _orchard;
        if (people.soleOwner && orchard != null) {
          // A team needs an owner: Make someone owner, then
          // leave, or Delete the team.
          await soleOwnerLeave(context, ref, orchard, people, onLeft: () {
            ref.read(orchardListVersionProvider.notifier).state++;
            if (!mounted) return;
            if (widget.onLeft != null) {
              widget.onLeft!();
            } else {
              Navigator.of(context).pop();
            }
          });
          return;
        }
        if (!await _confirm(ZestDialogTone.destructive, l10n.orchardLeaveTitle(orchardName), l10n.orchardLeaveBody,
            l10n.orchardLeaveConfirm)) {
          return;
        }
        await _leave(orchardName);
    }
  }

  Future<bool> _confirm(ZestDialogTone tone, String title, String body, String confirm, {String? warning}) async =>
      await ZestConfirmDialog.show(context, tone: tone, title: title, body: body, warning: warning, confirmLabel: confirm) ==
      true;

  /// Leaves the Orchard: the Tree comes on screen first, since the
  /// Orchard's database closes and leaves this device.
  Future<void> _leave(String orchardName) async {
    final l10n = AppLocalizations.of(context)!;
    final space = ref.read(activeSpaceProvider);
    setState(() => _busyUid = _people?.me);
    try {
      if (space is OrchardSpace && space.orchardId == widget.orchardId) {
        await ref.read(spaceControllerProvider).switchTo(const TreeSpace());
      }
      await ref.read(orchardServiceProvider).leaveOrchard(widget.orchardId);
      ref.read(orchardListVersionProvider.notifier).state++;
      if (!mounted) return;
      showTopSnackBar(context, l10n.orchardLeftToast(orchardName), isSuccess: true);
      if (widget.onLeft != null) {
        widget.onLeft!();
      } else {
        Navigator.of(context).pop();
      }
    } catch (e) {
      AppLogger.warning('Orchard members: leaving did not go through ($e)');
      if (mounted) {
        setState(() => _busyUid = null);
        showTopSnackBar(context, orchardChangeErrorMessage(e, l10n, nameOf: _nameOf), isError: true, details: '$e');
      }
    }
  }

  List<_Act> _actsFor(OrchardPerson p, OrchardPeople people) {
    if (p.isMe) {
      return [
        _Act.devices,
        if (people.stepDown) _Act.stepDown,
        // The only owner too: offered a new owner, or deleting the team once
        // new kinds of record entry are on.
        if (people.leave || (people.soleOwner && (people.members.length > 1 || newRecordKindsOn.value))) _Act.leave,
      ];
    }
    final a = p.actions;
    final myRole = people.record.members[people.me]?.role;
    return [
      if (p.trust?.fingerprint != null) _Act.check,
      if (a.changeRole || a.makeOwner) _Act.role,
      if (a.grants) _Act.vaults,
      if (a.endDate) _Act.endDate,
      if (a.suspend) _Act.suspend,
      if (a.resume) _Act.resume,
      if (a.remove) _Act.remove,
      if (myRole == FixedRoles.owner || myRole == FixedRoles.admin) _Act.exposure,
      // Their approved devices, which every member may see.
      if (p.status != MemberStatus.removed) _Act.devices,
    ];
  }

  String _actLabel(_Act act, AppLocalizations l10n) => switch (act) {
        _Act.check => l10n.orchardMemberCheck,
        _Act.role => l10n.orchardMemberChangeRole,
        _Act.vaults => l10n.memberPanelCrates,
        _Act.endDate => l10n.orchardMemberEndDateAction,
        _Act.owner => l10n.orchardMemberMakeOwner,
        _Act.suspend => l10n.orchardMemberSuspend,
        _Act.resume => l10n.orchardMemberResume,
        _Act.remove => l10n.orchardMemberRemove,
        _Act.exposure => l10n.orchardMemberExposure,
        _Act.devices => l10n.memberDevicesTitle,
        _Act.stepDown => l10n.orchardStepDown,
        _Act.leave => l10n.orchardLeave,
      };

  IconData _actIcon(_Act act) => switch (act) {
        _Act.check => LucideIcons.fingerprint,
        _Act.role => LucideIcons.userCog,
        _Act.vaults => LucideIcons.package,
        _Act.endDate => LucideIcons.calendarClock,
        _Act.owner => LucideIcons.crown,
        _Act.suspend => LucideIcons.pauseCircle,
        _Act.resume => LucideIcons.playCircle,
        _Act.remove => LucideIcons.userMinus,
        _Act.exposure => LucideIcons.keyRound,
        _Act.devices => LucideIcons.monitorSmartphone,
        _Act.stepDown => LucideIcons.arrowDownCircle,
        _Act.leave => LucideIcons.logOut,
      };

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final people = _people;
    final failed = _failed;
    if (failed != null && people == null) {
      final problem = _problem(failed, l10n, stale: false);
      if (!widget.pageLayout) return problem;
      // Inside the page's margins, as the list would be.
      return SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
        child: Align(
          alignment: Alignment.topLeft,
          child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 860), child: problem),
        ),
      );
    }
    if (people == null) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      );
    }
    final me = people.members.where((m) => m.isMe).firstOrNull;
    final orchard = ref
        .watch(orchardSummariesProvider)
        .valueOrNull
        ?.where((o) => o.id == widget.orchardId)
        .firstOrNull;
    final now = DateTime.now().millisecondsSinceEpoch ~/ 1000;
    if (widget.pageLayout) return _page(people, orchard, now, l10n);
    final stale = _stale;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (stale != null) ...[
          _problem(stale, l10n, stale: true),
          const SizedBox(height: 14),
        ],
        if (orchard != null && orchard.canInvite && orchard.active) ...[
          OrchardInvitesSection(
            key: const ValueKey('orchard-invites'),
            orchard: orchard,
            showInviteButton: !widget.inviteInHeader,
            onMembersChanged: () => _load(refresh: false),
          ),
          const SizedBox(height: 14),
        ],
        ?_outsideNotice(people, orchard, l10n),
        if (me?.trust?.fingerprint != null) ...[
          Text(l10n.orchardYourFingerprint,
              style: TextStyle(fontSize: 12.5, fontWeight: FontWeight.w600, color: AppColors.v3TextPrimary)),
          const SizedBox(height: 6),
          FingerprintBox(fingerprint: me!.trust!.fingerprint!, key: const ValueKey('my-fingerprint')),
          const SizedBox(height: 4),
          Text(l10n.orchardYourFingerprintHelp,
              style: TextStyle(fontSize: 11.5, color: AppColors.v3TextTertiary)),
          const SizedBox(height: 14),
        ],
        if (people.soleOwner) ...[
          _Note(key: const ValueKey('sole-owner'), icon: LucideIcons.crown, text: l10n.orchardSoleOwnerNudge),
          const SizedBox(height: 10),
        ],
        for (final m in people.members)
          _MemberRow(
            key: ValueKey('member-${m.uid}'),
            name: _face(m).primary,
            picture: _face(m).picture,
            isMe: m.isMe,
            role: _roleLabel(m.role, l10n),
            chips: _standing(m, now, l10n),
            status: m.isMe || m.trust == null ? null : _status(m.trust!, l10n),
            busy: _busyUid == m.uid,
            onTap: m.isMe || m.trust?.fingerprint == null || _busyUid != null ? null : () => _check(m),
            actions: [
              for (final a in _actsFor(m, people)) (label: _actLabel(a, l10n), icon: _actIcon(a), act: a),
            ],
            onAction: _busyUid != null ? null : (a) => _act(a as _Act, m),
          ),
      ],
    );
  }

  /// Where a member stands, each as a state of its own: red for what ended,
  /// amber for what is held, the neutral grey for what is only so.
  List<_Standing> _standing(OrchardPerson m, int now, AppLocalizations l10n) => [
        if (m.accountDeleted) (l10n.orchardMemberAccountDeleted, ZestStatusKind.critical, LucideIcons.userX),
        // Outside the team's domains (a rule): held back until that changes,
        // or a guest until an end date. Where this device does not know their
        // address yet, nothing is said.
        if (m.status == MemberStatus.active && m.email != null && _heldByDomains(m))
          (l10n.orchardMemberOutsideDomains, ZestStatusKind.warning, LucideIcons.atSign),
        if (m.status == MemberStatus.active && m.email != null && !m.endedAt(now) && m.endsAt != null && _isOutsideDomains(m))
          (l10n.orchardMemberGuest, ZestStatusKind.neutral, LucideIcons.atSign),
        if (m.status == MemberStatus.suspended) (l10n.orchardMemberSuspended, ZestStatusKind.warning, LucideIcons.pauseCircle),
        if (m.status == MemberStatus.active && m.endedAt(now))
          (l10n.orchardMemberEnded, ZestStatusKind.critical, LucideIcons.calendarX),
        if (m.endsAt != null && !m.endedAt(now))
          (l10n.orchardMemberEndsOn(accessThrough(m.endsAt!, context)), ZestStatusKind.neutral, LucideIcons.calendarClock),
        // Extra access a limit there does not hold back.
        if (m.grants.keys.any((c) => !m.limits.containsKey(c)))
          (
            l10n.orchardMemberExtraCrates(m.grants.keys.where((c) => !m.limits.containsKey(c)).length),
            ZestStatusKind.neutral,
            LucideIcons.packagePlus,
          ),
        if (m.limits.isNotEmpty)
          (l10n.orchardMemberLimitedCrates(m.limits.length), ZestStatusKind.neutral, LucideIcons.packageMinus),
      ];

  /// Whether the team's rule on address domains holds [m] back.
  bool _heldByDomains(OrchardPerson m) =>
      domainRuleHolds(_orchard?.rules.emailDomains ?? const <String>{}, m.email, endsAt: m.endsAt);

  /// Whether [m]'s address is outside the domains the team's rules allow.
  bool _isOutsideDomains(OrchardPerson m) {
    final domains = _orchard?.rules.emailDomains ?? const <String>{};
    return domains.isNotEmpty && !domains.contains(addressDomain(m.email));
  }

  /// For an owner, who can do something about it: who the team's domains
  /// hold back, and Review. Null where nobody is.
  Widget? _outsideNotice(OrchardPeople people, OrchardSummary? orchard, AppLocalizations l10n) {
    if (orchard == null || !orchard.isOwner || !orchard.active) return null;
    final domains = orchard.rules.emailDomains;
    final outside = outsideDomainsOf(people, domains);
    // A guest whose date an owner gave was decided on; one no owner gave (their
    // address moved outside after someone else dated them) was not.
    final unseen = outside.unseen;
    if (outside.held.isEmpty && unseen.isEmpty) return null;
    final shown = [...outside.held, ...unseen];
    return Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: TeamCallout(
        key: const ValueKey('members-outside'),
        tone: TeamTone.warning,
        icon: LucideIcons.atSign,
        title: l10n.orchardOutsideTitle(shown.length, outsideDomainsWords(domains, ref, l10n)),
        body: [
          '${outsidePeopleWords(shown, ref, l10n)}.',
          if (outside.held.isNotEmpty) l10n.orchardRulesOutsideBody,
          if (unseen.isNotEmpty) l10n.orchardOutsideUnseenBody,
        ].join(' '),
        action: teamButton(
          key: const ValueKey('members-outside-review'),
          label: l10n.teamReview,
          onPressed: _busyUid != null ? null : () => _reviewOutside(people, orchard, outside, l10n),
        ),
      ),
    );
  }

  /// Keeps them as guests or removes them; the domains themselves are changed
  /// on the Rules page.
  Future<void> _reviewOutside(
      OrchardPeople people, OrchardSummary orchard, OutsideDomains outside, AppLocalizations l10n) async {
    final proven = await ref.read(orchardProvenDomainsProvider(orchard.id).future);
    if (!mounted) return;
    final answer = await showOutsideDomains(context,
        domains: orchard.rules.emailDomains,
        outside: OutsideDomains(held: outside.held, guests: outside.unseen, unknown: outside.unknown),
        beforeSaving: false,
        proven: {...proven},
        onChangeDomains: widget.onOpenRules);
    if (answer is! OutsideDecided || !answer.changesMembers || !mounted) return;
    setState(() => _busyUid = people.me);
    try {
      final done = await applyOutsideDomains(context, ref, orchard, answer,
          people: people, summary: (what: l10n.stepUpOutside, effects: outsideEffects(answer, context, l10n)));
      if (!mounted) return;
      if (done) showTopSnackBar(context, l10n.orchardChangeSaved, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Orchard members: a change was not made ($e)');
      if (mounted) {
        showTopSnackBar(context, orchardChangeErrorMessage(e, l10n, nameOf: _nameOf), isError: true, details: '$e');
      }
    } finally {
      // What was done stands, whatever stopped after it.
      if (mounted) {
        setState(() => _busyUid = null);
        await _load(refresh: false);
      }
    }
  }

  /// The Team page's Members on a computer:
  /// a filter and All / Waiting over "Waiting for you",
  /// "Invited" and the members, the selected member's panel (or the review
  /// of someone waiting) on the right.
  Widget _page(OrchardPeople people, OrchardSummary? orchard, int now, AppLocalizations l10n) {
    final selectedUid = ref.watch(teamMemberPanelProvider(widget.orchardId));
    final reviewing = ref.watch(teamReviewPanelProvider(widget.orchardId));
    // Another page asked for a review (the Overview's Review): open it here.
    final asked = ref.watch(teamReviewToOpenProvider);
    if (asked != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ref.read(teamReviewToOpenProvider.notifier).state = null;
        _openReview(asked);
      });
    }
    final selected = people.members.where((m) => m.uid == selectedUid).firstOrNull;
    // Someone who is no longer listed (removed elsewhere, the list read
    // again): no panel, and the header no longer keeps room for one.
    if (selectedUid != null && selected == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(teamMemberPanelProvider(widget.orchardId)) == selectedUid) _selectedUid = null;
      });
    }
    final canInvite = orchard != null && orchard.canInvite && orchard.active;
    final invitesRead = canInvite ? ref.watch(teamInvitesProvider(widget.orchardId)) : null;
    final invites = invitesRead?.valueOrNull ?? const <InviteView>[];
    final review = invites.where((v) => v.invite.id == reviewing && v.waiting).firstOrNull;
    // Let in, turned away or gone meanwhile: the review closes.
    if (reviewing != null && review == null && (invitesRead == null || invitesRead.hasValue)) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && ref.read(teamReviewPanelProvider(widget.orchardId)) == reviewing) {
          ref.read(teamReviewPanelProvider(widget.orchardId).notifier).state = null;
        }
      });
    }
    final filter = _filter.text;
    final q = filter.trim().toLowerCase();
    final shown = [
      for (final m in people.members)
        if (q.isEmpty ||
            _name(m).toLowerCase().contains(q) ||
            (m.name?.toLowerCase().contains(q) ?? false) ||
            _roleLabel(m.role, l10n).toLowerCase().contains(q))
          m,
    ];
    final waitingOnly = canInvite && _waitingOnly;
    final names = orchardRoleNames(ref, widget.orchardId);
    final invitesShown = [
      for (final v in invites)
        if (inviteMatches(v, orchardRoleLabel(v.invite.role, l10n, names: names), filter)) v,
    ];
    final nothing = q.isNotEmpty && invitesShown.isEmpty && (waitingOnly || shown.isEmpty);
    final stale = _stale;
    final list = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (stale != null) ...[
                _problem(stale, l10n, stale: true),
                const SizedBox(height: 16),
              ],
              ?_outsideNotice(people, orchard, l10n),
              // Who waits for you, first, until a review is open beside the
              // list.
              if (canInvite && review == null && invites.any((v) => v.waiting)) ...[
                WaitingBanner(
                  waiting: [...invites.where((v) => v.waiting)],
                  onReview: (v) => _openReview(v.invite.id),
                ),
                const SizedBox(height: 16),
              ],
              Row(
                children: [
                  Flexible(
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 360),
                      child: ZestListSearchField(
                        key: const ValueKey('members-filter'),
                        controller: _filter,
                        hintText: l10n.teamFilterPeople,
                        onChanged: (_) => setState(() {}),
                      ),
                    ),
                  ),
                  const Spacer(),
                  if (canInvite) ...[
                    const SizedBox(width: 12),
                    ZestModeToggle(
                      key: const ValueKey('members-show'),
                      segments: [
                        ZestModeSegment(id: 'all', label: l10n.teamFilterAll(people.members.length + invites.length)),
                        ZestModeSegment(id: 'waiting', label: l10n.teamFilterWaiting(invites.length)),
                      ],
                      selectedId: waitingOnly ? 'waiting' : 'all',
                      onChanged: (id) => setState(() => _waitingOnly = id == 'waiting'),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 20),
              if (canInvite)
                OrchardInvitesSection(
                  key: const ValueKey('orchard-invites'),
                  orchard: orchard,
                  pageLayout: true,
                  filter: filter,
                  reviewing: review?.invite.id,
                  onOpenReview: (v) => _openReview(v.invite.id),
                  showInviteButton: !widget.inviteInHeader,
                  onMembersChanged: () => _load(refresh: false),
                ),
              if (!waitingOnly && shown.isNotEmpty) ...[
                ZestSectionHeader(
                  key: const ValueKey('members-title'),
                  label: l10n.orchardMembers,
                  count: shown.length,
                ),
                for (final m in shown)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 8),
                    child: _PageMemberRow(
                      key: ValueKey('member-${m.uid}'),
                      name: _face(m).primary,
                      picture: _face(m).picture,
                      isMe: m.isMe,
                      role: _roleLabel(m.role, l10n),
                      owner: m.role == FixedRoles.owner,
                      line: [
                        ?_face(m).secondary,
                        if ((people.record.members[m.uid]?.devices.length ?? 0) > 0)
                          l10n.teamMemberDevices(people.record.members[m.uid]!.devices.length),
                        if (!m.isMe && m.trust != null && _healthy(m.trust!)) _status(m.trust!, l10n).label,
                        for (final (label, kind, _) in _standing(m, now, l10n))
                          if (kind == ZestStatusKind.neutral) label,
                      ].join(' · '),
                      pills: [
                        for (final (label, kind, icon) in _standing(m, now, l10n))
                          if (kind != ZestStatusKind.neutral) ZestStatusPill(kind: kind, icon: icon, label: label),
                        if (!m.isMe && m.trust != null && !_healthy(m.trust!))
                          ZestStatusPill(
                              kind: _status(m.trust!, l10n).kind,
                              icon: _status(m.trust!, l10n).icon,
                              label: _status(m.trust!, l10n).label),
                        for (final e in (people.record.members[m.uid]?.timed ?? const <String, RecordTimedGrant>{}).entries)
                          if (e.value.until > now)
                            _TimedPill(
                              key: ValueKey('member-timed-${m.uid}-${e.key}'),
                              label: l10n.teamTimedPill(
                                Redactable.group(_crateName(orchard, e.key, l10n)).displayIn(ref),
                                accessTimeText(e.value.until, l10n),
                              ),
                            ),
                      ],
                      busy: _busyUid == m.uid,
                      selected: m.uid == selectedUid && review == null,
                      onTap: () => setState(() {
                        ref.read(teamReviewPanelProvider(widget.orchardId).notifier).state = null;
                        _selectedUid = m.uid == selectedUid ? null : m.uid;
                      }),
                    ),
                  ),
              ],
              if (nothing)
                Padding(
                  key: const ValueKey('members-no-match'),
                  padding: const EdgeInsets.symmetric(vertical: 16),
                  child: Text(l10n.teamMembersNoMatch,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
                ),
            ],
          ),
        ),
      ),
    );
    final Widget? panel = review != null && orchard != null
        ? JoinReviewPanel(
              key: ValueKey('review-${review.invite.id}'),
              orchard: orchard,
              view: review,
              onClose: () {
                ref.read(teamReviewPanelProvider(widget.orchardId).notifier).state = null;
                _load(refresh: false);
              },
            )
        : selected == null
            ? null
            : _MemberPanel(
            key: ValueKey('member-panel-${selected.uid}'),
            person: selected,
            name: _face(selected).primary,
            address: _face(selected).secondary,
            picture: _face(selected).picture,
            role: _roleLabel(selected.role, l10n),
            standing: _standing(selected, now, l10n),
            status: selected.isMe || selected.trust == null ? null : _status(selected.trust!, l10n),
            vaultAccess: _vaultAccessFor(selected.uid, l10n),
            acts: _actsFor(selected, people),
            // Their approved devices, listed in the panel itself.
            devices: orchard == null || selected.status == MemberStatus.removed
                ? null
                : MemberDevicesView(
                    key: ValueKey('member-devices-${selected.uid}'),
                    header: true,
                    orchard: orchard,
                    uid: selected.uid,
                    name: _name(selected),
                    isMe: selected.isMe,
                  ),
            busy: _busyUid == selected.uid,
            actLabel: (a) => _actLabel(a, l10n),
            onAct: _busyUid != null ? null : (a) => _act(a, selected),
            onClose: () => setState(() => _selectedUid = null),
          );
    if (panel == null) return list;
    // Beside the list where the page has room for both, in its place where
    // it has not (its close brings the list back).
    return TeamListAndPanel(panelWidth: kMemberPanelWidth, list: list, panel: panel);
  }

  /// Opens the review of invitation [inviteId] beside the list, in place of
  /// a member's panel.
  void _openReview(String inviteId) {
    ref.read(teamMemberPanelProvider(widget.orchardId).notifier).state = null;
    ref.read(teamReviewPanelProvider(widget.orchardId).notifier).state = inviteId;
  }

  /// A vault's name as this device has it.
  String _crateName(OrchardSummary? orchard, String crateId, AppLocalizations l10n) {
    final c = orchard?.crates.where((s) => s.id == crateId).firstOrNull;
    return c == null ? l10n.crateUnnamed : crateDisplayName(c, l10n);
  }

  /// This device trusts [m]'s keys (compared here or by others): nothing to
  /// flag on their row.
  static bool _healthy(MemberView m) =>
      !m.hardStop && m.fingerprint != null && (m.verifiedByMe || m.verifiedBy.isNotEmpty);

  _TrustStatus _status(MemberView m, AppLocalizations l10n) {
    if (m.hardStop) {
      return (label: l10n.orchardMemberKeyChanged, kind: ZestStatusKind.critical, icon: LucideIcons.shieldAlert);
    }
    if (m.fingerprint == null) {
      return (label: l10n.orchardMemberNoKeys, kind: ZestStatusKind.neutral, icon: LucideIcons.keyRound);
    }
    if (m.verifiedByMe) {
      return (label: l10n.orchardMemberVerifiedByYou, kind: ZestStatusKind.healthy, icon: LucideIcons.badgeCheck);
    }
    final others = m.verifiedBy.length;
    if (others > 0) {
      return (
        label: l10n.orchardMemberVerifiedByOthers(others),
        kind: ZestStatusKind.healthy,
        icon: LucideIcons.checkCircle,
      );
    }
    // They replaced their keys since this person compared them.
    if (m.replacedSinceCompared) {
      return (label: l10n.orchardMemberKeysReplaced, kind: ZestStatusKind.warning, icon: LucideIcons.refreshCw);
    }
    return (label: l10n.orchardMemberNotVerified, kind: ZestStatusKind.warning, icon: LucideIcons.fingerprint);
  }
}

/// Where a member stands, in words, as a state, with its glyph.
typedef _Standing = (String, ZestStatusKind, IconData);

/// How far this device trusts a member's keys.
typedef _TrustStatus = ({String label, ZestStatusKind kind, IconData icon});

/// A short note set apart from the list.
class _Note extends StatelessWidget {
  const _Note({super.key, required this.icon, required this.text});

  final IconData icon;
  final String text;

  @override
  Widget build(BuildContext context) => TeamCallout(tone: TeamTone.warning, icon: icon, title: text);
}

/// A member on a computer's Members page,
/// a card of its own: their initials, name, You and their role, a
/// line of what is known about them, what to flag and what they hold for a
/// while, and a chevron that opens their panel.
class _PageMemberRow extends StatelessWidget {
  const _PageMemberRow({
    super.key,
    required this.name,
    this.picture,
    required this.isMe,
    required this.role,
    required this.owner,
    required this.line,
    required this.pills,
    required this.busy,
    required this.selected,
    required this.onTap,
  });

  /// As shown (masked in recording mode).
  final String name;

  /// Their account's picture; null for initials.
  final String? picture;
  final bool isMe;
  final String role;

  /// Their role is Owner: its tag in the accent.
  final bool owner;

  /// Under the name: devices, how far this device trusts their keys, when
  /// their access ends; empty for nothing.
  final String line;
  final List<Widget> pills;
  final bool busy;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Material(
      color: selected ? ZestTokens.surfaceRaisedAlt : ZestTokens.surfaceRaised,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 60),
          padding: const EdgeInsets.fromLTRB(14, 10, 12, 10),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
                color: selected ? ZestTokens.brandBorder : ZestTokens.borderSubtle, width: selected ? 1.4 : 1),
          ),
          // The pills take what the row leaves once the name has 120, and
          // wrap onto a second line there: laid out at their full width, a
          // timed pill ("Production until Nov 13 12:59 AM", as wide as the
          // clock makes it) ran the row past its edge at 800 by 600.
          child: LayoutBuilder(builder: (context, box) => Row(
            children: [
              TeamFace(name: name, picture: picture),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Wrap(
                      spacing: 8,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(name,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        if (isMe) TeamRolePill(l10n.orchardMemberYou),
                        TeamRolePill(role, accent: owner),
                      ],
                    ),
                    if (line.isNotEmpty) ...[
                      const SizedBox(height: 3),
                      Text(line, style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
                    ],
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (busy)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              else
                ConstrainedBox(
                  constraints: BoxConstraints(maxWidth: (box.maxWidth - _kRowFixedWidth - 120).clamp(0, double.infinity)),
                  child: Wrap(
                    spacing: 6,
                    runSpacing: 4,
                    alignment: WrapAlignment.end,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: pills,
                  ),
                ),
              const SizedBox(width: 8),
              Icon(LucideIcons.chevronRight, size: 16, color: ZestTokens.textTertiary),
            ],
          )),
        ),
      ),
    );
  }
}

/// Something a member holds until a set time ("Production until 4:06 PM"),
/// a tag in the accent with a clock.
class _TimedPill extends StatelessWidget {
  const _TimedPill({super.key, required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.brandSubtle,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: ZestTokens.brandBorder),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(LucideIcons.clock, size: 12, color: zestBrandOnSubtle),
          const SizedBox(width: 5),
          // Where the row leaves it less than its words, they wrap inside the
          // pill (the vault and the time both kept) rather than run past it.
          Flexible(
            child: Text(label, style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w500, color: zestBrandOnSubtle)),
          ),
        ],
      ),
    );
  }
}

/// A member row's face (32), its gaps (12, 12 and 8) and its chevron (16).
const double _kRowFixedWidth = 32 + 12 + 12 + 8 + 16;

class _MemberRow extends StatelessWidget {
  const _MemberRow({
    super.key,
    required this.name,
    this.picture,
    required this.isMe,
    required this.role,
    required this.chips,
    required this.status,
    required this.busy,
    required this.onTap,
    required this.actions,
    required this.onAction,
  });

  final String name;
  final String? picture;
  final bool isMe;
  final String role;
  final List<_Standing> chips;
  final _TrustStatus? status;
  final bool busy;
  final VoidCallback? onTap;
  final List<({String label, IconData icon, Object act})> actions;
  final ValueChanged<Object>? onAction;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final status = this.status;
    final touch = isTouchLayout;
    // 56 high at least, 16 in from each edge.
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 56),
          padding: EdgeInsets.fromLTRB(14, 8, actions.isEmpty ? 16 : 6, 8),
          child: Row(
            children: [
              TeamFace(name: name, picture: picture),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(name,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                        ),
                        // You: plain text on a phone and a tablet, before
                        // the role (chips are for filters and what needs
                        // someone; 3.0 quick wins).
                        if (isMe && !touch) ...[
                          const SizedBox(width: 8),
                          ZestStatusPill(kind: ZestStatusKind.neutral, icon: LucideIcons.user, label: l10n.orchardMemberYou),
                        ],
                      ],
                    ),
                    const SizedBox(height: 4),
                    Wrap(
                      spacing: 6,
                      runSpacing: 4,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        Text(isMe && touch ? '${l10n.orchardMemberYou} · $role' : role,
                            style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
                        for (final (label, kind, icon) in chips) ZestStatusPill(kind: kind, icon: icon, label: label),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 12),
              if (busy)
                const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
              // Keys verified: plain text on a phone and a tablet; what needs
              // someone (keys changed, none yet, not compared) keeps its chip.
              else if (status != null && touch && status.kind == ZestStatusKind.healthy)
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 130),
                  child: Text(status.label,
                      key: const ValueKey('member-status-text'),
                      maxLines: 2,
                      textAlign: TextAlign.end,
                      style: TextStyle(fontSize: 11.5, color: ZestTokens.statusHealthy)),
                )
              else if (status != null)
                ZestStatusPill(kind: status.kind, icon: status.icon, label: status.label),
              if (actions.isNotEmpty)
                PopupMenuButton<Object>(
                  enabled: onAction != null && !busy,
                  tooltip: l10n.orchardMemberActions,
                  // Room for longer words in other languages; a label that is
                  // longer still wraps.
                  constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
                  icon: Icon(LucideIcons.moreHorizontal, size: 16, color: ZestTokens.textSecondary),
                  onSelected: (a) => onAction?.call(a),
                  itemBuilder: (context) => [
                    for (final a in actions)
                      PopupMenuItem<Object>(
                        value: a.act,
                        height: 36,
                        child: Row(
                          children: [
                            Icon(a.icon, size: 14, color: ZestTokens.textSecondary),
                            const SizedBox(width: 10),
                            Flexible(child: Text(a.label, style: const TextStyle(fontSize: 13))),
                          ],
                        ),
                      ),
                  ],
                ),
            ],
          ),
        ),
      ),
    );
  }
}

/// How wide a member's panel is beside the Members page's list.
const kMemberPanelWidth = 400.0;

/// One member on the Team page (3.0): their role and when their
/// access ends, what they can open in each Crate, how far this device trusts
/// their keys, and what this account may change about them. Every change
/// goes through the same steps as the list's menu.
class _MemberPanel extends StatelessWidget {
  const _MemberPanel({
    super.key,
    required this.person,
    required this.name,
    this.address,
    this.picture,
    required this.role,
    required this.standing,
    required this.status,
    required this.vaultAccess,
    required this.acts,
    required this.busy,
    required this.actLabel,
    required this.onAct,
    required this.onClose,
    this.devices,
  });

  /// The member's approved devices, when there is an Orchard to list
  /// them from.
  final Widget? devices;

  final OrchardPerson person;
  final String name;

  /// Their address under their name, where the name is their own (masked
  /// like the name); and their picture, null for initials.
  final String? address;
  final String? picture;
  final String role;
  final List<_Standing> standing;
  final _TrustStatus? status;

  /// Their Vault access: null where there is nothing to show.
  final Widget? vaultAccess;
  final List<_Act> acts;
  final bool busy;
  final String Function(_Act) actLabel;
  final void Function(_Act)? onAct;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    Widget section(String label, {bool danger = false}) => Padding(
          padding: const EdgeInsets.only(top: 20),
          child: ZestSectionHeader(label: label, danger: danger),
        );
    VoidCallback? press(_Act a) => onAct == null || busy ? null : () => onAct!(a);
    // A change of what a line shows: a button, not a bare word.
    Widget change(_Act a, String label) => teamButton(key: ValueKey('member-panel-${a.name}'), label: label, onPressed: press(a));
    // What opens a list of its own: a row with a chevron.
    Widget opens(_Act a, IconData icon) =>
        TeamLinkRow(key: ValueKey('member-panel-${a.name}'), icon: icon, label: actLabel(a), onTap: press(a));
    Widget line(String k, String v, {_Act? act}) => ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 40),
          child: Row(
            children: [
              SizedBox(width: 110, child: Text(k, style: TextStyle(fontSize: 12.5, color: ZestTokens.textTertiary))),
              Expanded(child: Text(v, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary))),
              if (act != null && acts.contains(act)) change(act, l10n.memberPanelChange),
            ],
          ),
        );
    final trust = person.trust;
    final status = this.status;
    final ends = person.endsAt;
    // As wide as its place (TeamListAndPanel).
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        border: Border(left: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (busy) const LinearProgressIndicator(minHeight: 2) else const SizedBox(height: 2),
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 14, 8, 12),
            child: Row(
              children: [
                TeamFace(name: name, picture: picture, size: 36),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                      if (address != null)
                        Text(address!,
                            key: const ValueKey('member-panel-address'),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
                      const SizedBox(height: 2),
                      Text(person.isMe ? '${l10n.orchardMemberYou} · $role' : role,
                          style: TextStyle(fontSize: 12, color: ZestTokens.textSecondary)),
                    ],
                  ),
                ),
                IconButton(
                  key: const ValueKey('member-panel-close'),
                  tooltip: l10n.close,
                  icon: Icon(LucideIcons.x, size: 16, color: ZestTokens.textSecondary),
                  onPressed: onClose,
                ),
              ],
            ),
          ),
          Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              children: [
                if (standing.isNotEmpty) ...[
                  const SizedBox(height: 14),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: [
                      for (final (label, kind, icon) in standing) ZestStatusPill(kind: kind, icon: icon, label: label),
                    ],
                  ),
                ],
                if (person.isMe) ...[
                  section(l10n.fpYourWords),
                  if (trust?.fingerprint != null) ...[
                    FingerprintBox(fingerprint: trust!.fingerprint!, key: const ValueKey('my-fingerprint')),
                    const SizedBox(height: 6),
                    Text(l10n.orchardYourFingerprintHelp,
                        style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textTertiary)),
                  ],
                ] else ...[
                  const SizedBox(height: 10),
                  line(l10n.memberPanelRole, role, act: _Act.role),
                  line(
                    l10n.memberPanelEnds,
                    ends == null ? l10n.memberPanelNever : accessThrough(ends, context),
                    act: _Act.endDate,
                  ),
                  if (vaultAccess != null) ...[
                    section(l10n.memberPanelCrates),
                    const SizedBox(height: 6),
                    vaultAccess!,
                  ],
                  section(l10n.memberPanelVerification),
                  if (status != null)
                    Container(
                      key: const ValueKey('member-panel-trust'),
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: ZestTokens.surfaceRaisedAlt,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(color: ZestTokens.borderSubtle),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          ZestStatusPill(kind: status.kind, icon: status.icon, label: status.label),
                          const SizedBox(height: 8),
                          Text(
                            _trustBody(trust, l10n),
                            style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textSecondary),
                          ),
                          if (acts.contains(_Act.check)) ...[
                            const SizedBox(height: 10),
                            teamButton(
                              key: const ValueKey('member-panel-check'),
                              icon: LucideIcons.fingerprint,
                              label: l10n.orchardCompareCodes,
                              onPressed: press(_Act.check),
                            ),
                          ],
                        ],
                      ),
                    ),
                  if (acts.contains(_Act.exposure)) ...[
                    const SizedBox(height: 8),
                    opens(_Act.exposure, LucideIcons.keyRound),
                  ],
                ],
                if (devices != null) ...[const SizedBox(height: 20), devices!],
                // What Suspend and Remove do, read with the rest: only the
                // buttons stay at the foot (before,
                // the words held there cut the page above them in half).
                if (acts.contains(_Act.suspend) || acts.contains(_Act.remove)) ...[
                  KeyedSubtree(
                      key: const ValueKey('member-panel-danger'), child: section(l10n.memberPanelDanger, danger: true)),
                  const SizedBox(height: 6),
                  Text(l10n.memberPanelDangerBody,
                      style: TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary)),
                ],
              ],
            ),
          ),
          if (acts.any((a) => _footerActs.contains(a))) ...[
            Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  // Suspend and Remove say what they do, as proper buttons
                  // their
                  // words are at the end of the panel above.
                  Row(
                    children: [
                      for (final (i, a) in _footerActs.where(acts.contains).indexed) ...[
                        if (i > 0) const SizedBox(width: 8),
                        Expanded(
                          child: teamButton(
                            key: ValueKey('member-panel-${a.name}'),
                            kind: a == _Act.remove || a == _Act.leave ? TeamButtonKind.danger : TeamButtonKind.secondary,
                            label: actLabel(a),
                            onPressed: press(a),
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// The actions in the panel's footer, in order: those that change who is
  /// in, and this account's own.
  static const _footerActs = [_Act.suspend, _Act.resume, _Act.remove, _Act.stepDown, _Act.leave];

  static String _trustBody(MemberView? m, AppLocalizations l10n) {
    if (m == null) return '';
    if (m.hardStop) return l10n.memberPanelHardStopBody;
    if (m.fingerprint == null) return l10n.memberPanelNoKeysBody;
    if (m.verifiedByMe) return l10n.memberPanelVerifiedBody;
    if (m.verifiedBy.isNotEmpty) return l10n.memberPanelOthersBody;
    if (m.replacedSinceCompared) return l10n.teamAttnKeysReplacedBody;
    return l10n.memberPanelNotVerifiedBody;
  }
}
