import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart';
import 'package:zestssh/features/orchards/record/orchard_record.dart';
import 'package:zestssh/features/orchards/widgets/cert_handover_dialogs.dart';
import 'package:zestssh/features/orchards/widgets/orchard_step_up.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart' show ZestFieldLabel;
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/zest_status.dart';
import 'package:zestssh/utils/logger.dart';

// A Crate's certificate authority on screen (3.0): whether it is
// on and how long each certificate lasts, the user names this account signs
// in as, and for owners its settings (how long certificates last, the user
// names each role signs in as, a new key, off) and the commands that make a
// host trust it. Changes are record entries, so they need a recent sign-in.

/// How long a certificate lasts, in words.
String certLifetimeName(int minutes, AppLocalizations l10n) => switch (minutes) {
      60 => l10n.certLifetime1h,
      480 => l10n.certLifetime8h,
      1440 => l10n.certLifetime24h,
      10080 => l10n.certLifetime7d,
      _ => l10n.certLifetime24h,
    };

/// The certificates line of [crate]'s row in the Crates screen.
class CrateCertificatesLine extends ConsumerWidget {
  const CrateCertificatesLine({super.key, required this.orchard, required this.crate, this.pane = false});

  final OrchardSummary orchard;
  final CrateSummary crate;

  /// As the Vaults page's pane shows it: its state first, as a pill, with
  /// how long each certificate lasts; the settings a link in its header.
  final bool pane;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final authorities = ref.watch(crateAuthoritiesProvider(orchard.id)).valueOrNull;
    if (authorities == null) return const SizedBox.shrink();
    final authority = authorities[crate.id];
    final owner = orchard.isOwner && orchard.active;
    final on = authority?.on ?? false;
    // A certificate handed over with nothing of ZestSSH Cloud in between
    // (3.0): a device that holds the authority's key signs the requests
    // handed to it, and needs nobody to sign for it; everybody else who
    // signs in to the Crate's hosts can hand a request to an owner.
    final signsHere = owner && on && (authority?.keyHere ?? false);
    final asksAnOwner =
        on && orchard.active && !signsHere && (authority?.myUserNames?.isNotEmpty ?? false);
    final keeps = [
      for (final a in authorities.values)
        if (a.keyCrate == crate.id) a.crateId,
    ];
    if (!on && !owner && keeps.isEmpty) return const SizedBox.shrink();
    String nameOf(String crateId) {
      final c = orchard.crates.where((c) => c.id == crateId).firstOrNull;
      return c == null ? l10n.crateUnnamed : crateDisplayName(c, l10n);
    }

