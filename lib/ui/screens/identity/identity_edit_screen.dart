import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/database/database.dart' show Identity;
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/widgets/password_ref_editor.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ActivityKind;
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/orchards/rules/reveal_gate.dart';
import 'package:zestssh/features/orchards/widgets/hidden_secret_note.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/theme/desktop_dimensions.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/utils/platform_utils.dart';
import 'package:zestssh/features/keys/key_export_save.dart';
import 'package:zestssh/ui/screens/desktop/widgets/cert_import_dialog.dart';
import 'package:zestssh/ui/widgets/fido_make_key_dialog.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/fido/fido_key_pair.dart' show speaksToSecurityKeys;
import 'package:zestssh/services/fido/fido_signer.dart';
import 'package:zestssh/services/fido/fido_words.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:zestssh/ui/widgets/zest_color_picker.dart';
import 'package:zestssh/ui/widgets/responsive_scaffold.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_field.dart';
import 'package:zestssh/ui/widgets/zest_pressable.dart';
import 'package:zestssh/ui/widgets/zest_section_header.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/theme/ui_density.dart' show touchSizedAt;
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/features/run/install_key.dart';
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/utils/secret_clipboard.dart';
import 'package:zestssh/ui/widgets/button_spinner.dart';
import 'package:zestssh/ui/widgets/zest_select.dart';
import 'package:zestssh/ui/widgets/host_row.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/kept_from_sync.dart';
import 'package:zestssh/utils/after_next_frame.dart';

/// The app monospace family (matches the connection editor / key/code text).
const String _kMono = 'JetBrainsMono';

/// Shared value text style for this screen's fields - matches the connection
/// editor's `.val` (13px primary), so both editors read as one design system.
/// The bare decoration of the editor's own one-line fields (its name and
/// user name) whose input fills its box: a finger's 48 high where the app is
/// touch sized, a mouse's 40 otherwise, as [ZestField]'s own input does (4.0
/// accessibility pass: its line of 16 was all a press could land on, and the
/// box was 40 high on a phone).
InputDecoration _nameFieldDecoration(BuildContext context, String hint) =>
    zestShellFieldDecoration(hintText: hint).copyWith(
      isCollapsed: false,
      contentPadding: const EdgeInsets.symmetric(vertical: 11),
      constraints: BoxConstraints(minHeight: touchSizedAt(context) ? 48 : 40),
    );

TextStyle _kValStyle =
    TextStyle(fontSize: 13, color: ZestTokens.textPrimary, height: 1.25);

/// Create or edit an identity (username + auth method).
///
/// Redesigned with JuiceSSH-style layout:
/// - Display Name, Username, auth method toggle
/// - SSH Key option opens a centered dialog with
///   Generate / Paste / Import tabs (no key) or
///   key management dialog (key set)
/// Key material pre-loaded by an EXTERNAL import entry point (e.g. Settings >
/// Import PuTTY Keys, which converts the picked .ppk before opening the
/// editor) so the editor starts with the key already attached instead of the
/// old pick-then-discard dead end.
class InitialImportedKey {
  final String privatePem;
  final String fingerprint;
  final String keyType;

  /// The key's name, where it has one already (a key just generated).
  final String? label;

  /// Its public key line, where it is known already (a key just generated
  /// shows it, and it is kept as shown).
  final String? publicKeyData;

  /// The passphrase it opened with, where it has one: kept with it, as Keys'
  /// own import keeps it.
  final String? passphrase;

  const InitialImportedKey({
    required this.privatePem,
    required this.fingerprint,
    required this.keyType,
    this.label,
    this.publicKeyData,
    this.passphrase,
  });
}

class IdentityEditScreen extends ConsumerStatefulWidget {
  final String? identityId;

  /// A2 embedded mode (Keys split-view): drops the ResponsiveScaffold back
  /// arrow and routes cancel / save / delete through [onClose] instead of
  /// popping a route. [onClose] receives the saved id (null for cancel/delete).
  final bool embedded;
  final void Function(String? savedId)? onClose;

  /// See [InitialImportedKey]. Only meaningful for NEW identities.
  final InitialImportedKey? initialImportedKey;

  const IdentityEditScreen({
    super.key,
    this.identityId,
    this.embedded = false,
    this.onClose,
    this.initialImportedKey,
  });

  /// Show as a dialog on desktop or push a route on mobile.
  ///
  /// For new identities only - editing an existing identity always
  /// uses the full route (it has more fields and key management).
  /// Show as a dialog on desktop or push a route on mobile.
  ///
  /// Returns the newly created identity ID (or null if editing/cancelled).
  static Future<String?> showAdaptive(BuildContext context, {String? identityId, InitialImportedKey? key}) {
    final size = MediaQuery.of(context).size;
    final isWide = size.width > 600;
    if (isWide) {
      // Take a bigger slice of the window - the old 0.45 / 0.75
      // multipliers produced a dialog that felt postage-stamp-sized
      // on 1920px+ displays.
      final dialogWidth = (size.width * 0.6).clamp(
          DesktopDimensions.identityEditMinWidth,
          DesktopDimensions.identityEditMaxWidth);
      final dialogHeight = (size.height * 0.85).clamp(520.0, 900.0);
      return showDialog<String?>(
        context: context,
        builder: (ctx) => Dialog(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
            child: SizedBox(
              width: dialogWidth,
              height: dialogHeight,
              child: IdentityEditScreen(identityId: identityId, initialImportedKey: key),
            ),
          ),
        ),
      );
    } else {
      if (identityId != null) {
        return context.push<String?>('/identity/edit/$identityId');
      }
      return context.push<String?>(Routes.identityEdit, extra: key);
    }
  }

  @override
  ConsumerState<IdentityEditScreen> createState() =>
      _IdentityEditScreenState();
}

class _IdentityEditScreenState extends ConsumerState<IdentityEditScreen> {
  final _formKey = GlobalKey<FormState>();
  final _labelController = TextEditingController();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  AuthMethod _authMethod = AuthMethod.password;

  /// Where a password manager keeps the password (3.0).
  String? _passwordRef;
  String? _privateKeyPem;
  String? _keyPassphrase;
  String? _publicKeyFingerprint;
  String? _keyType;

  /// The key's public line where it is known (kept with it, or given with a
  /// key just generated); else made from the private key when it is needed
  /// and when the key is saved ([_publicLine]).
  String? _publicKeyData;
  int _colorIndex = 0;
  int? _colorValue;
  bool _allowUnattended = false;
  // Snapshot of the saved display name, used as a fallback in the unattended
  // confirm dialog when the name field has been cleared (matches desktop).
  String _originalLabel = '';
  bool _isLoading = false;

  /// Where a new key is saved ("Save in", 3.4); null: where new items of the
  /// space on screen go.
  SavePlace? _saveIn;

  /// An Orchard key whose Crate this account reaches at Connect (3.0):
  /// its password and private key are never read into this screen,
  /// and it cannot be changed or exported here.
  bool _secretsHidden = false;

  /// The key is in a Crate that asks again before its secrets are shown
  /// and they stay hidden until the person confirms it is them.
  bool _askAgain = false;

  /// What the identity was when it was opened: its kind, and whether the
  /// password saved with it was tried after its key (3.0, accounts per
  /// host). A password it holds is shown only where it is in use: its own,
  /// for a password key, or the one tried after a key; one left from before
  /// it became a key is not, and is not touched by a save.
  String? _openedKind;
  bool _openedPasswordAfterKey = false;

  /// What the password field showed when the identity was opened (or its
  /// secrets were shown): empty where it showed none.
  String _shownPassword = '';

  /// Whether [password] is shown, by what the identity was when it was
  /// opened.
  bool get _showsSavedPassword =>
      _openedKind == AuthMethod.password.name ||
      (_openedPasswordAfterKey && kKeysWithPasswordAfter.contains(_openedKind));

  /// Confirms it is them, then loads and shows the key's secrets.
  Future<void> _showSecrets() async {
    if (!await confirmItIsYou(context, ref) || !mounted) return;
    final crud = ref.read(identityCrudProvider);
    final id = widget.identityId!;
    final password = await crud.getPassword(id);
    final privateKey = await crud.getPrivateKey(id);
    if (!mounted) return;
    setState(() {
      _privateKeyPem = privateKey;
      if (password != null && _showsSavedPassword) _passwordController.text = password;
      _shownPassword = _passwordController.text;
      _secretsHidden = false;
      _askAgain = false;
    });
  }
  String? _createdId;

  @override
  void initState() {
    super.initState();
    if (widget.identityId != null) {
      _loadIdentity();
    } else if (widget.initialImportedKey != null) {
      // Externally imported key (e.g. Settings > Import PuTTY Keys): start
      // with the key attached and the auth method set accordingly - the same
      // fields the KeySetupDialog's onKeyLoaded callback would set.
      final k = widget.initialImportedKey!;
      _authMethod = AuthMethod.publicKey;
      _privateKeyPem = k.privatePem;
      _publicKeyFingerprint = k.fingerprint;
      _keyType = k.keyType;
      _publicKeyData = k.publicKeyData;
      _keyPassphrase = k.passphrase;
      if (k.label != null) _labelController.text = k.label!;
    }
  }

  /// The key as it was opened (what Install on hosts installs).
  Identity? _opened;

  Future<void> _loadIdentity() async {
    final dao = ref.read(identitiesDaoProvider);
    final identity = await dao.getById(widget.identityId!);
    if (identity != null && mounted) {
      final crud = ref.read(identityCrudProvider);
      // At Connect the secrets stay where they are: used to connect, never
      // shown, copied or exported. A Crate that asks again loads them
      // only once the person confirms it is them.
      final reveal = await mayRevealKeyNow(ref, identity.id);
      final ask = reveal && await revealAsksAgainNow(ref, identity.id);
      final password = reveal && !ask ? await crud.getPassword(identity.id) : null;
      final privateKey = reveal && !ask ? await crud.getPrivateKey(identity.id) : null;
      if (!mounted) return;
      // Its secrets opened on screen: a note while the team records
      // activity.
      if (password != null || privateKey != null) {
        unawaited(noteScreenActivity(ref, ActivityKind.reveal,
            itemKind: 'key', itemKey: identity.id, name: identity.label));
      }

      setState(() {
        _opened = identity;
        _openedKind = identity.authMethod;
        _openedPasswordAfterKey = identity.passwordAfterKey;
        _labelController.text = identity.label;
        _originalLabel = identity.label;
        _usernameController.text = identity.username;
        _authMethod = AuthMethod.values.firstWhere(
          (m) => m.name == identity.authMethod,
          orElse: () => AuthMethod.password,
        );
        _publicKeyFingerprint = identity.publicKeyFingerprint;
        _keyType = identity.keyType;
        _publicKeyData = identity.publicKeyData;
        _passwordRef = identity.passwordRef;
        _colorIndex = identity.colorIndex;
        _colorValue = identity.colorValue;
        _allowUnattended = identity.allowUnattended;
        _privateKeyPem = privateKey;
        // A team certificate (3.0) holds nothing to hide.
        final nothingHidden = identity.authMethod == AuthMethod.teamCertificate.name ||
            identity.authMethod == AuthMethod.passwordManager.name;
        _secretsHidden = !nothingHidden && (!reveal || ask);
        _askAgain = !nothingHidden && ask;
        if (password != null && _showsSavedPassword) {
          _passwordController.text = password;
        }
        _shownPassword = _passwordController.text;
      });
    }
  }

