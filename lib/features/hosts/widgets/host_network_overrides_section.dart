import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/models/enums.dart' show ConnectionProtocol;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/recording_masked_field.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';

import '../../../database/daos/connections_dao.dart';
import '../../../database/database.dart' show PortForwardRule;
import '../../../database/tables/port_forward_network_overrides.dart';
import '../../../l10n/generated/app_localizations.dart';
import '../../../providers/connection_providers.dart';
import '../../../providers/core_providers.dart';
import '../../../providers/identity_providers.dart';
import '../../../providers/network_providers.dart';
import '../../../providers/purchase_providers.dart';
import '../../../router/routes.dart';
import '../../../theme/app_colors.dart';
import '../../../ui/widgets/zest_section_header.dart';
import '../../networks/engine/connection_resolver.dart';
import '../../networks/models/network.dart';
import '../../networks/models/network_trigger.dart';
import '../models/host_network_override.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// A concrete set of connection parameters a "Test connection" probe should
/// run against - either the host's BASE config (footer buttons) or a network
/// row's resolved effective config ("Test as this network"). Decoupling the
/// probes from the live form controllers lets the same
/// reachability / full-auth logic run against any resolved tuple.
@immutable
class EffectiveTestConfig {
  const EffectiveTestConfig({
    required this.host,
    required this.port,
    this.username,
    this.identityKeyId,
    this.jumpChain = const [],
  });

  final String host;
  final int port;

  /// Explicit SSH username. Null means "derive from the identity" - the
  /// footer test passes null to preserve its original behaviour; a network
  /// row that overrides the username passes the resolved value.
  final String? username;

  /// Identity (key/credential) row id the probe loads credentials from, or
  /// null for a reachability-only / credential-less probe.
  final String? identityKeyId;

  /// Resolved jump-host chain. The probe connects directly to [host]:[port];
  /// a non-empty chain only drives an advisory note in the result.
  final List<String> jumpChain;
}

/// Signature for the two connection probes threaded down from the host
/// editor so each network row can run "Test as this network".
typedef TestProbe = Future<void> Function(EffectiveTestConfig cfg);

/// Maximum allowed jump-host hops on a single override row. The spec
/// caps the jump chain at 3 hops; more than that is almost certainly a
/// misconfiguration and the picker UI gets unwieldy.
const int _kMaxJumpHops = 3;

/// Section embedded inside the host edit form that lets the user define
/// per-network overrides for the host.
///
/// Drive it via a [GlobalKey] so the parent's `_save` can call
/// [HostNetworkOverridesSectionState.bakeDrafts] to read out the
/// currently-edited list of [HostNetworkOverride] models. The section
/// does not itself talk to the repository - that's the parent's job, so
/// the overrides save in the same atomic flow as the host record.
class HostNetworkOverridesSection extends ConsumerStatefulWidget {
  const HostNetworkOverridesSection({
    super.key,
    required this.hostId,
    required this.baseAddress,
    required this.basePort,
    required this.baseUsername,
    required this.baseIdentityKeyId,
    required this.baseJumpChain,
    required this.accentColor,
    this.isTesting = false,
    this.onTestReachability,
    this.onTestFullAuth,
  });

  /// The connection's id, or null if this is a brand-new host (whose id
  /// hasn't been generated yet). When null, the section starts with all
  /// rows in "Use base" mode.
  final String? hostId;

  /// The base host's address - used as the inherited placeholder text.
  final String baseAddress;

  /// The base host's port - used as the inherited placeholder text.
  final int basePort;

  /// The base host's SSH username (from the linked identity, if any).
  /// Empty string when the host has no identity assigned.
  final String baseUsername;

  /// The base host's identity (key) row id, or null when none is attached.
  /// Rendered read-only in the base reference card so the user can see what
  /// each network inherits.
  final String? baseIdentityKeyId;

  /// The base host's jump chain (the legacy single `connectViaId` wrapped in
  /// a list, or empty for a direct connection). Used for the base reference
  /// card and the inherited jump indicator on collapsed rows.
  final List<String> baseJumpChain;

  /// Accent color for the section header - matches the host's color label
  /// so the section visually reads as part of the host edit form.
  final Color accentColor;

  /// True while a connection probe is already running (from any row or the
  /// footer). Disables every per-row "Test as" control so two probes can't
  /// overlap and fight over the shared result banner.
  final bool isTesting;

  /// Reachability / full-auth probes, threaded down from the host editor.
  /// Null (e.g. a brand-new unsaved host) hides the "Test as" control.
  final TestProbe? onTestReachability;
  final TestProbe? onTestFullAuth;

  @override
  ConsumerState<HostNetworkOverridesSection> createState() =>
      HostNetworkOverridesSectionState();
}