    // A window opened from here takes the screen while it is up.
    void open(Future<void> Function() show) => overWindow(context, show);
    final small = TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary);
    final keepsLine = keeps.isEmpty
        ? null
        : Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 2),
                child: Icon(LucideIcons.keyRound, size: 13, color: ZestTokens.textSecondary),
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  l10n.crateCertsKeepsKeyOf(keeps.map(nameOf).join(', ')),
                  key: ValueKey('crate-certs-keeps-${crate.id}'),
                  style: small,
                ),
              ),
            ],
          );
    // What this account signs in as, a new key that is needed, the
    // authorities whose key this vault keeps.
    final mine = [
      if (on && authority!.myUserNames != null)
        Text(
          authority.myUserNames!.isEmpty
              ? l10n.crateCertsNoNamesForYou
              : l10n.crateCertsYouSignInAs(authority.myUserNames!.join(', ')),
          key: ValueKey('crate-certs-mine-${crate.id}'),
          style: small,
        ),
      if (owner && (authority?.newKeyNeeded ?? false))
        Row(
          key: ValueKey('crate-certs-new-key-needed-${crate.id}'),
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Icon(LucideIcons.alertTriangle, size: 13, color: ZestTokens.statusWarning),
            ),
            const SizedBox(width: 6),
            Flexible(child: Text(l10n.crateCertsNewKeyNeeded, style: small.copyWith(color: ZestTokens.textPrimary))),
          ],
        ),
      ?keepsLine,
    ];
    // The hosts' commands, signing what a member hands over, asking an
    // owner to sign.
    final more = [
      if (owner && on)
        VaultSettingRow(
          label: l10n.vaultUiCertsHostsLabel,
          helper: l10n.vaultUiCertsHostsHelp,
          control: vaultButton(
            context,
            key: ValueKey('crate-certs-hosts-${crate.id}'),
            onPressed: () => open(() => showCrateHostSetup(context, ref, orchard.id, crate.id)),
            icon: LucideIcons.terminal,
            label: l10n.crateCertsHostSetup,
          ),
        ),
      if (signsHere)
        VaultSettingRow(
          label: l10n.vaultUiSignLabel,
          helper: l10n.vaultUiSignHelp,
          control: vaultButton(
            context,
            key: ValueKey('crate-certs-sign-${crate.id}'),
            onPressed: () => open(() => showSignHandedRequest(context)),
            icon: LucideIcons.fileSignature,
            label: l10n.certSignButton,
          ),
        ),
      if (asksAnOwner)
        VaultSettingRow(
          label: l10n.certHandButton,
          helper: l10n.vaultUiCertsHandHelp,
          control: vaultButton(
            context,
            key: ValueKey('crate-certs-hand-${crate.id}'),
            onPressed: () => open(() => showCertFromOwner(context, orchardId: orchard.id, crateId: crate.id)),
            icon: LucideIcons.qrCode,
            label: l10n.vaultUiAsk,
          ),
        ),
    ];
    void settings() => open(() => showCrateAuthority(context, ref, orchard.id, crate.id));
    if (pane) {
      return KeyedSubtree(
        key: ValueKey('crate-certs-${crate.id}'),
        child: VaultSettingGroup(
          title: l10n.vaultUiGroupCertificates,
          // Set up already: its settings, from the header.
          trailing: owner && authority != null
              ? VaultHeaderLink(
                  key: ValueKey('crate-certs-settings-${crate.id}'), label: l10n.settingsTitle, onTap: settings)
              : null,
          rows: [
            if (owner && authority == null)
              VaultSettingRow(
                label: l10n.vaultUiCertsLabel,
                helper: l10n.vaultUiStateOff,
                helperKey: ValueKey('crate-certs-state-${crate.id}-off'),
                details: mine,
                control: vaultButton(
                  context,
                  key: ValueKey('crate-certs-settings-${crate.id}'),
                  onPressed: settings,
                  icon: LucideIcons.settings2,
                  label: l10n.crateCertsSetUp,
                ),
              )
            else
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      ZestStatusPill(
                        kind: on ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                        label: on ? l10n.vaultUiStateOn : l10n.vaultUiStateOff,
                      ),
                      if (on) ...[
                        const SizedBox(width: 10),
                        Expanded(
                          child: Padding(
                            padding: const EdgeInsets.only(top: 3),
                            child: Text(
                              l10n.vaultsCertsEach(certLifetimeName(authority!.ttlMinutes, l10n)),
                              key: ValueKey('crate-certs-state-${crate.id}-on'),
                              style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.textPrimary),
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  for (final d in mine) Padding(padding: const EdgeInsets.only(top: 6), child: d),
                ],
              ),
            ...more,
          ],
        ),
      );
    }
    return KeyedSubtree(
      key: ValueKey('crate-certs-${crate.id}'),
      child: VaultSettingGroup(
        title: l10n.vaultUiGroupCertificates,
        rows: [
          VaultSettingRow(
            label: l10n.vaultUiCertsLabel,
            helper: on || owner
                ? (on ? l10n.vaultUiCertsOnHelp(certLifetimeName(authority!.ttlMinutes, l10n)) : l10n.vaultUiStateOff)
                : null,
            helperKey: on || owner ? ValueKey('crate-certs-state-${crate.id}-${on ? 'on' : 'off'}') : null,
            details: mine,
            control: owner
                ? vaultButton(
                    context,
                    key: ValueKey('crate-certs-settings-${crate.id}'),
                    onPressed: settings,
                    icon: LucideIcons.settings2,
                    label: authority == null ? l10n.crateCertsSetUp : l10n.crateCertsSettings,
                  )
                : on
                    ? ZestStatusPill(kind: ZestStatusKind.healthy, label: l10n.vaultUiStateOn)
                    : null,
          ),
          ...more,
        ],
      ),
    );
  }
}

