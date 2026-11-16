import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart' show RenderProxyBox;
import 'package:zestssh/features/orchards/certs/crate_authorities.dart' show CrateAuthorityView, crateAuthoritiesProvider;
import 'package:zestssh/features/orchards/widgets/vault_picker.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/rules/crate_offline.dart' show crateClosedOfflineText;
import 'package:zestssh/features/orchards/team/team_notices.dart' show accessTimeText;
import 'package:zestssh/features/orchards/widgets/crate_authority_view.dart';
import 'package:zestssh/features/orchards/widgets/crate_offline_limit_view.dart';
import 'package:zestssh/features/orchards/widgets/crate_records_view.dart';
import 'package:zestssh/features/orchards/team/team_providers.dart'
    show
        TeamPage,
        teamPageProvider,
        teamPeopleProvider,
        teamSessionLogCratesProvider,
        teamVaultPanelProvider,
        teamVaultToOpenProvider,
        teamWatchedCratesProvider;
import 'package:zestssh/features/orchards/widgets/vaults_page.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart' show CloudReach;
import 'package:zestssh/features/orchards/widgets/crate_session_logs_view.dart';
import 'package:zestssh/features/orchards/widgets/crate_watched_view.dart';
import 'package:zestssh/features/orchards/widgets/member_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart' show cloudReachStateProvider;
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart' show zestUsesSheets;
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/utils/logger.dart';
import 'package:zestssh/ui/widgets/dashed_rounded_border.dart';

// An Orchard's Crates (3.0): each one's name, whether only owners
// reach it, what it allows at all, whether it asks again before its secrets
// are shown, its certificate authority, its trash and changes,
// and this account's own access. Whoever manages a Crate
// renames it and sets what it allows and whether it asks again; an owner
// opens an owners-only Crate to admins and roles. Its settings are changes
// to who may do what, so they need a recent sign-in.
//
// Each Crate is a card (3.0): its name, one line of what it holds and
// this account's access, one status where it has one (closed here, about to
// close, open by a pass, certificates on) with one callout saying why, and
// its settings as rows grouped Access, Offline, Certificates, Records and
// Danger zone, each with its one control. A window opened from here (a
// question, the certificate settings, a pass) takes the screen while it is
// up ([CoverableWindow]).

/// The Crates screen of the Orchard [orchardId].
Future<void> showOrchardCrates(BuildContext context, WidgetRef ref, String orchardId) {
  final l10n = AppLocalizations.of(context)!;
  // No Close button: the window's own X (and on a phone the sheet's handle)
  // closes it.
  // A computer: a wider window, the vaults' list beside the vault shown,
  // which fills it and scrolls by itself (4.0); and
  // at its foot the way to the Team page's Vaults. A phone: its sheet, which
  // scrolls as one.
  final sheet = zestUsesSheets(context);
  final height = MediaQuery.sizeOf(context).height;
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: CoverableWindow(
      child: ZestDialogShell(
        tone: ZestDialogTone.info,
        icon: LucideIcons.package,
        title: l10n.orchardCrates,
        subtitle: l10n.orchardCratesSubtitle,
        maxWidth: 780,
        maxHeight: (height * 0.85).clamp(420.0, 760.0),
        bodyScrolls: sheet,
        body: OrchardCratesView(
          orchardId: orchardId,
          onOpenInTeam: sheet
              ? null
              : (crateId) {
                  Navigator.of(context).pop();
                  ref.read(teamVaultToOpenProvider.notifier).state = crateId;
                  ref.read(teamPageProvider.notifier).state = TeamPage.crates;
                  ref.read(activeSidebarNavProvider.notifier).state = NavSection.team;
                },
        ),
      ),
    ),
  );
}

class OrchardCratesView extends ConsumerStatefulWidget {
  const OrchardCratesView({super.key, required this.orchardId, this.pageLayout = false, this.onOpenInTeam});

  final String orchardId;

  /// The Vaults window on a computer: "Open in Team, Vaults" at its foot,
  /// which opens the Team page's Vaults on the vault shown.
  final void Function(String crateId)? onOpenInTeam;

  /// The Team page's Vaults on a computer: the vaults as a list, and the
  /// one clicked in a pane at the right (vaults_page.dart), scrolled by
  /// the view itself. Otherwise (a phone, the dialog) each vault is a card
  /// with its settings under it.
  final bool pageLayout;

  @override
  ConsumerState<OrchardCratesView> createState() => _OrchardCratesViewState();
}

class _OrchardCratesViewState extends ConsumerState<OrchardCratesView> {
  String? _busy;

  /// The vault the Vaults window shows (null: the first in the list).
  String? _selected;

  /// Its tab, kept from vault to vault.
  VaultTab _tab = VaultTab.access;

  /// The words in the search (shown once there are more vaults than a
  /// glance takes in).
  String _query = '';