class HostNetworkOverridesSectionState
    extends ConsumerState<HostNetworkOverridesSection> {
  /// One draft per network. Keyed by network id, populated when the
  /// section finishes loading the existing overrides + networks list.
  final Map<String, _OverrideDraft> _drafts = {};

  /// Cached list of networks (in evaluation order) once loaded. Default
  /// is always last.
  List<Network>? _networks;

  /// Has the section finished its initial load? Until then, we render a
  /// thin loading placeholder.
  bool _loaded = false;

  /// True once the existing overrides have finished loading from the DB.
  /// The parent form MUST check this before persisting `bakeDrafts()` - the
  /// section is now always built (inside the inspector's IndexedStack), so
  /// saving before the async load completes would bake an empty draft list
  /// and wipe the host's real overrides.
  bool get isLoaded => _loaded;
  String? _loadError;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  /// Read networks + existing overrides once at mount time, then build
  /// the per-row drafts. After this we never re-read from the
  /// repository, so the user's in-progress edits aren't clobbered if
  /// some background stream emits.
  Future<void> _bootstrap() async {
    try {
      final networks = await ref.read(allNetworksProvider.future);

      // Initial overrides: empty for a new host, otherwise fetch from repo.
      final existing = widget.hostId == null
          ? <HostNetworkOverride>[]
          : await ref.read(
              hostNetworkOverridesProvider(widget.hostId!).future,
            );

      // Build a draft per network. Existing overrides populate the row,
      // missing ones default to "Use base".
      for (final net in networks) {
        final match = existing.where((o) => o.networkId == net.id).firstOrNull;
        _drafts[net.id] = _OverrideDraft.fromExisting(net.id, match);
      }

      if (!mounted) return;
      setState(() {
        _networks = networks;
        _loaded = true;
      });
    } catch (e) {
      if (!mounted) return;
      setState(() => _loadError = e.toString());
    }
  }

  @override
  void dispose() {
    for (final draft in _drafts.values) {
      draft.dispose();
    }
    super.dispose();
  }

  // ── Public API ──────────────────────────────────────────────────

  /// Build the list of overrides the parent should persist via
  /// [HostNetworkOverridesRepository.replaceForHost]. Drafts in
  /// "Use base" mode are dropped; "Skip" emits a `skipHost: true`
  /// override; "Override" emits a row whose null fields signal "inherit".
  ///
  /// Empty override rows (Override mode but no fields set, no jump
  /// chain) are filtered out - they would be functionally equivalent
  /// to "Use base" and would just bloat the storage.
  List<HostNetworkOverride> bakeDrafts(String resolvedHostId) {
    final out = <HostNetworkOverride>[];
    for (final entry in _drafts.entries) {
      final baked = entry.value.bake(
        hostId: resolvedHostId,
        networkId: entry.key,
      );
      if (baked == null) continue;
      out.add(baked);
    }
    return out;
  }

  // ── Build ───────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    if (_loadError != null) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Text(
          'Error: $_loadError',
          style: TextStyle(color: AppColors.v3Error, fontSize: 12),
        ),
      );
    }

    if (!_loaded || _networks == null) {
      return const Padding(
        padding: EdgeInsets.symmetric(vertical: 16),
        child: Center(
          child: SizedBox(
            width: 18,
            height: 18,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    // The matched network + WHY it matched (the winning trigger), so a
    // matched row can explain itself ("on subnet 10.0.0.0/24").
    final match = ref.watch(detectedNetworkMatchProvider).valueOrNull;
    final matchedId = match?.network.id;

    // Whether any non-fallback (user-defined) network exists. When none do,
    // the per-network editor only offers the Default row, so we surface a
    // gentle pointer at the Networks page.
    final hasCustomNetworks = _networks!.any((n) => !n.isFallback);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        ZestSectionHeader.category(
          label: l10n.hostNetworksSection,
          dot: widget.accentColor,
          labelColor: widget.accentColor,
        ),
        const SizedBox(height: 4),
        Text(
          l10n.hostNetworksDescription,
          style: TextStyle(
            fontSize: 12,
            color: AppColors.v3TextTertiary,
          ),
        ),
        const SizedBox(height: 12),
        // ── Base reference card (read-only) ───────────────────────
        _BasePreviewCard(
          address: widget.baseAddress,
          port: widget.basePort,
          username: widget.baseUsername,
          identityKeyId: widget.baseIdentityKeyId,
          jumpChain: widget.baseJumpChain,
        ),
        const SizedBox(height: 12),
        if (!hasCustomNetworks) ...[
          _EmptyNetworksNote(label: l10n.hostNetworksNoCustomNetworks),
          const SizedBox(height: 8),
        ],
        for (final net in _networks!)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: _OverrideRow(
              network: net,
              draft: _drafts[net.id]!,
              isMatched: matchedId == net.id,
              matchedReason: matchedId == net.id ? match?.reason : null,
              baseAddress: widget.baseAddress,
              basePort: widget.basePort,
              baseUsername: widget.baseUsername,
              baseJumpChain: widget.baseJumpChain,
              currentHostId: widget.hostId,
              isTesting: widget.isTesting,
              onTestReachability: widget.onTestReachability,
              onTestFullAuth: widget.onTestFullAuth,
              onChanged: () {
                // Force a parent rebuild so child rows that depend on the
                // matched-network hint refresh together. (Cheap - the
                // parent only paints the section.)
                if (mounted) setState(() {});
              },
            ),
          ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Draft model
// ══════════════════════════════════════════════════════════════════

enum _RowMode { useBase, override, skip }

/// The jump chain an Override row saves: its hops; none and "(direct)"
/// chosen ([direct]), an empty chain (no jump on this network); none
/// chosen, null (the host's own jump host).
List<String>? overrideJumpChain(List<String> hops, {required bool direct}) {
  if (hops.isNotEmpty) return hops;
  return direct ? const <String>[] : null;
}

/// What an Override row saves for [existing] (null: a row never saved),
/// after the jump hosts [picks] were chosen in it, each at its index (null:
/// "(direct)"): the row's own save path, for tests.
@visibleForTesting
HostNetworkOverride? bakeOverrideAfterPicks(
  HostNetworkOverride? existing, {
  required String hostId,
  required String networkId,
  List<(int, String?)> picks = const [],
  bool asHostAfter = false,
}) {
  final draft = _OverrideDraft.fromExisting(networkId, existing);
  if (picks.isNotEmpty || asHostAfter) draft.mode = _RowMode.override;
  for (final (index, id) in picks) {
    draft.setJumpAt(index, id);
  }
  // "As the host has it" chosen after the picks.
  if (asHostAfter) draft.setJumpAsHost();
  final out = draft.bake(hostId: hostId, networkId: networkId);
  draft.dispose();
  return out;
}

/// Mutable per-row state held in [_HostNetworkOverridesSectionState].
/// Holds the controllers for free-form fields plus the discrete picks
/// (mode, identity, jump chain). Has a [bake] method that produces an
/// immutable [HostNetworkOverride] (or null if the row has nothing
/// worth persisting).
class _OverrideDraft {
  _OverrideDraft._({
    required this.networkId,
    required this.existingId,
    required this.mode,
    required this.addressController,
    required this.portController,
    required this.usernameController,
    required this.identityKeyId,
    required this.jumpChain,
    this.jumpDirect = false,
  });

  factory _OverrideDraft.fromExisting(
    String networkId,
    HostNetworkOverride? existing,
  ) {
    final mode = existing == null
        ? _RowMode.useBase
        : (existing.skipHost == true ? _RowMode.skip : _RowMode.override);
    final addressCtl = TextEditingController(text: existing?.address ?? '');
    final portCtl = TextEditingController(
      text: existing?.port == null ? '' : existing!.port!.toString(),
    );
    final usernameCtl =
        TextEditingController(text: existing?.username ?? '');
    final jumps = <String>[
      if (existing?.jumpHostId != null) existing!.jumpHostId!,
      if (existing?.jumpHostChain != null) ...existing!.jumpHostChain!,
    ];
    return _OverrideDraft._(
      networkId: networkId,
      existingId: existing?.id,
      mode: mode,
      addressController: addressCtl,
      portController: portCtl,
      usernameController: usernameCtl,
      identityKeyId: existing?.identityKeyId,
      jumpChain: jumps,
      // Saved as an explicit empty chain: "(direct)" on this network, which
      // a save must keep (it read as "as the host has it" and became that).
      jumpDirect: existing?.jumpHostId == null && existing?.jumpHostChain?.isEmpty == true,
    );
  }

  final String networkId;

  /// The id of the existing override row, if one was loaded. Reused on
  /// save so an upsert truly updates in place rather than churning rows.
  final String? existingId;

  _RowMode mode;
  final TextEditingController addressController;
  final TextEditingController portController;
  final TextEditingController usernameController;
  String? identityKeyId;
  final List<String> jumpChain;

  /// "(direct)" was chosen for the jump host: on this network the host is
  /// reached with no jump, whatever jump host the host itself has. Saved as
  /// an empty chain; an empty chain without it means "as the host has it".
  bool jumpDirect;

  /// The jump host at [index] of the chain is [id]; null is "(direct)",
  /// which, where it leaves the chain with no hop, means no jump at all.
  void setJumpAt(int index, String? id) {
    // Lengthen the chain if necessary; clear "" for unset slots.
    while (jumpChain.length <= index) {
      jumpChain.add('');
    }
    jumpChain[index] = id ?? '';
    jumpDirect = jumpChain.every((h) => h.isEmpty);
  }

  /// Nothing chosen for the jump host: on this network the host goes the
  /// way it has itself (through its own jump host, or none).
  void setJumpAsHost() {
    jumpChain.clear();
    jumpDirect = false;
  }

  /// Reduce this draft to a persistable [HostNetworkOverride], or null
  /// if it should be dropped (Use base mode, or Override mode with
  /// nothing actually filled in).
  HostNetworkOverride? bake({
    required String hostId,
    required String networkId,
  }) {
    switch (mode) {
      case _RowMode.useBase:
        return null;
      case _RowMode.skip:
        return HostNetworkOverride(
          id: existingId ?? '',
          hostId: hostId,
          networkId: networkId,
          skipHost: true,
        );
      case _RowMode.override:
        final address = addressController.text.trim();
        final portText = portController.text.trim();
        final username = usernameController.text.trim();
        // Reject out-of-range ports rather than persisting a value the
        // SSH socket layer will only fail on later. The 5-digit input
        // formatter still allows 65536-99999.
        final parsedPort = int.tryParse(portText);
        final port = (parsedPort != null &&
                parsedPort >= 1 &&
                parsedPort <= 65535)
            ? parsedPort
            : null;
        final cleanedChain = jumpChain
            .where((id) => id.isNotEmpty)
            .toList(growable: false);
        // The chain semantics differ between "no chain set (inherit)"
        // and "explicit empty chain (clear base jump)": "(direct)" chosen
        // is the explicit empty chain, no jump on this network even where
        // the host has a jump host; nothing chosen inherits the host's.
        final chainOrNull = overrideJumpChain(cleanedChain, direct: jumpDirect);

        final override = HostNetworkOverride(
          id: existingId ?? '',
          hostId: hostId,
          networkId: networkId,
          address: address.isEmpty ? null : address,
          port: port,
          username: username.isEmpty ? null : username,
          identityKeyId: identityKeyId,
          jumpHostChain: chainOrNull,
        );
        // Skip rows that are "Override" but have no actionable content -
        // storing them is wasteful and reads as misleading in the UI.
        return override.isEmpty ? null : override;
    }
  }

  void dispose() {
    addressController.dispose();
    portController.dispose();
    usernameController.dispose();
  }
}

// ══════════════════════════════════════════════════════════════════
// Override row
// ══════════════════════════════════════════════════════════════════

class _OverrideRow extends ConsumerStatefulWidget {
  const _OverrideRow({
    required this.network,
    required this.draft,
    required this.isMatched,
    required this.matchedReason,
    required this.baseAddress,
    required this.basePort,
    required this.baseUsername,
    required this.baseJumpChain,
    required this.currentHostId,
    required this.isTesting,
    required this.onTestReachability,
    required this.onTestFullAuth,
    required this.onChanged,
  });

  final Network network;
  final _OverrideDraft draft;
  final bool isMatched;

  /// The winning trigger that made this network the current match, or null
  /// when this row isn't the matched one. Drives the "why" caption.
  final NetworkTrigger? matchedReason;
  final String baseAddress;
  final int basePort;
  final String baseUsername;
  final List<String> baseJumpChain;
  final String? currentHostId;
  final bool isTesting;
  final TestProbe? onTestReachability;
  final TestProbe? onTestFullAuth;
  final VoidCallback onChanged;

  @override
  ConsumerState<_OverrideRow> createState() => _OverrideRowState();
}

class _OverrideRowState extends ConsumerState<_OverrideRow> {
  void _setMode(_RowMode mode) {
    setState(() => widget.draft.mode = mode);
    widget.onChanged();
  }

  void _setIdentity(String? id) {
    setState(() => widget.draft.identityKeyId = id);
    widget.onChanged();
  }

  void _setJumpAt(int index, String? id) {
    setState(() => widget.draft.setJumpAt(index, id));
    widget.onChanged();
  }

  void _setJumpAsHost() {
    setState(() => widget.draft.setJumpAsHost());
    widget.onChanged();
  }

  void _addJumpHop() {
    setState(() => widget.draft.jumpChain.add(''));
    widget.onChanged();
  }

  void _removeJumpAt(int index) {
    setState(() => widget.draft.jumpChain.removeAt(index));
    widget.onChanged();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final draft = widget.draft;
    final color = widget.network.effectiveColor;
    final expanded = draft.mode == _RowMode.override;

    // The "why" caption for the matched row (e.g. "on subnet 10.0.0.0/24").
    // An SSID is masked at the source by the name rule; a subnet by the
    // free-text scan the whole caption goes through in recording mode.
    final rawWhy = widget.isMatched
        ? _matchWhyLabel(l10n, widget.matchedReason, ref)
        : null;
    final whyLabel =
        rawWhy == null ? null : Redactable.freeText(rawWhy).displayIn(ref);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Surface,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: widget.isMatched
              ? AppColors.v3AccentPrimary.withValues(alpha: 0.4)
              : AppColors.v3BorderSubtle,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // ── Header row ────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(0, 8, 12, 8),
            child: Row(
              children: [
                // Color bar flush left
                Container(
                  width: 3,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color,
                    borderRadius: const BorderRadius.only(
                      topLeft: Radius.circular(2),
                      bottomLeft: Radius.circular(2),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Container(
                  width: 28,
                  height: 28,
                  decoration: BoxDecoration(
                    color: color.withValues(alpha: 0.18),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  alignment: Alignment.center,
                  child: Icon(widget.network.icon, size: 14, color: color),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // The profile name identifies the environment: painted
                      // in its display form (recording mode).
                      RedactedText(
                        Redactable.network(widget.network.name),
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: AppColors.v3TextPrimary,
                        ),
                      ),
                      if (whyLabel != null)
                        Padding(
                          padding: const EdgeInsets.only(top: 1),
                          child: Text(
                            whyLabel,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w500,
                              color: AppColors.v3AccentInk,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                if (widget.isMatched) ...[
                  _CurrentPill(label: l10n.networksMatchedNow),
                  const SizedBox(width: 8),
                ],
                _ModeDropdown(
                  mode: draft.mode,
                  onChanged: _setMode,
                ),
              ],
            ),
          ),

          // ── Collapsed preview + status chip ───────────────────
          // When the row isn't in Override mode (so no edit fields are
          // shown) surface the resolved connection + a 3-state label so the
          // user can read what happens on this network at a glance.
          if (!expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 12, 10),
              child: _CollapsedPreview(
                mode: draft.mode,
                network: widget.network,
                currentHostId: widget.currentHostId,
                baseAddress: widget.baseAddress,
                basePort: widget.basePort,
                baseJumpChain: widget.baseJumpChain,
              ),
            ),

          // ── Expanded body ─────────────────────────────────────
          if (expanded)
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 12, 12),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _StatusChip(
                    tone: _ChipTone.overrides,
                    label: l10n.hostNetworksStatusOverridden,
                    icon: LucideIcons.pencil,
                  ),
                  const SizedBox(height: 10),
                  Divider(height: 1, color: AppColors.v3BorderSubtle),
                  const SizedBox(height: 12),
                  _OverrideField(
                    label: l10n.hostNetworksAddress,
                    controller: draft.addressController,
                    // The inherited hint names the base address: masked too.
                    hint: l10n.hostNetworksAddressPlaceholder(
                        Redactable.address(widget.baseAddress).displayIn(ref)),
                    identifier: Redactable.address,
                    inputFormatters: [
                      // Cap at 255 chars - comfortably above any real
                      // hostname/IP and stops a paste accident from
                      // ballooning storage.
                      LengthLimitingTextInputFormatter(255),
                    ],
                    onChanged: (_) => widget.onChanged(),
                  ),
                  const SizedBox(height: 8),
                  _OverrideField(
                    label: l10n.hostNetworksPort,
                    controller: draft.portController,
                    hint: l10n.hostNetworksPortPlaceholder(widget.basePort),
                    keyboardType: TextInputType.number,
                    inputFormatters: [
                      FilteringTextInputFormatter.digitsOnly,
                      LengthLimitingTextInputFormatter(5),
                    ],
                    onChanged: (_) => widget.onChanged(),
                  ),
                  const SizedBox(height: 8),
                  _OverrideField(
                    label: l10n.hostNetworksUsername,
                    controller: draft.usernameController,
                    hint: l10n.hostNetworksUsernamePlaceholder(
                      widget.baseUsername.isEmpty
                          ? '-'
                          : Redactable.username(widget.baseUsername)
                              .displayIn(ref),
                    ),
                    identifier: Redactable.username,
                    inputFormatters: [
                      // POSIX usernames cap at 32; allow a generous 64
                      // for non-POSIX systems while still bounding input.
                      LengthLimitingTextInputFormatter(64),
                    ],
                    onChanged: (_) => widget.onChanged(),
                  ),
                  const SizedBox(height: 12),
                  _IdentityPicker(
                    selectedId: draft.identityKeyId,
                    label: l10n.hostNetworksKey,
                    onChanged: _setIdentity,
                  ),
                  const SizedBox(height: 12),
                  _JumpChainPicker(
                    chain: draft.jumpChain,
                    excludeHostId: widget.currentHostId,
                    label: l10n.hostNetworksJumpHost,
                    addLabel: l10n.hostNetworksJumpAddAnother,
                    directLabel: l10n.hostNetworksJumpDirect,
                    asHostLabel: l10n.hostNetworksJumpAsHost,
                    direct: draft.jumpDirect,
                    onAsHost: _setJumpAsHost,
                    onSetAt: _setJumpAt,
                    onAdd: _addJumpHop,
                    onRemoveAt: _removeJumpAt,
                  ),
                  // Per-network enable/disable state for the host's saved
                  // port-forward rules. Renders nothing (incl. no spacing)
                  // when the host has no forwards. Only reachable for a saved
                  // host (currentHostId).
                  if (widget.currentHostId != null)
                    _PortForwardOverridesList(
                      hostId: widget.currentHostId!,
                      networkId: widget.network.id,
                    ),
                ],
              ),
            ),

          // ── Test as this network ──────────────────────────────
          // Reuses the host editor's probes against this row's resolved
          // effective config. Hidden for skipped rows (nothing to reach) and
          // for unsaved hosts (no persisted identity to authenticate with).
          if (widget.currentHostId != null &&
              draft.mode != _RowMode.skip &&
              (widget.onTestReachability != null ||
                  widget.onTestFullAuth != null))
            Padding(
              padding: const EdgeInsets.fromLTRB(15, 0, 12, 12),
              child: _TestAsControl(
                hostId: widget.currentHostId!,
                network: widget.network,
                isTesting: widget.isTesting,
                onTestReachability: widget.onTestReachability,
                onTestFullAuth: widget.onTestFullAuth,
              ),
            ),
        ],
      ),
    );
  }
}

