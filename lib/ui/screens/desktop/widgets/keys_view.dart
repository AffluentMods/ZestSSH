import 'dart:async';

import 'package:flutter/material.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart' show ImportKind;
import 'package:zestssh/features/cloud_import/ui/import_file.dart' show ImportFile, readImportFile, readKeyFileToImport;
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/features/keys/key_action_dialogs.dart';
import 'package:zestssh/features/keys/key_agent.dart' show canAddToSystemAgent, systemAgentProvider;
import 'package:zestssh/features/keys/key_passphrase.dart';
import 'package:zestssh/features/keys/replace_key_view.dart';
import 'package:zestssh/services/identity_secret_store.dart' show IdentitySecret;
import 'package:zestssh/features/password_managers/widgets/password_manager_dialogs.dart';
import 'package:zestssh/features/password_managers/widgets/move_password_dialog.dart';
import 'package:zestssh/features/password_managers/password_managers.dart';
import 'package:zestssh/features/password_managers/password_manager_ref.dart';
import 'package:zestssh/features/orchards/activity/activity_notes.dart';
import 'package:zestssh/features/orchards/certs/crate_authorities.dart';
import 'package:zestssh/features/orchards/guardrails.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace, TransferKinds, TransferMode;
import 'package:zestssh/features/orchards/move/move_copy_dialog.dart' show defaultSavePlace, savePlaces, showMoveCopyDialog, transferOffer;
import 'package:zestssh/features/orchards/move/move_copy_menu.dart';
import 'package:zestssh/features/orchards/move/save_in_field.dart';
import 'package:zestssh/features/orchards/orchard_providers.dart';
import 'package:zestssh/features/orchards/orchard_service.dart' show ActivityKind;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart';
import 'package:zestssh/features/orchards/widgets/orchard_ui.dart';
import 'package:zestssh/features/run/install_key_view.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/screens/model/rdp_offered.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/theme/zest_tokens.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_controller.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_detail_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_inspector_pane.dart';
import 'package:zestssh/ui/screens/desktop/widgets/keys_list_pane.dart';
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart' show KeySetupDialog;
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/ui/widgets/app_lock_offer.dart';
import 'package:zestssh/ui/widgets/desktop_drop_target.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_master_detail.dart';
import 'package:zestssh/utils/platform_utils.dart' show isDesktopPlatform;

/// Sentinel selection id used while composing a brand-new identity (before it
/// has a real id).
const String _kNewSelection = '__new__';

/// The key editor's unsaved edits while the Keys page is away ([EditDrafts]),
/// by the key's id (or the new key's): what [KeyEditDraft] holds, and nothing
/// secret.
final keyDraftsProvider = editDraftsProvider<KeyEditDraft>();

/// The Keys page on a computer, as the design
/// draws it: [KeysListPane] (the page's line and the table of every sign-in)
/// and, once a row is picked, its details beside it: [KeysInspectorPane],
/// which shows only what is public about it, and, behind its Edit, the
/// editor [KeysDetailPane] (kept as it was),
/// which is where a key's private details are loaded.
/// With nothing picked the list has the whole width. In a narrow window the
/// details open as a page of their own. A key file dropped on the page opens
/// in the new key's editor (4.0).
///
/// The screen owns the selection, the dirty guard, and the identity CRUD and
/// secure-storage I/O the [KeyEditController] deliberately avoids.
class KeysView extends ConsumerStatefulWidget {
  const KeysView({super.key});

  @override
  ConsumerState<KeysView> createState() => _KeysViewState();
}

class _KeysViewState extends ConsumerState<KeysView> with KeepsEditDrafts<KeysView, KeyEditDraft> {
  late final KeyEditController _controller;

  /// Edits kept as the page went, for a saved key whose editor is opening
  /// again (its secrets are being read); put over it once it is open.
  KeyEditDraft? _reopening;

  /// null = nothing open; [_kNewSelection] = composing a new identity; else the
  /// identity id.
  String? _selectedId;

  /// The editor is open (else the details).
  bool _editing = false;

  /// Where a new key is saved ("Save in", 3.4); null: where new items of the
  /// space on screen go.
  SavePlace? _saveIn;

  /// Bumped with every change of what the pane shows, for the narrow
  /// window's page of its own.
  final ValueNotifier<int> _paneTick = ValueNotifier<int>(0);

  /// The narrow window's page, while it is open.
  BuildContext? _routeContext;

  @override
  void initState() {
    super.initState();
    _controller = KeyEditController();
    // Unsaved edits kept as the page went (a terminal was shown in its
    // place): the same editor opens again, with them, as unsaved. A change
    // of profile builds the drafts anew, empty, and the form open here goes.
    final kept = takeEditDraft(keyDraftsProvider, onRenewed: () {
      _reopening = null;
      _saveIn = null;
      _dropDraft();
      _closePane();
    });
    final original = kept?.original;
    if (kept != null && original == null) {
      _controller.bindNew(kept.authMethod);
      _controller.applyKept(kept);
      _saveIn = kept.saveIn;
      _selectedId = _kNewSelection;
      _editing = true;
    } else if (kept != null && original != null) {
      // A saved key's editor opens as Edit opens it, its secrets read again,
      // and the edits are put over it.
      _reopening = kept;
      _selectedId = original.id;
      WidgetsBinding.instance.addPostFrameCallback((_) => unawaited(_reopen(kept, original)));
    }
    _controller.addListener(_onControllerChanged);
  }