  /// Toggle unattended-runs authorisation. Disabling is immediate (safe
  /// direction); enabling prompts a confirmation spelling out the consequence.
  /// The value persists with the identity on Save.
  Future<void> _onUnattendedChanged(bool value) async {
    if (!value) {
      setState(() => _allowUnattended = false);
      return;
    }
    final l10n = AppLocalizations.of(context)!;
    final typed = _labelController.text.trim();
    final label = typed.isNotEmpty ? typed : _originalLabel;
    // The app's own question (it was a plain dialog built here); the
    // question names the key, masked like everywhere else.
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.warning,
      title: l10n.zestKeysUnattendedConfirmTitle,
      body: l10n.zestKeysUnattendedConfirmLead(Redactable.keyName(label).display),
      // Which keys to allow it for: the one sentence that warns.
      warning: l10n.zestKeysUnattendedConfirmWarning,
      confirmLabel: l10n.zestKeysUnattendedConfirmEnable,
    );
    if (confirmed == true && mounted) {
      setState(() => _allowUnattended = true);
    }
  }

  @override
  void dispose() {
    _labelController.dispose();
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Close the editor: embedded (A2 split) → invoke onClose; route → pop.
  void _close([String? savedId]) {
    final onClose = widget.onClose;
    if (onClose != null) {
      onClose(savedId);
    } else if (context.canPop()) {
      context.pop(savedId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final isEditing = widget.identityId != null;
    // Recording mode: the identifier fields below swap to read-only masked
    // stand-ins while it is on (spec section 5).
    final recording = ref.watch(recordingModeProvider);
    // An Orchard key changes only where its Crate lets this account edit
    // (and delete) it, and never while its secrets are hidden (3.0).
    final canSave = !_secretsHidden &&
        (isEditing ? mayChangeItem(ref, 'key', widget.identityId!) : mayAddScreenSpace(ref));
    final canDelete = isEditing && mayChangeItem(ref, 'key', widget.identityId!, delete: true);
    // The certificate authority of the key's Crate, for a team
    // certificate key there.
    final authority = keyCrateAuthority(ref, widget.identityId);

    return ResponsiveScaffold(
      title: isEditing ? l10n.identityEditTitle : l10n.identityNewTitle,
      showBackButton: !widget.embedded,
      actions: [
        // A saved key's Move or copy (4.0): its places, then Move here or
        // Copy here. Never the key a vault signs certificates with, nor a
        // team certificate key: those belong to their vault.
        if (_opened case final opened?
            when isEditing &&
                opened.authMethod != AuthMethod.teamCertificate.name &&
                authorityOfKey(ref, opened) == null)
          MoveCopyMenuButton(
            kind: TransferKinds.key,
            itemKey: opened.id,
            onMoved: () {
              if (mounted) _close();
            },
          ),
        if (canSave)
          IconButton(
            icon: _isLoading
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(LucideIcons.check),
            tooltip: l10n.save,
            onPressed: _isLoading ? null : _save,
          ),
        if (isEditing &&
            _authMethod == AuthMethod.publicKey &&
            !_secretsHidden &&
            mayExportKeysScreenSpace(ref))
          IconButton(
            icon: const Icon(LucideIcons.download),
            tooltip: l10n.identityExportPrivateKey,
            onPressed: _exportPrivateKey,
          ),
        // Its public key added on hosts, as ssh-copy-id adds it (3.0): a key
        // that kept none has it made from its private key there.
        if (_opened case final opened? when installLineOf(opened) != null || opened.authMethod == 'publicKey')
          IconButton(
            key: const ValueKey('identity-install-on-hosts'),
            icon: const Icon(LucideIcons.server),
            tooltip: l10n.installKeyMenu,
            onPressed: () => showInstallKey(context, opened),
          ),
        if (canDelete)
          IconButton(
            tooltip: AppLocalizations.of(context)!.delete,
            icon: const Icon(LucideIcons.trash2),
            onPressed: _confirmDelete,
          ),
      ],
      body: ZestFieldLabels(
        // The names measured, as the host editor's are: in their 88 pixels
        // "Benutzername" and "Имя пользователя" were cut.
        labels: [
          l10n.identityDisplayName,
          l10n.identityUsername,
          l10n.identityPassword,
          l10n.identityPasswordAfterKey,
        ],
        child: Form(
          key: _formKey,
          child: ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Where a new key is saved (3.4).
              if (!isEditing)
                SaveInField(
                  value: _saveIn,
                  onChanged: (p) => setState(() => _saveIn = p),
                  padding: const EdgeInsets.only(bottom: 16),
                ),
              // ── Display Name ─────────────────────────────────
              // While recording, the field never paints its real value: the
              // masked stand-in is read-only, and tapping it runs the reveal
              // gate. Turning the mode off there brings the editable field back
              // on rebuild. The real controller is untouched either way.
              if (recording)
                RecordingMaskedField(
                  label: l10n.identityDisplayName,
                  value: Redactable.keyName(_labelController.text),
                  placeholder: l10n.identityDisplayNameHint,
                  validator: (v) => v == null || v.isEmpty
                      ? l10n.identityDisplayNameRequired
                      : null,
                )
              else
                ZestField.custom(
                  label: l10n.identityDisplayName,
                  child: TextFormField(
                    controller: _labelController,
                    style: _kValStyle,
                    decoration: _nameFieldDecoration(context, l10n.identityDisplayNameHint),
                    textCapitalization: TextCapitalization.words,
                    validator: (v) => v == null || v.isEmpty
                        ? l10n.identityDisplayNameRequired
                        : null,
                  ),
                ),
              const SizedBox(height: 11),

              // ── Username ─────────────────────────────────────
              if (recording)
                RecordingMaskedField(
                  label: l10n.identityUsername,
                  value: Redactable.username(_usernameController.text),
                  placeholder: l10n.identityUsernameHint,
                  validator: (v) => v == null || v.isEmpty
                      ? l10n.identityUsernameRequired
                      : null,
                )
              else
                ZestField.custom(
                  label: l10n.identityUsername,
                  child: TextFormField(
                    controller: _usernameController,
                    style: _kValStyle,
                    decoration: _nameFieldDecoration(context, l10n.identityUsernameHint),
                    autocorrect: false,
                    validator: (v) => v == null || v.isEmpty
                        ? l10n.identityUsernameRequired
                        : null,
                  ),
                ),
              const SizedBox(height: 22),

              // ── Section: Authentication ──────────────────────
              ZestSectionHeader(label: l10n.identityAuthSection),

              // Auth method toggle - segmented pills matching the connection
              // editor's protocol chooser. Not for a key whose secrets are
              // hidden: nothing about them changes here (3.0).
              if (!_secretsHidden) ...[
                Row(
                  children: [
                    Expanded(
                      child: _ChoicePill(
                        label: l10n.identityPassword,
                        selected: _authMethod == AuthMethod.password,
                        onTap: () =>
                            setState(() => _authMethod = AuthMethod.password),
                      ),
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: _ChoicePill(
                        label: l10n.identitySshKey,
                        // A key with its certificate is a key too: picking
                        // it again keeps the certificate.
                        selected: _authMethod == AuthMethod.publicKey || _authMethod == AuthMethod.certificate,
                        onTap: () => setState(() {
                          if (_authMethod != AuthMethod.certificate) _authMethod = AuthMethod.publicKey;
                        }),
                      ),
                    ),
                    // Where the key's Crate signs certificates (3.0).
                    if (authority != null || _authMethod == AuthMethod.teamCertificate) ...[
                      const SizedBox(width: 6),
                      Expanded(
                        child: _ChoicePill(
                          key: const ValueKey('auth-team-certificate'),
                          label: l10n.identityTeamCertificate,
                          selected: _authMethod == AuthMethod.teamCertificate,
                          onTap: () => setState(() => _authMethod = AuthMethod.teamCertificate),
                        ),
                      ),
                    ],
                  ],
                ),
                // The password stays in a password manager: picked on a
                // desktop, where its tools are; a phone keeps such a key.
                if (PasswordManagers.supported || _authMethod == AuthMethod.passwordManager) ...[
                  const SizedBox(height: 6),
                  _ChoicePill(
                    key: const ValueKey('auth-password-manager'),
                    label: l10n.pmKeyTypeLabel,
                    selected: _authMethod == AuthMethod.passwordManager,
                    onTap: () => setState(() => _authMethod = AuthMethod.passwordManager),
                  ),
                ],
                const SizedBox(height: 16),
              ],
              if (_authMethod == AuthMethod.teamCertificate && !_secretsHidden)
                Text(
                  authority == null
                      ? l10n.identityTeamCertNoAuthority
                      : '${l10n.identityTeamCertNote} '
                          '${l10n.identityTeamCertNames(authorityUserNames(authority).join(', '))}',
                  key: const ValueKey('team-certificate-note'),
                  style: TextStyle(fontSize: 12, height: 1.4, color: ZestTokens.textTertiary),
                ),

              // ── Password field ───────────────────────────────
              // At Connect it is used to connect and never shown (3.0).
              if (_secretsHidden)
                HiddenSecretNote(
                  key: const ValueKey('secret-hidden'),
                  text: _askAgain ? l10n.orchardRevealAskAgain : l10n.orchardSecretHidden,
                  action: _askAgain ? (label: l10n.orchardRevealShow, onPressed: _showSecrets) : null,
                )
              else if (_authMethod == AuthMethod.passwordManager)
                PasswordRefEditor(
                  key: const ValueKey('pm-editor'),
                  value: _passwordRef,
                  onChanged: (value) => _passwordRef = value,
                )
              else if (_authMethod == AuthMethod.password)
                ZestField(
                  label: l10n.identityPassword,
                  controller: _passwordController,
                  obscureText: true,
                  placeholder: l10n.identityPasswordHint,
                  helperText: l10n.identityPasswordStoredInfo,
                ),

              // ── SSH Key section ──────────────────────────────
              // A key with its certificate shows its key; it is changed by a
              // new certificate, not here (the certificate is for this key).
              if (_authMethod == AuthMethod.publicKey || _authMethod == AuthMethod.certificate) ...[
                // Show loaded key info
                if (_publicKeyFingerprint != null) ...[
                  Container(
                    padding: const EdgeInsets.all(14),
                    decoration: BoxDecoration(
                      color: ZestTokens.surfaceRaised,
                      borderRadius:
                          BorderRadius.circular(ZestSizing.fieldRadius),
                      border: Border.all(color: ZestTokens.border, width: 0.5),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Row(
                          children: [
                            Icon(LucideIcons.checkCircle2,
                                color: AppColors.success, size: 20),
                            const SizedBox(width: 8),
                            Text(
                              l10n.identityKeyLoaded(_keyType ?? ''),
                              style: TextStyle(
                                fontWeight: FontWeight.w600,
                                color: ZestTokens.textPrimary,
                              ),
                            ),
                          ],
                        ),
                        const SizedBox(height: 8),
                        RedactedText(
                          Redactable.fingerprint(_publicKeyFingerprint!),
                          style: TextStyle(
                            fontFamily: _kMono,
                            fontSize: 12,
                            color: ZestTokens.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (_authMethod == AuthMethod.publicKey) ...[
                    const SizedBox(height: 12),
                    _KeyActionButton(
                      hasKey: true,
                      onTap: _showExistingKeyDialog,
                    ),
                  ],
                ] else if (_authMethod == AuthMethod.publicKey) ...[
                  // No key loaded - show 3 clear options
                  _KeyOptionCard(
                    icon: LucideIcons.keyRound,
                    title: l10n.identityGenerateNewKey,
                    subtitle: l10n.identityGenerateNewKeyDesc,
                    onTap: () => _showSetupKeyDialogAtTab(0),
                  ),
                  const SizedBox(height: 8),
                  _KeyOptionCard(
                    icon: LucideIcons.clipboardPaste,
                    title: l10n.identityPasteKey,
                    subtitle: l10n.identityPasteKeyDesc,
                    onTap: () => _showSetupKeyDialogAtTab(1),
                  ),
                  const SizedBox(height: 8),
                  _KeyOptionCard(
                    icon: LucideIcons.folderOpen,
                    title: l10n.identityImportFromFile,
                    subtitle: l10n.identityImportFromFileDesc,
                    onTap: () => _showSetupKeyDialogAtTab(2),
                  ),
                  // A phone or a tablet speaks to a FIDO2 security key itself
                  // (4.0): the key is made on it, by NFC or USB. (A security
                  // key's key file made elsewhere comes in by the two above.)
                  if (speaksToSecurityKeys) ...[
                    const SizedBox(height: 8),
                    _KeyOptionCard(
                      key: const ValueKey('key-option-security-key'),
                      icon: LucideIcons.nfc,
                      title: l10n.fidoMakeOption,
                      subtitle: l10n.fidoMakeOptionDesc,
                      onTap: _makeOnSecurityKey,
                    ),
                  ],
                ],
              ],

              // ── SSH certificate (4.0: it was only added on a computer) ──
              if (_mayAddCertificate(isEditing)) ...[
                const SizedBox(height: 12),
                _KeyOptionCard(
                  key: const ValueKey('identity-add-certificate'),
                  icon: LucideIcons.fileBadge2,
                  title: _authMethod == AuthMethod.certificate
                      ? l10n.identityReplaceCertificate
                      : l10n.identityAddCertificate,
                  subtitle: l10n.identityAddCertificateDesc,
                  onTap: _addCertificate,
                ),
              ],

              // ── A key's own password, tried after the key (3.0,
              // accounts per host) ──
              if (!_secretsHidden && kKeysWithPasswordAfter.contains(_authMethod.name)) ...[
                const SizedBox(height: 16),
                ZestField(
                  key: const ValueKey('password-after-key'),
                  label: l10n.identityPasswordAfterKey,
                  controller: _passwordController,
                  obscureText: true,
                  helperText: l10n.identityPasswordAfterKeyNote,
                ),
              ],

              const SizedBox(height: 22),

              // ── Color Label ──────────────────────────────────
              ZestSectionHeader(label: l10n.identityColorLabel),
              ZestColorPicker(
                presets: AppColors.labelPalette,
                selected: AppColors.labelColorFor(_colorValue, _colorIndex),
                allowCustom: true,
                // None is colorValue==null && colorIndex==0, as on a computer.
                allowNone: true,
                noneSelected: _colorValue == null && _colorIndex == 0,
                onNoneSelected: () => setState(() {
                  _colorValue = null;
                  _colorIndex = 0;
                }),
                // Every pick is kept as its colour (colorValue), so it needs no
                // palette to be read back; a key given a colour by its index
                // before keeps it until someone picks another. Matches desktop.
                onChanged: (c) => setState(() {
                  _colorValue = c.toARGB32();
                  _colorIndex = 0;
                }),
              ),
              const SizedBox(height: 22),

              // ── Unattended runs (edit mode only) ──────────────
              if (isEditing) ...[
                ZestSectionHeader(label: l10n.zestKeysUnattendedSection),
                _ToggleRow(
                  label: l10n.zestKeysUnattendedSwitch,
                  note: _allowUnattended
                      ? l10n.zestKeysUnattendedConsequence
                      : l10n.zestKeysUnattendedOffHint,
                  value: _allowUnattended,
                  onChanged: _onUnattendedChanged,
                ),
                const SizedBox(height: 22),
              ],

              // ── Assign to Connections (edit mode only) ────────
              if (isEditing) ...[
                ZestSectionHeader(label: l10n.identityAssignToConnections),
                _AssignToConnectionsPanel(
                  identityId: widget.identityId!,
                ),
                const SizedBox(height: 22),
              ],

              // ── Bottom save/cancel buttons (visible in modal) ──
              _buildBottomButtons(l10n, isEditing),

              const SizedBox(height: 16),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildBottomButtons(AppLocalizations l10n, bool isEditing) {
    final cancel = OutlinedButton(
      onPressed: () => _close(),
      style: OutlinedButton.styleFrom(
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
      child: Text(l10n.cancel),
    );
    final saveLabel = isEditing ? l10n.save : l10n.identitySaveIdentity;
    final save = FilledButton.icon(
      onPressed: _isLoading ? null : _save,
      icon: _isLoading
          ? const SizedBox(
              width: 16,
              height: 16,
              child: ButtonSpinner(),
            )
          : const Icon(LucideIcons.check, size: 18),
      label: Text(saveLabel),
      style: FilledButton.styleFrom(
        backgroundColor: AppColors.brandOrange,
        padding: const EdgeInsets.symmetric(vertical: 14),
      ),
    );
    // Side by side where each keeps room for its words in half the row;
    // otherwise Save stands under Cancel, as wide as the page (in half a
    // phone's row, "Сохранить идентификатор" was cut in two), as the host
    // editor's buttons do.
    return LayoutBuilder(builder: (context, constraints) {
      final half = (constraints.maxWidth - 12) / 2;
      if (_buttonWordsWidth(context, saveLabel) + 18 + 8 + 24 <= half &&
          _buttonWordsWidth(context, l10n.cancel) + 24 <= half) {
        return Row(children: [Expanded(child: cancel), const SizedBox(width: 12), Expanded(child: save)]);
      }
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [cancel, const SizedBox(height: 12), save],
      );
    });
  }

  /// How wide a button's [words] are drawn, at the text size the app is
  /// drawn at.
  double _buttonWordsWidth(BuildContext context, String words) {
    final painter = TextPainter(
      text: TextSpan(text: words, style: Theme.of(context).textTheme.labelLarge),
      textDirection: Directionality.of(context),
      textScaler: MediaQuery.textScalerOf(context),
      maxLines: 1,
    )..layout();
    final width = painter.width;
    painter.dispose();
    return width;
  }

  // ═══════════════════════════════════════════════════════════════════
  //  SETUP KEY DIALOG - 3 tabs: Generate / Paste / Import
  // ═══════════════════════════════════════════════════════════════════

  /// What a key loaded in the key setup dialog does here: it becomes this
  /// key's, and the dialog (opened as [dialogContext]) closes.
  KeyLoadedCallback _keyLoadedIn(BuildContext dialogContext) {
    final l10n = AppLocalizations.of(context)!;
    return (privatePem, fingerprint, keyType, [passphrase]) {
      setState(() {
        _privateKeyPem = privatePem;
        _keyPassphrase = passphrase;
        _publicKeyFingerprint = fingerprint;
        _keyType = keyType;
        // Made from this key when it is saved (the one before was the
        // other key's).
        _publicKeyData = null;
      });
      // Delay pop to next frame - the dialog's controllers may still
      // be referenced in the current call stack (e.g. after passphrase
      // prompt returns). Popping synchronously disposes them mid-frame
      // and causes "TextEditingController used after being disposed".
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (dialogContext.mounted) Navigator.pop(dialogContext);
      });
      showTopSnackBar(
        context,
        l10n.identitySshKeyLoaded(keyType),
        isSuccess: true,
      );
    };
  }

  /// Makes this key on a security key held to the phone or plugged into it:
  /// what kind is asked first, then the key's own sheet takes over
  /// (FidoSigner). What comes back is the key's file, with nothing secret in
  /// it, kept as any key's is.
  Future<void> _makeOnSecurityKey() async {
    final l10n = AppLocalizations.of(context)!;
    final choice = await showFidoMakeKeyDialog(context);
    if (choice == null || !mounted) return;
    final name = _labelController.text.trim();
    try {
      final made = await fidoSigner.makeKey(
        ed25519: choice.ed25519,
        verifyRequired: choice.askPin,
        label: name.isEmpty ? l10n.fidoMakeTitle : name,
        comment: name,
      );
      final imported = KeyImportService().importOpenSSHKey(made.key.toPem());
      if (!mounted) return;
      setState(() {
        _privateKeyPem = imported.privatePem;
        _keyPassphrase = null;
        _publicKeyFingerprint = imported.fingerprint;
        _keyType = imported.keyType;
        _publicKeyData = null;
      });
      if (choice.askPin && !made.keyRequiresPin) {
        // The security key could not be told to hold to the PIN itself
        // (no credProtect): the key works, and asking for the PIN is the
        // app's own rule, which the person is told.
        showTopSnackBar(context, l10n.fidoMadePinAppOnly, isWarning: true);
      } else {
        showTopSnackBar(context, l10n.identitySshKeyLoaded(imported.keyType), isSuccess: true);
      }
    } on FidoFailure catch (failure) {
      // (Closing the sheet says nothing: the person knows.)
      if (!mounted || failure.kind == FidoFailureKind.cancelled) return;
      showTopSnackBar(context, fidoFailureText(l10n, failure), isError: true, details: failure.detail);
    }
  }

  void _showSetupKeyDialogAtTab(int tabIndex) {
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (dialogContext) => KeySetupDialog(
          ref: ref,
          initialTab: tabIndex,
          onKeyLoaded: _keyLoadedIn(dialogContext),
        ),
      ),
    );
  }

  // ═══════════════════════════════════════════════════════════════════
  //  EXISTING KEY DIALOG - copy, change, delete
  // ═══════════════════════════════════════════════════════════════════

  /// The key that is set: its type and fingerprint, each half copied by an
  /// icon on it, and Change key and Delete key in the footer, each of which
  /// changes this dialog in place (the dialog rules of 3.4: Export opened a
  /// second dialog whose only choice was Copy text, and Delete a third).
  void _showExistingKeyDialog() {
    showZestModal<void>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (dialogContext) => _ExistingKeyDialog(
          keyType: _keyType ?? gl10n.homeUnknown,
          fingerprint: _publicKeyFingerprint ?? '',
          // At Connect the private key is neither exported nor replaced here,
          // nor exported where the Orchard's rules forbid exports.
          onCopyPrivate: _secretsHidden || !mayExportKeysScreenSpace(ref, watch: false)
              ? null
              : () => _copyKeyToClipboard(isPublic: false),
          onCopyPublic: () => _copyKeyToClipboard(isPublic: true),
          onDelete: _secretsHidden
              ? null
              : () => setState(() {
                    _privateKeyPem = null;
                    _publicKeyFingerprint = null;
                    _keyType = null;
                    _publicKeyData = null;
                  }),
          keySetup: _secretsHidden
              ? null
              : () => KeySetupDialog(ref: ref, onKeyLoaded: _keyLoadedIn(dialogContext)),
        ),
      ),
    );
  }

  /// The key's public line: the one known, else made from its private key
  /// (opened with its passphrase where it is sealed), named as the key is.
  /// Null with no key, or one that cannot be read. Kept when the key is
  /// saved: a key made here kept none, and could be neither installed on
  /// hosts nor shared.
  String? _publicLine() {
    final known = _publicKeyData?.trim();
    if (known != null && known.isNotEmpty) return publicKeyLineNamed(known);
    final pem = _privateKeyPem;
    if (pem == null) return null;
    return publicKeyLineOf(pem, passphrase: _keyPassphrase, comment: _labelController.text.trim());
  }

  Future<void> _copyKeyToClipboard({required bool isPublic}) async {
    final l10n = AppLocalizations.of(context)!;
    if (isPublic) {
      // A key (or its fingerprint) goes to the clipboard: reveal gate (spec 5).
      if (!await confirmRevealWhileRecording(context, ref)) return;
      if (!mounted) return;
      // Its public line: kept, or made from the private key (with its
      // passphrase where it is sealed; a sealed key gave its fingerprint).
      final publicLine = _publicLine();
      if (publicLine != null) {
        await Clipboard.setData(ClipboardData(text: publicLine));
        if (mounted) showTopSnackBar(context, l10n.identityPublicKeyCopied, isSuccess: true);
      } else if (_privateKeyPem != null) {
        // Fallback: copy the fingerprint
        await Clipboard.setData(ClipboardData(text: _publicKeyFingerprint ?? ''));
        if (mounted) showTopSnackBar(context, l10n.identityFingerprintCopied, isSuccess: true);
      }
    } else {
      // The private key goes to the clipboard: reveal gate (spec 5).
      if (!await confirmRevealWhileRecording(context, ref)) return;
      if (!mounted) return;
      if (_privateKeyPem != null) {
        await SecretClipboard.copy(_privateKeyPem!);
        if (widget.identityId != null) {
          unawaited(noteScreenActivity(ref, ActivityKind.copy,
              itemKind: 'key', itemKey: widget.identityId!, name: _labelController.text));
        }
        if (mounted) {
          showTopSnackBar(
            context,
            '${l10n.identityPrivateKeyCopied} ${l10n.identityEditClipboardAutoClearNote}',
            isSuccess: true,
          );
        }
      }
    }
  }

  // ─── Actions ───────────────────────────────────────────────────

  /// Whether a certificate can be added to this key here: a saved key whose
  /// private key this account may see and change (Import certificate checks
  /// the certificate against it), with the key as it was saved (one loaded
  /// in its place and not saved yet would be checked against the old one).
  bool _mayAddCertificate(bool isEditing) {
    final id = widget.identityId;
    if (!isEditing || id == null || _secretsHidden) return false;
    if (_authMethod != AuthMethod.publicKey && _authMethod != AuthMethod.certificate) return false;
    final fingerprint = _publicKeyFingerprint;
    if (fingerprint == null || fingerprint != _opened?.publicKeyFingerprint) return false;
    final rules = ItemRules.of(ref, 'key');
    return rules.mayChange(id) && rules.mayReveal(id);
  }

  /// Import certificate, as a computer's Keys page has it, for this key. A
  /// certificate attached makes the key one that signs in with it: the
  /// editor follows, so a Save keeps it.
  Future<void> _addCertificate() async {
    final id = widget.identityId!;
    await CertImportDialog.show(context, forIdentityId: id);
    if (!mounted) return;
    final now = await ref.read(identitiesDaoProvider).getById(id);
    if (!mounted || now == null) return;
    if (now.authMethod == AuthMethod.certificate.name) {
      setState(() {
        _authMethod = AuthMethod.certificate;
        _openedKind = now.authMethod;
        _opened = now;
      });
    }
  }

  Future<void> _save() async {
    // Hidden secrets are not in this screen: saving would write over them.
    if (_secretsHidden) return;
    if (!_formKey.currentState!.validate()) return;
    // A password manager's key needs the item its password is in.
    if (_authMethod == AuthMethod.passwordManager && _passwordRef == null) {
      showTopSnackBar(context, AppLocalizations.of(context)!.pmRefRequired, isError: true);
      return;
    }

    setState(() => _isLoading = true);

    try {
      final crud = ref.read(identityCrudProvider);

      // A key's own password (3.0, accounts per host): what the field shows
      // is what is tried after the key, changed only where the field was
      // (keyPasswordOnSave). Emptied, it is taken off; one the field never
      // showed (left from before the identity became a key) is left as it is.
      final kept = kKeysWithPasswordAfter.contains(_authMethod.name)
          ? keyPasswordOnSave(
              kind: _authMethod.name,
              openedKind: widget.identityId == null ? null : _openedKind,
              shown: _shownPassword,
              text: _passwordController.text,
            )
          : null;
      if (widget.identityId != null) {
        // A sync may have changed this key while the editor was open: its
        // name, user, colour and unattended switch that the person did not
        // touch keep what is there now (found in a code audit). What
        // signs in (its kind and secrets) is written as the form holds it.
        final now = await ref.read(identitiesDaoProvider).getById(widget.identityId!);
        final keep = keptSince<Identity>(_opened, now, (i) => i.updatedAt);
        await crud.update(
          id: widget.identityId!,
          label: keep(_labelController.text.trim(), (i) => i.label),
          username: keep(_usernameController.text.trim(), (i) => i.username),
          authMethod: _authMethod.name,
          keyType: _keyType,
          publicKeyFingerprint: _publicKeyFingerprint,
          publicKeyData: _authMethod == AuthMethod.publicKey ? _publicLine() : null,
          password: _authMethod == AuthMethod.password ? _passwordController.text : kept?.write,
          passwordAfterKey: kept == null ? false : kept.afterKey,
          clearPassword: kept?.clear ?? false,
          privateKeyPem:
              _authMethod == AuthMethod.publicKey ? _privateKeyPem : null,
          keyPassphrase:
              _authMethod == AuthMethod.publicKey ? _keyPassphrase : null,
          colorIndex: keep(_colorIndex, (i) => i.colorIndex),
          colorValue: keep(_colorValue, (i) => i.colorValue),
          allowUnattended: keep(_allowUnattended, (i) => i.allowUnattended),
          passwordRef: _authMethod == AuthMethod.passwordManager ? _passwordRef : null,
          clearPasswordRef: _authMethod != AuthMethod.passwordManager,
        );
        // A team certificate keeps nothing secret, nor does a key whose
        // password stays in a password manager.
        if (_authMethod == AuthMethod.teamCertificate || _authMethod == AuthMethod.passwordManager) {
          await crud.clearSecrets(widget.identityId!);
        }
      } else {
        // Where "Save in" says (3.4): here, as before, or any other place.
        final place = _saveIn ?? defaultSavePlace(ref);
        final here = place == defaultSavePlace(ref);
        final newId = await saveNewItemIn(context, ref, place: place, kind: TransferKinds.key, write: () => crud.create(
          label: _labelController.text.trim(),
          username: _usernameController.text.trim(),
          authMethod: _authMethod.name,
          keyType: _keyType,
          publicKeyFingerprint: _publicKeyFingerprint,
          publicKeyData: _authMethod == AuthMethod.publicKey ? _publicLine() : null,
          password: _authMethod == AuthMethod.password ? _passwordController.text : kept?.write,
          passwordAfterKey: kept?.afterKey ?? false,
          privateKeyPem:
              _authMethod == AuthMethod.publicKey ? _privateKeyPem : null,
          keyPassphrase:
              _authMethod == AuthMethod.publicKey ? _keyPassphrase : null,
          colorIndex: _colorIndex,
          colorValue: _colorValue,
          passwordRef: _authMethod == AuthMethod.passwordManager ? _passwordRef : null,
        ));
        if (newId == null) return;
        if (!here && mounted) {
          // Saved in another space: not one this screen's caller can use.
          final l10n = AppLocalizations.of(context)!;
          final saved = savePlaces(ref, l10n, watch: false).where((p) => p.place == place).firstOrNull;
          showTopSnackBar(context, l10n.saveInSavedToast(Redactable.freeText(saved?.title ?? '').display), isSuccess: true);
        }
        _createdId = here ? newId : null;
        // The first secret saved: the app lock is offered, once (a computer
        // too, 4.0).
        final saved = _authMethod == AuthMethod.password || _authMethod == AuthMethod.publicKey;
        if (saved && mounted) await maybeOfferAppLock(context, ref);
      }

      if (mounted) _close(_createdId);
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          isOrchardWriteRefused(e)
              ? AppLocalizations.of(context)!.orchardWriteNotAllowed
              : AppLocalizations.of(context)!.identityNotSaved,
          isError: true,
          details: isOrchardWriteRefused(e) ? null : '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  Future<void> _exportPrivateKey() async {
    final l10n = AppLocalizations.of(context)!;
    if (widget.identityId == null) return;

    final crud = ref.read(identityCrudProvider);
    final pem = await crud.getPrivateKey(widget.identityId!);

    if (pem == null || pem.isEmpty) {
      if (mounted) {
        showTopSnackBar(context, l10n.identityNoPrivateKey);
      }
      return;
    }
    if (!mounted) return;

    // Exporting key material while recording is a reveal (spec 5): the toast
    // and the share sheet name the key, and the files carry the real PEM.
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;

    // Asked first: a private key signs in as the person. A security key's
    // key file (the FIDO2 keys keep theirs in the private key's place) holds
    // no secret, only the key handle and the public key, and signs in with
    // nothing but the security key itself: it gets a note that says so, not
    // the private key's warning.
    final securityKey = isSecurityKeyFile(pem);
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: securityKey ? ZestDialogTone.info : ZestDialogTone.neutral,
      title: securityKey ? l10n.identityExportSecurityKeyTitle : l10n.identityExportPrivateKey,
      body: securityKey ? l10n.identityExportSecurityKeyNote : l10n.identityExportPrivateKeyWarning,
      confirmLabel: l10n.settingsExportLabel,
    );

    if (confirmed != true || !mounted) return;
    unawaited(noteScreenActivity(ref, ActivityKind.export,
        itemKind: 'key', itemKey: widget.identityId!, name: _labelController.text));

    try {
      final label = _labelController.text.trim().replaceAll(RegExp(r'[^\w\-]'), '_');
      final privateName = '${label}_id_rsa.pem';
      final publicName = '${label}_id_rsa.pub';
      // Its public key beside it, where it can be made from the private one
      // (the line named every key wrongly: ssh-ssh-ed25519, ssh-rsa-sha2-256).
      final publicLine = publicKeyLineOf(pem, comment: label);
      // A computer saves them where the person says (the share sheet
      // is a phone's; on Linux it throws for files).
      if (isDesktopPlatform) {
        final saved = await saveKeyFilesOnComputer(
          {
            privateName: utf8.encode(pem),
            if (publicLine != null) publicName: utf8.encode('$publicLine\n'),
          },
          pick: pickKeyFileWithSaveDialog,
          title: l10n.keysExportSaveDialog,
        );
        if (saved == null || !mounted) return;
        await showFileSavedDialog(
          context,
          title: l10n.keysExportSavedTitle,
          message: saved.length > 1
              ? l10n.keysExportSavedBesideBody(saved[1].split(Platform.pathSeparator).last)
              : l10n.keysExportPrivateWarning,
          path: saved.first,
        );
        return;
      }
      // Written into a folder of its own that only the person can open, and
      // deleted with it once the sheet has closed (it was written straight
      // into the folder of temporary files, under a name that can be
      // guessed, and kept to the person only once it was written).
      await ConnectionShareService.shareFiles(
        {
          privateName: utf8.encode(pem),
          if (publicLine != null) publicName: utf8.encode('$publicLine\n'),
        },
        subject: l10n.identityEditShareSubject(label),
        // Said before the share sheet: users dismissing the sheet were
        // otherwise getting no confirmation that the export produced files.
        written: () {
          if (!mounted) return;
          showTopSnackBar(
              context,
              publicLine == null
                  ? l10n.identityEditExportedFileMessage(privateName)
                  : l10n.identityEditExportedFilesMessage(privateName, publicName),
              isSuccess: true,
              duration: const Duration(seconds: 4));
        },
      );
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.identityExportFailed, isError: true, details: '$e');
      }
    }
  }

  Future<void> _confirmDelete() async {
    final l10n = AppLocalizations.of(context)!;
    final identity = await ref.read(identitiesDaoProvider).getById(widget.identityId!);
    if (!mounted) return;
    final authority = identity == null ? null : authorityOfKey(ref, identity);
    if (authority != null) {
      final crate =
          ref.read(activeOrchardProvider).valueOrNull?.crates.where((c) => c.id == authority.crateId).firstOrNull;
      final sure = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: l10n.certAuthorityKeyDeleteTitle,
        body: l10n.certAuthorityKeyDeleteBody(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)),
        confirmLabel: l10n.certAuthorityKeyDeleteConfirm,
      );
      if (sure != true || !mounted) return;
    }
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      title: l10n.identityDeleteTitle,
      body: l10n.identityDeleteMsg,
      confirmLabel: l10n.delete,
    );

    if (confirmed == true && mounted) {
      await ref.read(identityCrudProvider).delete(widget.identityId!);
      if (mounted) _close();
    }
  }
}

