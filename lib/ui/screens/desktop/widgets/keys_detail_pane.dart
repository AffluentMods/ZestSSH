import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_switch.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/widgets/crate_records_view.dart' show ItemVersionsLink;
import 'package:zestssh/features/orchards/widgets/hidden_secret_note.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/features/identity/identity_cert_expiry.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/utils/redactor.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_button.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_mode_toggle.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/l10n/time_ago.dart';
import 'package:zestssh/ui/widgets/host_row.dart';

/// The right-hand detail pane of the 1.7 Keys master/detail - the EDITOR for
/// both new and existing identities (the pre-1.7 modal `IdentityEditScreen` no
/// longer drives the desktop new/edit-identity flow).
///
/// The pane ALWAYS renders the editor - a blank/creating controller is a
/// ready-to-fill "new identity" form, so there is no empty state; the footer
/// Clear resets to a blank new identity. It
/// composes a [ZestDetailScaffold] whose body edits the display name, username,
/// auth method (Password / SSH key) and its secret material, and the color
/// label - with Save/Cancel/Delete in the footer. For an existing identity it
/// also surfaces the FULL fingerprint with a copy button, the hosts that use it
/// (each clickable through to the host), created / last-used dates, and the
/// Rotate / Export public key actions. Certificate + agent identities are
/// name/username/color-only (their key material can't be edited here).
///
/// The Keys editor's longest label ('Display Name') overflows the shared 88px
/// [ZestField] label cell (it clipped to 'Display Nar'), so every Keys field
/// shares this wider cell - nothing truncates and the inputs still align on one
/// vertical rule.
const double _kKeysFieldLabelWidth = 120;

class KeysDetailPane extends ConsumerWidget {
  const KeysDetailPane({
    super.key,
    required this.controller,
    required this.hasSelection,
    required this.onSave,
    required this.onClose,
    required this.onDelete,
    required this.onRotate,
    required this.onExportPublic,
    required this.onOpenHost,
    this.onShowSecrets,
    this.onMoveToManager,
    this.onInstallOnHosts,
    this.saveIn,
    this.headerAction,
  });

  final KeyEditController controller;

  /// In the header, left of the close: a saved key's Move or copy (4.0).
  final Widget? headerAction;

  /// "Save in" (3.4), over a new key's fields.
  final Widget? saveIn;

  /// Whether an identity is currently bound for editing (existing or new).
  final bool hasSelection;

  /// Persist the draft (create or update). Returns true on success. Fired by
  /// the footer Save and by the discard dialog's Save.
  final Future<bool> Function() onSave;

  /// Close the pane - the X and the footer Cancel (runs the dirty guard).
  final VoidCallback onClose;

  /// Delete the bound identity.
  final VoidCallback onDelete;

  /// Rotate (regenerate) the bound key.
  final VoidCallback onRotate;

  /// Export the public key to the clipboard.
  final VoidCallback onExportPublic;

  /// Confirm it is you, then show the key's secrets (a Crate that asks
  /// again).
  final VoidCallback? onShowSecrets;

  /// Moves a saved password into a password manager (3.0): only
  /// for the person's own keys, where the tools run.
  final VoidCallback? onMoveToManager;

  /// Navigate through to a host that uses this key.
  final ValueChanged<Connection> onOpenHost;

  /// Installs the key's public key on hosts (3.0): where it has one.
  final VoidCallback? onInstallOnHosts;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final usageHosts =
        ref.watch(identityUsageHostsProvider).valueOrNull ?? const {};
    final lastUsed =
        ref.watch(identityLastUsedProvider).valueOrNull ?? const {};
    // Recording mode is read here (where `ref` is in scope) and threaded into
    // the editor, which is a plain helper method with no WidgetRef.
    final recording = ref.watch(recordingModeProvider);
    // What this account may do with an Orchard's keys (3.0).
    final rules = ItemRules.of(ref, 'key');
    // The certificate authority of the key's Crate: what a team
    // certificate key there signs in with; and the authority whose own key
    // this is, if any.
    final authority = keyCrateAuthority(ref, controller.isCreating ? null : controller.original?.id);
    final original = controller.original;
    final authorityOfThis = original == null ? null : authorityOfKey(ref, original);
    final crates = ref.watch(activeOrchardProvider).valueOrNull?.crates ?? const [];
    final l10n = AppLocalizations.of(context)!;
    String crateName(String id) {
      final c = crates.where((c) => c.id == id).firstOrNull;
      return c == null ? l10n.crateUnnamed : crateDisplayName(c, l10n);
    }