  @override
  void initState() {
    super.initState();
    // A vault another page asked for (the Roles page's "Change in Vaults"):
    // its pane opens with the page.
    if (widget.pageLayout) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        final open = ref.read(teamVaultToOpenProvider);
        if (open == null) return;
        ref.read(teamVaultToOpenProvider.notifier).state = null;
        ref.read(teamVaultPanelProvider(widget.orchardId).notifier).state = open;
      });
    }
  }

  Future<void> _run(String crateId, Future<void> Function(OrchardService s) change, String done) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busy = crateId);
    try {
      final crate = ref
          .read(orchardSummariesProvider)
          .valueOrNull
          ?.where((o) => o.id == widget.orchardId)
          .firstOrNull
          ?.crates
          .where((c) => c.id == crateId)
          .firstOrNull;
      final summary = (
        what: l10n.stepUpCrate(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)),
        effects: const <String>[],
      );
      if (!await overWindow(context,
              () => withRecentSignIn(context, ref, () => change(ref.read(orchardServiceProvider)), summary: summary)) ||
          !mounted) {
        return;
      }
      showTopSnackBar(context, done, isSuccess: true);
      ref.read(orchardListVersionProvider.notifier).state++;
    } catch (e) {
      AppLogger.warning('Orchard Crates: a change was not made ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = null);
    }
  }

  Future<void> _rename(CrateSummary crate) async {
    final l10n = AppLocalizations.of(context)!;
    final name = await overWindow(
      context,
      () => showZestInputDialog(
        context: context,
        title: l10n.crateRenameTitle(crateDisplayName(crate, l10n)),
        icon: LucideIcons.pencil,
        fieldLabel: l10n.crateNewNameLabel,
        initialValue: crate.name ?? '',
        confirmLabel: l10n.crateRenameConfirm,
        maxLength: kSpaceNameMaxChars,
        validator: (v) => v.trim().isEmpty ? l10n.manageTreeEnterAName : null,
        onConfirm: (value) async {
          try {
            await ref.read(orchardServiceProvider).renameCrate(widget.orchardId, crate.id, value);
            return null;
          } catch (e) {
            AppLogger.warning('Orchard Crates: renaming failed ($e)');
            return orchardChangeErrorMessage(e, l10n);
          }
        },
      ),
    );
    if (name == null || !mounted) return;
    ref.read(orchardListVersionProvider.notifier).state++;
    showTopSnackBar(context, l10n.crateRenamed(name.trim()), isSuccess: true);
  }

  Future<void> _openUp(CrateSummary crate) async {
    final l10n = AppLocalizations.of(context)!;
    final name = crateDisplayName(crate, l10n);
    final ok = await overWindow(
      context,
      () => ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.warning,
        title: l10n.crateOpenToAllTitle(name),
        body: l10n.crateOpenToAllLead,
        warning: l10n.crateOpenToAllWarning,
        confirmLabel: l10n.crateOpenToAllConfirm,
      ),
    );
    if (ok != true || !mounted) return;
    await _run(crate.id, (s) => s.openCrateToAll(widget.orchardId, crate.id), l10n.orchardChangeSaved);
  }

  @override
  Widget build(BuildContext context) {
    final orchard = ref
        .watch(orchardSummariesProvider)
        .valueOrNull
        ?.where((o) => o.id == widget.orchardId)
        .firstOrNull;
    if (orchard == null) return const SizedBox.shrink();
    // A watched Crate allows the terminal only: what it allows is not
    // offered for changing while it is watched.
    final watched = ref.watch(teamWatchedCratesProvider(orchard.id)).valueOrNull ?? const <String>{};
    // What is said of a Crate its own offline limit has closed here follows
    // what is known of the service (said anew when that changes).
    final reach = orchard.crates.any((c) => c.closedOffline)
        ? ref.watch(cloudReachStateProvider).valueOrNull?.reach
        : null;
    // Which hand out certificates: said in their headers.
    final authorities = ref.watch(crateAuthoritiesProvider(orchard.id)).valueOrNull;
    final counts = vaultHostCounts(ref, orchard);
    if (widget.pageLayout) return _page(orchard, watched: watched, reach: reach, authorities: authorities, counts: counts);
    return _vaults(orchard, watched: watched, reach: reach, authorities: authorities, counts: counts);
  }

  /// The Vaults window, and a phone's Team, Vaults page (4.0):
  /// the vaults in a
  /// list at the left (a phone: a picker over the page), one vault at a time
  /// at the right with its name, hosts and this account's access always in
  /// sight, and its settings under four tabs, Access, Offline, Certificates
  /// and Records. Every setting, who may change it and what a closed vault
  /// says are as they were; only where they stand changed. (It was every
  /// setting of every vault in one scroll.)
  Widget _vaults(
    OrchardSummary orchard, {
    required Set<String> watched,
    required CloudReach? reach,
    required Map<String, CrateAuthorityView>? authorities,
    required Map<String, int> counts,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final all = vaultsInOrder(orchard.crates);
    if (all.isEmpty) return const SizedBox.shrink();
    final crate = all.where((c) => c.id == _selected).firstOrNull ?? all.first;
    final q = _query.trim().toLowerCase();
    final listed = [
      for (final c in all)
        if (q.isEmpty || crateDisplayName(c, l10n).toLowerCase().contains(q) || c.id == crate.id) c,
    ];
    final many = all.length > 7;
    final phone = vaultOnPhone(context);
    final addVault = orchard.canAddCrates && orchard.active
        ? () => overWindow(context, () => showNewCrateDialog(context, ref, orchard.id))
        : null;
    final manage = crate.allows(CrateSwitches.manage) && orchard.active && _busy == null;
    final closedText =
        crate.closedOffline ? crateClosedOfflineText(l10n, crateDisplayName(crate, l10n), reach) : null;
    final detail = _VaultDetail(
      key: ValueKey('vault-detail-${crate.id}'),
      crate: crate,
      hostCount: counts[crate.id] ?? 0,
      tab: _tab,
      onTab: (t) => setState(() => _tab = t),
      onShowHosts: () {
        showVaultHosts(ref, crate);
        ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
      },
      closedText: closedText,
      certsOn: !crate.closedOffline && (authorities?[crate.id]?.on ?? false),
      watched: watched.contains(crate.id),
      busy: _busy == crate.id,
      // Changing a vault needs Manage on it; lifting owners-only is an
      // owner's call.
      onRename: manage ? () => _rename(crate) : null,
      onAllow: manage
          ? (allow) => _run(crate.id, (s) => s.setCrateAllow(widget.orchardId, crate.id, allow), l10n.orchardChangeSaved)
          : null,
      onOpenUp: crate.ownersOnly && orchard.isOwner && orchard.active && _busy == null ? () => _openUp(crate) : null,
      onConfirmReveal: manage
          ? (on) => _run(crate.id, (s) => s.setCrateConfirmReveal(widget.orchardId, crate.id, on), l10n.orchardChangeSaved)
          : null,
      // Its own offline limit: the owners' choice, and what everyone else is
      // told (also while it is closed, when it is only said).
      offlineLimit: CrateOfflineLimitLine(orchard: orchard, crate: crate),
      // A vault that is closed on this device offers nothing of its own to
      // look into or to set up until it is open again.
      certificates: crate.closedOffline ? null : CrateCertificatesLine(orchard: orchard, crate: crate),
      records: crate.closedOffline ? null : CrateRecordsLine(orchard: orchard, crate: crate),
      sessionLogs: crate.closedOffline ? null : CrateSessionLogsLine(orchard: orchard, crate: crate),
      watchedLine: crate.closedOffline ? null : CrateWatchedLine(orchard: orchard, crate: crate),
    );
    final openInTeam = widget.onOpenInTeam;
    final link = openInTeam == null
        ? null
        : Align(
            alignment: AlignmentDirectional.centerStart,
            child: TextButton(
              key: const ValueKey('vaults-open-in-team'),
              onPressed: () => openInTeam(crate.id),
              style: TextButton.styleFrom(
                foregroundColor: ZestTokens.textSecondary,
                padding: const EdgeInsets.symmetric(horizontal: 6),
                minimumSize: const Size(0, 30),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(l10n.vaultsOpenInTeam, style: const TextStyle(fontSize: 13)),
                  const SizedBox(width: 7),
                  Icon(LucideIcons.arrowRight, size: 14, color: ZestTokens.textTertiary),
                ],
              ),
            ),
          );

    if (phone) {
      // A phone: which vault, as a picker over the page; the vault under it.
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestSelect<String>(
            key: const ValueKey('vault-picker'),
            value: crate.id,
            large: true,
            items: [
              for (final c in all)
                ZestSelectItem(
                  c.id,
                  [
                    crateDisplayName(c, l10n),
                    if (c.ownersOnly) l10n.crateOwnersOnly,
                    l10n.hostsMetaHostCount(counts[c.id] ?? 0),
                  ].join(' · '),
                ),
            ],
            onChanged: (id) => setState(() => _selected = id),
          ),
          const SizedBox(height: 14),
          detail,
          if (addVault != null) ...[
            const SizedBox(height: 16),
            Align(
              alignment: AlignmentDirectional.centerStart,
              child: vaultButton(context,
                  key: const ValueKey('crate-new'), onPressed: addVault, icon: LucideIcons.plus, label: l10n.crateNewAction),
            ),
          ],
          if (link != null) ...[const SizedBox(height: 12), link],
        ],
      );
    }

    final rail = Container(
      width: 188,
      decoration: BoxDecoration(
        color: ZestTokens.surfacePanel,
        border: BorderDirectional(end: BorderSide(color: ZestTokens.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (many)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 0),
              child: SizedBox(
                height: 34,
                child: TextField(
                  key: const ValueKey('crate-search'),
                  onChanged: (v) => setState(() => _query = v),
                  style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                  decoration: InputDecoration(
                    isDense: true,
                    hintText: l10n.vaultPickerSearch,
                    prefixIcon: const Icon(LucideIcons.search, size: 14),
                    prefixIconConstraints: const BoxConstraints(minWidth: 34),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                  ),
                ),
              ),
            ),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.fromLTRB(10, 12, 10, 12),
              children: [
                for (final c in listed)
                  _VaultRailItem(
                    key: ValueKey('vault-item-${c.id}'),
                    crate: c,
                    hosts: counts[c.id] ?? 0,
                    selected: c.id == crate.id,
                    onTap: () => setState(() => _selected = c.id),
                  ),
              ],
            ),
          ),
          if (addVault != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 12),
              child: _NewVaultButton(onPressed: addVault),
            ),
        ],
      ),
    );
    final layout = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Expanded(
          child: Container(
            clipBehavior: Clip.antiAlias,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: ZestTokens.borderSubtle),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [rail, Expanded(child: SingleChildScrollView(child: detail))],
            ),
          ),
        ),
        if (link != null) ...[const SizedBox(height: 10), link],
      ],
    );
    // In the window it fills the height it is given; where nothing gives one
    // (a tablet's page that scrolls), a height of its own.
    return LayoutBuilder(
      builder: (context, box) => box.hasBoundedHeight ? layout : SizedBox(height: 640, child: layout),
    );
  }

  /// The Vaults page on a computer: the list, and the pane of the vault
  /// clicked. New vault is the page header's.
  Widget _page(
    OrchardSummary orchard, {
    required Set<String> watched,
    required CloudReach? reach,
    required Map<String, CrateAuthorityView>? authorities,
    required Map<String, int> counts,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final people = ref.watch(teamPeopleProvider(orchard.id)).valueOrNull;
    final timed = ref.watch(timedAccessProvider(orchard.id)).valueOrNull ?? const <TimedAccess>[];
    final logged = ref.watch(teamSessionLogCratesProvider(orchard.id)).valueOrNull ?? const <String>{};
    final selectedId = ref.watch(teamVaultPanelProvider(orchard.id));
    // One that is gone (deleted elsewhere, no longer open to this account):
    // no pane.
    final selected = orchard.crates.where((c) => c.id == selectedId).firstOrNull;
    void select(String? id) => ref.read(teamVaultPanelProvider(orchard.id).notifier).state = id;
    String nameOf(String uid) => people == null ? '' : vaultPersonName(ref, people, uid);
    VaultAccess? accessOf(CrateSummary c) => people == null ? null : VaultAccess.of(c, people, timed, l10n);
    String? closedTextOf(CrateSummary c) =>
        c.closedOffline ? crateClosedOfflineText(l10n, crateDisplayName(c, l10n), reach) : null;

    final q = _query.trim().toLowerCase();
    final shown = [
      for (final c in vaultsInOrder(orchard.crates))
        if (q.isEmpty || crateDisplayName(c, l10n).toLowerCase().contains(q)) c,
    ];
    List<Widget> marks(CrateSummary c) {
      final isWatched = watched.contains(c.id);
      return [
        if (c.ownersOnly) VaultMark(label: l10n.crateOwnersOnly, icon: LucideIcons.lock),
        if (!c.closedOffline && (authorities?[c.id]?.on ?? false))
          VaultMark(
              key: ValueKey('vault-mark-certs-${c.id}'),
              label: l10n.vaultUiGroupCertificates,
              icon: LucideIcons.shieldCheck,
              strong: true),
        if (logged.contains(c.id)) VaultMark(label: l10n.crateSessionLogs),
        if (isWatched) VaultMark(label: l10n.crateWatchedOnNote, icon: LucideIcons.eye),
        if (c.confirmReveal) VaultMark(label: l10n.vaultsChipAsksBeforeRevealing),
        if (!isWatched)
          for (final (what, label) in [
            (CrateSwitches.sftp, l10n.crateAllowSftp),
            (CrateSwitches.forward, l10n.crateAllowForward),
            (CrateSwitches.agent, l10n.crateAllowAgent),
          ])
            if (c.allow.contains(what)) VaultMark(label: label),
      ];
    }

    final list = SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(28, 4, 28, 28),
      child: Align(
        alignment: Alignment.topLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 860),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              if (orchard.crates.length > 7) ...[
                SizedBox(
                  height: 34,
                  child: TextField(
                    key: const ValueKey('crate-search'),
                    onChanged: (v) => setState(() => _query = v),
                    style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary),
                    decoration: InputDecoration(
                      isDense: true,
                      hintText: l10n.vaultPickerSearch,
                      prefixIcon: const Icon(LucideIcons.search, size: 14),
                      prefixIconConstraints: const BoxConstraints(minWidth: 34),
                      contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    ),
                  ),
                ),
                const SizedBox(height: 12),
              ],
              for (final c in shown)
                VaultCard(
                  key: ValueKey('vault-card-${c.id}'),
                  crate: c,
                  line: vaultCardLine(c, hosts: counts[c.id] ?? 0, access: accessOf(c), nameOf: nameOf, l10n: l10n),
                  marks: marks(c),
                  status: vaultStatus(c, l10n, closedText: closedTextOf(c)),
                  selected: c.id == selected?.id,
                  onTap: () => select(c.id == selected?.id ? null : c.id),
                ),
              if (orchard.crates.any((c) => c.ownersOnly)) ...[
                const SizedBox(height: 6),
                Text(l10n.vaultsOwnersOnlyNote,
                    key: const ValueKey('vaults-owners-only-note'),
                    style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary)),
              ],
            ],
          ),
        ),
      ),
    );
    final crate = selected;
    if (crate == null) return list;
    // Changing a vault needs Manage on it; lifting owners-only is an
    // owner's call (as on its card).
    final manage = crate.allows(CrateSwitches.manage) && orchard.active;
    final closedText = closedTextOf(crate);
    // Beside the list where the page has room for both, in its place where
    // it has not (its close brings the list back).
    return TeamListAndPanel(
      panelWidth: kVaultPaneWidth,
      list: list,
      panel: VaultPane(
          key: ValueKey('vault-pane-of-${crate.id}'),
          orchard: orchard,
          crate: crate,
          hosts: counts[crate.id] ?? 0,
          people: people,
          access: accessOf(crate),
          busy: _busy != null,
          watched: watched.contains(crate.id),
          onClose: () => select(null),
          onShowHosts: () {
            showVaultHosts(ref, crate);
            ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
          },
          actions: VaultPaneActions(
            onRename: manage ? () => _rename(crate) : null,
            onAllow: manage
                ? (allow) => _run(crate.id, (s) => s.setCrateAllow(widget.orchardId, crate.id, allow),
                    l10n.orchardChangeSaved)
                : null,
            onConfirmReveal: manage
                ? (on) => _run(crate.id, (s) => s.setCrateConfirmReveal(widget.orchardId, crate.id, on),
                    l10n.orchardChangeSaved)
                : null,
            onOpenUp: crate.ownersOnly && orchard.isOwner && orchard.active ? () => _openUp(crate) : null,
            // Each role's level in it is set on the Roles page (owners).
            onEditRoles: orchard.isOwner && orchard.active
                ? () => ref.read(teamPageProvider.notifier).state = TeamPage.roles
                : null,
          ),
          callout: vaultCallout(crate, l10n, closedText: closedText),
          offlineLimit: CrateOfflineLimitLine(orchard: orchard, crate: crate),
          certificates: crate.closedOffline ? null : CrateCertificatesLine(orchard: orchard, crate: crate, pane: true),
          records: crate.closedOffline ? null : CrateRecordsLine(orchard: orchard, crate: crate),
          sessionLogs: crate.closedOffline ? null : CrateSessionLogsLine(orchard: orchard, crate: crate),
          watchedLine: crate.closedOffline ? null : CrateWatchedLine(orchard: orchard, crate: crate),
        ),
    );
  }
}