/// The certificate settings of [crateId] in [orchardId] (owners).
Future<void> showCrateAuthority(BuildContext context, WidgetRef ref, String orchardId, String crateId) {
  // The editor is the whole window: its footer holds Save, New key and Turn
  // off; its questions take the screen while they are up.
  return showZestModal<void>(
    context: context,
    size: ZestModalSize.standard,
    child: CoverableWindow(child: CrateAuthorityEditor(orchardId: orchardId, crateId: crateId)),
  );
}

/// [crateId] of [orchardId] as this device has it: from the Orchards read,
/// else the Orchard on screen (the list may not have been read yet).
CrateSummary? _crateOf(WidgetRef ref, String orchardId, String crateId) {
  final orchards = [
    ...?ref.read(orchardSummariesProvider).valueOrNull,
    ?ref.read(activeOrchardProvider).valueOrNull,
  ];
  return orchards
      .where((o) => o.id == orchardId)
      .expand((o) => o.crates)
      .where((c) => c.id == crateId)
      .firstOrNull;
}

/// Where a new authority keeps its key: an owners-only Crate, or a new one.
const String _newKeyCrate = '';

class CrateAuthorityEditor extends ConsumerStatefulWidget {
  const CrateAuthorityEditor({super.key, required this.orchardId, required this.crateId});

  final String orchardId;
  final String crateId;

  @override
  ConsumerState<CrateAuthorityEditor> createState() => _CrateAuthorityEditorState();
}

class _CrateAuthorityEditorState extends ConsumerState<CrateAuthorityEditor> {
  final _names = <String, TextEditingController>{};
  int? _ttl;
  String? _keyCrate;
  String? _error;
  bool _busy = false;
  bool _filled = false;