    // The detail pane is ALWAYS the editor now - a blank/creating controller
    // renders a ready-to-fill "new identity" form, so there is no empty state.
    // Clearing (footer) or deleting simply rebinds a blank new one.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final identity = controller.original; // null while creating.
        return _editor(
          context,
          identity: identity,
          hosts: identity == null
              ? const <Connection>[]
              : (usageHosts[identity.id] ?? const <Connection>[]),
          lastUsedAt: identity == null ? null : lastUsed[identity.id],
          recording: recording,
          rules: rules,
          authority: authority,
          authorityOfThis: authorityOfThis == null ? null : crateName(authorityOfThis.crateId),
        );
      },
    );
  }

  Widget _editor(
    BuildContext context, {
    required Identity? identity,
    required List<Connection> hosts,
    required DateTime? lastUsedAt,
    required bool recording,
    required ItemRules rules,
    CrateAuthorityView? authority,
    String? authorityOfThis,
  }) {
    final l10n = AppLocalizations.of(context)!;
    final isCreating = controller.isCreating;

    final typedName = controller.nameController.text.trim();
    // The header names the key, so it is masked like every other key name; the
    // "New identity" fallback is an l10n string, not an identifier.
    final headerName = typedName.isNotEmpty ? typedName : identity?.label;
    final title = headerName == null || headerName.isEmpty
        ? l10n.zestKeysNewIdentityTitle
        : Redactable.keyName(headerName).display;
    // The identity's TYPE / algorithm - an Ed25519 / RSA / … algorithm for a
    // key, else Password / Certificate / Agent key. Rendered as the header badge
    // (an SSH-key algorithm in ok/green tones; Password / Certificate / Agent in
    // brand tones) and reused for the cert/agent read-only Type row below.
    final typeLabel = identity != null
        ? identityTypeLabel(AppLocalizations.of(context)!, identity)
        : (controller.authMethod == AuthMethod.publicKey
            ? l10n.identitySshKey
            : l10n.identityPassword);
    final isKeyAlgorithm = identity != null && identity.authMethod == 'publicKey';

    // The header's mono identity line: the full fingerprint for a key / cert /
    // agent, otherwise the username (a saved password carries no fingerprint).
    // Null while composing a blank new identity, so the header shows just the
    // title + type badge.
    final headerFingerprint = controller.publicKeyFingerprint;
    final headerUser = controller.usernameController.text.trim();
    final baseSubtitle =
        (headerFingerprint != null && headerFingerprint.isNotEmpty)
            ? Redactable.fingerprint(headerFingerprint).display
            : (headerUser.isNotEmpty
                ? Redactable.username(headerUser).display
                : null);
    // Surface an OpenSSH certificate's expiry as a reminder: once it's within
    // the renew window (or already past), append it to the header subtitle so a
    // stale cert is visible before it causes a login failure.
    final certReminder = (identity != null &&
            (identity.certExpired() || identity.certExpiringSoon()))
        ? certExpirySaid(identity, l10n)
        : null;
    final headerSubtitle = certReminder != null
        ? (baseSubtitle != null ? '$baseSubtitle · $certReminder' : certReminder)
        : baseSubtitle;

    // The publicKey editor shows the key material (with its fingerprint) inline,
    // so the standalone read-only Fingerprint block is only for cert / agent.
    // An Orchard key changes only where its Crate lets this account edit (or
    // delete) it, and never while its secrets are hidden (3.0).
    final selectedId = controller.original?.id;
    final canEdit = isCreating || (selectedId != null && !controller.secretsHidden && rules.mayChange(selectedId));
    final canDelete = selectedId != null && rules.mayChange(selectedId, delete: true);
    final showInlineKeyMaterial = controller.canEditAuthMaterial &&
        controller.authMethod == AuthMethod.publicKey;
    final fingerprint = controller.publicKeyFingerprint;
    final hasPublicMaterial = identity != null &&
        ((identity.publicKeyFingerprint?.isNotEmpty ?? false) ||
            (identity.publicKeyData?.isNotEmpty ?? false));

    return ZestDetailScaffold(
      title: title,
      icon: LucideIcons.keyRound,
      badge: ZestDetailBadge(
        label: typeLabel,
        // Algorithm badges (Ed25519 / RSA / …) are neutral, as the list's tag
        // is: an algorithm is not a health. The Password / Certificate /
        // Agent-key type badges keep the brand default.
        color: isKeyAlgorithm ? ZestTokens.textSecondary : null,
        background: isKeyAlgorithm ? ZestTokens.surfaceChip : null,
      ),
      subtitle: headerSubtitle,
      subtitleMono: true,
      isDirty: controller.isDirty && canEdit,
      onSave: canEdit ? () => onSave() : null,
      onCancel: onClose,
      onClose: onClose,
      headerAction: headerAction,
      // No delete while composing a brand-new identity - there is nothing to
      // delete yet - nor where its Crate does not let this account delete.
      footerLeading: isCreating || !canDelete
          ? null
          : ZestButton(
              label: MaterialLocalizations.of(context).deleteButtonTooltip,
              icon: LucideIcons.trash2,
              variant: ZestButtonVariant.danger,
              size: ZestButtonSize.large,
              onPressed: onDelete,
            ),
      body: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (isCreating && saveIn != null) ...[saveIn!, const SizedBox(height: 16)],
            // ── Display name ─────────────────────────────────────────
            // While recording, an identifier field never paints its real
            // value: the masked stand-in is read-only, and tapping it runs the
            // reveal gate. Turning the mode off there brings the editable
            // field back on rebuild. The real controllers are untouched.
            if (recording)
              RecordingMaskedField(
                label: l10n.identityDisplayName,
                value: Redactable.keyName(controller.nameController.text),
                placeholder: l10n.identityDisplayNameHint,
                labelWidth: _keysLabelWidth(context, l10n),
              )
            else
              ZestField(
                label: l10n.identityDisplayName,
                controller: controller.nameController,
                placeholder: l10n.identityDisplayNameHint,
                labelWidth: _keysLabelWidth(context, l10n),
              ),
            const SizedBox(height: 16),

            // ── Username (required - Identities.username CHECK ≥ 1) ──
            if (recording)
              RecordingMaskedField(
                label: l10n.identityUsername,
                value: Redactable.username(controller.usernameController.text),
                placeholder: l10n.identityUsernameHint,
                isMono: true,
                labelWidth: _keysLabelWidth(context, l10n),
              )
            else
              ZestField(
                label: l10n.identityUsername,
                controller: controller.usernameController,
                placeholder: l10n.identityUsernameHint,
                isMono: true,
                labelWidth: _keysLabelWidth(context, l10n),
              ),
            const SizedBox(height: 20),

            // ── Authentication ───────────────────────────────────────
            ZestSectionHeader(label: l10n.zestKeysAuthentication),
            const SizedBox(height: 12),
            if (authorityOfThis != null) ...[
              _InlineNote(key: const ValueKey('key-is-authority'), text: l10n.certAuthorityKeyNote(authorityOfThis)),
              const SizedBox(height: 12),
            ],
            if (controller.canEditAuthMaterial) ...[
              if (!controller.secretsHidden) ...[
                _AuthMethodToggle(controller: controller, teamCertificates: authority != null),
                const SizedBox(height: 16),
              ],
              // At Connect the secrets are used to connect and never shown.
              if (controller.secretsHidden)
                HiddenSecretNote(
                  key: const ValueKey('secret-hidden'),
                  text: controller.askAgain ? l10n.orchardRevealAskAgain : l10n.orchardSecretHidden,
                  action: controller.askAgain && onShowSecrets != null
                      ? (label: l10n.orchardRevealShow, onPressed: onShowSecrets!)
                      : null,
                )
              else if (controller.authMethod == AuthMethod.password) ...[
                ZestField(
                  label: l10n.identityPassword,
                  controller: controller.passwordController,
                  placeholder: l10n.identityPasswordHint,
                  obscureText: true,
                  labelWidth: _keysLabelWidth(context, l10n),
                ),
                if (onMoveToManager != null && identity != null && identity.authMethod == AuthMethod.password.name) ...[
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton.icon(
                      key: const ValueKey('pm-move'),
                      onPressed: onMoveToManager,
                      icon: const Icon(LucideIcons.arrowRightLeft, size: 14),
                      label: Text(l10n.pmMoveButton),
                    ),
                  ),
                ],
              ]
              else if (controller.authMethod == AuthMethod.passwordManager)
                PasswordRefEditor(
                  key: ValueKey('pm-editor-${identity?.id ?? 'new'}'),
                  value: controller.passwordRef,
                  onChanged: controller.setPasswordRef,
                  labelWidth: _keysLabelWidth(context, l10n),
                )
              else if (showInlineKeyMaterial)
                _KeyMaterialSection(controller: controller)
              else if (controller.authMethod == AuthMethod.teamCertificate)
                _InlineNote(
                  key: const ValueKey('team-certificate-note'),
                  text: authority == null
                      ? l10n.identityTeamCertNoAuthority
                      : '${l10n.identityTeamCertNote} '
                          '${l10n.identityTeamCertNames(authorityUserNames(authority).join(', '))}',
                ),
            ] else ...[
              // Certificate / agent: material is read-only here.
              _MetaRow(
                label: AppLocalizations.of(context)!.connectionType,
                value:
                    identity == null ? typeLabel : identityTypeLabel(AppLocalizations.of(context)!, identity),
              ),
              if (controller.usesAgent) ...[
                const SizedBox(height: 8),
                _InlineNote(text: l10n.zestKeysAgentReadOnly),
              ],
            ],
            // A key's own password, tried after the key where a server does
            // not take it (3.0, accounts per host).
            if (!controller.secretsHidden && kKeysWithPasswordAfter.contains(controller.authMethod.name)) ...[
              const SizedBox(height: 16),
              ZestField(
                key: const ValueKey('password-after-key'),
                label: l10n.identityPasswordAfterKey,
                controller: controller.passwordController,
                obscureText: true,
                labelWidth: _keysLabelWidth(context, l10n),
              ),
              const SizedBox(height: 6),
              _InlineNote(text: l10n.identityPasswordAfterKeyNote),
            ],
            const SizedBox(height: 20),

            // ── Color label ──────────────────────────────────────────
            ZestSectionHeader(label: l10n.zestKeysColorLabel),
            const SizedBox(height: 12),
            Align(
              alignment: Alignment.centerLeft,
              // Same picker and the same palette as Groups and Networks (it
              // had a palette of its own). Every pick is kept as its colour
              // (colorValue), so it needs no palette to be read back; a key
              // given a colour by its index before keeps it.
              child: ZestColorPicker(
                presets: AppColors.labelPalette,
                // Any custom colour now round-trips via `colorValue`.
                allowCustom: true,
                allowNone: true,
                selected: AppColors.labelColorFor(
                    controller.colorValue, controller.colorIndex),
                // None is the unambiguous colorValue==null && colorIndex==0
                // state (the identity default). Mirrors the connection editor.
                noneSelected: controller.colorValue == null &&
                    controller.colorIndex == 0,
                onNoneSelected: () {
                  // Clear to the "no colour" sentinel: setColorIndex(0) drops
                  // any custom colorValue and resets the index to 0.
                  controller.setColorIndex(0);
                },
                onChanged: (c) {
                  // Every explicit pick persists as `colorValue` (index left at
                  // 0) so it can never be confused with the None sentinel -
                  // including the orange preset, whose palette index IS 0. This
                  // matches how the connection editor persists colour labels.
                  controller.setColorValue(c.toARGB32());
                },
              ),
            ),

            // ── Existing-identity detail (metadata + usage + actions) ─
            if (identity != null) ...[
              const SizedBox(height: 20),
              _MetaRow(
                label: AppLocalizations.of(context)!.keysDetailCreated,
                value: timeAgoWords(AppLocalizations.of(context)!, identity.createdAt),
                valueTooltip: formatDateTimeStamp(identity.createdAt),
              ),
              _MetaRow(
                label: AppLocalizations.of(context)!.keysDetailLastUsed,
                value: lastUsedAt == null ? AppLocalizations.of(context)!.zestKeysNeverUsed : timeAgoWords(AppLocalizations.of(context)!, lastUsedAt),
                valueTooltip:
                    lastUsedAt == null ? null : formatDateTimeStamp(lastUsedAt),
              ),
              // Its versions, where the team records history (3.0):
              // who changed it and when, never its secrets.
              ItemVersionsLink(kind: 'key', itemKey: identity.id, name: identity.label),

              // ── Unattended runs (security opt-in) ────────────────────
              const SizedBox(height: 20),
              _UnattendedSection(controller: controller),

              // Standalone fingerprint copy - for cert / agent identities whose
              // material isn't shown by the inline key section above.
              if (!showInlineKeyMaterial &&
                  fingerprint != null &&
                  fingerprint.isNotEmpty) ...[
                const SizedBox(height: 20),
                ZestSectionHeader(label: AppLocalizations.of(context)!.keyGenFingerprint),
                const SizedBox(height: 10),
                KeyFingerprintCopyButton(
                  fingerprint: fingerprint,
                  display: fingerprint,
                ),
              ],

              // Hosts that use this key - each navigates through to the host.
              const SizedBox(height: 20),
              ZestSectionHeader(label: l10n.zestKeysUsedBy(hosts.length)),
              const SizedBox(height: 8),
              if (hosts.isEmpty)
                const _UsedByEmpty()
              else
                for (final host in hosts)
                  HostRow(key: ValueKey('keys-used-by-${host.id}'), host: host, onTap: () => onOpenHost(host)),

              // Actions (replace / export) - only where there is key material.
              if (identity.authMethod == 'publicKey' || hasPublicMaterial) ...[
                const SizedBox(height: 24),
                Wrap(
                  spacing: ZestSizing.buttonGap,
                  runSpacing: ZestSizing.buttonGap,
                  children: [
                    // Replace key, as the Keys page names it (it was "Rotate"
                    // here, the same action: the 3.0 docs check); not twice,
                    // where the key's own section above has it already.
                    if (identity.authMethod == 'publicKey' &&
                        !(showInlineKeyMaterial && fingerprint != null && fingerprint.isNotEmpty))
                      ZestButton(
                        key: const ValueKey('keys-detail-replace-key'),
                        label: l10n.zestKeysReplaceKey,
                        icon: LucideIcons.refreshCw,
                        onPressed: onRotate,
                      ),
                    // A key's public line is made from it where none was kept.
                    if (hasPublicMaterial || identity.authMethod == 'publicKey')
                      ZestButton(
                        label: l10n.zestKeysExportPublic,
                        icon: LucideIcons.upload,
                        onPressed: onExportPublic,
                      ),
                    // Its public key added on hosts, as ssh-copy-id adds it.
                    if (onInstallOnHosts != null &&
                        (installLineOf(identity) != null || identity.authMethod == 'publicKey'))
                      ZestButton(
                        key: const ValueKey('keys-install-on-hosts'),
                        label: l10n.installKeyMenu,
                        icon: LucideIcons.server,
                        onPressed: onInstallOnHosts,
                      ),
                  ],
                ),
              ],
            ],
          ],
        ),
      ),
    );
  }
}