// ═══════════════════════════════════════════════════════════════════════
//  SETUP KEY DIALOG - 3 tabs: Generate / Paste / Import
// ═══════════════════════════════════════════════════════════════════════

// ═══════════════════════════════════════════════════════════════════════
//  RECORDING-MODE STAND-IN FOR AN IDENTIFIER FIELD
// ═══════════════════════════════════════════════════════════════════════

/// The read-only stand-in an editor renders in place of a text field that
/// holds an identifier (display name, username, key comment, a fingerprint)
/// while recording mode is on.
///
/// Its own controller holds the MASKED form of the real field's text, so the
/// real value is never painted and the real controller is never written. A
/// recording glyph sits at the trailing edge, and a tap anywhere on the field
/// runs the reveal gate ([confirmRevealWhileRecording]): choosing to turn the
/// mode off there flips the setting, and the editor's rebuild renders the real,
/// editable field again. Shared by the mobile editor above and the desktop Keys
/// detail pane.
///
/// A [validator] sees the masked text. Every masking rule keeps an empty value
/// empty, so a required-field check behaves exactly as it does on the real
/// field, and a [Form] still validates a masked field.
class RecordingMaskedField extends ConsumerStatefulWidget {
  const RecordingMaskedField({
    super.key,
    required this.label,
    required this.value,
    this.placeholder,
    this.isMono = false,
    this.labelWidth,
    this.maxLines = 1,
    this.validator,
  });