  @override
  void dispose() {
    for (final c in _names.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _field(String role, CrateAuthorityView? authority) => _names.putIfAbsent(
        role,
        () => TextEditingController(text: (authority?.principals[role] ?? const <String>[]).join(' ')),
      );

  /// The user names typed for each role, or null (with [_error] said) when
  /// one is not a name a certificate can carry, or no role has any.
  Map<String, List<String>>? _principals(AppLocalizations l10n) {
    final out = <String, List<String>>{};
    for (final e in _names.entries) {
      final names = parseCertUserNames(e.value.text);
      if (names == null) {
        setState(() => _error = l10n.certNamesInvalid);
        return null;
      }
      if (names.isNotEmpty) out[e.key] = names;
    }
    if (out.isEmpty) {
      setState(() => _error = l10n.certNamesNone);
      return null;
    }
    setState(() => _error = null);
    return out;
  }

  Future<void> _run(Future<void> Function(OrchardService s) change, String done) async {
    final l10n = AppLocalizations.of(context)!;
    final crate = _crateOf(ref, widget.orchardId, widget.crateId);
    setState(() => _busy = true);
    try {
      final summary = (
        what: l10n.stepUpCrate(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)),
        effects: const <String>[],
      );
      if (!await overWindow(context,
              () => withRecentSignIn(context, ref, () => change(ref.read(orchardServiceProvider)), summary: summary)) ||
          !mounted) {
        return;
      }
      ref.read(orchardListVersionProvider.notifier).state++;
      showTopSnackBar(context, done, isSuccess: true);
    } catch (e) {
      AppLogger.warning('Orchard certificates: a change was not made ($e)');
      if (mounted) showTopSnackBar(context, orchardChangeErrorMessage(e, l10n), isError: true, details: '$e');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  /// The Crate that keeps a new key: the one picked, or a new owners-only
  /// Crate made now.
  Future<String> _keyCrateFor(OrchardService s, AppLocalizations l10n) async {
    final picked = _keyCrate;
    if (picked != null && picked != _newKeyCrate) return picked;
    return s.createCrate(widget.orchardId, l10n.certKeyCrateName, ownersOnly: true);
  }

  Future<void> _save(CrateAuthorityView? authority, String crateName) async {
    final l10n = AppLocalizations.of(context)!;
    final principals = _principals(l10n);
    if (principals == null) return;
    final ttl = _ttl ?? authority?.ttlMinutes ?? 1440;
    if (authority == null) {
      await _run(
        (s) async => s.setAuthorityKey(widget.orchardId, widget.crateId,
            keyCrate: await _keyCrateFor(s, l10n),
            ttlMinutes: ttl,
            principals: principals,
            keyLabel: l10n.certKeyLabel(crateName)),
        l10n.certTurnedOn,
      );
    } else {
      await _run(
        (s) => s.changeAuthority(widget.orchardId, widget.crateId, ttlMinutes: ttl, principals: principals),
        authority.on ? l10n.certSaved : l10n.certTurnedOn,
      );
    }
  }

  Future<void> _newKey(CrateAuthorityView authority, String crateName) async {
    final l10n = AppLocalizations.of(context)!;
    final principals = _principals(l10n);
    if (principals == null) return;
    final ok = await overWindow(context, () => ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.neutral,
      title: l10n.certNewKeyTitle,
      body: l10n.certNewKeyBody,
      confirmLabel: l10n.certNewKey,
    ));
    if (ok != true || !mounted) return;
    await _run(
      (s) => s.setAuthorityKey(widget.orchardId, widget.crateId,
          keyCrate: authority.keyCrate,
          ttlMinutes: _ttl ?? authority.ttlMinutes,
          principals: principals,
          keyLabel: l10n.certKeyLabel(crateName)),
      l10n.certNewKeyDone,
    );
  }

  Future<void> _turnOff(String crateName) async {
    final l10n = AppLocalizations.of(context)!;
    // Turning it off ends what it signs: a red button.
    final ok = await overWindow(context, () => ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.certTurnOffTitle(crateName),
      body: l10n.certTurnOffBody,
      confirmLabel: l10n.certTurnOff,
    ));
    if (ok != true || !mounted) return;
    await _run((s) => s.turnAuthorityOff(widget.orchardId, widget.crateId), l10n.certTurnedOff);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final orchard =
        ref.watch(orchardSummariesProvider).valueOrNull?.where((o) => o.id == widget.orchardId).firstOrNull;
    final authorities = ref.watch(crateAuthoritiesProvider(widget.orchardId)).valueOrNull;
    final roles = ref.watch(orchardRolesProvider(widget.orchardId)).valueOrNull;
    final named = _crateOf(ref, widget.orchardId, widget.crateId);
    Widget shell(Widget body,
            {({String label, VoidCallback? onPressed, IconData? icon})? primary,
            ({String label, VoidCallback? onPressed})? secondary,
            ({String label, VoidCallback? onPressed})? tertiary}) =>
        ZestDialogShell(
          size: ZestModalSize.standard,
          tone: ZestDialogTone.info,
          icon: LucideIcons.badgeCheck,
          title: l10n.certDialogTitle(named == null ? l10n.crateUnnamed : crateDisplayName(named, l10n)),
          body: body,
          primaryAction: primary,
          primaryKey: const ValueKey('cert-save'),
          secondaryAction: secondary,
          secondaryKey: const ValueKey('cert-new-key'),
          tertiaryAction: tertiary,
          tertiaryKey: const ValueKey('cert-turn-off'),
        );
    if (orchard == null || authorities == null || roles == null) {
      return shell(const Center(
          child: Padding(padding: EdgeInsets.all(16), child: CircularProgressIndicator(strokeWidth: 2))));
    }
    final authority = authorities[widget.crateId];
    final crate = orchard.crates.where((c) => c.id == widget.crateId).firstOrNull;
    final crateName = crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n);
    final keyCrates = [
      for (final c in orchard.crates)
        if (c.ownersOnly && c.id != widget.crateId) c,
    ];
    if (!_filled) {
      _filled = true;
      _ttl = authority?.ttlMinutes ?? 1440;
      _keyCrate = keyCrates.isEmpty ? _newKeyCrate : keyCrates.first.id;
    }
    final help = TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textSecondary);
    final roleRows = <(String, String)>[
      (FixedRoles.owner, l10n.orchardRoleOwner),
      (FixedRoles.admin, l10n.orchardRoleAdmin),
      for (final r in roles) (r.id, r.name ?? l10n.orchardRoleMember),
    ];

