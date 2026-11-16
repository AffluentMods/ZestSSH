import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/identity/identity_cert_expiry.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart' show KeyPassphraseMode;
import 'package:zestssh/features/keys/key_agent.dart';
import 'package:zestssh/features/keys/key_passphrase.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/password_managers/agent_sources.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/core_providers.dart' show activeSpaceProvider;
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_list_pane.dart' show keyAddedDate, keyKindIcon;
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_scroll_fade.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/utils/line_breaks.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// A selected key's details beside the Keys list:
/// only what is public about it, its private details behind
/// Edit (the editor beside it). Its icon, name and a line of what it is,
/// when it was added and last used; Edit, more and close; its actions
/// (Copy public key, Export, Add to agent); IDENTITY (its fingerprint and
/// public key, each to copy, or the user name and where the password is);
/// USED BY (the hosts that sign in with it, each opening the Hosts page);
/// PROTECTION (where its secret is kept, its passphrase with Add one, Change
/// or Remove, whether the SSH agent holds it, how it syncs, whether
/// unattended runs may use it); and Replace on all hosts and Install on
/// hosts at its foot. Nothing here reads a secret: whether a key has a
/// passphrase is what the device kept when it was saved or edited
/// ([KeyPassphraseFlags]).
class KeysInspectorPane extends ConsumerStatefulWidget {
  const KeysInspectorPane({
    super.key,
    required this.identityId,
    required this.onEdit,
    required this.onClose,
    required this.onCopyPublicKey,
    required this.onOpenHost,
    this.onInstallOnHosts,
    this.onReplaceKey,
    this.onDuplicate,
    this.onMoveTo,
    this.onCopyTo,
    this.onDelete,
    this.onMoveToManager,
    this.onExport,
    this.onAddToAgent,
    this.onReplaceOnHosts,
    this.onPassphrase,
    this.onCheckPassphrase,
  });

  final String identityId;

  /// Opens the editor, which loads the private details.
  final VoidCallback onEdit;
  final VoidCallback onClose;

  /// Copies the key's public line (made from its private key where none was
  /// kept).
  final VoidCallback onCopyPublicKey;
  final ValueChanged<Connection> onOpenHost;

  /// Installs the key on hosts, where it has a public key.
  final VoidCallback? onInstallOnHosts;

  /// A new key in this one's place (the editor, with the key's setup open).
  final VoidCallback? onReplaceKey;
  final VoidCallback? onDuplicate;

  /// Move to... and Copy to...: Personal, or a team's vault (3.4).
  final VoidCallback? onMoveTo;
  final VoidCallback? onCopyTo;
  final VoidCallback? onDelete;

  /// Moves a saved password into a password manager.
  final VoidCallback? onMoveToManager;

  /// Exports the key as OpenSSH files.
  final VoidCallback? onExport;

  /// Gives the key to the computer's SSH agent (none on a phone).
  final VoidCallback? onAddToAgent;

  /// Replaces the key on every host that signs in with it.
  final VoidCallback? onReplaceOnHosts;

  /// Adds, changes or takes off the key's passphrase.
  final ValueChanged<KeyPassphraseMode>? onPassphrase;

  /// Finds out whether the key has a passphrase, where the device does not
  /// know yet.
  final VoidCallback? onCheckPassphrase;

  @override
  ConsumerState<KeysInspectorPane> createState() => _KeysInspectorPaneState();
}

/// How many hosts USED BY lists before Show all.
const int kKeysUsedByShown = 6;

class _KeysInspectorPaneState extends ConsumerState<KeysInspectorPane> {
  bool _allHosts = false;