  /// Already-localized field label (the left cell of the [ZestField] shell).
  final String label;

  /// The identifier, wrapped in its kind; only its display form is painted.
  final Redactable value;

  /// Dim empty-state hint, shown when the (masked) value is empty.
  final String? placeholder;

  /// Monospace the value (usernames, fingerprints).
  final bool isMono;

  /// Override for the shell's label-cell width, to align with sibling fields.
  final double? labelWidth;

  /// Lines for a multi-line value (a public key).
  final int maxLines;

  /// Optional [Form] validator; receives the masked text.
  final FormFieldValidator<String>? validator;

  @override
  ConsumerState<RecordingMaskedField> createState() =>
      _RecordingMaskedFieldState();
}

class _RecordingMaskedFieldState extends ConsumerState<RecordingMaskedField> {
  final TextEditingController _masked = TextEditingController();

  @override
  void dispose() {
    _masked.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final shown = widget.value.displayIn(ref);
    // Keep the masked controller on the current display form (the level can
    // change live). The field below is a descendant of this widget, so marking
    // it here, mid-build, is permitted.
    if (_masked.text != shown) _masked.text = shown;
    final tall = widget.maxLines > 1;
    return ZestField.custom(
      label: widget.label,
      labelWidth: widget.labelWidth,
      tall: tall,
      child: Tooltip(
        message: l10n.recModeTooltipOn,
        waitDuration: const Duration(milliseconds: 400),
        child: MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: () => confirmRevealWhileRecording(context, ref),
            child: Row(
              crossAxisAlignment:
                  tall ? CrossAxisAlignment.start : CrossAxisAlignment.center,
              children: [
                Expanded(
                  // Purely visual: pointer events go to the gate above, and
                  // the field is not a tab stop.
                  child: IgnorePointer(
                    child: TextFormField(
                      controller: _masked,
                      readOnly: true,
                      canRequestFocus: false,
                      showCursor: false,
                      enableInteractiveSelection: false,
                      maxLines: widget.maxLines,
                      style: widget.isMono
                          ? _kValStyle.copyWith(
                              fontFamily: _kMono, letterSpacing: 0.4)
                          : _kValStyle,
                      decoration: zestShellFieldDecoration(
                          hintText: widget.placeholder),
                      validator: widget.validator,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Icon(LucideIcons.video,
                    size: 16, color: ZestTokens.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Result of a [KeySetupDialog] - the in-memory key material the user
/// generated / pasted / imported, ready to be handed to
/// `IdentityCrudNotifier.create` / `update` (which perform the secure-storage
/// writes). Carries no secrets to disk itself.
class LoadedKeyResult {
  const LoadedKeyResult({
    required this.privatePem,
    required this.fingerprint,
    required this.keyType,
    this.passphrase,
  });

  final String privatePem;
  final String fingerprint;
  final String keyType;
  final String? passphrase;
}

/// What a key loaded in [KeySetupDialog] is given to: its private key, its
/// fingerprint and type, and the passphrase it was opened with.
typedef KeyLoadedCallback = void Function(String privatePem, String fingerprint, String keyType,
    [String? passphrase]);

/// The Generate / Paste / Import key-setup dialog.
///
/// Reused by both the legacy [IdentityEditScreen] modal (via [onKeyLoaded]) and
/// the 1.7 desktop Keys detail pane (via the static [show], which resolves to a
/// [LoadedKeyResult]). The key-loading logic is identical for both callers so
/// the secure-storage handling downstream stays byte-for-byte the same.
///
/// The app's dialog (the dialog rules of 3.4): the tab's action is the main
/// button in the footer (Generate key, Load key, Choose key file), Paste is
/// the paste tab's side option at its left, and the passphrase of a sealed
/// key is asked in this dialog's place (it was a second dialog over it).
class KeySetupDialog extends StatefulWidget {
  final WidgetRef ref;
  final int initialTab;
  final KeyLoadedCallback onKeyLoaded;

  const KeySetupDialog({
    super.key,
    required this.ref,
    this.initialTab = 0,
    required this.onKeyLoaded,
  });

  /// Show the dialog and resolve to the loaded key material, or null if the
  /// user dismissed it without loading a key.
  static Future<LoadedKeyResult?> show(
    BuildContext context,
    WidgetRef ref, {
    int initialTab = 0,
  }) {
    return showZestModal<LoadedKeyResult>(
      context: context,
      size: ZestModalSize.compact,
      child: Builder(
        builder: (dialogContext) => KeySetupDialog(
          ref: ref,
          initialTab: initialTab,
          onKeyLoaded: (privatePem, fingerprint, keyType, [passphrase]) {
            // Pop on the next frame - the dialog's controllers may still be
            // referenced in the current call stack (e.g. after a passphrase
            // prompt returns). Popping synchronously would dispose them mid-frame.
            afterNextFrame((_) {
              if (dialogContext.mounted) {
                Navigator.pop(
                  dialogContext,
                  LoadedKeyResult(
                    privatePem: privatePem,
                    fingerprint: fingerprint,
                    keyType: keyType,
                    passphrase: passphrase,
                  ),
                );
              }
            });
          },
        ),
      ),
    );
  }

  @override
  State<KeySetupDialog> createState() => _KeySetupDialogState();
}

class _KeySetupDialogState extends State<KeySetupDialog>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;
  final _pasteController = TextEditingController();

  // Generate tab state
  _KeyFormat _selectedFormat = _KeyFormat.ed25519;
  _KeyStrength _selectedStrength = _KeyStrength.rsa4096;
  bool _isGenerating = false;

  // Paste tab state
  bool _isPasting = false;
  String? _pasteError;

  /// The passphrase of a sealed key, asked in this dialog's place while it is
  /// set; [_answerPassphrase] answers it (null: not given).
  Completer<String?>? _passphraseAsk;
  String? _passphraseError;
  bool _decrypting = false;
  final _passphraseField = TextEditingController();

  /// Resolve the selected format + strength into a KeyType.
  KeyType get _resolvedKeyType {
    return switch (_selectedFormat) {
      _KeyFormat.ed25519 => KeyType.ed25519,
      _KeyFormat.rsa => _selectedStrength == _KeyStrength.rsa2048
          ? KeyType.rsa2048
          : KeyType.rsa4096,
      _KeyFormat.ecdsa => switch (_selectedStrength) {
          _KeyStrength.ecdsaP256 => KeyType.ecdsaP256,
          _KeyStrength.ecdsaP384 => KeyType.ecdsaP384,
          _KeyStrength.ecdsaP521 => KeyType.ecdsaP521,
          _ => KeyType.ecdsaP256,
        },
    };
  }

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab,
    );
    // The footer's main button is the tab's own.
    _tabController.addListener(_tabChanged);
  }

  void _tabChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _tabController.removeListener(_tabChanged);
    _tabController.dispose();
    _pasteController.dispose();
    // A passphrase still asked as the dialog went: not given.
    final ask = _passphraseAsk;
    if (ask != null && !ask.isCompleted) ask.complete(null);
    _passphraseField.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    if (_passphraseAsk != null) return _buildPassphraseStep(l10n);
    final tab = _tabController.index;
    final busy = _isGenerating || _isPasting;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.identityKeySetupTitle,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TabBar(
            controller: _tabController,
            // Neutral, with no line under it: colour in a dialog is for what
            // it means.
            indicatorColor: AppColors.v3TextPrimary,
            labelColor: AppColors.v3TextPrimary,
            unselectedLabelColor: AppColors.v3TextSecondary,
            dividerColor: Colors.transparent,
            tabs: [
              Tab(text: l10n.identityGenerate),
              Tab(text: l10n.identityPaste),
              Tab(text: l10n.identityImport),
            ],
          ),
          SizedBox(
            height: 290,
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildGenerateTab(),
                _buildPasteTab(),
                _buildImportTab(),
              ],
            ),
          ),
        ],
      ),
      // Paste from the clipboard: the paste tab's side option.
      tertiaryKey: const ValueKey('key-setup-paste'),
      tertiaryAction: tab == 1
          ? (label: l10n.identityPaste, onPressed: busy ? null : _pasteFromClipboard)
          : null,
      secondaryAction: (
        label: l10n.cancel,
        onPressed: busy ? null : () => Navigator.of(context).pop(),
      ),
      primaryKey: const ValueKey('key-setup-go'),
      primaryAction: switch (tab) {
        0 => (
            label: _isGenerating ? l10n.identityGenerating : l10n.identityGenerateKey,
            icon: null,
            onPressed: busy ? null : _generateKey,
          ),
        1 => (label: l10n.identityLoadKey, icon: null, onPressed: busy ? null : _importPastedKey),
        _ => (label: l10n.identityChooseKeyFile, icon: null, onPressed: busy ? null : _importKeyFile),
      },
    );
  }

  /// The passphrase of a sealed key, in this dialog's place; a wrong one says
  /// so under the field and asks again.
  Widget _buildPassphraseStep(AppLocalizations l10n) {
    void cancel() => _answerPassphrase(null);
    void submit() => _answerPassphrase(_passphraseField.text);
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.lock,
      title: l10n.identityKeyPassphrase,
      subtitle: l10n.identityEditKeyEncryptedSubtitle,
      onClose: _decrypting ? () {} : cancel,
      body: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          ZestTextField(
            key: const ValueKey('key-setup-passphrase'),
            controller: _passphraseField,
            label: l10n.identityPassphrase,
            hintText: l10n.identityEnterPassphrase,
            obscureText: true,
            errorText: _passphraseError,
            onSubmit: _decrypting ? null : submit,
            onChanged: (_) {
              if (_passphraseError != null) setState(() => _passphraseError = null);
            },
          ),
          if (_decrypting) ...[
            const SizedBox(height: 12),
            Row(
              children: [
                SizedBox.square(
                  dimension: 14,
                  child: CircularProgressIndicator(strokeWidth: 2, color: AppColors.v3TextSecondary),
                ),
                const SizedBox(width: 8),
                Text(l10n.zestDialogWorking, style: TextStyle(fontSize: 12.5, color: AppColors.v3TextSecondary)),
              ],
            ),
          ],
        ],
      ),
      secondaryAction: (label: l10n.cancel, onPressed: _decrypting ? null : cancel),
      primaryKey: const ValueKey('key-setup-decrypt'),
      primaryAction: (label: l10n.identityDecrypt, icon: null, onPressed: _decrypting ? null : submit),
    );
  }

  /// Asks for the passphrase of a sealed key in this dialog's place, with
  /// [errorMessage] (a wrong one before) under the field. Null: not given.
  Future<String?> _promptPassphrase({String? errorMessage}) {
    final ask = Completer<String?>();
    setState(() {
      _passphraseAsk = ask;
      _passphraseError = errorMessage;
      _decrypting = false;
      _passphraseField.clear();
    });
    return ask.future;
  }

  /// Answers the passphrase asked: null takes the tabs back; one given is
  /// tried, the dialog saying it works meanwhile.
  void _answerPassphrase(String? passphrase) {
    final ask = _passphraseAsk;
    if (ask == null || ask.isCompleted) return;
    setState(() {
      if (passphrase == null) {
        _passphraseAsk = null;
      } else {
        _decrypting = true;
      }
    });
    ask.complete(passphrase);
  }

  /// The passphrase is asked no more (the key could not be read): the tabs.
  void _endPassphrase() {
    if (mounted && _passphraseAsk != null) {
      setState(() {
        _passphraseAsk = null;
        _decrypting = false;
      });
    }
  }

  // ── Generate Tab ───────────────────────────────────────────────

  Widget _buildGenerateTab() {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Key Format ──────────────────────────────────────
          Text(
            l10n.identityKeyFormat,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              fontSize: 13,
            ),
          ),
          const SizedBox(height: 8),
          // The app's selects, as the key generation screen's (Material
          // dropdowns; a design audit).
          ZestSelect<_KeyFormat>(
            value: _selectedFormat,
            items: [
              ZestSelectItem(_KeyFormat.ed25519, l10n.identityEd25519Recommended),
              ZestSelectItem(_KeyFormat.rsa, l10n.identityRsa),
              ZestSelectItem(_KeyFormat.ecdsa, l10n.identityEcdsa),
            ],
            onChanged: (v) {
              setState(() {
                _selectedFormat = v;
                if (v == _KeyFormat.rsa) {
                  _selectedStrength = _KeyStrength.rsa4096;
                } else if (v == _KeyFormat.ecdsa) {
                  _selectedStrength = _KeyStrength.ecdsaP256;
                }
              });
            },
          ),
          const SizedBox(height: 6),
          Text(
            _formatDescription(_selectedFormat, l10n),
            style: TextStyle(
              color: AppColors.textSecondary,
              fontSize: 12,
            ),
          ),

          // ── Key Strength (RSA / ECDSA only) ────────────────
          if (_selectedFormat == _KeyFormat.rsa ||
              _selectedFormat == _KeyFormat.ecdsa) ...[
            const SizedBox(height: 16),
            Text(
              l10n.identityKeyStrength,
              style: const TextStyle(
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
            const SizedBox(height: 8),
            ZestSelect<_KeyStrength>(
              value: _selectedStrength,
              items: _strengthOptionsForFormat(_selectedFormat, l10n),
              onChanged: (v) => setState(() => _selectedStrength = v),
            ),
          ],
        ],
      ),
    );
  }

  String _formatDescription(_KeyFormat format, AppLocalizations l10n) {
    return switch (format) {
      _KeyFormat.ed25519 => l10n.identityEd25519Desc,
      _KeyFormat.rsa => l10n.identityRsaDesc,
      _KeyFormat.ecdsa => l10n.identityEcdsaDesc,
    };
  }

  List<ZestSelectItem<_KeyStrength>> _strengthOptionsForFormat(
      _KeyFormat format, AppLocalizations l10n) {
    return switch (format) {
      _KeyFormat.rsa => [
          ZestSelectItem(_KeyStrength.rsa2048, l10n.identityRsa2048Bits),
          ZestSelectItem(_KeyStrength.rsa4096, l10n.identityRsa4096Bits),
        ],
      _KeyFormat.ecdsa => [
          ZestSelectItem(_KeyStrength.ecdsaP256, l10n.identityEcdsaP256Nist),
          ZestSelectItem(_KeyStrength.ecdsaP384, l10n.identityEcdsaP384Nist),
          ZestSelectItem(_KeyStrength.ecdsaP521, l10n.identityEcdsaP521Nist),
        ],
      _ => const [],
    };
  }

  Future<void> _generateKey() async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _isGenerating = true);

    try {
      final keyGen = widget.ref.read(keyGenerationServiceProvider);
      final result = await keyGen.generate(_resolvedKeyType);

      widget.onKeyLoaded(
        result.privatePem,
        result.fingerprint,
        _resolvedKeyType.displayName,
      );
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          l10n.keyNotGenerated,
          isError: true,
          details: '$e',
        );
      }
    } finally {
      if (mounted) setState(() => _isGenerating = false);
    }
  }

  // ── Paste Tab ──────────────────────────────────────────────────

  Widget _buildPasteTab() {
    final l10n = AppLocalizations.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            l10n.identityPasteKeyPrompt,
            style: TextStyle(fontSize: 13, color: AppColors.textSecondary),
          ),
          const SizedBox(height: 12),

          // Paste text field
          TextField(
            controller: _pasteController,
            maxLines: 6,
            style: const TextStyle(
              fontFamily: 'JetBrainsMono',
              fontSize: 11,
            ),
            decoration: InputDecoration(
              hintText: l10n.identityPasteKeyHint,
              hintStyle: TextStyle(
                fontFamily: 'JetBrainsMono',
                fontSize: 11,
                color: ZestTokens.textPlaceholder,
              ),
              errorText: _pasteError,
              border: const OutlineInputBorder(),
              contentPadding: const EdgeInsets.all(12),
            ),
          ),
        ],
      ),
    );
  }

  Future<void> _pasteFromClipboard() async {
    final l10n = AppLocalizations.of(context)!;
    final clipboardData = await Clipboard.getData(Clipboard.kTextPlain);
    if (!mounted) return;
    if (clipboardData?.text != null) {
      _pasteController.text = clipboardData!.text!;
      setState(() => _pasteError = null);
    } else {
      setState(() => _pasteError = l10n.identityClipboardEmpty);
    }
  }

  Future<void> _importPastedKey() async {
    final l10n = AppLocalizations.of(context)!;
    final content = _pasteController.text.trim();
    if (content.isEmpty) {
      setState(() => _pasteError = l10n.identityPasteKeyFirst);
      return;
    }

    // Check for public key mistake
    if (content.startsWith('ssh-rsa ') ||
        content.startsWith('ssh-ed25519 ') ||
        content.startsWith('ssh-dss ') ||
        content.startsWith('ecdsa-sha2-')) {
      setState(() => _pasteError = l10n.identityPublicKeyError);
      return;
    }

    setState(() {
      _isPasting = true;
      _pasteError = null;
    });

    try {
      final importService = KeyImportService();

      // Check if encrypted - prompt for passphrase with retry
      String? passphrase;
      if (importService.isEncrypted(content) && mounted) {
        String? errorHint;
        for (var attempt = 0; attempt < 3; attempt++) {
          passphrase = await _promptPassphrase(errorMessage: errorHint);
          if (passphrase == null) {
            if (mounted) setState(() => _isPasting = false);
            return;
          }
          // Try decrypting with this passphrase
          try {
            final ImportedKey imported;
            if (importService.isPpkFormat(content)) {
              imported = await importService.importPpkKeyInBackground(content, passphrase);
            } else {
              imported = importService.importOpenSSHKey(content, passphrase);
            }
            // Success! Guard with mounted since passphrase dialog is async.
            if (mounted) {
              widget.onKeyLoaded(
                imported.privatePem,
                imported.fingerprint,
                imported.keyType,
                passphrase,
              );
            }
            return;
          } catch (e) {
            if (KeyImportService.isPassphraseError(e.toString())) {
              errorHint = l10n.identityIncorrectPassphrase;
              continue; // Retry
            }
            // Non-passphrase error - show friendly message, don't crash
            final msg = KeyImportService.problemSaid(e, l10n);
            _endPassphrase();
            if (mounted) setState(() => _pasteError = msg);
            return;
          }
        }
        // Exhausted attempts
        _endPassphrase();
        if (mounted) {
          setState(() => _pasteError =
              l10n.identityDecryptFailed);
        }
        return;
      }

      // Not encrypted - import directly
      final ImportedKey imported;
      if (importService.isPpkFormat(content)) {
        imported = await importService.importPpkKeyInBackground(content, passphrase);
      } else {
        imported = importService.importOpenSSHKey(content, passphrase);
      }

      widget.onKeyLoaded(
        imported.privatePem,
        imported.fingerprint,
        imported.keyType,
      );
    } catch (e) {
      final message = KeyImportService.problemSaid(e, l10n);
      if (mounted) setState(() => _pasteError = message);
    } finally {
      if (mounted) setState(() => _isPasting = false);
    }
  }

  // ── Import Tab ─────────────────────────────────────────────────

  Widget _buildImportTab() {
    final l10n = AppLocalizations.of(context)!;
    return Padding(
      padding: const EdgeInsets.only(top: 16),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Container(
            width: 48,
            height: 48,
            decoration: BoxDecoration(
              color: AppColors.v3TextPrimary.withValues(alpha: 0.07),
              shape: BoxShape.circle,
            ),
            child: Icon(
              LucideIcons.upload,
              size: 22,
              color: AppColors.v3TextSecondary,
            ),
          ),
          const SizedBox(height: 16),
          Text(
            l10n.identityImportKeyDesc,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 8),
          Text(
            l10n.identityImportKeyFormats,
            textAlign: TextAlign.center,
            style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Future<void> _importKeyFile() async {
    final l10n = AppLocalizations.of(context)!;
    try {
      final result = await FilePicker.platform.pickFiles(
        type: FileType.any,
        withData: true,
        // Open straight to ~/.ssh (desktop) - that is where keys live.
        initialDirectory: defaultSshPickerDirectory(),
      );

      if (result == null || result.files.isEmpty) return;

      final file = result.files.first;
      String content;

      if (file.bytes != null) {
        content = String.fromCharCodes(file.bytes!);
      } else if (file.path != null) {
        content = await File(file.path!).readAsString();
      } else {
        throw const FormatException('Could not read file');
      }

      final importService = KeyImportService();

      // Check if encrypted - prompt for passphrase with retry
      if (importService.isEncrypted(content) && mounted) {
        String? errorHint;
        for (var attempt = 0; attempt < 3; attempt++) {
          final passphrase = await _promptPassphrase(errorMessage: errorHint);
          if (passphrase == null) return; // User cancelled
          try {
            final ImportedKey imported;
            if (importService.isPpkFormat(content)) {
              imported = await importService.importPpkKeyInBackground(content, passphrase);
            } else {
              imported = importService.importOpenSSHKey(content, passphrase);
            }
            // Success! Guard with mounted since passphrase dialog is async.
            if (mounted) {
              widget.onKeyLoaded(
                imported.privatePem,
                imported.fingerprint,
                imported.keyType,
                passphrase,
              );
            }
            return;
          } catch (e) {
            if (KeyImportService.isPassphraseError(e.toString())) {
              errorHint = l10n.identityIncorrectPassphrase;
              continue; // Retry
            }
            // Non-passphrase error - show friendly message, don't crash
            _endPassphrase();
            if (mounted) {
              final msg = KeyImportService.problemSaid(e, l10n);
              showTopSnackBar(context, msg, isError: true, details: '$e');
            }
            return;
          }
        }
        // Exhausted attempts
        _endPassphrase();
        if (mounted) {
          showTopSnackBar(
            context,
            l10n.identityImportFailed(l10n.identityDecryptFailed),
            isError: true,
          );
        }
        return;
      }

      // Not encrypted - import directly
      final ImportedKey imported;
      if (importService.isPpkFormat(content)) {
        imported = importService.importPpkKey(content, null);
      } else {
        imported = importService.importOpenSSHKey(content, null);
      }

      widget.onKeyLoaded(
        imported.privatePem,
        imported.fingerprint,
        imported.keyType,
      );
    } catch (e) {
      if (mounted) {
        showTopSnackBar(
          context,
          KeyImportService.problemSaid(e, l10n),
          isError: true,
          details: '$e',
        );
      }
    }
  }

}

// ═══════════════════════════════════════════════════════════════════════
//  EXISTING KEY DIALOG - Manage/Export/Delete
// ═══════════════════════════════════════════════════════════════════════

enum _KeyStep { key, delete, change }

/// The key that is set ([_IdentityEditScreenState._showExistingKeyDialog]):
/// its type and fingerprint, each half copied by an icon on it; Change key
/// shows the key setup dialog in this one's place, Delete key asks in this
/// one's place, with DELETE typed.
class _ExistingKeyDialog extends StatefulWidget {
  final String keyType;
  final String fingerprint;

  /// Null when the private key is not this account's to export (an Orchard
  /// key at Connect): no copy icon for it. Likewise [onDelete] and
  /// [keySetup] (no Delete key, no Change key).
  final VoidCallback? onCopyPrivate;
  final VoidCallback onCopyPublic;

  /// Takes the key away, once DELETE is typed; the dialog then closes.
  final VoidCallback? onDelete;

  /// The key setup dialog, shown in this one's place by Change key.
  final Widget Function()? keySetup;

  const _ExistingKeyDialog({
    required this.keyType,
    required this.fingerprint,
    required this.onCopyPrivate,
    required this.onCopyPublic,
    required this.onDelete,
    required this.keySetup,
  });

  @override
  State<_ExistingKeyDialog> createState() => _ExistingKeyDialogState();
}

class _ExistingKeyDialogState extends State<_ExistingKeyDialog> {
  var _step = _KeyStep.key;
  final _typed = TextEditingController();

  @override
  void dispose() {
    _typed.dispose();
    super.dispose();
  }

  bool get _typedDelete => _typed.text.trim().toUpperCase() == 'DELETE';

  void _delete() {
    if (!_typedDelete) return;
    widget.onDelete?.call();
    Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final setup = widget.keySetup;
    if (_step == _KeyStep.change && setup != null) return setup();
    if (_step == _KeyStep.delete) {
      return ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.destructive,
        icon: LucideIcons.trash2,
        title: l10n.identityDeleteKeyTitle,
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              l10n.identityDeleteKeyMsg,
              style: TextStyle(fontSize: 13.5, height: 1.5, color: AppColors.v3TextSecondary),
            ),
            const SizedBox(height: 14),
            ZestTextField(
              key: const ValueKey('identity-delete-key-typed'),
              controller: _typed,
              hintText: l10n.identityDeleteKeyHint,
              onChanged: (_) => setState(() {}),
              onSubmit: _delete,
            ),
          ],
        ),
        secondaryAction: (
          label: l10n.cancel,
          onPressed: () => setState(() {
            _step = _KeyStep.key;
            _typed.clear();
          }),
        ),
        primaryKey: const ValueKey('identity-delete-key-go'),
        primaryAction: (label: l10n.identityDeleteKey, icon: null, onPressed: _typedDelete ? _delete : null),
      );
    }
    final copyPrivate = widget.onCopyPrivate;
    return ZestDialogShell(
      size: ZestModalSize.compact,
      tone: ZestDialogTone.neutral,
      icon: LucideIcons.keyRound,
      title: l10n.identitySshKeyTitle,
      body: Container(
        padding: const EdgeInsets.fromLTRB(12, 12, 4, 6),
        decoration: BoxDecoration(
          color: AppColors.v3Background,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(color: AppColors.v3BorderSubtle),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    widget.keyType,
                    style: TextStyle(fontWeight: FontWeight.w600, fontSize: 14, color: AppColors.v3TextPrimary),
                  ),
                  const SizedBox(height: 6),
                  RedactedText(
                    Redactable.fingerprint(widget.fingerprint),
                    style: TextStyle(fontFamily: _kMono, fontSize: 11, color: AppColors.v3TextSecondary),
                  ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            _KeyCopyRow(
              key: const ValueKey('identity-key-copy-public'),
              label: l10n.keysUiPublicKey,
              tooltip: l10n.keysUiCopyPublicKey,
              onCopy: widget.onCopyPublic,
            ),
            if (copyPrivate != null)
              _KeyCopyRow(
                key: const ValueKey('identity-key-copy-private'),
                label: l10n.keysUiPrivateKey,
                tooltip: l10n.identityCopyPrivateKey,
                onCopy: copyPrivate,
              ),
          ],
        ),
      ),
      tertiaryKey: const ValueKey('identity-key-delete'),
      tertiaryDanger: true,
      tertiaryAction: widget.onDelete == null
          ? null
          : (label: l10n.identityDeleteKey, onPressed: () => setState(() => _step = _KeyStep.delete)),
      secondaryKey: const ValueKey('identity-key-change'),
      secondaryAction: setup == null
          ? null
          : (label: l10n.identityChangeKey, onPressed: () => setState(() => _step = _KeyStep.change)),
      primaryKey: const ValueKey('identity-key-done'),
      primaryAction: (label: l10n.done, icon: null, onPressed: () => Navigator.of(context).pop()),
      autofocusPrimary: true,
    );
  }
}