class _CurrentPill extends StatelessWidget {
  const _CurrentPill({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: AppColors.v3AccentPrimary.withValues(alpha: 0.18),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: AppColors.v3AccentPrimary.withValues(alpha: 0.3),
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w600,
          color: AppColors.v3AccentInk,
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Match-reason phrasing
// ══════════════════════════════════════════════════════════════════

/// Compact "why this network matched" phrasing for the matched row's
/// caption (e.g. "on subnet 10.0.0.0/24", "on Wi-Fi 'Home'", "fallback").
/// Returns null when there's nothing meaningful to say (unknown trigger).
/// Painted, so an SSID takes its display form (recording mode).
String? _matchWhyLabel(
    AppLocalizations l10n, NetworkTrigger? reason, WidgetRef ref) {
  if (reason == null) return null;
  return switch (reason) {
    SsidTrigger(:final ssid) =>
      l10n.hostNetworksMatchWhySsid(Redactable.network(ssid).displayIn(ref)),
    SubnetTrigger(:final cidr) => l10n.hostNetworksMatchWhySubnet(cidr),
    CellularTrigger() => l10n.hostNetworksMatchWhyCellular,
    ConnectivityTrigger(:final kind) =>
      l10n.hostNetworksMatchWhyConnectivity(_connectivityKindLabel(l10n, kind)),
    AlwaysTrigger() => l10n.hostNetworksMatchWhyFallback,
    // `_UnknownTrigger` (a network authored by a newer build) - say nothing.
    _ => null,
  };
}

String _connectivityKindLabel(AppLocalizations l10n, ConnectivityKind kind) =>
    switch (kind) {
      ConnectivityKind.wifi => l10n.networkConnectivityWifi,
      ConnectivityKind.ethernet => l10n.networkConnectivityEthernet,
      ConnectivityKind.cellular => l10n.networkConnectivityCellular,
      ConnectivityKind.vpn => l10n.networkConnectivityVpn,
      ConnectivityKind.none => l10n.networkConnectivityNone,
    };

// ══════════════════════════════════════════════════════════════════
// Collapsed-row status chip + resolved preview
// ══════════════════════════════════════════════════════════════════

/// The three resolution states a network row can be in. Mirrors
/// [HostNetworkStatus] but scoped to chip rendering (tone + label).
enum _ChipTone { inherits, overrides, unreachable }

/// Small pill communicating a row's resolution state at a glance. Uses only
/// v3 tokens: muted for inherit, accent for override, warning (readable, not
/// alarming) for skip.
class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.tone,
    required this.label,
    required this.icon,
  });

