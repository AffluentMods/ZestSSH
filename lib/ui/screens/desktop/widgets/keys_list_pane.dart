import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:intl/intl.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show TransferKinds;
import 'package:zestssh/features/selection/item_selection.dart';
import 'package:zestssh/features/selection/item_selection_bar.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/features/keys/key_agent.dart' show deviceHasSystemAgent, systemAgentKeysProvider;
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/core_providers.dart' show activeSpaceProvider;
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/cert_generate_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/cert_import_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/hardware_token_dialog.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_first_steps.dart';
import 'package:zestssh/utils/platform_utils.dart' show isTouchLayout;
import 'package:zestssh/ui/screens/identity/key_generation_screen.dart';
import 'package:zestssh/ui/widgets/load_error_state.dart';
import 'package:zestssh/ui/widgets/middle_ellipsis_text.dart' show middleEllipsis;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_empty_state.dart';
import 'package:zestssh/ui/widgets/zest_page_header.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/ui/widgets/selection_bar.dart' show SelectBox;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/zest_list_search_field.dart';
import 'package:zestssh/ui/widgets/guide_help_button.dart';
import 'package:zestssh/ui/widgets/zest_a11y.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart' show minTapTarget;

/// The Keys page's list on a computer, as the design
/// draws it: the page's line (its title, New identity, the filter box,
/// and the filters All, Unused and In agent at its end), then one table of
/// every sign-in under the columns NAME, FINGERPRINT, USED BY, LAST USED and
/// ADDED, in four sections (SSH keys, Saved passwords, SSH agent,
/// Certificates), each section's own actions on its line. A row opens its
/// details beside the list; the selected row has the accent's tint and
/// border. Select on the page's line (3.4) selects several keys, as the
/// hosts are selected: a box on each row, the keys that select, and the
/// selection's bar at the list's foot (Move to..., Copy to..., Delete).
/// With nothing saved, the ways to add a first key ([KeysFirstSteps], 4.0).
class KeysListPane extends ConsumerWidget {
  const KeysListPane({
    super.key,
    required this.selectedId,
    required this.onSelect,
    required this.onNew,
    this.onRowMenu,
    this.beforeChange,
    this.onImportKey,
    this.takesKeyDrops = false,
  });

  /// The page with nothing saved, Import a key file: the key setup's Import
  /// in the new key's editor (4.0). Null: the editor as New key's Import or
  /// paste key opens it.
  final VoidCallback? onImportKey;

  /// A key file dropped on the page is imported (a computer's): the page
  /// with nothing saved says so.
  final bool takesKeyDrops;

  /// Runs before the selection's bar changes keys (the editor beside the
  /// list asks about its changes).
  final Future<bool> Function()? beforeChange;

  /// A right-click on a key's row, with the key and where the pointer was.
  final void Function(Identity identity, Offset position)? onRowMenu;

  /// Currently-open identity id, for row highlight.
  final String? selectedId;

  /// Select an identity row.
  final ValueChanged<String> onSelect;

  /// Compose a new identity of the given method in the detail pane (password
  /// / SSH key). Key generation still uses its own wizard.
  final ValueChanged<AuthMethod> onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final visibleAsync = ref.watch(filteredIdentitiesProvider);
    // Counted and badged across ALL identities (not the filtered view) so
    // the filters' numbers stay as they are whatever is searched, and a
    // duplicate is still flagged when the search hides its twin.
    final all = ref.watch(identitiesProvider).valueOrNull ?? const <Identity>[];
    final usageCounts = ref.watch(identityUsageCountsProvider).valueOrNull ?? const {};
    final lastUsed = ref.watch(identityLastUsedProvider).valueOrNull ?? const {};
    final duplicateIds = duplicateIdentityIds(all);
    final activeFilter = ref.watch(keysSummaryFilterProvider);
    final query = ref.watch(identitySearchQueryProvider);
    // The keys the computer's SSH agent holds now (Add to agent): in the
    // In agent filter with the agent's own.
    final inSystemAgent = ref.watch(systemAgentKeysProvider).valueOrNull ?? const <String>{};
    final selection = ref.watch(keySelectionProvider);
    // A click on a row: a selection click where it is one (Ctrl or Cmd,
    // Shift, or any click while selecting), else it opens the key's details.
    void tap(String id) {
      if (!itemSelectionClick(ref, TransferKinds.key, id, openId: selectedId)) onSelect(id);
    }