  @override
  void didUpdateWidget(covariant KeysInspectorPane oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identityId != widget.identityId) _allHosts = false;
  }

  Future<void> _copyFingerprint(String fp) async {
    // Copying the real fingerprint while recording is a reveal (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    await Clipboard.setData(ClipboardData(text: fp));
    if (mounted) showTopSnackBar(context, AppLocalizations.of(context)!.zestKeysFingerprintCopied, isSuccess: true);
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final identities = ref.watch(identitiesProvider).valueOrNull ?? const <Identity>[];
    final identity = identities.where((i) => i.id == widget.identityId).firstOrNull;
    if (identity == null) return const SizedBox.shrink();
    final hosts = ref.watch(identityUsageHostsProvider).valueOrNull?[identity.id] ?? const <Connection>[];
    final lastUsedAt = ref.watch(identityLastUsedProvider).valueOrNull?[identity.id];
    final recording = ref.watch(recordingModeProvider);
    final team = ref.watch(activeSpaceProvider) is OrchardSpace;
    final syncOn = ref.watch(syncIsActiveProvider).valueOrNull ?? false;
    final isKey = identity.authMethod == 'publicKey' && !identity.usesAgent;
    // Whether it has a passphrase, as the device kept it; null: not known.
    final states = ref.watch(keyPassphraseStatesProvider).valueOrNull;
    final sealed = isKey ? (states == null ? null : states[identity.id]) : null;
    final agentShown = isKey && ref.watch(systemAgentProvider) != null;
    final inAgent = agentShown && keyIsInSystemAgent(identity, ref.watch(systemAgentKeysProvider).valueOrNull ?? const {});

    final type = identityTypeLabel(l10n, identity);
    final added = keyAddedDate(l10n, identity.createdAt);
    // A line ends only between its parts: it broke "last used 2" over
    // "hours ago" (found in a design audit).
    final subtitle = breakAtDots(lastUsedAt == null
        ? l10n.keysUiSubtitleNever(type, added)
        : l10n.keysUiSubtitle(type, added, timeAgoInSentence(l10n, lastUsedAt)));
    // A certificate that has run out, or runs out soon, says so under its
    // name, as the editor does: before it fails a sign-in.
    final certReminder =
        identity.certExpired() || identity.certExpiringSoon() ? certExpirySaid(identity, l10n) : null;
    final method = identity.authMethod;
    final fp = identity.publicKeyFingerprint ?? '';
    final publicLine = (identity.publicKeyData ?? '').trim();
    final hasPublicKey = method == 'publicKey' || publicLine.isNotEmpty;
    final canInstall =
        widget.onInstallOnHosts != null && (installLineOf(identity) != null || method == 'publicKey');
    final pmKind = PasswordRef.decode(identity.passwordRef)?.kind;
    final vault = team ? l10n.keysUiInTeamVault : l10n.keysUiInYourVault;

    // ── IDENTITY: what is public about it ───────────────────────────
    final identityFields = <Widget>[
      if (fp.isNotEmpty)
        _Field(
          key: const ValueKey('keys-inspector-fingerprint'),
          label: l10n.keysUiColFingerprint,
          value: RedactedText(Redactable.fingerprint(fp), maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono),
          onCopy: () => _copyFingerprint(fp),
        ),
      if (publicLine.isNotEmpty)
        _Field(
          key: const ValueKey('keys-inspector-public-key'),
          label: l10n.keysUiPublicKey,
          value: Text(
            recording ? '${publicLine.split(RegExp(r'\s+')).first} ${Redactor.fingerprint(publicLine)}' : shortPublicLine(publicLine),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: _mono,
          ),
          onCopy: widget.onCopyPublicKey,
        ),
      if (identity.username.isNotEmpty)
        _Field(
          label: l10n.identityUsername,
          value: RedactedText(Redactable.username(identity.username), maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono),
        ),
      if (method == 'passwordManager')
        if (PasswordRef.decode(identity.passwordRef) case final pmRef?)
        _Field(
          label: l10n.keysUiItem,
          value: Text(pmRef.target, maxLines: 1, overflow: TextOverflow.ellipsis, style: _mono),
        ),
      if (method == 'hardwareToken')
        _Field(
          label: l10n.keysUiAgent,
          value: Text(
            switch (AgentSource.of(identity.agentSource)) {
              AgentSource.onePassword => '1Password',
              AgentSource.bitwarden => 'Bitwarden',
              AgentSource.system => l10n.keysUiSystemAgent,
            },
            style: _plain,
          ),
        ),
      if (method == 'certificate' && (identity.certPrincipals ?? '').isNotEmpty)
        _Field(label: l10n.keysUiPrincipals, value: Text(identity.certPrincipals!, style: _mono)),
      if (method == 'certificate' && identity.certValidBefore != null)
        _Field(
          label: l10n.keysUiValidUntil,
          value: Text(keyAddedDate(l10n, identity.certValidBefore!, now: DateTime(0)), style: _plain),
        ),
    ];

    // ── PROTECTION: where its secret is, how it syncs ───────────────
    final (secretLabel, secretValue) = switch (method) {
      'password' => (l10n.identityPassword, vault),
      'passwordManager' => (
          l10n.identityPassword,
          pmKind == null ? l10n.pmKeyTypeLabel : l10n.keysUiFetchedFrom(passwordManagerName(pmKind)),
        ),
      'hardwareToken' => (l10n.keysUiPrivateKey, l10n.keysUiLivesInAgent),
      'teamCertificate' => (l10n.keysUiPrivateKey, l10n.keysUiTeamCertSigned),
      _ => (l10n.keysUiPrivateKey, vault),
    };

    final shownHosts = _allHosts ? hosts : hosts.take(kKeysUsedByShown).toList();
    final replaceShown = widget.onReplaceOnHosts != null && isKey && hosts.isNotEmpty;
    final more = <PopupMenuEntry<String>>[
      if (widget.onReplaceKey != null) _menuItem('replace', LucideIcons.refreshCw, l10n.zestKeysReplaceKey),
      if (widget.onDuplicate != null) _menuItem('duplicate', LucideIcons.copy, l10n.commonDuplicate),
      if (widget.onMoveTo != null) _menuItem('move_to', LucideIcons.folderInput, l10n.transferMoveTo),
      if (widget.onCopyTo != null) _menuItem('copy_to', LucideIcons.copyPlus, l10n.transferCopyTo),
      if (widget.onDelete != null) ...[
        if (widget.onReplaceKey != null || widget.onDuplicate != null || widget.onMoveTo != null || widget.onCopyTo != null)
          const PopupMenuDivider(),
        _menuItem('delete', LucideIcons.trash2, MaterialLocalizations.of(context).deleteButtonTooltip, danger: true),
      ],
    ];

    return Container(
      key: const ValueKey('keys-inspector'),
      color: ZestTokens.surfacePanel,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Header ──────────────────────────────────────────────
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 12, 12),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: ZestTokens.brand.withValues(alpha: 0.16),
                    borderRadius: BorderRadius.circular(9),
                  ),
                  child: Icon(keyKindIcon(identity), size: 18, color: ZestTokens.brandInk),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      RedactedText(
                        Redactable.keyName(identity.label),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600, color: ZestTokens.textPrimary),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        key: const ValueKey('keys-inspector-subtitle'),
                        style: TextStyle(fontSize: 12, height: 1.35, color: ZestTokens.textTertiary),
                      ),
                      if (certReminder != null) ...[
                        const SizedBox(height: 3),
                        Text(
                          certReminder,
                          key: const ValueKey('keys-inspector-cert-expiry'),
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w500,
                            color: identity.certExpired() ? ZestTokens.statusCritical : ZestTokens.statusWarning,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                ZestButton(
                  key: const ValueKey('keys-inspector-edit'),
                  label: l10n.edit,
                  icon: LucideIcons.pencil,
                  onPressed: widget.onEdit,
                ),
                if (more.isNotEmpty)
                  PopupMenuButton<String>(
                    key: const ValueKey('keys-inspector-more'),
                    tooltip: l10n.zestCommonMoreActions,
                    icon: Icon(LucideIcons.moreHorizontal, size: 18, color: ZestTokens.textSecondary),
                    position: PopupMenuPosition.under,
                    color: ZestTokens.surfaceRaised,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(color: ZestTokens.border),
                    ),
                    onSelected: (v) => switch (v) {
                      'replace' => widget.onReplaceKey?.call(),
                      'duplicate' => widget.onDuplicate?.call(),
                      'move_to' => widget.onMoveTo?.call(),
                      'copy_to' => widget.onCopyTo?.call(),
                      'delete' => widget.onDelete?.call(),
                      _ => null,
                    },
                    itemBuilder: (_) => more,
                  ),
                IconButton(
                  key: const ValueKey('keys-inspector-close'),
                  tooltip: l10n.close,
                  icon: Icon(LucideIcons.x, size: 18, color: ZestTokens.textSecondary),
                  onPressed: widget.onClose,
                ),
              ],
            ),
          ),
          // ── Actions ─────────────────────────────────────────────
          if (hasPublicKey || widget.onMoveToManager != null || widget.onExport != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 14),
              child: Wrap(
                spacing: ZestSizing.buttonGap,
                runSpacing: ZestSizing.buttonGap,
                children: [
                  if (hasPublicKey)
                    ZestButton(
                      key: const ValueKey('keys-copy-public'),
                      label: l10n.keysUiCopyPublicKey,
                      icon: LucideIcons.copy,
                      onPressed: widget.onCopyPublicKey,
                    ),
                  if (widget.onExport != null)
                    ZestButton(
                      key: const ValueKey('keys-export'),
                      label: l10n.keysActExport,
                      icon: LucideIcons.download,
                      onPressed: widget.onExport,
                    ),
                  if (widget.onAddToAgent != null && agentShown)
                    ZestButton(
                      key: const ValueKey('keys-add-to-agent'),
                      label: l10n.keysActAddToAgent,
                      icon: LucideIcons.cpu,
                      onPressed: widget.onAddToAgent,
                    ),
                  if (widget.onMoveToManager != null && method == 'password')
                    ZestButton(
                      key: const ValueKey('pm-move'),
                      label: l10n.pmMoveButton,
                      icon: LucideIcons.arrowRightLeft,
                      onPressed: widget.onMoveToManager,
                    ),
                ],
              ),
            ),
          Divider(height: 1, color: ZestTokens.borderSubtle),
          Expanded(
            child: ZestScrollFade(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(20, 18, 20, 20),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (identityFields.isNotEmpty) ...[
                      ZestSectionHeader(label: l10n.keysUiSectionIdentity),
                      for (final f in identityFields) Padding(padding: const EdgeInsets.only(bottom: 8), child: f),
                      const SizedBox(height: 14),
                    ],
                    ZestSectionHeader(
                      key: const ValueKey('keys-inspector-used-by'),
                      label: l10n.keysUiColUsedBy,
                      count: hosts.length,
                      trailing: hosts.length > kKeysUsedByShown
                          ? ZestButton(
                              key: const ValueKey('keys-inspector-show-all'),
                              label: _allHosts ? l10n.keysUiShowFewer : l10n.keysUiShowAll,
                              variant: ZestButtonVariant.ghost,
                              onPressed: () => setState(() => _allHosts = !_allHosts),
                            )
                          : null,
                    ),
                    if (hosts.isEmpty)
                      Padding(
                        padding: const EdgeInsets.only(bottom: 6),
                        child: Text(l10n.keysDetailNotUsed, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
                      )
                    else
                      for (final h in shownHosts)
                        HostRow(
                          key: ValueKey('keys-inspector-host-${h.id}'),
                          host: h,
                          user: identity.username,
                          onTap: () => widget.onOpenHost(h),
                        ),
                    const SizedBox(height: 18),
                    ZestSectionHeader(label: l10n.keysUiSectionProtection),
                    _Fact(
                      key: const ValueKey('keys-inspector-secret'),
                      label: secretLabel,
                      value: secretValue,
                      icon: LucideIcons.shieldCheck,
                    ),
                    if (isKey)
                      _Fact(
                        key: const ValueKey('keys-inspector-passphrase'),
                        label: l10n.keysActPassphrase,
                        value: switch (sealed) {
                          true => l10n.keysActPassphraseSet,
                          false => l10n.keysActPassphraseNone,
                          null => l10n.keysActPassphraseUnknown,
                        },
                        actions: [
                          if (widget.onPassphrase != null && sealed == false)
                            _FactAction('keys-passphrase-add', l10n.keysActPassphraseAdd,
                                () => widget.onPassphrase!(KeyPassphraseMode.add)),
                          if (widget.onPassphrase != null && sealed == true) ...[
                            _FactAction('keys-passphrase-change', l10n.keysActPassphraseChange,
                                () => widget.onPassphrase!(KeyPassphraseMode.change)),
                            _FactAction('keys-passphrase-remove', l10n.keysActPassphraseRemove,
                                () => widget.onPassphrase!(KeyPassphraseMode.remove)),
                          ],
                          if (widget.onCheckPassphrase != null && sealed == null)
                            _FactAction('keys-passphrase-check', l10n.keysActPassphraseCheck, widget.onCheckPassphrase!),
                        ],
                      ),
                    if (agentShown)
                      _Fact(
                        key: const ValueKey('keys-inspector-agent'),
                        label: l10n.keysActAgentRow,
                        value: inAgent ? l10n.keysActAgentLoaded : l10n.keysActAgentNotLoaded,
                      ),
                    _Fact(
                      key: const ValueKey('keys-inspector-sync'),
                      label: l10n.keysUiSync,
                      value: team ? l10n.keysUiSyncTeam : (syncOn ? l10n.keysUiSyncOn : l10n.keysUiSyncOff),
                    ),
                    _Fact(
                      key: const ValueKey('keys-inspector-unattended'),
                      label: l10n.keysUiUnattended,
                      value: identity.allowUnattended ? l10n.keysUiAllowed : l10n.keysUiNotAllowed,
                    ),
                  ],
                ),
              ),
            ),
          ),
          // ── Footer ──────────────────────────────────────────────
          if (canInstall || replaceShown)
            Container(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 16),
              decoration: BoxDecoration(border: Border(top: BorderSide(color: ZestTokens.borderSubtle))),
              child: Wrap(
                alignment: WrapAlignment.end,
                spacing: ZestSizing.buttonGap,
                runSpacing: ZestSizing.buttonGap,
                children: [
                  if (replaceShown)
                    ZestButton(
                      key: const ValueKey('keys-replace-on-hosts'),
                      label: l10n.keysActReplaceOnHosts(hosts.length),
                      icon: LucideIcons.refreshCw,
                      size: ZestButtonSize.large,
                      onPressed: widget.onReplaceOnHosts,
                    ),
                  if (canInstall)
                    ZestButton(
                      key: const ValueKey('keys-install-on-hosts'),
                      label: l10n.installKeyMenu,
                      icon: LucideIcons.server,
                      variant: ZestButtonVariant.primary,
                      size: ZestButtonSize.large,
                      onPressed: widget.onInstallOnHosts,
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  PopupMenuItem<String> _menuItem(String value, IconData icon, String label, {bool danger = false}) {
    final color = danger ? ZestTokens.statusCritical : ZestTokens.textPrimary;
    return PopupMenuItem<String>(
      key: ValueKey('keys-inspector-$value'),
      value: value,
      height: 36,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 15, color: danger ? color : ZestTokens.textSecondary),
          const SizedBox(width: 10),
          Text(label, style: TextStyle(fontSize: 13, color: color)),
        ],
      ),
    );
  }
}