/// The Password / SSH-key auth-method segmented toggle, with Team
/// certificate where the key's Crate signs certificates (3.0), or
/// while the key is one.
class _AuthMethodToggle extends StatelessWidget {
  const _AuthMethodToggle({required this.controller, this.teamCertificates = false});

  final KeyEditController controller;
  final bool teamCertificates;

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Align(
      alignment: Alignment.centerLeft,
      child: ZestModeToggle(
        selectedId: controller.authMethod.name,
        onChanged: (id) => controller.setAuthMethod(
          id == AuthMethod.publicKey.name
              ? AuthMethod.publicKey
              : id == AuthMethod.teamCertificate.name
                  ? AuthMethod.teamCertificate
                  : id == AuthMethod.passwordManager.name
                      ? AuthMethod.passwordManager
                      : AuthMethod.password,
        ),
        segments: [
          ZestModeSegment(
            id: AuthMethod.password.name,
            label: l10n.identityPassword,
          ),
          ZestModeSegment(
            id: AuthMethod.publicKey.name,
            label: l10n.identitySshKey,
          ),
          if (teamCertificates || controller.authMethod == AuthMethod.teamCertificate)
            ZestModeSegment(
              id: AuthMethod.teamCertificate.name,
              label: l10n.identityTeamCertificate,
            ),
          // The password stays in the person's password manager.
          ZestModeSegment(
            id: AuthMethod.passwordManager.name,
            label: l10n.pmKeyTypeLabel,
          ),
        ],
      ),
    );
  }
}