    final list = Container(
      color: ZestTokens.surfaceBase,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestPageBand(
            child: _PageLine(
              onNew: onNew,
              all: all,
              usageCounts: usageCounts,
              duplicateCount: duplicateIds.length,
              inSystemAgent: inSystemAgent,
              activeFilter: activeFilter,
              onSelectFilter: (f) => ref.read(keysSummaryFilterProvider.notifier).state =
                  f == activeFilter ? KeysSummaryFilter.all : f,
            ),
          ),
          Expanded(
            child: ItemSelectionFocusArea(
              child: visibleAsync.when(
              // A reload (another space) keeps what is shown until its rows come: a spinner here was a flash.
              skipLoadingOnReload: true,
              loading: () => Center(
                child: SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(strokeWidth: 2, color: ZestTokens.brand),
                ),
              ),
              // What could not be loaded says so with Try again and its
              // details, as a phone's Keys list does.
              error: (e, stack) => LoadErrorState(
                message: l10n.homeUnableToLoadIdentities,
                hint: l10n.homeTryRestartingApp,
                where: 'Loading the keys',
                error: e,
                stack: stack,
                onRetry: () => ref.invalidate(filteredIdentitiesProvider),
              ),
              data: (visible) {
                final shown = _applyFilter(visible, activeFilter, usageCounts, duplicateIds, inSystemAgent);
                // The keys in the order the table shows them, by section:
                // what Ctrl+A selects and a Shift-click's range runs along.
                publishShownItems(ref, TransferKinds.key, [
                  for (final part in [sshKeysOf(shown), passwordsOf(shown), agentKeysOf(shown), certificatesOf(shown)])
                    for (final i in part) i.id,
                ]);
                // No identities at all: the ways to add a first one.
                if (all.isEmpty) {
                  return _EmptyKeysState(onNew: onNew, onImportKey: onImportKey, takesDrops: takesKeyDrops);
                }
                // Search excluded everything.
                if (visible.isEmpty) return _NoMatchesState(query: query);
                // A filter is engaged but matches nothing searched: the
                // filters stay above so it can be cleared.
                if (shown.isEmpty) return const _NoFilterMatchesState();
                return _Table(
                  identities: shown,
                  usageCounts: usageCounts,
                  lastUsed: lastUsed,
                  duplicateIds: duplicateIds,
                  selectedId: selectedId,
                  onSelect: tap,
                  onRowMenu: onRowMenu,
                  filterActive: activeFilter != KeysSummaryFilter.all,
                  selecting: selection.active,
                  checked: selection.selected,
                );
              },
              ),
            ),
          ),
        ],
      ),
    );
    // The keys that select, and the selection's bar over the list's foot.
    return ItemSelectionKeys(
      kind: TransferKinds.key,
      beforeChange: beforeChange,
      child: Stack(
        children: [
          Positioned.fill(child: list),
          Positioned(
            left: 0,
            right: 0,
            bottom: 0,
            child: ItemSelectionBar(kind: TransferKinds.key, beforeChange: beforeChange),
          ),
        ],
      ),
    );
  }
}

/// Narrow [list] to the active filter. `all` is a pass-through.
List<Identity> _applyFilter(
  List<Identity> list,
  KeysSummaryFilter filter,
  Map<String, int> usageCounts,
  Set<String> duplicateIds,
  Set<String> inSystemAgent,
) {
  switch (filter) {
    case KeysSummaryFilter.all:
      return list;
    case KeysSummaryFilter.unattended:
      return list.where((i) => i.allowUnattended).toList(growable: false);
    case KeysSummaryFilter.unused:
      return list.where((i) => isUnusedIdentity(i.id, usageCounts)).toList(growable: false);
    case KeysSummaryFilter.duplicates:
      return list.where((i) => duplicateIds.contains(i.id)).toList(growable: false);
    case KeysSummaryFilter.inAgent:
      return list.where((i) => isInAgentFilter(i, inSystemAgent)).toList(growable: false);
  }
}

// ══════════════════════════════════════════════════════════════════
// The page's line: title, New identity, filter box, filters
// ══════════════════════════════════════════════════════════════════

class _PageLine extends StatelessWidget {
  const _PageLine({
    required this.onNew,
    required this.all,
    required this.usageCounts,
    required this.duplicateCount,
    required this.activeFilter,
    required this.onSelectFilter,
    this.inSystemAgent = const {},
  });

  final ValueChanged<AuthMethod> onNew;
  final List<Identity> all;
  final Map<String, int> usageCounts;
  final int duplicateCount;
  final Set<String> inSystemAgent;
  final KeysSummaryFilter activeFilter;
  final ValueChanged<KeysSummaryFilter> onSelectFilter;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final title = GuideTitle(
      feature: 'keys',
      title: Text(
        l10n.zestKeysTitle,
        maxLines: 1,
        style: TextStyle(fontSize: 19, fontWeight: FontWeight.w600, letterSpacing: -0.3, color: ZestTokens.textPrimary),
      ),
    );
    // The filters stand at the line's end; nothing to filter, none.
    final filters = all.isEmpty
        ? null
        : _FilterSegments(
            total: all.length,
            unused: keysUnusedCount(all, usageCounts),
            inAgent: keysAgentCount(all, inSystemAgent),
            unattended: keysUnattendedCount(all),
            duplicates: duplicateCount,
            active: activeFilter,
            onSelect: onSelectFilter,
          );
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 12, 24, 12),
      child: LayoutBuilder(builder: (context, box) {
        final head = Row(
          children: [
            title,
            const SizedBox(width: 16),
            _NewIdentityMenu(onNew: onNew),
            // Select: several keys to move, copy or delete at once (3.4).
            if (all.isNotEmpty) ...[
              const SizedBox(width: 10),
              const ItemSelectToggle(kind: TransferKinds.key),
            ],
            const SizedBox(width: 12),
            Flexible(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: const _FilterField(),
              ),
            ),
          ],
        );
        // On a narrow list the filters go under the line rather than squeeze
        // the filter box.
        if (filters == null) return head;
        if (box.maxWidth < 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              head,
              const SizedBox(height: 10),
              Align(alignment: AlignmentDirectional.centerStart, child: filters),
            ],
          );
        }
        return Row(
          children: [
            Expanded(child: head),
            const SizedBox(width: 16),
            filters,
          ],
        );
      }),
    );
  }
}

/// The filters: All, Unused and In agent always, with their counts;
/// Unattended and Duplicates where there are some (or one is on, so it can
/// be cleared). Drawn as the app's segmented control is.
class _FilterSegments extends StatelessWidget {
  const _FilterSegments({
    required this.total,
    required this.unused,
    required this.inAgent,
    required this.unattended,
    required this.duplicates,
    required this.active,
    required this.onSelect,
  });