/// A vault's one status, the most pressing first: closed here
/// ([closedText] says why), about to close, open by a pass, handing out
/// certificates ([certsOn]); none otherwise.
(ZestStatusKind, String)? vaultStatus(CrateSummary crate, AppLocalizations l10n,
    {String? closedText, bool certsOn = false}) {
  if (closedText != null) return (ZestStatusKind.critical, l10n.vaultUiStatusClosed);
  if (crate.closesAt != null) return (ZestStatusKind.warning, l10n.vaultUiStatusClosesSoon);
  if (crate.passUntil != null) return (ZestStatusKind.healthy, l10n.vaultUiStatusPass);
  if (certsOn) return (ZestStatusKind.neutral, l10n.vaultUiStatusCertsOn);
  return null;
}

/// The one explanation of a vault's status: what closed it here
/// ([closedText]), when it closes, until when a pass holds it open.
Widget? vaultCallout(CrateSummary crate, AppLocalizations l10n, {String? closedText}) {
  if (closedText != null) {
    return VaultCallout(
      kind: ZestStatusKind.critical,
      icon: LucideIcons.wifiOff,
      text: closedText,
      textKey: ValueKey('crate-closed-${crate.id}'),
    );
  }
  // About to close on this device by its own offline limit: when. (Never
  // while it is closed: what has closed is not about to.)
  if (crate.closesAt case final at?) {
    return VaultCallout(
      key: ValueKey('crate-closing-${crate.id}'),
      kind: ZestStatusKind.warning,
      icon: LucideIcons.timer,
      text: l10n.crateClosesAt(accessTimeText(at, l10n)),
    );
  }
  // Open here by a pass an owner signed: until when.
  if (crate.passUntil case final until?) {
    return VaultCallout(
      key: ValueKey('crate-pass-${crate.id}'),
      kind: ZestStatusKind.healthy,
      icon: LucideIcons.badgeCheck,
      text: l10n.cratePassHolds(accessTimeText(until, l10n)),
    );
  }
  return null;
}