    final body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.certDialogIntro, style: help),
        if (authority != null) ...[
          const SizedBox(height: 12),
          Row(
            children: [
              ZestStatusPill(
                key: const ValueKey('cert-editor-state'),
                kind: authority.on ? ZestStatusKind.healthy : ZestStatusKind.neutral,
                label: authority.on
                    ? l10n.crateCertsOn(certLifetimeName(authority.ttlMinutes, l10n))
                    : l10n.crateCertsOff,
              ),
            ],
          ),
          if (authority.newKeyNeeded) ...[
            const SizedBox(height: 8),
            VaultCallout(
              key: const ValueKey('cert-editor-new-key-needed'),
              kind: ZestStatusKind.warning,
              icon: LucideIcons.alertTriangle,
              text: l10n.crateCertsNewKeyNeeded,
            ),
          ],
        ],
        if (authority == null) ...[
          const SizedBox(height: 16),
          ZestFieldLabel(l10n.certKeyCrateLabel),
          const SizedBox(height: 6),
          ZestSelect<String>(
            key: const ValueKey('cert-key-crate'),
            value: _keyCrate,
            onChanged: _busy ? null : (v) => setState(() => _keyCrate = v),
            items: [
              for (final c in keyCrates) ZestSelectItem(c.id, crateDisplayName(c, l10n)),
              ZestSelectItem(_newKeyCrate, l10n.certKeyCrateNew),
            ],
          ),
          const SizedBox(height: 6),
          Text(l10n.certKeyCrateHelp, style: help),
        ],
        const SizedBox(height: 16),
        ZestFieldLabel(l10n.certLifetimeLabel),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            for (final m in kCaTtlMinutes.toList()..sort())
              VaultChoiceChip(
                key: ValueKey('cert-ttl-$m'),
                label: certLifetimeName(m, l10n),
                selected: _ttl == m,
                onSelected: _busy ? null : (_) => setState(() => _ttl = m),
              ),
          ],
        ),
        const SizedBox(height: 6),
        Text(l10n.certLifetimeHelp, style: help),
        // An outage of ZestSSH Cloud's is the one thing that keeps a member
        // from a new certificate, and a short life makes it bite sooner:
        // said where the life is chosen.
        const SizedBox(height: 4),
        Text(l10n.certLifetimeOutageNote, style: help),
        const SizedBox(height: 16),
        ZestFieldLabel(l10n.certNamesLabel),
        const SizedBox(height: 2),
        Text(l10n.certNamesHelp, style: help),
        const SizedBox(height: 8),
        for (final (id, name) in roleRows)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Row(
              children: [
                SizedBox(
                  width: 120,
                  child: Text(name,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    key: ValueKey('cert-names-$id'),
                    controller: _field(id, authority),
                    enabled: !_busy,
                    style: const TextStyle(fontSize: 12.5, fontFamily: 'JetBrainsMono'),
                    decoration: InputDecoration(isDense: true, hintText: l10n.certNamesHint),
                  ),
                ),
              ],
            ),
          ),
        if (_error != null)
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 1),
                child: Icon(LucideIcons.alertCircle, size: 14, color: ZestTokens.statusCritical),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(_error!,
                    key: const ValueKey('cert-error'),
                    style: TextStyle(fontSize: 12.5, height: 1.4, color: ZestTokens.statusCritical)),
              ),
            ],
          ),
      ],
    );
    return shell(
      body,
      primary: (
        label: authority != null && authority.on ? l10n.certSave : l10n.certTurnOn,
        onPressed: _busy ? null : () => _save(authority, crateName),
        icon: null,
      ),
      secondary: authority == null
          ? null
          : (label: l10n.certNewKey, onPressed: _busy ? null : () => _newKey(authority, crateName)),
      tertiary: authority != null && authority.on
          ? (label: l10n.certTurnOff, onPressed: _busy ? null : () => _turnOff(crateName))
          : null,
    );
  }
}