TextStyle get _mono => TextStyle(fontSize: 12.5, fontFamily: 'JetBrainsMono', color: ZestTokens.textPrimary);
TextStyle get _plain => TextStyle(fontSize: 13, color: ZestTokens.textPrimary);

/// A public fact in a box: its label over its value, with Copy where it can
/// be copied.
class _Field extends StatelessWidget {
  const _Field({super.key, required this.label, required this.value, this.onCopy});

  final String label;
  final Widget value;
  final VoidCallback? onCopy;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: EdgeInsets.fromLTRB(12, 9, onCopy == null ? 12 : 4, 10),
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaisedAlt,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ZestTokens.borderSubtle),
      ),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                ZestFieldLabel(label),
                const SizedBox(height: 4),
                value,
              ],
            ),
          ),
          if (onCopy != null)
            IconButton(
              tooltip: AppLocalizations.of(context)!.copy,
              icon: Icon(LucideIcons.copy, size: 15, color: ZestTokens.textSecondary),
              onPressed: onCopy,
            ),
        ],
      ),
    );
  }
}

/// A button beside a fact's value (PROTECTION: Add one, Change...).
class _FactAction {
  const _FactAction(this.key, this.label, this.onPressed);

  final String key;
  final String label;
  final VoidCallback onPressed;
}