/// The SSH-key material editor: a "Set up" button when no key is loaded, else
/// the loaded key's type + fingerprint with Replace / Remove. Key generation /
/// paste / import is delegated to the shared [KeySetupDialog] so the
/// secure-storage handling stays identical to the legacy editor.
class _KeyMaterialSection extends ConsumerWidget {
  const _KeyMaterialSection({required this.controller});

  final KeyEditController controller;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final l10n = AppLocalizations.of(context)!;
    final fp = controller.publicKeyFingerprint;
    final hasKey = fp != null && fp.isNotEmpty;

    if (!hasKey) {
      return Align(
        alignment: Alignment.centerLeft,
        child: ZestButton(
          label: l10n.identitySetupKey,
          icon: LucideIcons.keyRound,
          onPressed: () => _setup(context, ref),
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(
            color: ZestTokens.surfaceSunken,
            borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
            border: Border.all(color: ZestTokens.border),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Icon(LucideIcons.check,
                  size: 16, color: ZestTokens.statusHealthy),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      keyTypeLabel(AppLocalizations.of(context)!, controller.keyType),
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                        color: ZestTokens.textPrimary,
                      ),
                    ),
                    const SizedBox(height: 4),
                    RedactedText(
                      Redactable.fingerprint(fp),
                      style: TextStyle(
                        fontSize: 11.5,
                        fontFamily: 'JetBrainsMono',
                        color: ZestTokens.textSecondary,
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: ZestSizing.buttonGap,
          runSpacing: ZestSizing.buttonGap,
          children: [
            ZestButton(
              label: l10n.zestKeysReplaceKey,
              icon: LucideIcons.refreshCw,
              onPressed: () => _setup(context, ref),
            ),
            ZestButton(
              label: l10n.zestKeysRemoveKey,
              icon: LucideIcons.trash2,
              variant: ZestButtonVariant.danger,
              onPressed: controller.clearKeyMaterial,
            ),
          ],
        ),
      ],
    );
  }

