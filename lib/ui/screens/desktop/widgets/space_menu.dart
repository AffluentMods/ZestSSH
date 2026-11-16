import 'dart:async';

import 'package:flutter/foundation.dart' show TargetPlatform, defaultTargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/orchards/sync/crate_server.dart' show MyInvite;
import 'package:zestssh/features/orchards/team/team_providers.dart';
import 'package:zestssh/features/orchards/widgets/join_team.dart';
import 'package:zestssh/features/orchards/widgets/orchard_invites.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/providers/sync_health_provider.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/profile/account_switch.dart';
import 'package:zestssh/ui/screens/purchase/plan_popover.dart' show PlanChip;
import 'package:zestssh/ui/screens/tree/manage_tree_screen.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/utils/logger.dart';

/// How many spaces show a filter.
const kSpaceFilterFrom = 6;

/// The space switcher on a computer: the account at the top with how it
/// syncs, this computer's accounts, then one list of spaces, the invitations among them,
/// and New team and Join with code at the foot. Sign out is the account row's.
Future<void> showSpaceMenu(
  BuildContext context,
  WidgetRef ref, {
  required String treeName,
  required int hostCount,
}) async {
  final anchor = rectOf(context);
  if (anchor == null) return;
  await showAnchoredPanel<void>(
    context,
    anchor: anchor,
    width: 340,
    label: AppLocalizations.of(context)!.spaceMenuLabel,
    child: _SpaceMenu(outer: context, outerRef: ref, treeName: treeName, hostCount: hostCount),
  );
}

class _SpaceMenu extends ConsumerStatefulWidget {
  const _SpaceMenu({required this.outer, required this.outerRef, required this.treeName, required this.hostCount});

  final BuildContext outer;
  final WidgetRef outerRef;
  final String treeName;
  final int hostCount;

  @override
  ConsumerState<_SpaceMenu> createState() => _SpaceMenuState();
}

class _SpaceMenuState extends ConsumerState<_SpaceMenu> {
  final _filter = TextEditingController();
  final _focus = FocusNode();

  /// An invitation being declined: one answer at a time.
  String? _busyInvite;