/// The commands that make a host trust [crateId]'s authority (owners).
Future<void> showCrateHostSetup(BuildContext context, WidgetRef ref, String orchardId, String crateId) {
  final l10n = AppLocalizations.of(context)!;
  final crate = _crateOf(ref, orchardId, crateId);
  // No Close button: the window's X closes it.
  return ZestDialogShell.showModal<void>(
    context,
    size: ZestModalSize.standard,
    tone: ZestDialogTone.info,
    icon: LucideIcons.terminal,
    title: l10n.certHostTitle(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)),
    body: CrateHostSetupView(orchardId: orchardId, crateId: crateId),
  );
}

class CrateHostSetupView extends ConsumerWidget {
  const CrateHostSetupView({super.key, required this.orchardId, required this.crateId});

  final String orchardId;
  final String crateId;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final authority = ref.watch(crateAuthoritiesProvider(orchardId)).valueOrNull?[crateId];
    if (authority == null) return const SizedBox.shrink();
    final help = TextStyle(fontSize: 12, height: 1.45, color: ZestTokens.textSecondary);
    final script = certHostSetupScript(keyLine: authority.keyLine, oldKeyLines: authority.oldKeyLines);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(l10n.certHostIntro, style: help),
        if (authority.newKeyNeeded) ...[
          const SizedBox(height: 12),
          VaultCallout(kind: ZestStatusKind.warning, icon: LucideIcons.alertTriangle, text: l10n.certHostNewKeyFirst),
        ],
        const SizedBox(height: 12),
        Text(l10n.certHostFingerprint(authority.fingerprint),
            key: const ValueKey('cert-host-fingerprint'),
            style: TextStyle(fontSize: 12, fontFamily: 'JetBrainsMono', color: ZestTokens.textPrimary)),
        const SizedBox(height: 8),
        // The commands as a code block, one step lighter than the window,
        // with its own scroll where it is long.
        Container(
          constraints: const BoxConstraints(maxHeight: 240),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceChip,
            border: Border.all(color: ZestTokens.borderSubtle),
            borderRadius: BorderRadius.circular(8),
          ),
          child: ZestScrollFade(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(12),
              child: SelectableText(
                script,
                key: const ValueKey('cert-host-script'),
                style: TextStyle(fontSize: 12, height: 1.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textPrimary),
              ),
            ),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: AlignmentDirectional.centerStart,
          child: vaultButton(
            context,
            key: const ValueKey('cert-host-copy'),
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: script));
              if (context.mounted) showTopSnackBar(context, l10n.certHostCopied, isSuccess: true);
            },
            icon: LucideIcons.copy,
            label: l10n.certHostCopy,
          ),
        ),
        const SizedBox(height: 12),
        Text(authority.oldKeyLines.isEmpty ? l10n.certHostNotes : l10n.certHostNotesNewKey, style: help),
      ],
    );
  }
}