  Future<void> _setup(BuildContext context, WidgetRef ref) async {
    final result = await KeySetupDialog.show(context, ref);
    if (result != null) {
      controller.setKeyMaterial(
        privateKeyPem: result.privatePem,
        fingerprint: result.fingerprint,
        keyType: result.keyType,
        passphrase: result.passphrase,
      );
    }
  }
}

/// A dim inline note (e.g. the agent-material-read-only explainer).
class _InlineNote extends StatelessWidget {
  const _InlineNote({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 12,
        height: 1.4,
        color: ZestTokens.textTertiary,
      ),
    );
  }
}

/// The "Allow unattended runs" security opt-in section (existing identities).
///
/// A shield-marked switch that authorises this credential for headless
/// automation (scheduled workflows, deep links, API keys). Turning it ON
/// prompts a confirmation that spells out the consequence; turning it OFF is
/// immediate (the safe direction). The consequence line is ALWAYS visible so
/// the state is never ambiguous. The value persists with the identity on Save;
/// each real flip is emitted to the security-event log (`AppLogger`, the same
/// channel used for PIN-lockout / host-key events - a console signal, not a
/// persisted trail, consistent with the app's no-log-files privacy stance).
class _UnattendedSection extends StatelessWidget {
  const _UnattendedSection({required this.controller});