/// A half of the key (public, private) with the icon that copies it.
class _KeyCopyRow extends StatelessWidget {
  const _KeyCopyRow({super.key, required this.label, required this.tooltip, required this.onCopy});

  final String label;
  final String tooltip;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Expanded(
          child: Text(label, style: TextStyle(fontSize: 13, color: AppColors.v3TextSecondary)),
        ),
        IconButton(
          tooltip: tooltip,
          iconSize: 15,
          style: IconButton.styleFrom(
            fixedSize: const Size.square(32),
            minimumSize: const Size.square(32),
            padding: EdgeInsets.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          ),
          color: AppColors.v3TextSecondary,
          icon: const Icon(LucideIcons.copy),
          onPressed: onCopy,
        ),
      ],
    );
  }
}

// ─── Segmented choice pill (auth method) ────────────────────────

/// One equal-width pill in a two-option segmented row, matching the connection
/// editor's protocol chooser. Text-only; ACTIVE = brand fill with panel-dark
/// text, otherwise a raised surface with a subtle border.
class _ChoicePill extends StatelessWidget {
  const _ChoicePill({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The app's pressable: pressed anywhere in a finger's 48 where the app is
    // touch sized (the pill was 36 high, all of it the target), reached with
    // Tab, and said once as a button with its state (its name was said twice).
    return ZestPressable(
      onTap: onTap,
      semanticLabel: label,
      selected: selected,
      excludeChildSemantics: true,
      borderRadius: 7,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 2),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: selected ? ZestTokens.brand : ZestTokens.surfaceRaisedAlt,
          borderRadius: BorderRadius.circular(7),
          border: Border.all(
            color: selected ? Colors.transparent : ZestTokens.borderStrong,
            width: 0.5,
          ),
        ),
        child: Text(
          label,
          maxLines: 1,
          softWrap: false,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w500,
            color:
                selected ? ZestTokens.onBrand : ZestTokens.textSecondary,
          ),
        ),
      ),
    );
  }
}