  final _ChipTone tone;
  final String label;
  final IconData icon;

  @override
  Widget build(BuildContext context) {
    final (Color fg, Color bg, Color border) = switch (tone) {
      _ChipTone.inherits => (
          AppColors.v3TextTertiary,
          AppColors.v3Background,
          AppColors.v3BorderSubtle,
        ),
      _ChipTone.overrides => (
          AppColors.v3AccentPrimary,
          AppColors.v3AccentPrimary.withValues(alpha: 0.18),
          AppColors.v3AccentPrimary.withValues(alpha: 0.3),
        ),
      _ChipTone.unreachable => (
          AppColors.v3Warning,
          AppColors.v3Warning.withValues(alpha: 0.14),
          AppColors.v3Warning.withValues(alpha: 0.3),
        ),
    };

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 11, color: fg),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w600,
              color: fg,
            ),
          ),
        ],
      ),
    );
  }
}

/// The collapsed-state body of a network row: a status chip plus (for
/// non-skipped rows) the effective `address:port` and a jump indicator,
/// read straight off [hostNetworkResolutionsProvider] (the pure engine
/// merge) so it can't drift from what the connect flow would actually do.
class _CollapsedPreview extends ConsumerWidget {
  const _CollapsedPreview({
    required this.mode,
    required this.network,
    required this.currentHostId,
    required this.baseAddress,
    required this.basePort,
    required this.baseJumpChain,
  });