  final int total;
  final int unused;
  final int inAgent;
  final int unattended;
  final int duplicates;
  final KeysSummaryFilter active;
  final ValueChanged<KeysSummaryFilter> onSelect;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    bool show(int count, KeysSummaryFilter f) => count > 0 || active == f;
    final segments = <(KeysSummaryFilter, String, int)>[
      (KeysSummaryFilter.all, l10n.zestKeysFilterAll, total),
      (KeysSummaryFilter.unused, l10n.zestKeysFilterUnused, unused),
      (KeysSummaryFilter.inAgent, l10n.keysUiFilterInAgent, inAgent),
      if (show(unattended, KeysSummaryFilter.unattended))
        (KeysSummaryFilter.unattended, l10n.zestKeysFilterUnattended, unattended),
      if (show(duplicates, KeysSummaryFilter.duplicates))
        (KeysSummaryFilter.duplicates, l10n.zestKeysFilterDuplicates, duplicates),
    ];
    return Container(
      // Each filter 32 high to a pointer, 48 to a finger (it was 26), or
      // more where larger text needs it.
      constraints: BoxConstraints(minHeight: minTapTarget(context) + 6),
      padding: const EdgeInsets.all(2),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.border),
      ),
      child: IntrinsicHeight(
        child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final (filter, label, count) in segments)
            _Segment(
              key: ValueKey('keys-filter-${filter.name}'),
              label: label,
              count: count,
              selected: active == filter,
              onTap: () => onSelect(filter),
            ),
        ],
        ),
      ),
    );
  }
}

class _Segment extends StatefulWidget {
  const _Segment({super.key, required this.label, required this.count, required this.selected, required this.onTap});

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  State<_Segment> createState() => _SegmentState();
}

class _SegmentState extends State<_Segment> {
  bool _hover = false;
  bool _focusRing = false;

  @override
  Widget build(BuildContext context) {
    final selected = widget.selected;
    final fg = selected ? zestBrandOnSubtle : (_hover ? ZestTokens.textPrimary : ZestTokens.textSecondary);
    // One of a few to a screen reader, said selected; a stop for the keyboard
    // with the accent ring (a pointer alone reached it).
    return Semantics(
      container: true,
      button: true,
      selected: selected,
      inMutuallyExclusiveGroup: true,
      child: ZestHover(onHover: (h) => setState(() => _hover = h), child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (f) => setState(() => _focusRing = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: zestMotion(context, const Duration(milliseconds: 120)),
            padding: const EdgeInsets.symmetric(horizontal: 12),
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: selected ? ZestTokens.brandSubtle : (_hover ? ZestTokens.surfaceHover : Colors.transparent),
              borderRadius: BorderRadius.circular(6),
              border: _focusRing ? Border.all(color: ZestTokens.brand, width: 2) : null,
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  widget.label,
                  style: TextStyle(
                      fontSize: 12.5, fontWeight: selected ? FontWeight.w600 : FontWeight.w500, color: fg, height: 1.0),
                ),
                const SizedBox(width: 6),
                Text(
                  '${widget.count}',
                  style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: fg, height: 1.0),
                ),
              ],
            ),
          ),
        ),
      )),
    );
  }
}

class _FilterField extends ConsumerStatefulWidget {
  const _FilterField();

  @override
  ConsumerState<_FilterField> createState() => _FilterFieldState();
}

class _FilterFieldState extends ConsumerState<_FilterField> {
  late final TextEditingController _controller = TextEditingController(text: ref.read(identitySearchQueryProvider));
  final FocusNode _focus = FocusNode();

  @override
  void dispose() {
    _controller.dispose();
    _focus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ZestListSearchField(
      controller: _controller,
      focusNode: _focus,
      hintText: AppLocalizations.of(context)!.keysUiFilterHint,
      onChanged: (v) => ref.read(identitySearchQueryProvider.notifier).state = v,
    );
  }
}

/// "New identity": every way to add one, anchored under its button.
class _NewIdentityMenu extends ConsumerWidget {
  const _NewIdentityMenu({required this.onNew});