/// The Vaults window's tabs for a vault's settings.
enum VaultTab { access, offline, certificates, records }

/// A vault in the Vaults window's list: its mark, its name and its hosts
/// (and that only owners open it). The one shown at the right is marked, by
/// its weight and its mark as well as its colour.
class _VaultRailItem extends StatefulWidget {
  const _VaultRailItem({super.key, required this.crate, required this.hosts, required this.selected, required this.onTap});

  final CrateSummary crate;
  final int hosts;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_VaultRailItem> createState() => _VaultRailItemState();
}

class _VaultRailItemState extends State<_VaultRailItem> {
  bool _hover = false;
  bool _focus = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final crate = widget.crate;
    final on = widget.selected;
    final sub = [
      if (crate.ownersOnly) l10n.crateOwnersOnly,
      l10n.hostsMetaHostCount(widget.hosts),
    ].join(' · ');
    return Semantics(
      button: true,
      selected: on,
      child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowHoverHighlight: (h) => setState(() => _hover = h),
        onShowFocusHighlight: (f) => setState(() => _focus = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 2),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: on
                  ? ZestTokens.brandFill
                  : _hover
                      ? ZestTokens.surfaceRaisedAlt
                      : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
              border: Border.all(color: _focus ? ZestTokens.brandInk : Colors.transparent, width: 1.5),
            ),
            child: Row(
              children: [
                Icon(crate.ownersOnly ? LucideIcons.lock : LucideIcons.package,
                    size: 16, color: on ? ZestTokens.brandInk : ZestTokens.textFaint),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(crateDisplayName(crate, l10n),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13.5,
                            height: 1.3,
                            fontWeight: on ? FontWeight.w600 : FontWeight.w500,
                            color: on ? ZestTokens.brandInk : ZestTokens.textPrimary,
                          )),
                      Text(sub,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary)),
                    ],
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