  final _RowMode mode;
  final Network network;
  final String? currentHostId;
  final String baseAddress;
  final int basePort;
  final List<String> baseJumpChain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    // Skip is authoritative from the live draft - a brand-new unsaved skip
    // wouldn't yet appear in the persisted resolutions provider.
    if (mode == _RowMode.skip) {
      return Align(
        alignment: Alignment.centerLeft,
        child: _StatusChip(
          tone: _ChipTone.unreachable,
          label: l10n.hostNetworksStatusUnreachable,
          icon: LucideIcons.x,
        ),
      );
    }

    // Use-base rows: show the resolved connection. Prefer the engine's
    // computed inherits preview; fall back to the base values for a
    // new/unsaved host or a transient mid-edit divergence.
    HostNetworkResolution? resolution;
    if (currentHostId != null) {
      final resolutions = ref
          .watch(hostNetworkResolutionsProvider(currentHostId!))
          .valueOrNull;
      resolution =
          resolutions?.where((r) => r.network.id == network.id).firstOrNull;
    }
    final useResolved = resolution?.status == HostNetworkStatus.inherits &&
        resolution?.preview != null;
    final address = useResolved ? resolution!.preview!.address : baseAddress;
    final port = useResolved ? resolution!.preview!.port : basePort;
    final jumpCount = useResolved
        ? resolution!.preview!.jumpChain.length
        : baseJumpChain.length;

    return Row(
      children: [
        _StatusChip(
          tone: _ChipTone.inherits,
          label: l10n.hostNetworksStatusInherits,
          icon: LucideIcons.arrowDown,
        ),
        const SizedBox(width: 8),
        Expanded(
          child: _ResolvedPreviewLine(
            address: address,
            port: port,
            jumpCount: jumpCount,
            color: AppColors.v3TextTertiary,
          ),
        ),
      ],
    );
  }
}

/// One-line `address:port` (+ jump indicator) in the terminal mono face.
class _ResolvedPreviewLine extends ConsumerWidget {
  const _ResolvedPreviewLine({
    required this.address,
    required this.port,
    required this.jumpCount,
    required this.color,
  });

  final String address;
  final int port;
  final int jumpCount;
  final Color color;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final target = address.trim().isEmpty
        ? '-'
        : Redactable.address('$address:$port').displayIn(ref);
    return Row(
      children: [
        Flexible(
          child: Text(
            target,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
              color: color,
            ),
          ),
        ),
        if (jumpCount > 0) ...[
          const SizedBox(width: 8),
          _JumpBadge(count: jumpCount),
        ],
      ],
    );
  }
}

/// A muted "via N jumps" indicator used wherever a jump chain is non-empty.
class _JumpBadge extends StatelessWidget {
  const _JumpBadge({required this.count});

  final int count;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          LucideIcons.gitBranch,
          size: 11,
          color: AppColors.v3TextTertiary,
        ),
        const SizedBox(width: 3),
        Text(
          l10n.hostNetworksJumpBadge(count),
          style: TextStyle(
            fontSize: 10,
            fontWeight: FontWeight.w500,
            color: AppColors.v3TextTertiary,
          ),
        ),
      ],
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Base reference card (read-only)
// ══════════════════════════════════════════════════════════════════

/// Read-only summary of the host's base connection - the values every
/// network inherits unless it overrides them below. Resolves the identity
/// and jump-host display names from their providers.
class _BasePreviewCard extends ConsumerWidget {
  const _BasePreviewCard({
    required this.address,
    required this.port,
    required this.username,
    required this.identityKeyId,
    required this.jumpChain,
  });

  final String address;
  final int port;
  final String username;
  final String? identityKeyId;
  final List<String> jumpChain;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    // Resolve the identity label (username shown separately). Every value in
    // this card is painted, so each goes through its rule in recording mode.
    String? identityLabel;
    if (identityKeyId != null) {
      final identities = ref.watch(identitiesProvider).valueOrNull;
      final match =
          identities?.where((i) => i.id == identityKeyId).firstOrNull;
      final label = match?.label;
      identityLabel =
          label == null ? null : Redactable.keyName(label).displayIn(ref);
    }

    // Resolve jump-host display names into a "A → B" route string.
    String? jumpRoute;
    if (jumpChain.isNotEmpty) {
      final rows = ref.watch(connectionsWithDetailsProvider).valueOrNull;
      final names = <String>[];
      for (final id in jumpChain) {
        final row =
            rows?.where((r) => r.connection.id == id).firstOrNull;
        final c = row?.connection;
        names.add(
          c == null
              ? id
              : (c.label.isEmpty
                  ? Redactable.address(c.host).displayIn(ref)
                  : Redactable.host(c.label).displayIn(ref)),
        );
      }
      jumpRoute = names.join(' → ');
    }

    final target = address.trim().isEmpty
        ? '-'
        : Redactable.address('$address:$port').displayIn(ref);
    final shownUsername =
        username.isEmpty ? '-' : Redactable.username(username).displayIn(ref);

    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
      ),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(
                LucideIcons.lock,
                size: 12,
                color: AppColors.v3TextTertiary,
              ),
              const SizedBox(width: 6),
              // The title takes the row's room, the badge at its end (a title
              // in a Flexible beside a Spacer had half of it, and lost the end
              // of "Basiskonfiguration").
              Expanded(
                child: Text(
                  l10n.hostNetworksBaseLabel,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w700,
                    color: AppColors.v3TextSecondary,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: AppColors.v3Surface,
                  borderRadius: BorderRadius.circular(6),
                  border:
                      Border.all(color: AppColors.v3BorderSubtle, width: 1),
                ),
                child: Text(
                  l10n.hostNetworksBaseReadOnly,
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.w600,
                    color: AppColors.v3TextTertiary,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            target,
            style: TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: AppColors.v3TextPrimary,
            ),
          ),
          const SizedBox(height: 6),
          _BaseFieldLine(
            label: l10n.hostNetworksUsername,
            value: shownUsername,
          ),
          if (identityLabel != null) ...[
            const SizedBox(height: 2),
            _BaseFieldLine(
              label: l10n.hostNetworksKey,
              value: identityLabel,
            ),
          ],
          if (jumpRoute != null) ...[
            const SizedBox(height: 2),
            _BaseFieldLine(
              label: l10n.hostNetworksJumpHost,
              value: jumpRoute,
            ),
          ],
          const SizedBox(height: 8),
          Text(
            l10n.hostNetworksBaseSubtitle,
            style: TextStyle(
              fontSize: 10,
              color: AppColors.v3TextTertiary,
            ),
          ),
        ],
      ),
    );
  }
}