  final ValueChanged<AuthMethod> onNew;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    // In a team, only where a vault lets this account add (3.0).
    if (!mayAddScreenSpace(ref)) return const SizedBox.shrink();
    PopupMenuItem<String> item(String value, IconData icon, String label) =>
        PopupMenuItem(value: value, height: 36, child: _MenuRow(icon: icon, label: label));
    return PopupMenuButton<String>(
      key: const ValueKey('keys-new-identity'),
      tooltip: l10n.keysUiNewIdentity,
      position: PopupMenuPosition.under,
      offset: const Offset(0, 6),
      constraints: const BoxConstraints(minWidth: 240, maxWidth: 300),
      color: ZestTokens.surfaceRaised,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: ZestTokens.border),
      ),
      onSelected: (value) => _handle(context, ref, value),
      itemBuilder: (_) => [
        // In-pane forms.
        item('new_password', LucideIcons.lock, l10n.zestKeysNewPassword),
        item('new_key', LucideIcons.keyRound, l10n.zestKeysImportPasteKey),
        const PopupMenuDivider(),
        // The key generator (its own wizard).
        item('ed25519', LucideIcons.sparkles, l10n.keysListGenerateSshKeyEd25519),
        item('ecdsa', LucideIcons.sparkles, l10n.keysListGenerateSshKeyEcdsa),
        item('rsa4096', LucideIcons.sparkles, l10n.keysListGenerateSshKeyRsa4096),
        const PopupMenuDivider(),
        if (PasswordManagers.supported) item('pm', LucideIcons.listChecks, l10n.pmAddFrom),
        // A computer's SSH agent: none on a phone or a tablet.
        if (offersSystemAgent) item('agent', LucideIcons.usb, l10n.zestKeysConnectAgent),
        item('cert_generate', LucideIcons.filePlus, l10n.zestKeysGenerateCertificate),
        item('cert_import', LucideIcons.download, l10n.zestKeysImportCertificate),
      ],
      child: Container(
        height: ZestSizing.buttonMedium,
        padding: const EdgeInsets.symmetric(horizontal: ZestSizing.buttonMediumPaddingX),
        decoration: BoxDecoration(
          color: ZestTokens.brand,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(LucideIcons.plus, size: 16, color: ZestTokens.onBrand),
            const SizedBox(width: 6),
            Text(
              l10n.keysUiNewIdentity,
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: ZestTokens.onBrand, height: 1.0),
            ),
            const SizedBox(width: 4),
            Icon(LucideIcons.chevronDown, size: 15, color: ZestTokens.onBrand),
          ],
        ),
      ),
    );
  }

  void _handle(BuildContext context, WidgetRef ref, String value) {
    switch (value) {
      case 'new_password':
        onNew(AuthMethod.password);
      case 'new_key':
        onNew(AuthMethod.publicKey);
      case 'ed25519':
        KeyGenerationScreen.showAdaptive(context, initialFormat: KeyGenerationFormatHint.ed25519);
      case 'ecdsa':
        KeyGenerationScreen.showAdaptive(context, initialFormat: KeyGenerationFormatHint.ecdsa);
      case 'rsa4096':
        KeyGenerationScreen.showAdaptive(context, initialFormat: KeyGenerationFormatHint.rsa);
      case 'pm':
        addFromPasswordManager(context, ref);
      case 'agent':
        HardwareTokenDialog.show(context);
      case 'cert_generate':
        CertGenerateDialog.show(context);
      case 'cert_import':
        CertImportDialog.show(context);
    }
  }
}

/// Adds keys (and hosts) from a password manager, saying what was
/// added.
Future<void> addFromPasswordManager(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  final done = await showAddFromPasswordManager(context, ref);
  if (done != null && context.mounted) {
    showTopSnackBar(context, l10n.pmAdded(done.keys, done.hosts), isSuccess: true);
  }
}

/// Whether the Keys page offers to connect the system's SSH agent: on a
/// computer. A phone or a tablet has none ([deviceHasSystemAgent]; the
/// system agent there is null), a large tablet with the computer's Keys page
/// included (4.0 platform comparison: it offered Connect via ssh-agent, which
/// probed for an agent that cannot be there). Read from [isTouchLayout], the
/// same answer in the app, which a test can stand in for.
bool get offersSystemAgent => !isTouchLayout;

/// What the SSH agent is, with the way to connect one.
Future<void> showKeysAgentHelp(BuildContext context) {
  final l10n = AppLocalizations.of(context)!;
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.usb,
    title: l10n.keysUiAgentHelpTitle,
    body: Text(
      l10n.zestKeysAgentHelp,
      key: const ValueKey('keys-agent-help'),
      style: TextStyle(fontSize: 13, height: 1.5, color: ZestTokens.textSecondary),
    ),
    primaryAction: (
      label: l10n.zestKeysConnectAgent,
      icon: LucideIcons.usb,
      onPressed: () {
        Navigator.of(context, rootNavigator: true).pop();
        HardwareTokenDialog.show(context);
      },
    ),
    secondaryAction: (label: l10n.close, onPressed: () => Navigator.of(context, rootNavigator: true).pop()),
  );
}

class _MenuRow extends StatelessWidget {
  const _MenuRow({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, size: 16, color: ZestTokens.textSecondary),
        const SizedBox(width: 10),
        Flexible(child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary))),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// The table
// ══════════════════════════════════════════════════════════════════

/// The fixed columns' widths, and whether the fingerprint column is drawn
/// (a narrow list leaves it to the details).
class _Columns {
  const _Columns({required this.usedBy, required this.lastUsed, required this.added, required this.fingerprint});

  final double usedBy;
  final double lastUsed;
  final double added;
  final bool fingerprint;
}

/// The columns of the rows under it.
class _ColumnsScope extends InheritedWidget {
  const _ColumnsScope({required this.columns, required super.child});

  final _Columns columns;