/// New vault, at the foot of the Vaults window's list: a dashed outline.
class _NewVaultButton extends StatelessWidget {
  const _NewVaultButton({required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Semantics(
      button: true,
      child: InkWell(
        key: const ValueKey('crate-new'),
        onTap: onPressed,
        borderRadius: BorderRadius.circular(9),
        child: Container(
          height: 36,
          decoration: DashedRoundedBorder(color: ZestTokens.borderStrong, radius: 9),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(LucideIcons.plus, size: 15, color: ZestTokens.textSecondary),
              const SizedBox(width: 7),
              Flexible(
                child: Text(l10n.crateNewAction,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: ZestTokens.textSecondary)),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// One vault in the Vaults window: its name, hosts and this account's
/// access (and its one status) at the top, always in sight; its tabs; the
/// settings of the tab chosen.
class _VaultDetail extends StatelessWidget {
  const _VaultDetail({
    super.key,
    required this.crate,
    required this.hostCount,
    required this.tab,
    required this.onTab,
    required this.onShowHosts,
    required this.busy,
    required this.onRename,
    required this.onAllow,
    required this.onOpenUp,
    this.onConfirmReveal,
    this.offlineLimit,
    this.certificates,
    this.records,
    this.sessionLogs,
    this.watchedLine,
    this.watched = false,
    this.certsOn = false,
    this.closedText,
  });

  final CrateSummary crate;
  final int hostCount;
  final VaultTab tab;
  final ValueChanged<VaultTab> onTab;
  final VoidCallback onShowHosts;
  final String? closedText;
  final bool watched;
  final bool certsOn;
  final bool busy;
  final VoidCallback? onRename;
  final ValueChanged<Set<String>>? onAllow;
  final VoidCallback? onOpenUp;
  final ValueChanged<bool>? onConfirmReveal;
  final Widget? offlineLimit;
  final Widget? certificates;
  final Widget? records;
  final Widget? sessionLogs;
  final Widget? watchedLine;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final phone = vaultOnPhone(context);
    final level = levelOf(crate.switches);
    final status = vaultStatus(crate, l10n, closedText: closedText, certsOn: certsOn);
    final callout = vaultCallout(crate, l10n, closedText: closedText);
    final target = phone ? 44.0 : 32.0;
    final subtitle = [
      l10n.hostsMetaHostCount(hostCount),
      // Closed on this device, it allows nothing just now: that is said,
      // not a level it does not have.
      if (closedText != null)
        l10n.orchardClosedOfflineShort
      else
        l10n.crateYourAccess(level == null ? l10n.crateLevelCustom : crateLevelName(level, l10n)),
      if (crate.ownersOnly) l10n.crateOwnersOnly,
    ].join(' · ');
    final onRename = this.onRename;
    final head = Padding(
      padding: EdgeInsetsDirectional.fromSTEB(phone ? 0 : 22, phone ? 0 : 16, phone ? 0 : 16, 14),
      child: Row(
        children: [
          VaultTile(crate: crate, size: 36),
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
                    Text(crateDisplayName(crate, l10n),
                        key: ValueKey('vault-detail-name-${crate.id}'),
                        style: TextStyle(fontSize: 16, height: 1.3, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary)),
                    if (status != null)
                      ZestStatusPill(key: ValueKey('crate-status-${crate.id}'), kind: status.$1, label: status.$2),
                  ],
                ),
                const SizedBox(height: 1),
                Text(subtitle,
                    key: ValueKey('vault-detail-line-${crate.id}'),
                    style: TextStyle(fontSize: 12.5, height: 1.35, color: ZestTokens.textTertiary)),
              ],
            ),
          ),
          if (busy) ...[
            const SizedBox(width: 8),
            const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 1.6)),
          ],
          const SizedBox(width: 8),
          // Show its hosts and Rename, in its menu.
          MenuAnchor(
            alignmentOffset: const Offset(0, 4),
            menuChildren: [
              MenuItemButton(
                key: ValueKey('crate-show-hosts-${crate.id}'),
                leadingIcon: const Icon(LucideIcons.server, size: 16),
                style: MenuItemButton.styleFrom(minimumSize: Size(0, target)),
                onPressed: onShowHosts,
                child: Text(l10n.vaultShowHosts),
              ),
              if (onRename != null)
                MenuItemButton(
                  key: ValueKey('crate-rename-${crate.id}'),
                  leadingIcon: const Icon(LucideIcons.pencil, size: 16),
                  style: MenuItemButton.styleFrom(minimumSize: Size(0, target)),
                  onPressed: busy ? null : onRename,
                  child: Text(l10n.crateRenameConfirm),
                ),
            ],
            builder: (context, menu, _) => IconButton(
              key: ValueKey('crate-more-${crate.id}'),
              icon: const Icon(LucideIcons.moreHorizontal, size: 18),
              tooltip: l10n.vaultUiMore,
              style: IconButton.styleFrom(
                side: BorderSide(color: ZestTokens.border),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
              ),
              constraints: BoxConstraints.tightFor(width: target, height: target),
              padding: EdgeInsets.zero,
              onPressed: () => menu.isOpen ? menu.close() : menu.open(),
            ),
          ),
        ],
      ),
    );

    final tabs = [
      (VaultTab.access, l10n.vaultUiGroupAccess),
      (VaultTab.offline, l10n.vaultUiGroupOffline),
      (VaultTab.certificates, l10n.vaultUiGroupCertificates),
      (VaultTab.records, l10n.vaultUiGroupRecords),
    ];
    final tabBar = Container(
      decoration: BoxDecoration(border: Border(bottom: BorderSide(color: ZestTokens.borderSubtle))),
      padding: EdgeInsetsDirectional.only(start: phone ? 0 : 14, end: phone ? 0 : 16),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (final (t, label) in tabs)
              _VaultTabButton(
                key: ValueKey('vault-tab-${t.name}'),
                label: label,
                selected: t == tab,
                height: phone ? 48 : 38,
                onTap: () => onTab(t),
              ),
          ],
        ),
      ),
    );

    final pane = switch (tab) {
      VaultTab.access => _access(context, l10n),
      VaultTab.offline => [?offlineLimit],
      VaultTab.certificates => [?certificates],
      VaultTab.records => [?sessionLogs, ?records],
    };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        head,
        if (callout != null)
          Padding(
            padding: EdgeInsetsDirectional.fromSTEB(phone ? 0 : 22, 0, phone ? 0 : 16, 14),
            child: callout,
          ),
        tabBar,
        Padding(
          padding: phone ? const EdgeInsets.only(top: 16) : const EdgeInsets.fromLTRB(22, 18, 22, 20),
          child: VaultSettingsLayout(
            // The tab says what its groups are.
            hiddenTitles: {
              l10n.vaultUiGroupOffline,
              l10n.vaultUiGroupCertificates,
              l10n.vaultUiGroupRecords,
            },
            child: _OrNothing(
              key: ValueKey('vault-pane-${crate.id}-${tab.name}'),
              empty: Text(l10n.vaultTabEmpty,
                  key: ValueKey('vault-tab-empty-${crate.id}'),
                  style: TextStyle(fontSize: 12.5, height: 1.45, color: ZestTokens.textTertiary)),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                mainAxisSize: MainAxisSize.min,
                children: pane,
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// Access: what may be used on its hosts besides the terminal, a row each
  /// with its switch; then its protection; then, for an owner, opening an
  /// owners-only vault to the team.
  List<Widget> _access(BuildContext context, AppLocalizations l10n) {
    // Someone who does not manage it reads its settings, at full contrast,
    // with nothing that looks like a control. (A closed one is still the
    // manager's: its controls are only off until it opens again.)
    final readOnly = !crate.allows(CrateSwitches.manage) && !crate.closedOffline;
    final onAllow = this.onAllow;
    final onConfirmReveal = this.onConfirmReveal;
    final items = [
      (CrateSwitches.sftp, LucideIcons.folder, l10n.crateAllowSftp, l10n.vaultsAllowSftpHelp),
      (CrateSwitches.forward, LucideIcons.arrowLeftRight, l10n.crateAllowForward, l10n.vaultsAllowForwardHelp),
      (CrateSwitches.agent, LucideIcons.keyRound, l10n.crateAllowAgent, l10n.vaultsAllowAgentHelp),
    ];
    Widget state(bool on, {Key? key}) => ZestStatusPill(
          key: key,
          kind: on ? ZestStatusKind.healthy : ZestStatusKind.neutral,
          label: on ? l10n.vaultUiStateOn : l10n.vaultUiStateOff,
        );
    return [
      _GroupHead(title: l10n.vaultUiAllowedLabel, first: true),
      Text(
        watched ? l10n.crateWatchedTerminalOnly : l10n.vaultUiAllowedHelp,
        key: watched ? ValueKey('crate-terminal-only-${crate.id}') : null,
        style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textTertiary),
      ),
      const SizedBox(height: 10),
      _RowsCard(
        key: ValueKey('vault-allowed-${crate.id}'),
        rows: [
          for (final (what, icon, label, help) in items)
            _SwitchRow(
              icon: icon,
              label: label,
              help: help,
              control: readOnly
                  ? state(crate.allow.contains(what) && !watched, key: ValueKey('crate-allow-state-${crate.id}-$what'))
                  : ZestSwitch(
                      key: ValueKey('crate-allow-${crate.id}-$what'),
                      // A watched vault allows the terminal only: off, and
                      // not to be changed while it is watched.
                      value: crate.allow.contains(what) && !watched,
                      onChanged: onAllow == null || busy || watched
                          ? null
                          : (v) => onAllow({
                                ...crate.allow.where((s) => s != what),
                                if (v) what,
                              }),
                    ),
            ),
        ],
      ),
      _GroupHead(title: l10n.keysUiSectionProtection),
      Container(
        key: ValueKey('vault-protection-${crate.id}'),
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        decoration: BoxDecoration(
          color: ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: ZestTokens.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
          VaultSettingRow(
            label: l10n.crateConfirmReveal,
            helper: l10n.crateConfirmRevealBody,
            helperKey: ValueKey('crate-confirm-reveal-help-${crate.id}'),
            compact: true,
            control: readOnly
                ? state(crate.confirmReveal)
                : ZestSwitch(
                    key: ValueKey('crate-confirm-reveal-${crate.id}'),
                    value: crate.confirmReveal,
                    onChanged: onConfirmReveal == null || busy ? null : onConfirmReveal,
                  ),
          ),
          ?watchedLine,
          ],
        ),
      ),
      if (onOpenUp case final onOpenUp?)
        VaultSettingGroup(
          title: l10n.vaultUiGroupDanger,
          rows: [
            VaultSettingRow(
              label: l10n.crateOpenToAll,
              helper: l10n.crateOpenToAllBody,
              // What a danger does is said whole.
              full: true,
              control: vaultButton(
                context,
                key: ValueKey('crate-open-${crate.id}'),
                label: l10n.vaultUiOpenUp,
                icon: LucideIcons.unlock,
                variant: ZestButtonVariant.danger,
                onPressed: busy ? null : onOpenUp,
              ),
            ),
          ],
        ),
    ];
  }
}