  final KeyEditController controller;

  String get _effectiveLabel {
    final typed = controller.nameController.text.trim();
    if (typed.isNotEmpty) return typed;
    return controller.original?.label ?? '';
  }

  Future<void> _onChanged(BuildContext context, bool value) async {
    // Disabling is the safe direction - apply immediately, no confirm.
    if (!value) {
      controller.setAllowUnattended(false);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    // The app's own question (it was a plain dialog built here); the
    // question names the key, masked like everywhere else.
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.warning,
      title: l10n.zestKeysUnattendedConfirmTitle,
      body: l10n.zestKeysUnattendedConfirmLead(Redactable.keyName(_effectiveLabel).display),
      // Which keys to allow it for: the one sentence that warns.
      warning: l10n.zestKeysUnattendedConfirmWarning,
      confirmLabel: l10n.zestKeysUnattendedConfirmEnable,
    );
    if (confirmed == true) {
      controller.setAllowUnattended(true);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final on = controller.allowUnattended;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        ZestSectionHeader(label: l10n.zestKeysUnattendedSection),
        const SizedBox(height: 8),
        Row(
          children: [
            Icon(
              LucideIcons.shield,
              size: 16,
              color: on ? ZestTokens.brandInk : ZestTokens.textTertiary,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                l10n.zestKeysUnattendedSwitch,
                style: TextStyle(
                  fontSize: 13,
                  color: ZestTokens.textPrimary,
                ),
              ),
            ),
            ZestSwitch(value: on, onChanged: (v) => _onChanged(context, v)),
          ],
        ),
        const SizedBox(height: 4),
        _InlineNote(
          text: on
              ? l10n.zestKeysUnattendedConsequence
              : l10n.zestKeysUnattendedOffHint,
        ),
        if (controller.usesAgent) ...[
          const SizedBox(height: 6),
          _InlineNote(text: l10n.zestKeysUnattendedAgentNote),
        ],
      ],
    );
  }
}