  static _Columns of(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<_ColumnsScope>()?.columns ??
      const _Columns(usedBy: 96, lastUsed: 96, added: 80, fingerprint: true);

  @override
  bool updateShouldNotify(_ColumnsScope oldWidget) =>
      oldWidget.columns.usedBy != columns.usedBy ||
      oldWidget.columns.lastUsed != columns.lastUsed ||
      oldWidget.columns.added != columns.added ||
      oldWidget.columns.fingerprint != columns.fingerprint;
}

/// How the table's values are drawn, so a column is as wide as its widest.
const _kCell = TextStyle(fontSize: 13, height: 1.2);

/// A column as wide as the widest of [values] (and its head) at the
/// person's text size, at least [least].
double _columnWidth(BuildContext context, double least, List<String> values) {
  final style = DefaultTextStyle.of(context).style.merge(_kCell);
  final scaler = MediaQuery.textScalerOf(context);
  final direction = Directionality.of(context);
  var widest = 0.0;
  for (final value in values.toSet()) {
    final painter = TextPainter(
      text: TextSpan(text: value, style: style),
      textDirection: direction,
      textScaler: scaler,
      maxLines: 1,
    )..layout();
    if (painter.width > widest) widest = painter.width;
    painter.dispose();
  }
  final needs = (widest + 16).ceilToDouble();
  return needs > least ? needs : least;
}

/// When a key was added, as a short date in the page's language: the day
/// and the month this year ("Sep 1"), with the year before it.
String keyAddedDate(AppLocalizations l10n, DateTime when, {DateTime? now}) {
  final at = (now ?? DateTime.now());
  final local = when.toLocal();
  return local.year == at.year
      ? DateFormat.MMMd(l10n.localeName).format(local)
      : DateFormat.yMMMd(l10n.localeName).format(local);
}

/// When a key was last used, as a cell says it: within a week how long ago
/// ("2h ago"), before that its date as ADDED writes one ("Oct 12").
String keyLastUsedWords(AppLocalizations l10n, DateTime? when, {DateTime? now}) {
  if (when == null) return l10n.zestKeysNeverUsed;
  final at = now ?? DateTime.now();
  return at.difference(when).inDays < 7 ? timeAgoWords(l10n, when, now: at) : keyAddedDate(l10n, when, now: at);
}

class _Table extends StatelessWidget {
  const _Table({
    required this.identities,
    required this.usageCounts,
    required this.lastUsed,
    required this.duplicateIds,
    required this.selectedId,
    required this.onSelect,
    required this.filterActive,
    this.onRowMenu,
    this.selecting = false,
    this.checked = const {},
  });

  /// The keys are being selected (3.4): each row has its box, and the heads
  /// the box over them; [checked] are the selected ones.
  final bool selecting;
  final Set<String> checked;

  final void Function(Identity identity, Offset position)? onRowMenu;
  final List<Identity> identities;
  final Map<String, int> usageCounts;
  final Map<String, DateTime> lastUsed;
  final Set<String> duplicateIds;
  final String? selectedId;
  final ValueChanged<String> onSelect;

  /// While a filter is on, the list is a slice across sections: a section
  /// with nothing in it is left out.
  final bool filterActive;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final sshKeys = sshKeysOf(identities);
    final passwords = passwordsOf(identities);
    final agentKeys = agentKeysOf(identities);
    final certificates = certificatesOf(identities);

    return LayoutBuilder(builder: (context, box) {
      final columns = _Columns(
        usedBy: _columnWidth(context, 96, [
          l10n.keysUiColUsedBy.toUpperCase(),
          for (final i in identities) l10n.keysUiHosts(usageCounts[i.id] ?? 0),
        ]),
        lastUsed: _columnWidth(context, 96, [
          l10n.keysUiColLastUsed.toUpperCase(),
          for (final i in identities) keyLastUsedWords(l10n, lastUsed[i.id]),
        ]),
        added: _columnWidth(context, 80, [
          l10n.keysUiColAdded.toUpperCase(),
          for (final i in identities) keyAddedDate(l10n, i.createdAt),
        ]),
        fingerprint: box.maxWidth >= 720,
      );
      return _ColumnsScope(
        columns: columns,
        child: ListView(
          // Room for the selection's bar under the last row while selecting.
          padding: EdgeInsets.fromLTRB(24, 14, 24, selecting ? 140 : 28),
          children: [
            _ColumnHeads(selecting: selecting),
            const SizedBox(height: 14),
            ..._section(
              key: 'ssh',
              label: l10n.zestKeysSectionSshKeys,
              items: sshKeys,
              emptyMessage: l10n.keysUiEmptySshKeys,
            ),
            ..._section(
              key: 'passwords',
              label: l10n.keysUiSectionSavedPasswords,
              items: passwords,
              emptyMessage: l10n.keysUiEmptyPasswords,
              // Keys from a password manager, where its tools run.
              trailing: PasswordManagers.supported ? const _PasswordManagerAction() : null,
            ),
            // A phone or a tablet has no SSH agent: the section only lists
            // keys of a computer's agent that came here by sync, with no way
            // to connect one.
            if (offersSystemAgent || agentKeys.isNotEmpty)
              ..._section(
                key: 'agent',
                label: l10n.keysUiSectionAgent,
                items: agentKeys,
                emptyMessage: l10n.keysUiEmptyAgent,
                trailing: offersSystemAgent ? const _AgentHelpAction() : null,
              ),
            ..._section(
              key: 'certificates',
              label: l10n.zestKeysSectionCertificates,
              items: certificates,
              emptyMessage: l10n.keysUiEmptyCertificates,
              trailing: const _CertificateActions(),
            ),
          ],
        ),
      );
    });
  }

  List<Widget> _section({
    required String key,
    required String label,
    required List<Identity> items,
    required String emptyMessage,
    Widget? trailing,
  }) {
    if (items.isEmpty && filterActive) return const [];
    return [
      ZestSectionHeader(key: ValueKey('keys-section-$key'), label: label, count: items.length, trailing: trailing),
      if (items.isEmpty)
        Padding(
          padding: const EdgeInsets.only(left: 12),
          child: ZestEmptyRow(key: ValueKey('keys-empty-$key'), message: emptyMessage),
        )
      else
        for (final id in items) _row(id),
      const SizedBox(height: 18),
    ];
  }