  /// Opens the editor of [original] again, with the edits [kept] put over it.
  Future<void> _reopen(KeyEditDraft kept, Identity original) async {
    if (!mounted || !identical(_reopening, kept)) return;
    await _edit(original);
    if (!mounted || !identical(_reopening, kept)) return;
    _reopening = null;
    if (_editing && _controller.original?.id == original.id) _controller.applyKept(kept);
  }

  void _onControllerChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller.removeListener(_onControllerChanged);
    // Going with unsaved edits (the shell shows a terminal in this page's
    // place): what was changed, but for the secrets, is kept in memory for
    // when the page comes back.
    final kept = _reopening ?? (_editing && _controller.isDirty ? _controller.snapshot(saveIn: _saveIn) : null);
    if (kept != null) keepEditDraft(kept.original?.id ?? _kNewSelection, kept);
    _controller.dispose();
    _paneTick.dispose();
    super.dispose();
  }

  Identity? _findIdentity(String id) {
    final identities = ref.read(identitiesProvider).valueOrNull ?? const [];
    for (final i in identities) {
      if (i.id == id) return i;
    }
    return null;
  }

  void _setPane(String? id, {required bool editing}) {
    if (!mounted) return;
    if (_reopening?.original?.id != id) _reopening = null;
    setState(() {
      _selectedId = id;
      _editing = editing;
    });
    _paneTick.value++;
  }

  /// Leaves the editor's draft, with the secrets it loaded.
  void _dropDraft() => _controller.clear();

  /// Whether the editor may be left: nothing changed, or the person said
  /// what to do with the change.
  Future<bool> _mayLeaveEditor([BuildContext? from]) async {
    if (!_editing) return true;
    return _controller.confirmDiscardIfDirty(from ?? context, onSave: _save);
  }

  // ── Selection / creation (all run the discard guard first) ─────────

  Future<void> _select(String id, {required bool narrow}) async {
    if (_selectedId == id && !_editing) {
      if (narrow) await _pushPaneRoute();
      return;
    }
    if (!await _mayLeaveEditor() || !mounted) return;
    if (_findIdentity(id) == null) return;
    _dropDraft();
    _setPane(id, editing: false);
    if (narrow && _routeContext == null) await _pushPaneRoute();
  }

  /// Opens the editor of the selected key: its secrets are loaded here and
  /// only here (the details beside the list show what is public).
  Future<void> _edit([Identity? known]) async {
    final id = _selectedId;
    if (id == null || id == _kNewSelection) return;
    final identity = _findIdentity(id) ?? (known?.id == id ? known : null);
    if (identity == null) return;
    // Load the secret material the row does not carry: password for password
    // identities, private key PEM for key identities. Certificate / agent
    // material is not editable here.
    final crud = ref.read(identityCrudProvider);
    // A team key at Connect keeps its secrets where they are: used to
    // connect, never loaded here (3.0).
    final reveal = await mayRevealKeyNow(ref, id);
    // A vault that asks again: loaded once the person confirms.
    final ask = reveal && await revealAsksAgainNow(ref, id);
    String? password;
    String? privateKey;
    // A password is shown where it is in use: a password key's own, or one
    // tried after a key (3.0, accounts per host); one left from before an
    // identity became a key is not.
    if (reveal && !ask && passwordInUseBy(identity)) {
      password = await crud.getPassword(id);
    }
    if (reveal && !ask && identity.authMethod == AuthMethod.publicKey.name) {
      privateKey = await crud.getPrivateKey(id);
    }
    if (!mounted || _selectedId != id) return;
    // Whether the key has a passphrase, kept on the device now that it was
    // read, for its details to show without reading it.
    if (privateKey != null) unawaited(_rememberPassphraseState(id, privateKey));
    // Its secrets opened on screen: a note while the team records
    // activity.
    if (password != null || privateKey != null) {
      unawaited(noteScreenActivity(ref, ActivityKind.reveal, itemKind: 'key', itemKey: id, name: identity.label));
    }
    // A team certificate or a password manager's key holds
    // nothing secret here.
    final nothingHidden = identity.authMethod == AuthMethod.teamCertificate.name ||
        identity.authMethod == AuthMethod.passwordManager.name;
    _controller.bind(identity,
        password: password,
        privateKeyPem: privateKey,
        secretsHidden: !nothingHidden && (!reveal || ask),
        askAgain: !nothingHidden && ask);
    _setPane(id, editing: true);
  }

  /// Keeps whether the key [id] ([pem]) has a passphrase, and has its
  /// details show it.
  Future<void> _rememberPassphraseState(String id, String? pem) async {
    await ref.read(keyPassphraseFlagsProvider).rememberOf(id, pem);
    if (mounted) ref.invalidate(keyPassphraseStatesProvider);
  }

  /// Confirms it is them, then shows the selected key's secrets.
  Future<void> _showSecrets() async {
    final id = _controller.original?.id;
    if (id == null || !await confirmItIsYou(context, ref) || !mounted) return;
    final crud = ref.read(identityCrudProvider);
    final method = _controller.authMethod;
    final original = _controller.original;
    final password = original != null && passwordInUseBy(original) ? await crud.getPassword(id) : null;
    final privateKey = method == AuthMethod.publicKey ? await crud.getPrivateKey(id) : null;
    if (!mounted || _controller.original?.id != id) return;
    _controller.showSecrets(password: password, privateKeyPem: privateKey);
    unawaited(noteScreenActivity(ref, ActivityKind.reveal,
        itemKind: 'key', itemKey: id, name: _controller.original?.label));
  }

  /// Moves the selected key's saved password into a password manager,
  /// then shows the key as it is now: fetching from there, nothing kept.
  Future<void> _moveToManager() async {
    final l10n = AppLocalizations.of(context)!;
    final proceed = await _mayLeaveEditor();
    final id = _selectedId;
    final identity = id == null || id == _kNewSelection ? null : _findIdentity(id);
    if (!proceed || identity == null || !mounted) return;
    final moved = await showMovePasswordToManager(context, ref, identity);
    if (moved == null || !mounted) return;
    if (_editing) {
      _controller.bind(moved, password: null, privateKeyPem: null, secretsHidden: false, askAgain: false);
    }
    setState(() {});
    _paneTick.value++;
    final name = passwordManagerName(PasswordRef.decode(moved.passwordRef)?.kind ?? PasswordManagerKind.onePassword);
    showTopSnackBar(context, l10n.pmMoved(name), isSuccess: true);
  }

  /// Only the person's own keys move out, where the tools run.
  bool get _canMoveToManager => PasswordManagers.supported && ref.read(activeSpaceProvider) is TreeSpace;

  Future<void> _createNew(AuthMethod method, {required bool narrow}) async {
    if (!await _mayLeaveEditor() || !mounted) return;
    _controller.bindNew(method);
    _setPane(_kNewSelection, editing: true);
    if (narrow && _routeContext == null) await _pushPaneRoute();
  }

  /// The page with nothing saved, Import a key file (4.0): the new key's
  /// editor, as New key's Import or paste key opens it, with its key setup
  /// open at Import (Choose key file, Paste a tab away). Cancelled there, the
  /// editor stays, as it is from New key.
  Future<void> _importKeyFile({required bool narrow}) async {
    if (!await _mayLeaveEditor() || !mounted) return;
    _controller.bindNew(AuthMethod.publicKey);
    _setPane(_kNewSelection, editing: true);
    if (narrow && _routeContext == null) unawaited(_pushPaneRoute());
    final result = await KeySetupDialog.show(context, ref, initialTab: 2);
    if (result == null || !mounted || _selectedId != _kNewSelection || !_controller.isCreating) return;
    _controller.setKeyMaterial(
      privateKeyPem: result.privatePem,
      fingerprint: result.fingerprint,
      keyType: result.keyType,
      passphrase: result.passphrase,
    );
  }

  /// Files dropped on the page (4.0): a private key among them is read as
  /// Import a file reads one (its passphrase asked for where it has one) and
  /// opened in the new key's editor, named after its file. A public key
  /// dropped with it is its other half, and is let be. Anything else is said
  /// and nothing is added: a public key alone, more than one private key, or
  /// what is no key.
  Future<void> _keyFilesDropped(List<String> paths, {required bool narrow}) async {
    final l10n = AppLocalizations.of(context)!;
    // What each file is, as Import a file tells it: nothing of a key is kept.
    final found = <ImportFile>[];
    for (final path in paths) {
      try {
        found.add(await readImportFile(path, rdp: ref.read(rdpOfferedProvider)));
      } catch (_) {
        found.add(ImportFile(name: path, path: path, kind: ImportKind.unknown));
      }
    }
    if (!mounted) return;
    final keys = [for (final f in found) if (f.kind == ImportKind.privateKey) f];
    if (keys.length > 1) {
      showTopSnackBar(context, l10n.keysDropOneAtATime, isError: true);
      return;
    }
    if (keys.isEmpty) {
      final public = found.any((f) => f.kind == ImportKind.publicKey);
      showTopSnackBar(context, public ? l10n.keysDropPublicKey : l10n.keyImportNotAKey, isError: true);
      return;
    }
    if (!await _mayLeaveEditor() || !mounted) return;
    final read = await readKeyFileToImport(context, keys.single.path!);
    if (read == null || !mounted) return;
    _controller.bindNew(AuthMethod.publicKey);
    // Named before the key is put in: its public line carries the name.
    _controller.nameController.text = read.name;
    _controller.setKeyMaterial(
      privateKeyPem: read.key.privatePem,
      fingerprint: read.key.fingerprint,
      keyType: read.key.keyType,
      passphrase: read.passphrase,
    );
    _setPane(_kNewSelection, editing: true);
    if (narrow && _routeContext == null) unawaited(_pushPaneRoute());
  }

  /// The editor's close and Cancel: back to the key's details, or, for a
  /// key not saved yet, nothing open.
  Future<void> _closeEditor() async {
    if (!await _mayLeaveEditor(_routeContext) || !mounted) return;
    final creating = _controller.isCreating || _selectedId == _kNewSelection;
    _dropDraft();
    if (creating) {
      _closePane();
    } else {
      _setPane(_selectedId, editing: false);
    }
  }

  /// Closes the pane (the details' close): the list has the whole width.
  void _closePane() {
    _setPane(null, editing: false);
    final route = _routeContext;
    if (route != null && route.mounted) Navigator.of(route).maybePop();
  }

  // ── Persistence ─────────────────────────────────────────────────────

  Future<bool> _save() async {
    final l10n = AppLocalizations.of(context)!;
    if (_selectedId == null) return false;
    // Hidden secrets and vaults this account may not edit: nothing to save.
    if (_controller.secretsHidden) return false;
    if (!_controller.isCreating && !mayChangeItem(ref, 'key', _selectedId!, watch: false)) return false;

    final name = _controller.trimmedName;
    if (name == null) {
      showTopSnackBar(context, l10n.zestKeysNameRequired, isError: true);
      return false;
    }
    // Username carries a min-length-1 CHECK - never persist an empty one.
    final username = _controller.trimmedUsername;
    if (username == null) {
      showTopSnackBar(context, l10n.zestKeysUsernameRequired, isError: true);
      return false;
    }
    final crud = ref.read(identityCrudProvider);
    final creating = _controller.isCreating;
    final method = _controller.authMethod;
    // A password manager's key needs the item its password is in.
    if (method == AuthMethod.passwordManager && _controller.passwordRef == null) {
      showTopSnackBar(context, l10n.pmRefRequired, isError: true);
      return false;
    }
    // Only password / SSH-key identities let us write secret material; a
    // certificate or agent identity is edited name/username/color-only, so its
    // key material must be left untouched.
    final editable = _controller.canEditAuthMaterial;
    // A key's own password (3.0, accounts per host), as the controller says
    // a save leaves it: changed only where the field was.
    final kept = _controller.keyPasswordSave;
    // Whether the key's material is another than the one opened (Replace
    // key): its fingerprint changed.
    final replacedMaterial = !creating && _controller.publicKeyFingerprint != _controller.original?.publicKeyFingerprint;

    try {
      if (creating) {
        // Where "Save in" says (3.4): here, as before, or any other place.
        final place = _saveIn ?? defaultSavePlace(ref);
        final here = place == defaultSavePlace(ref);
        final savedId = await saveNewItemIn(context, ref, place: place, kind: TransferKinds.key, write: () => crud.create(
          label: name,
          username: username,
          authMethod: method.name,
          keyType: _controller.keyType,
          publicKeyFingerprint: _controller.publicKeyFingerprint,
          publicKeyData: _controller.publicKeyData,
          // Only write a password when one was actually entered - an empty
          // field must NOT persist an empty secret (and on update must never
          // overwrite a real stored password; see the update branch).
          password: method == AuthMethod.password && _controller.passwordController.text.isNotEmpty
              ? _controller.passwordController.text
              : kept?.write,
          passwordAfterKey: kept?.afterKey ?? false,
          privateKeyPem: method == AuthMethod.publicKey ? _controller.privateKeyPem : null,
          keyPassphrase: method == AuthMethod.publicKey ? _controller.keyPassphrase : null,
          colorIndex: _controller.colorIndex,
          colorValue: _controller.colorValue,
          allowUnattended: _controller.allowUnattended,
          passwordRef: method == AuthMethod.passwordManager ? _controller.passwordRef : null,
        ));
        if (savedId == null) return false;
        if (!here) {
          // Saved in another space: nothing of it is open here.
          if (!mounted) return true;
          final saved = savePlaces(ref, l10n, watch: false).where((p) => p.place == place).firstOrNull;
          _saveIn = null;
          _dropDraft();
          _closePane();
          showTopSnackBar(context, l10n.saveInSavedToast(Redactable.freeText(saved?.title ?? '').display), isSuccess: true);
          return true;
        }
        _saveIn = null;
        final newId = savedId;
        if (method == AuthMethod.publicKey) unawaited(_rememberPassphraseState(newId, _controller.privateKeyPem));
        _controller.markSaved(_controller.buildIdentity(newId));
        _setPane(newId, editing: true);
        // The first private key or password saved here: the app lock is
        // offered, once, as the key editor on a phone offers it (4.0, the
        // computer's Keys page too).
        if ((method == AuthMethod.publicKey || method == AuthMethod.password) && mounted) {
          unawaited(maybeOfferAppLock(context, ref));
        }
      } else {
        final id = _selectedId!;
        await crud.update(
          id: id,
          label: name,
          username: username,
          authMethod: method.name,
          keyType: _controller.keyType,
          publicKeyFingerprint: _controller.publicKeyFingerprint,
          publicKeyData: _controller.publicKeyData,
          // Never overwrite a REAL stored password with an empty field (e.g. a
          // failed secure-storage load, or the user clearing it): empty → null
          // → update() preserves the existing secret. Changing it means typing
          // a new non-empty value.
          password: editable && method == AuthMethod.password && _controller.passwordController.text.isNotEmpty
              ? _controller.passwordController.text
              : kept?.write,
          passwordAfterKey: kept == null ? false : kept.afterKey,
          clearPassword: kept?.clear ?? false,
          privateKeyPem: editable && method == AuthMethod.publicKey ? _controller.privateKeyPem : null,
          keyPassphrase: editable && method == AuthMethod.publicKey ? _controller.keyPassphrase : null,
          colorIndex: _controller.colorIndex,
          colorValue: _controller.colorValue,
          clearColorValue: _controller.colorValue == null,
          allowUnattended: _controller.allowUnattended,
          passwordRef: editable && method == AuthMethod.passwordManager ? _controller.passwordRef : null,
          clearPasswordRef: editable && method != AuthMethod.passwordManager,
        );
        // A team certificate keeps nothing secret, nor does a key whose
        // password stays in a password manager.
        if (method == AuthMethod.teamCertificate || method == AuthMethod.passwordManager) {
          await crud.clearSecrets(id);
        }
        if (editable && method == AuthMethod.publicKey && _controller.privateKeyPem != null) {
          // A new key put in this one's place (Replace key) with no
          // passphrase of its own: the old key's kept passphrase goes. An
          // open key with a passphrase kept beside it does not open, and
          // every sign-in with it failed as a key that cannot be read.
          if (replacedMaterial && _controller.keyPassphrase == null && pemIsSealed(_controller.privateKeyPem) == false) {
            await ref.read(identitySecretsProvider).write(id, IdentitySecret.passphrase, null);
          }
          unawaited(_rememberPassphraseState(id, _controller.privateKeyPem));
        }
        _controller.markSaved(_controller.buildIdentity(id));
        if (mounted) setState(() {});
      }
    } catch (e) {
      if (mounted) {
        // In the app's language, with what was thrown to copy.
        final refused = isOrchardWriteRefused(e);
        showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.zestKeysNotSaved,
            isError: true, details: refused ? null : '$e');
      }
      return false;
    }
    return true;
  }

  Future<void> _delete() async {
    final id = _selectedId;
    final identity = (id == null || id == _kNewSelection) ? null : _findIdentity(id);
    if (identity == null) return;
    if (!mayChangeItem(ref, 'key', identity.id, delete: true, watch: false)) return;
    // A certificate authority's key: its vault signs nothing without
    // it, so it is said first.
    final authority = authorityOfKey(ref, identity);
    if (authority != null) {
      final l10n = AppLocalizations.of(context)!;
      final crate = ref.read(activeOrchardProvider).valueOrNull?.crates.where((c) => c.id == authority.crateId).firstOrNull;
      final sure = await ZestConfirmDialog.show(
        context,
        tone: ZestDialogTone.destructive,
        title: l10n.certAuthorityKeyDeleteTitle,
        body: l10n.certAuthorityKeyDeleteBody(crate == null ? l10n.crateUnnamed : crateDisplayName(crate, l10n)),
        confirmLabel: l10n.certAuthorityKeyDeleteConfirm,
      );
      if (sure != true || !mounted) return;
    }
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    final confirmed = await ZestConfirmDialog.show(
      context,
      tone: ZestDialogTone.destructive,
      // The dialog names the key: masked while recording.
      title: l10n.zestKeysDeleteTitle(Redactable.keyName(identity.label).display),
      body: l10n.zestKeysDeleteBody,
      bullets: [l10n.zestKeysDeleteFallsBack, l10n.zestKeysDeleteFileUntouched],
      confirmLabel: l10n.zestKeysDeleteConfirm,
    );
    if (confirmed != true || !mounted) return;
    try {
      await ref.read(identityCrudProvider).delete(id!);
    } catch (e) {
      if (mounted) {
        final refused = isOrchardWriteRefused(e);
        showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.zestKeysNotDeleted,
            isError: true, details: refused ? null : '$e');
      }
      return;
    }
    // Nothing open, so the deleted identity's now-stale draft can't later
    // prompt a spurious "save?".
    _dropDraft();
    _closePane();
  }

  // ── A row's menu (right-click) ──────────────────────────────────────

  /// Whether a copy of [identity] may be made here: a kind that can be
  /// copied, somewhere the person may add keys, and not the key a vault's
  /// certificates are signed with (a copy of that would leave its vault).
  bool _mayDuplicate(Identity identity) =>
      IdentityCrudNotifier.canDuplicate(identity) &&
      mayAddScreenSpace(ref, watch: false) &&
      authorityOfKey(ref, identity) == null;

  Future<void> _openRowMenu(Identity identity, Offset position, {required bool narrow}) async {
    final duplicate = _mayDuplicate(identity);
    final offer = _transferOffer(identity);
    if (!duplicate && !offer.move && !offer.copy) return; // nothing to offer for this key
    final l10n = AppLocalizations.of(context)!;
    final overlay = Overlay.of(context).context.findRenderObject()! as RenderBox;
    PopupMenuItem<String> item(String value, IconData icon, String label) => PopupMenuItem<String>(
          key: ValueKey('keys-row-menu-$value'),
          value: value,
          height: 36,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(icon, size: 15),
              const SizedBox(width: 10),
              Text(label, style: const TextStyle(fontSize: 13)),
            ],
          ),
        );
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(position & Size.zero, Offset.zero & overlay.size),
      color: ZestTokens.surfaceRaised,
      items: [
        if (duplicate) item('duplicate', LucideIcons.copy, l10n.commonDuplicate),
        if (offer.move) item('move_to', LucideIcons.folderInput, l10n.transferMoveTo),
        if (offer.copy) item('copy_to', LucideIcons.copyPlus, l10n.transferCopyTo),
      ],
    );
    if (!mounted) return;
    switch (picked) {
      case 'duplicate':
        await _duplicate(identity, narrow: narrow);
      case 'move_to':
        await _transfer(identity, TransferMode.move);
      case 'copy_to':
        await _transfer(identity, TransferMode.copy);
    }
  }

  /// What Move to... and Copy to... offer for [identity] (3.4): never for
  /// the key a vault signs certificates with, which belongs to its vault.
  ({bool move, bool copy}) _transferOffer(Identity identity) {
    if (identity.authMethod == AuthMethod.teamCertificate.name || authorityOfKey(ref, identity) != null) {
      return (move: false, copy: false);
    }
    return transferOffer(ref, TransferKinds.key, [identity.id]);
  }

  /// Move to... or Copy to... for [identity]: Personal, or a team's vault.
  Future<void> _transfer(Identity identity, TransferMode mode) async {
    if (!await _mayLeaveEditor() || !mounted) return;
    final result = await showMoveCopyDialog(context, ref, kind: TransferKinds.key, keys: [identity.id], mode: mode);
    // Moved out of this place: nothing of it is open here any more.
    if (result != null && result.done > 0 && mode == TransferMode.move && mounted && _selectedId == identity.id) {
      _dropDraft();
      _closePane();
    }
  }

  /// Makes a copy of [identity] that signs in by itself and opens it in the
  /// editor, so its username (the usual reason for a copy) can be changed at
  /// once.
  Future<void> _duplicate(Identity identity, {required bool narrow}) async {
    final l10n = AppLocalizations.of(context)!;
    // The copy carries what the key signs in with: only for a person who may
    // see that (a team key at Connect keeps its secrets where they are),
    // and after the vault's own question when it asks again.
    if (!await mayRevealKeyNow(ref, identity.id)) {
      if (mounted) showTopSnackBar(context, l10n.orchardWriteNotAllowed, isError: true);
      return;
    }
    if (await revealAsksAgainNow(ref, identity.id)) {
      if (!mounted || !await confirmItIsYou(context, ref)) return;
    }
    if (!mounted) return;
    if (!await _mayLeaveEditor() || !mounted) return;
    final String copyId;
    try {
      copyId = await ref.read(identityCrudProvider).duplicate(identity, label: l10n.homeCopyLabelSuffix(identity.label));
    } catch (e) {
      if (mounted) {
        final refused = isOrchardWriteRefused(e);
        showTopSnackBar(context, refused ? l10n.orchardWriteNotAllowed : l10n.zestKeysNotSaved,
            isError: true, details: refused ? null : '$e');
      }
      return;
    }
    if (!mounted) return;
    showTopSnackBar(context, l10n.homeIdentityDuplicated(Redactable.keyName(identity.label).display), isSuccess: true);
    // The list hears of the copy a moment later.
    for (var i = 0; i < 40 && mounted && _findIdentity(copyId) == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    if (!mounted) return;
    await _select(copyId, narrow: narrow);
    if (mounted && _selectedId == copyId) await _edit();
  }

  // ── Key actions ─────────────────────────────────────────────────────

  /// Rotate: a new key in the selected key's place, made as Replace key makes
  /// one (generated, pasted or imported), kept when the key is saved.
  Future<void> _rotate() async {
    final id = _selectedId;
    if (id == null || _findIdentity(id) == null) return;
    final result = await KeySetupDialog.show(context, ref);
    if (result == null || !mounted || _selectedId != id) return;
    _controller.setKeyMaterial(
      privateKeyPem: result.privatePem,
      fingerprint: result.fingerprint,
      keyType: result.keyType,
      passphrase: result.passphrase,
    );
  }

  /// The details' Replace key: the editor, with the key's setup open.
  Future<void> _replaceKey() async {
    await _edit();
    if (mounted && _editing && !_controller.secretsHidden) await _rotate();
  }

  Future<void> _exportPublic() async {
    final id = _selectedId;
    final identity = id == null ? null : _findIdentity(id);
    if (identity == null) return;
    // Its public line, kept or made from its private key.
    final text = await ref.read(identityCrudProvider).publicLineOf(identity) ?? '';
    if (!mounted) return;
    final l10n = AppLocalizations.of(context)!;
    if (text.isEmpty) {
      showTopSnackBar(context, l10n.zestKeysNoPublicKey, isError: true);
      return;
    }
    // The public key goes to the clipboard: reveal gate (spec 5).
    if (!await confirmRevealWhileRecording(context, ref)) return;
    if (!mounted) return;
    await Clipboard.setData(ClipboardData(text: text));
    if (mounted) showTopSnackBar(context, l10n.identityPublicKeyCopied, isSuccess: true);
  }

  /// Installs the key on screen on hosts (3.0).
  Future<void> _installOnHosts() async {
    final id = _selectedId;
    final identity = id == null ? null : _findIdentity(id);
    if (identity == null) return;
    await showInstallKey(context, identity);
  }

  /// Exports the selected key as OpenSSH files.
  Future<void> _export() async {
    final identity = _selectedId == null ? null : _findIdentity(_selectedId!);
    if (identity == null) return;
    await showKeyExport(context, ref, identity);
  }

  /// Gives the selected key to the computer's SSH agent.
  Future<void> _addToAgent() async {
    final identity = _selectedId == null ? null : _findIdentity(_selectedId!);
    if (identity == null) return;
    await showAddToAgent(context, ref, identity);
  }

  /// Replaces the selected key on every host that signs in with it.
  Future<void> _replaceOnHosts() async {
    final identity = _selectedId == null ? null : _findIdentity(_selectedId!);
    if (identity == null) return;
    await showReplaceKey(context, identity);
  }

  /// Adds, changes or takes off the selected key's passphrase.
  Future<void> _passphrase(KeyPassphraseMode mode) async {
    final identity = _selectedId == null ? null : _findIdentity(_selectedId!);
    if (identity == null) return;
    await showKeyPassphrase(context, ref, identity, mode);
  }

  /// Finds out whether the selected key has a passphrase.
  Future<void> _checkPassphrase() async {
    final identity = _selectedId == null ? null : _findIdentity(_selectedId!);
    if (identity == null) return;
    await checkKeyPassphrase(context, ref, identity);
  }

  void _openHost(Connection host) {
    // "Through to the host": switch the sidebar to the Hosts section where the
    // connection lives. In the narrow layout, also leave the details' page so
    // the switch is visible.
    ref.read(activeSidebarNavProvider.notifier).state = NavSection.hosts;
    final route = _routeContext;
    if (route != null && route.mounted) Navigator.of(route).maybePop();
  }

  // ── The pane ────────────────────────────────────────────────────────

  Widget _pane() {
    final id = _selectedId;
    if (id == null) return const SizedBox.shrink();
    if (_editing) {
      // A saved key's Move or copy (4.0), where Move to... or Copy to...
      // would be offered for it.
      final saved = _controller.isCreating ? null : _findIdentity(id);
      final offer = saved == null ? (move: false, copy: false) : _transferOffer(saved);
      return KeysDetailPane(
        controller: _controller,
        saveIn: SaveInField(value: _saveIn, onChanged: (p) => setState(() => _saveIn = p)),
        headerAction: saved != null && (offer.move || offer.copy)
            ? MoveCopyMenuButton(
                kind: TransferKinds.key,
                itemKey: saved.id,
                iconSize: 18,
                color: ZestTokens.textSecondary,
                hasUnsavedChanges: () => _controller.isDirty,
                // Moved out of this place: nothing of it is open here any more.
                onMoved: () {
                  if (!mounted || _selectedId != saved.id) return;
                  _dropDraft();
                  _closePane();
                },
              )
            : null,
        hasSelection: true,
        onSave: _save,
        onClose: _closeEditor,
        onDelete: _delete,
        onRotate: _rotate,
        onExportPublic: _exportPublic,
        onShowSecrets: _showSecrets,
        onMoveToManager: _canMoveToManager ? _moveToManager : null,
        onInstallOnHosts: _installOnHosts,
        onOpenHost: _openHost,
      );
    }
    final identity = _findIdentity(id);
    final rules = ItemRules.of(ref, 'key');
    final mayChange = identity != null && rules.mayChange(id);
    // A key whose private key the vault holds.
    final vaultKey = identity != null && canAddToSystemAgent(identity);
    return KeysInspectorPane(
      key: ValueKey('keys-inspector-$id'),
      identityId: id,
      onEdit: () => unawaited(_edit()),
      onClose: _closePane,
      onCopyPublicKey: () => unawaited(_exportPublic()),
      onOpenHost: _openHost,
      onInstallOnHosts: () => unawaited(_installOnHosts()),
      onReplaceKey: mayChange && identity.authMethod == AuthMethod.publicKey.name ? () => unawaited(_replaceKey()) : null,
      onDuplicate: identity != null && _mayDuplicate(identity)
          ? () => unawaited(_duplicate(identity, narrow: _routeContext != null))
          : null,
      onMoveTo: identity != null && _transferOffer(identity).move
          ? () => unawaited(_transfer(identity, TransferMode.move))
          : null,
      onCopyTo: identity != null && _transferOffer(identity).copy
          ? () => unawaited(_transfer(identity, TransferMode.copy))
          : null,
      onDelete: identity != null && rules.mayChange(id, delete: true) ? () => unawaited(_delete()) : null,
      onMoveToManager: _canMoveToManager && identity?.authMethod == AuthMethod.password.name
          ? () => unawaited(_moveToManager())
          : null,
      onExport: vaultKey ? () => unawaited(_export()) : null,
      onAddToAgent: vaultKey && ref.watch(systemAgentProvider) != null ? () => unawaited(_addToAgent()) : null,
      onReplaceOnHosts: vaultKey && mayChange ? () => unawaited(_replaceOnHosts()) : null,
      onPassphrase: vaultKey && mayChange ? (mode) => unawaited(_passphrase(mode)) : null,
      onCheckPassphrase: vaultKey ? () => unawaited(_checkPassphrase()) : null,
    );
  }

  /// The details as a page of their own, in a narrow window. It goes when
  /// the pane closes.
  Future<void> _pushPaneRoute() async {
    if (_routeContext != null) return;
    await ZestMasterDetail.pushDetail<void>(
      context,
      Builder(builder: (routeContext) {
        _routeContext = routeContext;
        return ValueListenableBuilder<int>(
          valueListenable: _paneTick,
          builder: (context, _, _) => ListenableBuilder(
            listenable: _controller,
            builder: (context, _) => PopScope<void>(
              canPop: !(_editing && _controller.isDirty),
              onPopInvokedWithResult: (didPop, _) async {
                if (didPop) return;
                if (await _mayLeaveEditor(routeContext) && routeContext.mounted) Navigator.of(routeContext).pop();
              },
              child: _selectedId == null ? const SizedBox.shrink() : _pane(),
            ),
          ),
        );
      }),
    );
    _routeContext = null;
    // The page was left by its back button: nothing open in the list.
    if (mounted && _selectedId != null) {
      _dropDraft();
      _setPane(null, editing: false);
    }
  }

  // ── Build ────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final identities = ref.watch(identitiesProvider).valueOrNull ?? const [];
    _reconcileSelection(identities);
    final l10n = AppLocalizations.of(context)!;

    return ColoredBox(
      color: ZestTokens.surfaceBase,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final narrow = constraints.maxWidth < ZestSizing.singleColumnBreakpoint;
          final list = KeysListPane(
            selectedId: _selectedId,
            onSelect: (id) => _select(id, narrow: narrow),
            onNew: (method) => _createNew(method, narrow: narrow),
            onImportKey: () => unawaited(_importKeyFile(narrow: narrow)),
            takesKeyDrops: isDesktopPlatform,
            onRowMenu: (identity, position) => _openRowMenu(identity, position, narrow: narrow),
            // The selection's Move to..., Copy to... and Delete ask the
            // editor about its changes first (3.4).
            beforeChange: () => _mayLeaveEditor(),
          );
          final page = narrow || _selectedId == null
              ? list
              : Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Expanded(child: FocusTraversalGroup(child: list)),
                    VerticalDivider(width: 1, thickness: 1, color: ZestTokens.border),
                    SizedBox(
                      width: (constraints.maxWidth * 0.34).clamp(440.0, 540.0),
                      child: FocusScope(debugLabel: 'Keys pane', child: _pane()),
                    ),
                  ],
                );
          // A key file dropped anywhere on the page is imported (4.0), with
          // the page lit while one is dragged over it; where this account
          // may not add a key (a team vault), nothing is taken.
          return DesktopDropTarget(
            key: const ValueKey('keys-drop'),
            enabled: mayAddScreenSpace(ref),
            hint: l10n.keysDropHint,
            icon: LucideIcons.keyRound,
            hintOnCard: true,
            onFilesDropped: (paths) => unawaited(_keyFilesDropped(paths, narrow: narrow)),
            child: page,
          );
        },
      ),
    );
  }

  /// Drop the selection if the open identity no longer exists (deleted
  /// elsewhere, e.g. via sync or the mobile editor).
  void _reconcileSelection(List<Identity> identities) {
    final id = _selectedId;
    // Nothing open, or a brand-new identity that has no persisted row yet.
    if (id == null || id == _kNewSelection) return;
    if (identities.any((i) => i.id == id)) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted || _selectedId != id) return;
      // Re-check against the freshest list: a just-created identity may only
      // have streamed in AFTER this frame was scheduled, so don't clear a
      // selection that now exists.
      final latest = ref.read(identitiesProvider).valueOrNull ?? const [];
      if (latest.any((i) => i.id == id)) return;
      _dropDraft();
      _closePane();
    });
  }
}