/// A label/value read-only row in the detail pane.
class _MetaRow extends StatelessWidget {
  const _MetaRow({required this.label, required this.value, this.valueTooltip});

  final String label;
  final String value;

  /// Optional hover tooltip on the value - e.g. the absolute timestamp behind a
  /// relative "3d ago".
  final String? valueTooltip;

  @override
  Widget build(BuildContext context) {
    Widget valueText = Text(
      value,
      style: TextStyle(
        fontSize: 13,
        color: ZestTokens.textPrimary,
      ),
    );
    final tip = valueTooltip;
    if (tip != null) {
      valueText = Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: valueText,
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 104,
            child: Text(
              label,
              style: TextStyle(
                fontSize: 13,
                color: ZestTokens.textTertiary,
              ),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(child: valueText),
        ],
      ),
    );
  }
}

/// Empty "used by" placeholder - a key that no host references yet.
class _UsedByEmpty extends StatelessWidget {
  const _UsedByEmpty();

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Text(
        AppLocalizations.of(context)!.keysDetailNotUsed,
        style: TextStyle(
          fontSize: 13,
          color: ZestTokens.textTertiary,
        ),
      ),
    );
  }
}

/// Copy-on-click fingerprint control with a checkmark confirmation.
///
/// Copies the FULL [fingerprint] to the clipboard (never the truncated
/// display), swaps its glyph to a check for a beat, and raises the
/// `zestKeysFingerprintCopied` toast. Used both in the detail pane (full value)
/// and in dense list rows ([compact], showing a short value).
class KeyFingerprintCopyButton extends ConsumerStatefulWidget {
  const KeyFingerprintCopyButton({
    super.key,
    required this.fingerprint,
    required this.display,
    this.compact = false,
  });