  /// A key's row, taking a right-click for its menu when there is one.
  Widget _row(Identity id) {
    final row = _KeyRow(
      key: ValueKey(id.id),
      identity: id,
      selected: selecting ? checked.contains(id.id) : selectedId == id.id,
      selecting: selecting,
      onTap: () => onSelect(id.id),
      usedBy: usageCounts[id.id] ?? 0,
      lastUsedAt: lastUsed[id.id],
      isDuplicate: duplicateIds.contains(id.id),
    );
    final menu = onRowMenu;
    if (menu == null) return row;
    return Builder(
      key: ValueKey('key-row-menu-${id.id}'),
      builder: (context) => GestureDetector(
        behavior: HitTestBehavior.translucent,
        // The right click is a pointer's; to a screen reader the row is the
        // row's own button (this gave it a nameless tap of its own).
        excludeFromSemantics: true,
        onSecondaryTapUp: (details) => menu(id, details.globalPosition),
        // The right click's menu under a long press too where the controls
        // are touch sized (a tablet, 4.0): a finger has no right button.
        onLongPressStart: touchSizedAt(context) ? (details) => menu(id, details.globalPosition) : null,
        child: row,
      ),
    );
  }
}

/// The geometry a row and the column heads share, so the heads stand over
/// their columns.
const double _kRowPadX = 12;
const double _kLeading = 30;
const double _kLeadingGap = 12;
const int _kNameFlex = 5;
const int _kFingerprintFlex = 4;

class _ColumnHeads extends StatelessWidget {
  const _ColumnHeads({this.selecting = false});

  /// While the keys are selected: the box over the rows' boxes, how many are
  /// selected and Clear selection, where NAME stands (3.4).
  final bool selecting;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = _ColumnsScope.of(context);
    Widget head(String text) => Text(
          text.toUpperCase(),
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 10.5,
            fontFamily: 'JetBrainsMono',
            fontWeight: FontWeight.w600,
            letterSpacing: 1.05,
            color: ZestTokens.textMuted,
            height: 1.0,
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: _kRowPadX + 1),
      child: Row(
        children: [
          Expanded(
            flex: _kNameFlex,
            child: selecting
                ? const Align(alignment: AlignmentDirectional.centerStart, child: ItemSelectionHead(kind: TransferKinds.key))
                : head(l10n.keysUiColName),
          ),
          if (c.fingerprint) Expanded(flex: _kFingerprintFlex, child: head(l10n.keysUiColFingerprint)),
          SizedBox(width: c.usedBy, child: head(l10n.keysUiColUsedBy)),
          SizedBox(width: c.lastUsed, child: head(l10n.keysUiColLastUsed)),
          SizedBox(width: c.added, child: head(l10n.keysUiColAdded)),
        ],
      ),
    );
  }
}

/// The icon a kind of sign-in is shown with, in the list and its details.
IconData keyKindIcon(Identity id) => switch (id.authMethod) {
      'password' => LucideIcons.lock,
      'passwordManager' => LucideIcons.fileKey,
      'hardwareToken' => isHardwareKey(id) ? LucideIcons.usb : LucideIcons.plug,
      'certificate' || 'teamCertificate' => LucideIcons.award,
      _ => LucideIcons.keyRound,
    };

/// Whether an agent's key is a security key (FIDO, "sk-" keys): its private
/// part never leaves the device in the person's hand.
bool isHardwareKey(Identity id) => (id.keyType ?? '').toLowerCase().startsWith('sk-');

/// The small tag beside a key's name: its algorithm, AGENT or HARDWARE, a
/// certificate's kind; none for a password (its user name is shown).
String? keyTag(AppLocalizations l10n, Identity id) => switch (id.authMethod) {
      'password' || 'passwordManager' => null,
      'hardwareToken' => isHardwareKey(id) ? l10n.keysUiTagHardware : l10n.keysUiTagAgent,
      'certificate' || 'teamCertificate' => identityTypeLabel(l10n, id),
      _ => keyTypeLabel(l10n, id.keyType),
    };

/// Where a sign-in's secret is, as the FINGERPRINT column says it for one
/// that has no fingerprint to show: kept in the vault, in a password manager,
/// in the agent, or signed by the team at each connect. Null where the
/// fingerprint is shown.
String? keySecretWhere(AppLocalizations l10n, Identity id, {required bool team}) {
  switch (id.authMethod) {
    case 'password':
      return team ? l10n.keysUiInTeamVault : l10n.keysUiInYourVault;
    case 'passwordManager':
      final kind = PasswordRef.decode(id.passwordRef)?.kind;
      return kind == null ? l10n.pmKeyTypeLabel : l10n.keysUiKeptIn(passwordManagerName(kind));
    case 'hardwareToken':
      return l10n.keysUiLivesInAgent;
    case 'teamCertificate':
      return l10n.keysUiTeamCertSigned;
  }
  final fp = id.publicKeyFingerprint;
  return fp == null || fp.isEmpty ? '-' : null;
}

class _KeyRow extends ConsumerStatefulWidget {
  const _KeyRow({
    super.key,
    required this.identity,
    required this.selected,
    required this.onTap,
    required this.usedBy,
    required this.lastUsedAt,
    required this.isDuplicate,
    this.selecting = false,
  });

  final Identity identity;

  /// Open beside the list, or (while [selecting]) selected.
  final bool selected;

  /// The keys are being selected: the row's box before its icon.
  final bool selecting;
  final VoidCallback onTap;
  final int usedBy;
  final DateTime? lastUsedAt;
  final bool isDuplicate;

  @override
  ConsumerState<_KeyRow> createState() => _KeyRowState();
}