/// A `label   value` line in the base reference card. Value is dimmed so
/// it reads as reference data rather than an editable field.
class _BaseFieldLine extends StatelessWidget {
  const _BaseFieldLine({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: _overrideLabelWidth(context),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.v3TextTertiary,
            ),
          ),
        ),
        Expanded(
          child: Text(
            value,
            style: TextStyle(
              fontSize: 12,
              color: AppColors.v3TextSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// The width of the names' column in a network's overrides: 84 at the text
/// size the app is drawn at, and as much wider as the text grows (in 84, at
/// 1.3 times, "Benutzername" and "Имя пользователя" were cut).
double _overrideLabelWidth(BuildContext context) => 84 * MediaQuery.textScalerOf(context).scale(11) / 11;

/// Muted note shown when the user has no custom networks - the per-network
/// editor then only offers the Default row.
class _EmptyNetworksNote extends StatelessWidget {
  const _EmptyNetworksNote({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          color: AppColors.v3TextTertiary,
          height: 1.4,
        ),
      ),
    );
  }
}

class _ModeDropdown extends StatelessWidget {
  const _ModeDropdown({required this.mode, required this.onChanged});

  final _RowMode mode;
  final ValueChanged<_RowMode> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;

    String labelFor(_RowMode m) => switch (m) {
          _RowMode.useBase => l10n.hostNetworksUseDefault,
          _RowMode.override => l10n.hostNetworksOverride,
          _RowMode.skip => l10n.hostNetworksSkip,
        };

    // The collapsed control uses a compact label so a long option (the
    // verbose "Mark unreachable from this network") can't overflow the
    // header row at phone width - the full text still shows in the menu.
    String collapsedLabelFor(_RowMode m) => switch (m) {
          _RowMode.useBase => l10n.hostNetworksUseDefault,
          _RowMode.override => l10n.hostNetworksOverride,
          _RowMode.skip => l10n.hostNetworksSkipShort,
        };

    return PopupMenuButton<_RowMode>(
      tooltip: '',
      color: AppColors.v3Surface,
      onSelected: onChanged,
      itemBuilder: (_) => [
        for (final m in _RowMode.values)
          PopupMenuItem<_RowMode>(
            value: m,
            child: Text(
              labelFor(m),
              style: TextStyle(
                fontSize: 12,
                color: m == mode
                    ? AppColors.v3AccentInk
                    : AppColors.v3TextPrimary,
                fontWeight: m == mode ? FontWeight.w600 : FontWeight.w400,
              ),
            ),
          ),
      ],
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        decoration: BoxDecoration(
          color: AppColors.v3Background,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              collapsedLabelFor(mode),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: mode == _RowMode.skip
                    ? AppColors.v3Error
                    : AppColors.v3TextSecondary,
              ),
            ),
            const SizedBox(width: 4),
            Icon(
              LucideIcons.chevronDown,
              size: 12,
              color: AppColors.v3TextTertiary,
            ),
          ],
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Override fields
// ══════════════════════════════════════════════════════════════════

class _OverrideField extends StatelessWidget {
  const _OverrideField({
    required this.label,
    required this.controller,
    required this.hint,
    required this.onChanged,
    this.keyboardType,
    this.inputFormatters,
    this.identifier,
  });

  final String label;
  final TextEditingController controller;
  final String hint;
  final ValueChanged<String> onChanged;
  final TextInputType? keyboardType;
  final List<TextInputFormatter>? inputFormatters;

  /// Set for a field whose value is an identifier (an address, a username):
  /// the recording-mode editor rule then shows a masked stand-in instead of
  /// the real text while the mode is on. Null for a port.
  final Redactable Function(String value)? identifier;

  @override
  Widget build(BuildContext context) {
    final textStyle = TextStyle(
      fontSize: 13,
      color: AppColors.v3TextPrimary,
    );
    final decoration = InputDecoration(
      hintText: hint,
      hintStyle: TextStyle(
        color: AppColors.v3TextTertiary,
        fontSize: 12,
        fontStyle: FontStyle.italic,
      ),
      filled: true,
      fillColor: AppColors.v3Background,
      isDense: true,
      contentPadding: const EdgeInsets.symmetric(
        horizontal: 10,
        vertical: 8,
      ),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.v3BorderSubtle),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(color: AppColors.v3BorderSubtle),
      ),
      focusedBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(6),
        borderSide: BorderSide(
          color: AppColors.v3AccentPrimary,
          width: 1.5,
        ),
      ),
    );
    final field = TextField(
      controller: controller,
      keyboardType: keyboardType,
      inputFormatters: inputFormatters,
      onChanged: onChanged,
      style: textStyle,
      decoration: decoration,
    );
    final kind = identifier;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: _overrideLabelWidth(context),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.v3TextSecondary,
            ),
          ),
        ),
        Expanded(
          child: kind == null
              ? field
              : RecordingMaskedFormField(
                  controller: controller,
                  mask: (raw) => kind(raw).display,
                  style: textStyle,
                  decoration: decoration,
                  child: field,
                ),
        ),
      ],
    );
  }
}

class _IdentityPicker extends ConsumerWidget {
  const _IdentityPicker({
    required this.selectedId,
    required this.label,
    required this.onChanged,
  });

  final String? selectedId;
  final String label;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final identitiesAsync = ref.watch(identitiesProvider);

    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        SizedBox(
          width: _overrideLabelWidth(context),
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w500,
              color: AppColors.v3TextSecondary,
            ),
          ),
        ),
        Expanded(
          child: identitiesAsync.when(
            loading: () => const SizedBox(
              height: 32,
              child: Center(
                child: SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              ),
            ),
            error: (_, _) => const Text('-'),
            data: (identities) {
              final knownIds = identities.map((i) => i.id).toSet();
              final value = (selectedId != null &&
                      knownIds.contains(selectedId))
                  ? selectedId
                  : null;
              // The app's select (a Material dropdown in a box of its own
              // before).
              return ZestSelect<String?>(
                value: value,
                hint: l10n.hostNetworksUseDefault,
                items: [
                  ZestSelectItem(null, l10n.hostNetworksUseDefault),
                  for (final i in identities) ZestSelectItem(i.id, Redactable.keyName(i.label).displayIn(ref)),
                ],
                onChanged: onChanged,
              );
            },
          ),
        ),
      ],
    );
  }
}

class _JumpChainPicker extends ConsumerWidget {
  const _JumpChainPicker({
    required this.chain,
    required this.excludeHostId,
    required this.label,
    required this.addLabel,
    required this.directLabel,
    required this.asHostLabel,
    required this.direct,
    required this.onAsHost,
    required this.onSetAt,
    required this.onAdd,
    required this.onRemoveAt,
  });

  final List<String> chain;
  final String? excludeHostId;
  final String label;
  final String addLabel;
  final String directLabel;

  /// With no hop yet: nothing chosen ([asHostLabel], the host's own way) is
  /// told apart from "(direct)" chosen ([direct], no jump on this network).
  final String asHostLabel;
  final bool direct;
  final VoidCallback onAsHost;
  final void Function(int index, String? id) onSetAt;
  final VoidCallback onAdd;
  final ValueChanged<int> onRemoveAt;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;