// ─── Toggle row (unattended) ────────────────────────────────────

/// A 13px label + a 32x18 pill switch, with an optional note below - matching
/// the connection editor's `.toggle-row`.
class _ToggleRow extends StatelessWidget {
  const _ToggleRow({
    required this.label,
    required this.value,
    required this.onChanged,
    this.note,
  });

  final String label;
  final bool value;
  final ValueChanged<bool> onChanged;
  final String? note;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        GestureDetector(
          onTap: () => onChanged(!value),
          behavior: HitTestBehavior.opaque,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 7),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                        fontSize: 13, color: ZestTokens.textSecondary),
                  ),
                ),
                const SizedBox(width: 10),
                _Switch(value: value),
              ],
            ),
          ),
        ),
        if (note != null && note!.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(
              note!,
              style: TextStyle(
                fontSize: 11,
                color: ZestTokens.textMuted,
                height: 1.5,
              ),
            ),
          ),
      ],
    );
  }
}

/// The 32x18 pill switch. Off: strong-border track + tertiary knob. On: brand
/// track + panel-dark knob.
class _Switch extends StatelessWidget {
  const _Switch({required this.value});
  final bool value;
  @override
  Widget build(BuildContext context) {
    return AnimatedContainer(
      duration: const Duration(milliseconds: 130),
      width: 32,
      height: 18,
      padding: const EdgeInsets.symmetric(horizontal: 2),
      alignment: value ? Alignment.centerRight : Alignment.centerLeft,
      decoration: BoxDecoration(
        // As the app's switch (ZestSwitch) draws itself.
        color: value ? ZestTokens.brand : ZestTokens.surfaceSunken,
        borderRadius: BorderRadius.circular(9),
        border: Border.all(color: value ? ZestTokens.brand : ZestTokens.border),
      ),
      child: Container(
        width: 12,
        height: 12,
        decoration: BoxDecoration(
          color: value ? Colors.white : ZestTokens.textTertiary,
          shape: BoxShape.circle,
        ),
      ),
    );
  }
}