/// A group's name in a tab (plain).
class _GroupHead extends StatelessWidget {
  const _GroupHead({required this.title, this.first = false});

  final String title;
  final bool first;

  @override
  Widget build(BuildContext context) => Padding(
        padding: EdgeInsets.only(top: first ? 0 : 22, bottom: first ? 6 : 10),
        child: Semantics(
          header: true,
          child: Text(
            title.toUpperCase(),
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              letterSpacing: 1.4,
              height: 1,
              color: ZestTokens.textFaint,
            ),
          ),
        ),
      );
}

/// Rows in one bordered card, a hairline between them.
class _RowsCard extends StatelessWidget {
  const _RowsCard({super.key, required this.rows});

  final List<Widget> rows;

  @override
  Widget build(BuildContext context) {
    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: ZestTokens.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (i, row) in rows.indexed) ...[
            if (i > 0) Divider(height: 1, thickness: 1, color: ZestTokens.borderSubtle),
            row,
          ],
        ],
      ),
    );
  }
}

/// One of what a vault allows: its icon, its name, one line of what it is,
/// and its switch (or its state, for someone who does not manage it).
class _SwitchRow extends StatelessWidget {
  const _SwitchRow({required this.icon, required this.label, required this.help, required this.control});

  final IconData icon;
  final String label;
  final String help;
  final Widget control;

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(minHeight: 58),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
        child: Row(
          children: [
            Container(
              width: 32,
              height: 32,
              decoration: BoxDecoration(
                color: ZestTokens.surfaceChip,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(icon, size: 16, color: ZestTokens.textSecondary),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(label,
                      style: TextStyle(fontSize: 13.5, height: 1.3, fontWeight: FontWeight.w500, color: ZestTokens.textPrimary)),
                  Text(help, style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textTertiary)),
                ],
              ),
            ),
            const SizedBox(width: 12),
            control,
          ],
        ),
      ),
    );
  }
}