    // Jump-host routing is a Squeezed feature: lock this editor on the free
    // tier exactly as the base host's Connect Via field is locked, so a free
    // user cannot configure a chain the connect path would then not dial.
    if (!ref.watch(isProProvider)) {
      return Row(
        children: [
          SizedBox(
            width: _overrideLabelWidth(context),
            child: Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w500,
                color: AppColors.v3TextSecondary,
              ),
            ),
          ),
          Icon(LucideIcons.lock, size: 14, color: AppColors.v3TextTertiary),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              l10n.proFeature,
              style: TextStyle(fontSize: 11, color: AppColors.v3TextTertiary),
            ),
          ),
          TextButton(
            onPressed: () => context.push(Routes.upgrade),
            style: TextButton.styleFrom(
              foregroundColor: AppColors.v3AccentInk,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              textStyle: const TextStyle(
                fontFamily: 'GeistSans',
                fontSize: 11,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(l10n.upgrade),
          ),
        ],
      );
    }

    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            SizedBox(
              width: _overrideLabelWidth(context),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                  color: AppColors.v3TextSecondary,
                ),
              ),
            ),
            if (chain.isEmpty)
              Expanded(
                child: connectionsAsync.when(
                  loading: () => const SizedBox(height: 32),
                  error: (_, _) => const Text('-'),
                  data: (rows) => _JumpHostDropdown(
                    key: const ValueKey('override-jump-first'),
                    selectedId: null,
                    excludeHostId: excludeHostId,
                    excludeOtherHopIds: const <String>{},
                    rows: rows,
                    directLabel: directLabel,
                    asHostLabel: asHostLabel,
                    direct: direct,
                    onAsHost: onAsHost,
                    onChanged: (id) => onSetAt(0, id),
                  ),
                ),
              ),
          ],
        ),
        // One row per existing hop, with delete affordance.
        for (var i = 0; i < chain.length; i++)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Row(
              children: [
                SizedBox(width: _overrideLabelWidth(context)),
                Expanded(
                  child: connectionsAsync.when(
                    loading: () => const SizedBox(height: 32),
                    error: (_, _) => const Text('-'),
                    data: (rows) => _JumpHostDropdown(
                      selectedId: chain[i].isEmpty ? null : chain[i],
                      excludeHostId: excludeHostId,
                      // Exclude every *other* hop in this chain so the
                      // user can't pick the same host twice. The current
                      // hop's own selection stays visible because it's
                      // not in the exclude set.
                      excludeOtherHopIds: <String>{
                        for (var j = 0; j < chain.length; j++)
                          if (j != i && chain[j].isNotEmpty) chain[j],
                      },
                      rows: rows,
                      directLabel: directLabel,
                      onChanged: (id) => onSetAt(i, id),
                    ),
                  ),
                ),
                IconButton(
                  tooltip: l10n.hostNetworksJumpRemove,
                  iconSize: 14,
                  onPressed: () => onRemoveAt(i),
                  splashRadius: 16,
                  icon: Icon(
                    LucideIcons.x,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
              ],
            ),
          ),
        // "Add another hop" button - disabled past the cap. Hidden if
        // we've not yet picked the first hop (chain is empty) so the UI
        // doesn't let the user stack three blank dropdowns.
        if (chain.isNotEmpty && chain.length < _kMaxJumpHops)
          Padding(
            padding: const EdgeInsets.only(top: 6, left: 84),
            child: Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: onAdd,
                icon: const Icon(LucideIcons.plus, size: 12),
                label: Text(addLabel),
                style: TextButton.styleFrom(
                  foregroundColor: AppColors.v3AccentInk,
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  textStyle: const TextStyle(
                    fontFamily: 'GeistSans',
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

/// The value of "(direct)" in a picker that also offers the host's own way
/// (null there): never a host's id.
const String _kDirectChoice = '\u0000direct';

class _JumpHostDropdown extends ConsumerWidget {
  const _JumpHostDropdown({
    super.key,
    required this.selectedId,
    required this.excludeHostId,
    required this.excludeOtherHopIds,
    required this.rows,
    required this.directLabel,
    required this.onChanged,
    this.asHostLabel,
    this.direct = false,
    this.onAsHost,
  });

  /// Where given (the first hop, none chosen yet), null is the host's own
  /// way ([onAsHost]) and "(direct)" a choice of its own ([direct] when it
  /// is the one chosen); [onChanged] gets null for "(direct)" as elsewhere.
  final String? asHostLabel;
  final bool direct;
  final VoidCallback? onAsHost;

  final String? selectedId;
  final String? excludeHostId;

  /// Other hops in the same chain - excluded from the picker so the user
  /// can't pick the same host twice (which would self-loop). The current
  /// row's own selection is *not* in this list, so it stays visible.
  final Set<String> excludeOtherHopIds;
  final List<ConnectionWithDetails> rows;
  final String directLabel;
  final ValueChanged<String?> onChanged;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Filter out the host being edited (no jumping through yourself) and
    // any host already selected as a different hop in this chain.
    // Only hosts signed in to over SSH can be a hop (a remote screen or an
    // FTPS host never: found in a security review); the one saved
    // before stays shown, and the chain refuses it.
    final hosts = rows
        .where(
          (r) =>
              (excludeHostId == null || r.connection.id != excludeHostId) &&
              !excludeOtherHopIds.contains(r.connection.id) &&
              (ConnectionProtocol.storedCanBeJumpHost(r.connection.protocol) || r.connection.id == selectedId),
        )
        .toList();
    final knownIds = hosts.map((h) => h.connection.id).toSet();
    final asHost = asHostLabel;
    final value = (selectedId != null && knownIds.contains(selectedId))
        ? selectedId
        : (asHost != null && direct ? _kDirectChoice : null);
    return ZestSelect<String?>(
      value: value,
      hint: asHost ?? directLabel,
      items: [
        if (asHost != null) ...[
          ZestSelectItem(null, asHost),
          ZestSelectItem(_kDirectChoice, directLabel),
        ] else
          ZestSelectItem(null, directLabel),
        for (final h in hosts)
          // Masked label; the item's value stays the real id.
          ZestSelectItem(
            h.connection.id,
            h.connection.label.isEmpty
                ? Redactable.address(h.connection.host).displayIn(ref)
                : Redactable.host(h.connection.label).displayIn(ref),
            leading: HostGlyph(host: h.connection, group: h.group, size: 16),
          ),
      ],
      onChanged: asHost == null
          ? onChanged
          : (v) => v == null ? onAsHost?.call() : onChanged(v == _kDirectChoice ? null : v),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Per-network port-forward controls
// ══════════════════════════════════════════════════════════════════

/// Compact `host:port → host:port` descriptor for a saved forward. Technical
/// (not prose), mirroring the connection editor's own rule description.
String _portForwardRuleDescription(PortForwardRule rule) {
  if (rule.type == 'dynamic') {
    return 'SOCKS5 ${rule.bindAddress}:${rule.bindPort}';
  }
  if (rule.type == 'remote') {
    return '${rule.remoteHost}:${rule.remotePort} → '
        '${rule.bindAddress}:${rule.bindPort}';
  }
  return '${rule.bindAddress}:${rule.bindPort} → '
      '${rule.remoteHost}:${rule.remotePort}';
}

/// The host's saved port-forward rules, each with a 3-state per-network
/// control. Lives inside a network row's override disclosure body. Renders
/// nothing when the host has no forwards so the body stays uncluttered.
class _PortForwardOverridesList extends ConsumerWidget {
  const _PortForwardOverridesList({
    required this.hostId,
    required this.networkId,
  });

  final String hostId;
  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final rules = ref
            .watch(portForwardRulesForConnectionProvider(hostId))
            .valueOrNull ??
        const <PortForwardRule>[];
    if (rules.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const SizedBox(height: 12),
        Divider(height: 1, color: AppColors.v3BorderSubtle),
        const SizedBox(height: 12),
        Row(
          children: [
            Icon(
              LucideIcons.arrowRightLeft,
              size: 12,
              color: AppColors.v3TextSecondary,
            ),
            const SizedBox(width: 6),
            Text(
              l10n.hostNetworksPortForwardsLabel,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w600,
                color: AppColors.v3TextSecondary,
                letterSpacing: 0.5,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final rule in rules)
          Padding(
            padding: const EdgeInsets.only(bottom: 6),
            child: _PortForwardNetworkControl(
              rule: rule,
              networkId: networkId,
            ),
          ),
      ],
    );
  }
}

/// One saved forward + its 3-state control for a single network. Watches the
/// live per-`(rule, network)` override state and persists a change IMMEDIATELY
/// via the DAO's single write path - never folded into the override
/// `bake()`/save, so there's exactly one write path for this concern.
class _PortForwardNetworkControl extends ConsumerWidget {
  const _PortForwardNetworkControl({
    required this.rule,
    required this.networkId,
  });

  final PortForwardRule rule;
  final String networkId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final overrides = ref
        .watch(portForwardNetworkOverridesForRuleProvider(rule.id))
        .valueOrNull;
    final state = PortForwardNetworkState.fromDb(
      overrides?.where((o) => o.networkId == networkId).firstOrNull?.state,
    );

    return Row(
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // The description carries the bind / remote addresses.
              Text(
                rule.label ??
                    Redactable.freeText(_portForwardRuleDescription(rule))
                        .displayIn(ref),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w500,
                  color: AppColors.v3TextPrimary,
                ),
              ),
              if (rule.label != null)
                Text(
                  Redactable.freeText(_portForwardRuleDescription(rule))
                      .displayIn(ref),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontFamily: 'JetBrainsMono',
                    fontSize: 10,
                    color: AppColors.v3TextTertiary,
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(width: 8),
        _PortForwardStateToggle(
          state: state,
          onChanged: (next) => ref
              .read(portForwardRulesDaoProvider)
              .setNetworkOverrideState(
                ruleId: rule.id,
                networkId: networkId,
                state: next,
              ),
        ),
      ],
    );
  }
}

/// Compact 3-segment control: Inherit | On | Off. Inherit keeps the rule's own
/// base autoStart + networkId semantics on this network; On/Off force it.
class _PortForwardStateToggle extends StatelessWidget {
  const _PortForwardStateToggle({
    required this.state,
    required this.onChanged,
  });

  final PortForwardNetworkState state;
  final ValueChanged<PortForwardNetworkState> onChanged;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: AppColors.v3Background,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _seg(
            label: l10n.hostNetworksPortForwardInherit,
            value: PortForwardNetworkState.inherit,
            activeColor: AppColors.v3TextSecondary,
            radius: const BorderRadius.only(
              topLeft: Radius.circular(5),
              bottomLeft: Radius.circular(5),
            ),
          ),
          _divider(),
          _seg(
            label: l10n.hostNetworksPortForwardOn,
            value: PortForwardNetworkState.on,
            activeColor: AppColors.v3Success,
          ),
          _divider(),
          _seg(
            label: l10n.hostNetworksPortForwardOff,
            value: PortForwardNetworkState.off,
            activeColor: AppColors.v3Warning,
            radius: const BorderRadius.only(
              topRight: Radius.circular(5),
              bottomRight: Radius.circular(5),
            ),
          ),
        ],
      ),
    );
  }

  Widget _divider() =>
      Container(width: 1, height: 22, color: AppColors.v3BorderSubtle);

  Widget _seg({
    required String label,
    required PortForwardNetworkState value,
    required Color activeColor,
    BorderRadius? radius,
  }) {
    final active = state == value;
    return InkWell(
      onTap: active ? null : () => onChanged(value),
      borderRadius: radius,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color:
              active ? activeColor.withValues(alpha: 0.16) : Colors.transparent,
          borderRadius: radius,
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 11,
            fontWeight: active ? FontWeight.w700 : FontWeight.w500,
            color: active ? activeColor : AppColors.v3TextTertiary,
          ),
        ),
      ),
    );
  }
}