// ─── SSH Key action button ──────────────────────────────────────

class _KeyActionButton extends StatelessWidget {
  final bool hasKey;
  final VoidCallback onTap;

  const _KeyActionButton({
    required this.hasKey,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(
                  hasKey ? LucideIcons.keyRound : LucideIcons.plusCircle,
                  color: AppColors.accentInk,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    hasKey ? l10n.identityManageKey : l10n.identitySetupKey,
                    style: TextStyle(
                      fontWeight: FontWeight.w600,
                      fontSize: 14,
                      color: ZestTokens.textPrimary,
                    ),
                  ),
                ),
                Icon(LucideIcons.chevronRight,
                    color: ZestTokens.textTertiary),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ─── Key option card (3 options for no-key state) ───────────────────

class _KeyOptionCard extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final VoidCallback onTap;

  const _KeyOptionCard({
    super.key,
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: ZestTokens.surfaceRaised,
        borderRadius: BorderRadius.circular(ZestSizing.fieldRadius),
        border: Border.all(color: ZestTokens.border, width: 0.5),
      ),
      clipBehavior: Clip.antiAlias,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Icon(icon, color: AppColors.accentInk, size: 22),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: TextStyle(
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                          color: ZestTokens.textPrimary,
                        ),
                      ),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: ZestTokens.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(LucideIcons.chevronRight,
                    color: ZestTokens.textTertiary, size: 20),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ── Key format & strength enums ─────────────────────────────────

enum _KeyFormat { ed25519, rsa, ecdsa }

enum _KeyStrength { rsa2048, rsa4096, ecdsaP256, ecdsaP384, ecdsaP521 }

// ── Assign to Connections Panel ─────────────────────────────────

/// Shows all connections with checkboxes to bulk-assign this identity.
///
/// Connections already using this identity are pre-checked. Toggling a
/// checkbox immediately updates the connection's identityId in the database.
class _AssignToConnectionsPanel extends ConsumerStatefulWidget {
  final String identityId;

  const _AssignToConnectionsPanel({required this.identityId});

  @override
  ConsumerState<_AssignToConnectionsPanel> createState() =>
      _AssignToConnectionsPanelState();
}

class _AssignToConnectionsPanelState
    extends ConsumerState<_AssignToConnectionsPanel> {
  /// Tracks in-flight updates to show loading indicators per-connection.
  final Set<String> _updating = {};

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    final connectionsAsync = ref.watch(connectionsWithDetailsProvider);
    // Watched so the rows re-mask live when recording mode (or its level)
    // toggles; the row builder runs outside this build and uses `.display`.
    ref.watch(recordingModeProvider);
    ref.watch(recordingRedactLevelProvider);

    return connectionsAsync.when(
      loading: () => const Padding(
        padding: EdgeInsets.all(16),
        child: Center(child: CircularProgressIndicator(strokeWidth: 2)),
      ),
      error: (_, _) => Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          l10n.identityEditCouldNotLoadConnections,
          style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
        ),
      ),
      data: (connections) {
        if (connections.isEmpty) {
          return Padding(
            padding: const EdgeInsets.all(12),
            child: Text(
              AppLocalizations.of(context)!.identityNoConnectionsToAssign,
              style: TextStyle(
                  color: AppColors.textSecondary, fontSize: 13),
            ),
          );
        }

        // Sort: assigned first, then alphabetically
        final sorted = List.of(connections);
        sorted.sort((a, b) {
          final aAssigned = a.connection.identityId == widget.identityId;
          final bAssigned = b.connection.identityId == widget.identityId;
          if (aAssigned != bAssigned) return aAssigned ? -1 : 1;
          return a.connection.label.compareTo(b.connection.label);
        });

        final assignedCount = sorted
            .where((c) => c.connection.identityId == widget.identityId)
            .length;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Quick summary
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              child: Text(
                l10n.identityEditConnectionsUsingSummary(
                    assignedCount, sorted.length),
                style: TextStyle(
                  color: AppColors.textSecondary,
                  fontSize: 12,
                ),
              ),
            ),

            // Select all / Deselect all
            Row(
              children: [
                TextButton(
                  onPressed: assignedCount == sorted.length
                      ? null
                      : () => _bulkAssign(sorted, true),
                  child: Text(l10n.identityEditSelectAll,
                      style: const TextStyle(fontSize: 12)),
                ),
                TextButton(
                  onPressed:
                      assignedCount == 0 ? null : () => _bulkAssign(sorted, false),
                  child: Text(l10n.identityEditDeselectAll,
                      style: const TextStyle(fontSize: 12)),
                ),
              ],
            ),

            // Connection list
            Container(
              decoration: BoxDecoration(
                color: AppColors.surfaceLight,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: AppColors.divider),
              ),
              constraints: const BoxConstraints(maxHeight: 280),
              child: ListView.separated(
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                itemCount: sorted.length,
                separatorBuilder: (_, _) => Divider(
                  height: 1,
                  color: AppColors.divider,
                ),
                itemBuilder: (context, index) {
                  final conn = sorted[index].connection;
                  final isAssigned =
                      conn.identityId == widget.identityId;
                  final isUpdating = _updating.contains(conn.id);
                  final identityName = sorted[index].identity?.label;
                  final hasOtherIdentity = conn.identityId != null &&
                      conn.identityId != widget.identityId;
                  // The host label, its address and the other identity's name
                  // are identifiers (the port is not): masked while recording.
                  final endpoint =
                      '${Redactable.address(conn.host).display}:${conn.port}';
                  final otherIdentity = identityName == null
                      ? l10n.identityEditOtherIdentity
                      : Redactable.keyName(identityName).display;

                  return CheckboxListTile(
                    value: isAssigned,
                    onChanged: isUpdating
                        ? null
                        : (v) => _toggleConnection(conn.id, v == true),
                    activeColor: AppColors.brandOrange,
                    dense: true,
                    title: conn.label.isNotEmpty
                        ? RedactedText(
                            Redactable.host(conn.label),
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          )
                        : Text(
                            endpoint,
                            style: const TextStyle(
                                fontSize: 13, fontWeight: FontWeight.w500),
                            overflow: TextOverflow.ellipsis,
                          ),
                    subtitle: Text(
                      hasOtherIdentity ? '$endpoint · $otherIdentity' : endpoint,
                      style: TextStyle(
                        fontFamily: 'JetBrainsMono',
                        fontSize: 11,
                        color: AppColors.textSecondary,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    secondary: isUpdating
                        ? const SizedBox(
                            width: 20,
                            height: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        // A host's own icon, not the terminal glyph every row
                        // had.
                        : HostGlyph(host: conn, size: 24),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _toggleConnection(String connectionId, bool assign) async {
    final l10n = AppLocalizations.of(context)!;
    setState(() => _updating.add(connectionId));
    try {
      final crud = ref.read(connectionCrudProvider);
      if (assign) {
        await crud.update(id: connectionId, identityId: widget.identityId);
      } else {
        await crud.update(
            id: connectionId, identityId: null, clearIdentityId: true);
      }
    } catch (e) {
      if (mounted) {
        showTopSnackBar(context, l10n.identityEditHostNotChanged, isError: true, details: '$e');
      }
    } finally {
      if (mounted) setState(() => _updating.remove(connectionId));
    }
  }

  Future<void> _bulkAssign(
      List<ConnectionWithDetails> connections, bool assign) async {
    final crud = ref.read(connectionCrudProvider);
    for (final c in connections) {
      final conn = c.connection;
      final isAssigned = conn.identityId == widget.identityId;
      if (assign && !isAssigned) {
        await crud.update(id: conn.id, identityId: widget.identityId);
      } else if (!assign && isAssigned) {
        await crud.update(id: conn.id, identityId: null, clearIdentityId: true);
      }
    }
  }
}