/// One of a vault's tabs: its name, the chosen one in full ink with a bar
/// under it (said as selected too).
class _VaultTabButton extends StatelessWidget {
  const _VaultTabButton(
      {super.key, required this.label, required this.selected, required this.height, required this.onTap});

  final String label;
  final bool selected;
  final double height;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: true,
      selected: selected,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: height,
          padding: const EdgeInsets.symmetric(horizontal: 9),
          decoration: BoxDecoration(
            border: Border(
              bottom: BorderSide(color: selected ? ZestTokens.brand : Colors.transparent, width: 2),
            ),
          ),
          alignment: Alignment.center,
          child: Text(
            label,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              color: selected ? ZestTokens.textPrimary : ZestTokens.textSecondary,
            ),
          ),
        ),
      ),
    );
  }
}

/// [child], or [empty] in its place where [child] draws nothing (a tab whose
/// settings are not this account's, a vault closed here).
class _OrNothing extends StatefulWidget {
  const _OrNothing({super.key, required this.child, required this.empty});

  final Widget child;
  final Widget empty;

  @override
  State<_OrNothing> createState() => _OrNothingState();
}

class _OrNothingState extends State<_OrNothing> {
  bool _empty = false;

  void _measured(Size size) {
    final empty = size.height < 1;
    if (empty != _empty && mounted) setState(() => _empty = empty);
  }

  @override
  Widget build(BuildContext context) {
    // The child stays in the tree (and so keeps its state and its reads);
    // only nothing of it is drawn, and [empty] stands in.
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: [
        _SizeWatch(onSize: _measured, child: widget.child),
        if (_empty) widget.empty,
      ],
    );
  }
}

/// Says the size its child was laid out at, after the frame.
class _SizeWatch extends SingleChildRenderObjectWidget {
  const _SizeWatch({required this.onSize, required super.child});

  final ValueChanged<Size> onSize;

  @override
  RenderObject createRenderObject(BuildContext context) => _RenderSizeWatch(onSize);

  @override
  void updateRenderObject(BuildContext context, _RenderSizeWatch renderObject) => renderObject.onSize = onSize;
}

class _RenderSizeWatch extends RenderProxyBox {
  _RenderSizeWatch(this.onSize);

  ValueChanged<Size> onSize;
  Size? _last;

  @override
  void performLayout() {
    super.performLayout();
    if (size == _last) return;
    _last = size;
    final now = size;
    WidgetsBinding.instance.addPostFrameCallback((_) => onSize(now));
  }
}