// ══════════════════════════════════════════════════════════════════
// Test-as-this-network control
// ══════════════════════════════════════════════════════════════════

enum _TestAsKind { reachability, fullAuth }

/// "Test as this network" - reads this row's resolved effective config from
/// the pure resolutions preview and runs the host editor's reachability /
/// full-auth probe against it. Preview-scoped: it never sets the global
/// manual-network override or mutates app state - it just test-and-reports
/// through the editor's shared result banner.
class _TestAsControl extends ConsumerWidget {
  const _TestAsControl({
    required this.hostId,
    required this.network,
    required this.isTesting,
    required this.onTestReachability,
    required this.onTestFullAuth,
  });

  final String hostId;
  final Network network;
  final bool isTesting;
  final TestProbe? onTestReachability;
  final TestProbe? onTestFullAuth;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final resolutions =
        ref.watch(hostNetworkResolutionsProvider(hostId)).valueOrNull;
    final preview = resolutions
        ?.where((r) => r.network.id == network.id)
        .firstOrNull
        ?.preview;
    // No resolved effective config yet (still loading, or unreachable) -
    // nothing to probe.
    if (preview == null) return const SizedBox.shrink();

    final cfg = EffectiveTestConfig(
      host: preview.address,
      port: preview.port,
      username: preview.username,
      identityKeyId: preview.identityKeyId,
      jumpChain: preview.jumpChain,
    );

    final items = <PopupMenuEntry<_TestAsKind>>[
      if (onTestReachability != null)
        PopupMenuItem<_TestAsKind>(
          value: _TestAsKind.reachability,
          child: Text(
            l10n.hostNetworksTestReachability,
            style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
          ),
        ),
      if (onTestFullAuth != null)
        PopupMenuItem<_TestAsKind>(
          value: _TestAsKind.fullAuth,
          child: Text(
            l10n.hostNetworksTestFullAuth,
            style: TextStyle(fontSize: 12, color: AppColors.v3TextPrimary),
          ),
        ),
    ];
    if (items.isEmpty) return const SizedBox.shrink();

    return Align(
      alignment: Alignment.centerLeft,
      child: PopupMenuButton<_TestAsKind>(
        enabled: !isTesting,
        tooltip: '',
        color: AppColors.v3Surface,
        onSelected: (kind) {
          final probe = kind == _TestAsKind.reachability
              ? onTestReachability
              : onTestFullAuth;
          probe?.call(cfg);
        },
        itemBuilder: (_) => items,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(
            color: AppColors.v3Background,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: AppColors.v3BorderSubtle, width: 1),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (isTesting)
                SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: AppColors.v3TextTertiary,
                  ),
                )
              else
                Icon(
                  LucideIcons.zap,
                  size: 12,
                  color: AppColors.v3AccentInk,
                ),
              const SizedBox(width: 6),
              Text(
                l10n.hostNetworksTestAs,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: isTesting
                      ? AppColors.v3TextTertiary
                      : AppColors.v3AccentInk,
                ),
              ),
              const SizedBox(width: 4),
              Icon(
                LucideIcons.chevronDown,
                size: 12,
                color: AppColors.v3TextTertiary,
              ),
            ],
          ),
        ),
      ),
    );
  }
}