  @override
  void initState() {
    super.initState();
    // Opening it asks the server, so someone just invited need not wait for the
    // next sync.
    unawaited(_askInvites());
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _focus.requestFocus();
    });
  }

  @override
  void dispose() {
    _filter.dispose();
    _focus.dispose();
    super.dispose();
  }

  Future<void> _askInvites() async {
    try {
      final list = await ref.read(orchardServiceProvider).myInvites();
      if (mounted) ref.read(myInvitesProvider.notifier).state = list;
    } catch (e) {
      AppLogger.info('Orchards: invitations could not be read ($e)');
    }
  }

  void _act(void Function() then) {
    Navigator.of(context).pop();
    then();
  }

  void _pick(Space space) => _act(() => switchToSpace(widget.outer, widget.outerRef, space));

  void _manage(Space space) => _act(() {
        if (space is TreeSpace) {
          Navigator.of(widget.outer).push(MaterialPageRoute<void>(builder: (_) => const ManageTreeScreen()));
          return;
        }
        // A team's Manage is the Team page, on that team.
        unawaited(() async {
          await switchToSpace(widget.outer, widget.outerRef, space);
          openTeamPage(widget.outerRef, TeamPage.overview);
        }());
      });

  Future<void> _decline(MyInvite invite) async {
    if (_busyInvite != null) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _busyInvite = invite.id);
    try {
      await ref.read(orchardServiceProvider).declineInvite(invite.id);
      if (mounted) showTopSnackBar(context, l10n.myInvitationDeclined);
    } catch (e) {
      AppLogger.warning('Orchards: an invitation was not answered ($e)');
      if (mounted) showTopSnackBar(context, inviteErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) {
        setState(() => _busyInvite = null);
        await _askInvites();
      }
    }
  }

  KeyEventResult _onKey(FocusNode _, KeyEvent event, List<Space> spaces) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    if (!keys.isControlPressed && !keys.isMetaPressed) return KeyEventResult.ignored;
    final at = event.logicalKey.keyId - LogicalKeyboardKey.digit1.keyId;
    if (at < 0 || at > 8 || at >= spaces.length) return KeyEventResult.ignored;
    _pick(spaces[at]);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final space = ref.watch(activeSpaceProvider);
    final orchards = ref.watch(orchardSummariesProvider).valueOrNull ?? const <OrchardSummary>[];
    final invites = ref.watch(myInvitesProvider);
    final total = orchards.length + 1;
    final query = _filter.text.trim().toLowerCase();
    bool shown(String name) => query.isEmpty || name.toLowerCase().contains(query);
    final showTree = shown(widget.treeName);
    final shownTeams = [
      for (final o in orchards)
        if (shown(orchardDisplayName(o.name, l10n))) o,
    ];
    final picked = <Space>[if (showTree) const TreeSpace(), for (final o in shownTeams) OrchardSpace(o.id)];
    Widget number(Space s) => _Hint(picked.indexOf(s));
    final hosts = l10n.treeSelectorHostCount(widget.hostCount);
    final titles = orchards.length >= 2;

    return Focus(
      focusNode: _focus,
      onKeyEvent: (node, event) => _onKey(node, event, picked),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _AccountLine(
            // Teams sync by themselves; this asks at once, as "Sync teams now" did.
            onSyncTeams: orchards.isEmpty ? null : () => _act(() => syncOrchardsNow(widget.outer, widget.outerRef)),
          ),
          const Divider(height: 10),
          AccountList(outer: widget.outer, outerRef: widget.outerRef),
          const Divider(height: 10),
          if (total >= kSpaceFilterFrom)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
              child: TextField(
                key: const ValueKey('space-filter'),
                controller: _filter,
                onChanged: (_) => setState(() {}),
                style: const TextStyle(fontSize: 13),
                decoration: InputDecoration(
                  isDense: true,
                  hintText: l10n.spaceMenuFilter,
                  prefixIcon: const Icon(LucideIcons.search, size: 14),
                  prefixIconConstraints: const BoxConstraints(minWidth: 28),
                ),
              ),
            ),
          if (titles) _Head(l10n.treeSelectorPersonal),
          if (showTree)
            _SpaceRow(
              key: const ValueKey('space-row-tree'),
              icon: LucideIcons.user,
              title: widget.treeName,
              subtitle: space is TreeSpace ? hosts : l10n.containerCrateDescription,
              selected: space is TreeSpace,
              hint: number(const TreeSpace()),
              onTap: () => _pick(const TreeSpace()),
              onManage: () => _manage(const TreeSpace()),
              manageLabel: l10n.spaceMenuManage,
            ),
          if (titles) _Head(l10n.spaceSwitcherTeams),
          for (final o in shownTeams)
            _SpaceRow(
              key: ValueKey('space-row-${o.id}'),
              icon: LucideIcons.users,
              title: orchardDisplayName(o.name, l10n),
              subtitle: orchardSubtitle(o, ref, l10n),
              selected: space is OrchardSpace && space.orchardId == o.id,
              hint: number(OrchardSpace(o.id)),
              onTap: () => _pick(OrchardSpace(o.id)),
              onManage: () => _manage(OrchardSpace(o.id)),
              manageLabel: l10n.spaceMenuManage,
            ),
          for (final invite in invites)
            _InviteLine(
              key: ValueKey('space-invite-${invite.id}'),
              invite: invite,
              busy: _busyInvite == invite.id,
              onOpen: () => _act(() => showMyInvitations(widget.outer)),
              onDecline: () => _decline(invite),
            ),
          const Divider(height: 10),
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 2, 12, 6),
            child: Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('space-new-team'),
                    icon: const Icon(LucideIcons.plus, size: 14),
                    label: Text(l10n.spaceMenuNewTeam, overflow: TextOverflow.ellipsis),
                    onPressed: () => _act(() => showCreateOrchardDialog(widget.outer, widget.outerRef)),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: OutlinedButton.icon(
                    key: const ValueKey('space-join-team'),
                    icon: const Icon(LucideIcons.qrCode, size: 14),
                    label: Text(l10n.spaceMenuJoinCode, overflow: TextOverflow.ellipsis),
                    onPressed: () => _act(() => showJoinTeam(widget.outer)),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// The account on top: its picture, its address, its plan, and how it syncs.
class _AccountLine extends ConsumerWidget {
  const _AccountLine({this.onSyncTeams});

  final VoidCallback? onSyncTeams;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final user = ref.watch(currentUserProvider);
    final paid = ref.watch(accountPlanProvider) != AccountPlan.free;
    final sync = ref.watch(syncHealthProvider);
    final name = user?.email ?? user?.displayName;
    final synced = sync.health == SyncHealth.upToDate && sync.confirmedAt != null
        ? l10n.spaceMenuSyncedAgo(timeAgoInSentence(l10n, sync.confirmedAt!))
        : null;
    return Padding(
      key: const ValueKey('space-account-line'),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
      child: Row(
        children: [
          const ProfileAvatar(size: 26),
          const SizedBox(width: 10),
          Expanded(
            child: name == null
                ? Text(l10n.narrowSidebarGuest, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary))
                : RedactedText(
                    Redactable.account(name),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                  ),
          ),
          // The plan's chip: a tap says what each plan is (4.0).
          if (paid) ...[
            const SizedBox(width: 6),
            const PlanChip(key: ValueKey('space-plan-chip')),
          ],
          if (synced != null || onSyncTeams != null) ...[
            const SizedBox(width: 6),
            Tooltip(
              message: [?synced, if (onSyncTeams != null) l10n.orchardSyncNow].join('\n'),
              child: InkResponse(
                key: const ValueKey('space-synced'),
                onTap: onSyncTeams,
                radius: 14,
                child: Padding(
                  padding: const EdgeInsets.all(2),
                  child: Icon(LucideIcons.cloud, size: 13, color: synced != null ? AppColors.v3Success : AppColors.v3TextSecondary),
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _Head extends StatelessWidget {
  const _Head(this.label);

  final String label;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 2),
        child: Text(
          label.toUpperCase(),
          style: TextStyle(
            fontFamily: 'JetBrainsMono',
            fontSize: 10,
            fontWeight: FontWeight.w600,
            letterSpacing: 1.1,
            color: AppColors.v3TextTertiary,
          ),
        ),
      );
}

/// The key a space answers to while the menu is open: Ctrl and its number.
class _Hint extends StatelessWidget {
  const _Hint(this.at);

  final int at;

  @override
  Widget build(BuildContext context) {
    if (at < 0 || at > 8) return const SizedBox.shrink();
    final mac = defaultTargetPlatform == TargetPlatform.macOS;
    return Text(
      mac ? '⌘${at + 1}' : 'Ctrl+${at + 1}',
      style: TextStyle(fontFamily: 'JetBrainsMono', fontSize: 10, color: AppColors.v3TextTertiary),
    );
  }
}

class _SpaceRow extends StatefulWidget {
  const _SpaceRow({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.selected,
    required this.hint,
    required this.onTap,
    required this.onManage,
    required this.manageLabel,
  });

  final IconData icon;
  final String title;
  final String subtitle;
  final bool selected;
  final Widget hint;
  final VoidCallback onTap;
  final VoidCallback onManage;
  final String manageLabel;

  @override
  State<_SpaceRow> createState() => _SpaceRowState();
}

class _SpaceRowState extends State<_SpaceRow> {
  bool _hovering = false;

  @override
  Widget build(BuildContext context) => MouseRegion(
        onEnter: (_) => setState(() => _hovering = true),
        onExit: (_) => setState(() => _hovering = false),
        child: InkWell(
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
            child: Row(
              children: [
                Container(
                  width: 24,
                  height: 24,
                  decoration: BoxDecoration(
                    color: AppColors.v3AccentPrimary.withValues(alpha: 0.08),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Icon(widget.icon, size: 13, color: AppColors.v3AccentInk),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      RedactedText(
                        Redactable.account(widget.title),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                      ),
                      const SizedBox(height: 1),
                      Text(
                        widget.subtitle,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 10.5, color: AppColors.v3TextTertiary),
                      ),
                    ],
                  ),
                ),
                if (_hovering)
                  Tooltip(
                    message: widget.manageLabel,
                    child: InkResponse(
                      key: widget.key is ValueKey<String> ? ValueKey('${(widget.key as ValueKey<String>).value}-manage') : null,
                      onTap: widget.onManage,
                      radius: 14,
                      child: Padding(
                        padding: const EdgeInsets.all(4),
                        child: Icon(LucideIcons.settings, size: 14, color: AppColors.v3TextSecondary),
                      ),
                    ),
                  ),
                const SizedBox(width: 6),
                widget.hint,
                SizedBox(
                  width: 20,
                  child: widget.selected ? Icon(LucideIcons.check, size: 14, color: AppColors.v3AccentInk) : null,
                ),
              ],
            ),
          ),
        ),
      );
}

/// An invitation among the spaces. Accept opens the invitations' own view, which says
/// what the team records of its members and shows the fingerprint to read out; a tap
/// on the row does too. Decline needs none of that.
class _InviteLine extends StatelessWidget {
  const _InviteLine({super.key, required this.invite, required this.busy, required this.onOpen, required this.onDecline});

  final MyInvite invite;
  final bool busy;
  final VoidCallback onOpen;
  final VoidCallback onDecline;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final from = invite.invitedBy;
    final buttonStyle = TextButton.styleFrom(
      minimumSize: const Size(0, 28),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 12),
    );
    return InkWell(
      onTap: onOpen,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 5),
        child: Row(
          children: [
            const SpacesAttentionDot(),
            const SizedBox(width: 10),
            Expanded(
              child: from == null
                  ? Text(l10n.myInvitationsTitle, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary))
                  : RedactedText(
                      Redactable.account(from),
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: AppColors.v3TextPrimary),
                    ),
            ),
            if (!invite.accepted) ...[
              TextButton(
                key: ValueKey('space-invite-accept-${invite.id}'),
                style: buttonStyle,
                onPressed: busy ? null : onOpen,
                child: Text(l10n.myInvitationAccept),
              ),
              TextButton(
                key: ValueKey('space-invite-decline-${invite.id}'),
                style: buttonStyle,
                onPressed: busy ? null : onDecline,
                child: Text(l10n.myInvitationDecline),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