/// A label and its value on one line (PROTECTION), with the buttons that
/// change it after the value.
class _Fact extends StatelessWidget {
  const _Fact({super.key, required this.label, required this.value, this.icon, this.actions = const []});

  final String label;
  final String value;
  final IconData? icon;
  final List<_FactAction> actions;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.symmetric(vertical: actions.isEmpty ? 7 : 2),
      child: Row(
        // Beside a button, the label and the value stand on its middle.
        crossAxisAlignment: actions.isEmpty ? CrossAxisAlignment.start : CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: 2,
            child: Text(label, style: TextStyle(fontSize: 13, color: ZestTokens.textTertiary)),
          ),
          const SizedBox(width: 12),
          Expanded(
            flex: 3,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 14, color: ZestTokens.statusHealthy),
                  const SizedBox(width: 6),
                ],
                Flexible(
                  child: Text(value,
                      textAlign: TextAlign.end, style: TextStyle(fontSize: 13, color: ZestTokens.textPrimary)),
                ),
                for (final a in actions) ...[
                  const SizedBox(width: 6),
                  // In the accent, as a link: Add one,
                  // Change, Remove, Check.
                  TextButton(
                    key: ValueKey(a.key),
                    onPressed: a.onPressed,
                    style: TextButton.styleFrom(
                      foregroundColor: ZestTokens.brandInk,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 28),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      textStyle: const TextStyle(fontFamily: 'GeistSans', fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                    child: Text(a.label),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