  /// The full fingerprint placed on the clipboard.
  final String fingerprint;

  /// What to show on the control (short in list rows, full in the detail pane).
  final String display;

  /// Dense variant for list rows.
  final bool compact;

  @override
  ConsumerState<KeyFingerprintCopyButton> createState() =>
      _KeyFingerprintCopyButtonState();
}

class _KeyFingerprintCopyButtonState
    extends ConsumerState<KeyFingerprintCopyButton> {
  bool _copied = false;
  bool _hover = false;
  Timer? _resetTimer;

  Future<void> _copy() async {
    // Spec 5: copying the real fingerprint while recording is a reveal.
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: widget.fingerprint));
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    setState(() => _copied = true);
    showTopSnackBar(context, l10n.zestKeysFingerprintCopied, isSuccess: true);
    _resetTimer?.cancel();
    _resetTimer = Timer(const Duration(milliseconds: 1600), () {
      if (mounted) setState(() => _copied = false);
    });
  }

  @override
  void dispose() {
    _resetTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final icon = _copied ? LucideIcons.check : LucideIcons.copy;
    final iconColor = _copied ? ZestTokens.statusHealthy : ZestTokens.textTertiary;
    final fontSize = widget.compact ? 11.5 : 12.5;
    // Spec 1a: ONE fingerprint, one treatment, in every location. The masked
    // form is the fixed fake, shortened the same way a real one is in a dense
    // row, so a screenshot never shows the value in one place and dots in
    // another.
    final recording = ref.watch(recordingModeProvider);
    final shown = !recording
        ? widget.display
        : (widget.compact
            ? shortFingerprint(Redactor.fingerprint(widget.fingerprint))
            : Redactor.fingerprint(widget.fingerprint));

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: _copy,
        child: Container(
          padding: EdgeInsets.symmetric(
            horizontal: widget.compact ? 6 : 12,
            vertical: widget.compact ? 3 : 10,
          ),
          decoration: BoxDecoration(
            color: _hover
                ? ZestTokens.surfaceRaised
                : (widget.compact ? Colors.transparent : ZestTokens.surfaceSunken),
            borderRadius: BorderRadius.circular(widget.compact ? 4 : 8),
            border: widget.compact
                ? null
                : Border.all(color: ZestTokens.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: widget.compact ? 12 : 14, color: iconColor),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  shown,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: fontSize,
                    fontFamily: 'JetBrainsMono',
                    color: ZestTokens.textSecondary,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// The names' column of the form, as wide as the longest of its names at the
/// text size the app is drawn at, and at least the _kKeysFieldLabelWidth it had (a longer
/// name was cut, in Russian or Spanish).
double _keysLabelWidth(BuildContext context, AppLocalizations l10n) =>
    zestFieldLabelWidth(context, [l10n.identityDisplayName, l10n.identityUsername, l10n.identityPassword, l10n.identityPasswordAfterKey], min: _kKeysFieldLabelWidth);