class _KeyRowState extends ConsumerState<_KeyRow> {
  bool _hover = false;
  bool _focusRing = false;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final c = _ColumnsScope.of(context);
    final id = widget.identity;
    final selected = widget.selected;
    final recording = ref.watch(recordingModeProvider);
    final team = ref.watch(activeSpaceProvider) is OrchardSpace;
    final hasColour = id.colorValue != null || id.colorIndex != 0;
    final labelColour = AppColors.labelColorFor(id.colorValue, id.colorIndex);
    final tag = keyTag(l10n, id);
    final where = keySecretWhere(l10n, id, team: team);
    final fp = id.publicKeyFingerprint ?? '';
    final cellStyle = _kCell.copyWith(color: ZestTokens.textSecondary);
    final dimStyle = _kCell.copyWith(color: ZestTokens.textTertiary);

    final name = Row(
      children: [
        if (widget.selecting) ...[
          SelectBox(key: ValueKey('key-row-box-${id.id}'), checked: selected, size: 16),
          const SizedBox(width: 10),
        ],
        Container(
          width: _kLeading,
          height: _kLeading,
          decoration: BoxDecoration(
            color: selected
                ? ZestTokens.brand.withValues(alpha: 0.16)
                : (hasColour ? labelColour.withValues(alpha: 0.14) : ZestTokens.surfaceChip),
            borderRadius: BorderRadius.circular(7),
          ),
          child: Icon(
            keyKindIcon(id),
            size: 15,
            color: selected ? ZestTokens.brandInk : (hasColour ? labelColour : ZestTokens.textSecondary),
          ),
        ),
        const SizedBox(width: _kLeadingGap),
        Flexible(
          child: RedactedText(
            Redactable.keyName(id.label),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 13.5, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
          ),
        ),
        const SizedBox(width: 8),
        if (tag != null)
          _Tag(label: tag)
        else if (id.username.isNotEmpty)
          Flexible(
            child: RedactedText(
              Redactable.username(id.username),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textTertiary),
            ),
          ),
        if (widget.isDuplicate) ...[
          const SizedBox(width: 6),
          _DuplicateBadge(),
        ],
        if (id.allowUnattended) ...[
          const SizedBox(width: 6),
          Tooltip(
            message: l10n.zestKeysUnattendedEnabledTooltip,
            child: Icon(LucideIcons.shield, size: 13, color: ZestTokens.brandInk),
          ),
        ],
      ],
    );

    final fpStyle = TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textSecondary);
    final Widget fingerprint = where != null
        ? Text(where, maxLines: 1, overflow: TextOverflow.ellipsis, style: cellStyle)
        // Whole where its column holds it, cut in its middle only where it
        // does not, both ends kept (it was cut to "SHA256:nC7x…2LmQaZ" with
        // half the row empty: found in a design audit).
        : LayoutBuilder(builder: (context, box) {
            final shown = fp.isEmpty ? '-' : (recording ? Redactor.fingerprint(fp) : fp);
            return Text(
              box.maxWidth.isFinite
                  ? middleEllipsis(shown, DefaultTextStyle.of(context).style.merge(fpStyle), box.maxWidth,
                      direction: Directionality.of(context), textScaler: MediaQuery.textScalerOf(context))
                  : shown,
              key: ValueKey('keys-row-fingerprint-${id.id}'),
              maxLines: 1,
              softWrap: false,
              overflow: TextOverflow.clip,
              style: fpStyle,
            );
          });

    // One stop to a screen reader, its cells read as one sentence ("Ops
    // laptop, ED25519, SHA256:..., 15 hosts, 2 hours ago, 1 Sep"), a button,
    // said selected; a stop for the keyboard, Enter opens it, with the accent
    // ring. It was a row of separate cells under a tap with no name, which a
    // keyboard could not reach.
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: MergeSemantics(
        child: Semantics(
        button: true,
        selected: selected,
        child: ZestHover(onHover: (h) => setState(() => _hover = h), child: FocusableActionDetector(
        mouseCursor: SystemMouseCursors.click,
        onShowFocusHighlight: (f) => setState(() => _focusRing = f),
        actions: {
          ActivateIntent: CallbackAction<ActivateIntent>(onInvoke: (_) {
            widget.onTap();
            return null;
          }),
        },
        child: GestureDetector(
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: zestMotion(context, const Duration(milliseconds: 120)),
            padding: const EdgeInsets.symmetric(horizontal: _kRowPadX, vertical: 11),
            decoration: BoxDecoration(
              color: selected ? ZestTokens.brandSubtle : (_hover ? ZestTokens.surfaceHover : ZestTokens.surfaceRaised),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                  color: _focusRing ? ZestTokens.brand : (selected ? ZestTokens.brandBorder : ZestTokens.borderSubtle),
                  width: _focusRing ? 2 : 1),
            ),
            child: Row(
              children: [
                Expanded(flex: _kNameFlex, child: Padding(padding: const EdgeInsetsDirectional.only(end: 12), child: name)),
                if (c.fingerprint)
                  Expanded(
                    flex: _kFingerprintFlex,
                    child: Padding(padding: const EdgeInsetsDirectional.only(end: 12), child: fingerprint),
                  ),
                SizedBox(
                  width: c.usedBy,
                  child: Tooltip(
                    message: l10n.zestKeysMetricUsedBy(widget.usedBy),
                    excludeFromSemantics: true,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(l10n.keysUiHosts(widget.usedBy),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: widget.usedBy == 0 ? dimStyle : cellStyle),
                  ),
                ),
                SizedBox(
                  width: c.lastUsed,
                  child: Tooltip(
                    message: widget.lastUsedAt == null
                        ? l10n.zestKeysMetricLastUsed(l10n.zestKeysNeverUsed)
                        : l10n.zestKeysMetricLastUsed(timeAgoInSentence(l10n, widget.lastUsedAt!)),
                    excludeFromSemantics: true,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(keyLastUsedWords(l10n, widget.lastUsedAt),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: widget.lastUsedAt == null ? dimStyle : cellStyle),
                  ),
                ),
                SizedBox(
                  width: c.added,
                  child: Tooltip(
                    message: l10n.zestKeysMetricAge(timeAgoInSentence(l10n, id.createdAt)),
                    excludeFromSemantics: true,
                    waitDuration: const Duration(milliseconds: 400),
                    child: Text(keyAddedDate(l10n, id.createdAt),
                        maxLines: 1, overflow: TextOverflow.ellipsis, style: cellStyle),
                  ),
                ),
              ],
            ),
          ),
        ),
        )),
        ),
      ),
    );
  }
}

/// The small tag beside a name (ED25519, AGENT, HARDWARE): mono capitals on
/// a chip.
class _Tag extends StatelessWidget {
  const _Tag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceChip,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Text(
        label.toUpperCase(),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 10,
          fontFamily: 'JetBrainsMono',
          fontWeight: FontWeight.w600,
          letterSpacing: 0.4,
          color: ZestTokens.textSecondary,
          height: 1.0,
        ),
      ),
    );
  }
}

/// The red "Duplicate" mark on every member of a group that shares a key.
class _DuplicateBadge extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final color = ZestTokens.statusCritical;
    return Tooltip(
      message: l10n.zestKeysBadgeDuplicateTooltip,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: color.withValues(alpha: 0.14),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: color.withValues(alpha: 0.5)),
        ),
        child: Text(
          l10n.zestKeysBadgeDuplicate,
          style: TextStyle(fontSize: 10.5, fontWeight: FontWeight.w600, color: color, height: 1.0),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// The sections' own actions, on their lines
// ══════════════════════════════════════════════════════════════════

class _PasswordManagerAction extends ConsumerWidget {
  const _PasswordManagerAction();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ZestButton(
      key: const ValueKey('pm-add-from'),
      label: l10n.keysUiFromPasswordManager,
      icon: LucideIcons.plus,
      variant: ZestButtonVariant.ghost,
      onPressed: () => addFromPasswordManager(context, ref),
    );
  }
}

class _AgentHelpAction extends StatelessWidget {
  const _AgentHelpAction();

  @override
  Widget build(BuildContext context) {
    return ZestButton(
      key: const ValueKey('keys-agent-what'),
      label: AppLocalizations.of(context)!.keysUiWhatIsThis,
      variant: ZestButtonVariant.ghost,
      onPressed: () => showKeysAgentHelp(context),
    );
  }
}

class _CertificateActions extends StatelessWidget {
  const _CertificateActions();

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Flexible(
          child: ZestButton(
            key: const ValueKey('keys-cert-generate'),
            label: l10n.keysUiGenerate,
            variant: ZestButtonVariant.ghost,
            onPressed: () => CertGenerateDialog.show(context),
          ),
        ),
        Flexible(
          child: ZestButton(
            key: const ValueKey('keys-cert-import'),
            label: l10n.keysUiImport,
            variant: ZestButtonVariant.ghost,
            onPressed: () => CertImportDialog.show(context),
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Empty / no-match states
// ══════════════════════════════════════════════════════════════════

/// Nothing saved: the ways to add a first key (4.0),
/// each opening what New key's menu opens. In a team vault this account may
/// not add to, there is nothing to start with (New key is not there either).
class _EmptyKeysState extends ConsumerWidget {
  const _EmptyKeysState({required this.onNew, required this.onImportKey, required this.takesDrops});

  final ValueChanged<AuthMethod> onNew;
  final VoidCallback? onImportKey;
  final bool takesDrops;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    if (!mayAddScreenSpace(ref)) {
      return ZestEmptyState(icon: LucideIcons.keyRound, title: l10n.keysListNoKeysYetTitle);
    }
    return KeysFirstSteps(
      onGenerate: () => KeyGenerationScreen.showAdaptive(context, initialFormat: KeyGenerationFormatHint.ed25519),
      onImport: onImportKey ?? () => onNew(AuthMethod.publicKey),
      // The computer's SSH agent, as New key's Connect via ssh-agent.
      onAgent: offersSystemAgent ? () => HardwareTokenDialog.show(context) : null,
      onPasswordManager: PasswordManagers.supported ? () => addFromPasswordManager(context, ref) : null,
      onNewPassword: () => onNew(AuthMethod.password),
      takesDrops: takesDrops,
    );
  }
}

class _NoMatchesState extends ConsumerWidget {
  const _NoMatchesState({required this.query});

  final String query;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.searchX,
      // The query may name a key or a host: free-text rule while recording.
      title: l10n.keysListNoKeysMatch(Redactable.freeText(query).displayIn(ref)),
      actionLabel: l10n.keysListClearSearch,
      actionIcon: LucideIcons.x,
      onAction: () => ref.read(identitySearchQueryProvider.notifier).state = '',
    );
  }
}

class _NoFilterMatchesState extends ConsumerWidget {
  const _NoFilterMatchesState();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    return ZestEmptyState(
      icon: LucideIcons.filterX,
      title: l10n.zestKeysNoFilterMatchesTitle,
      actionLabel: l10n.zestKeysClearFilter,
      actionIcon: LucideIcons.x,
      onAction: () => ref.read(keysSummaryFilterProvider.notifier).state = KeysSummaryFilter.all,
    );
  }
}
