import 'package:flutter/widgets.dart';
import 'package:zestssh/features/orchards/move/item_transfer.dart' show SavePlace;
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/identity/identity_kind.dart';
import 'package:zestssh/features/keys/key_agent.dart' show keyIsInSystemAgent;
import 'package:zestssh/models/enums.dart';
import 'package:zestssh/models/redactable.dart' show fingerprintAsShown;
import 'package:zestssh/providers/identity_providers.dart' show keyPasswordOnSave;
import 'package:zestssh/ui/widgets/zest_detail_scaffold.dart';
import 'package:zestssh/services/key_import_service.dart' show publicKeyLineOf;

// ══════════════════════════════════════════════════════════════════
// Section partitions (single source of truth for the four Keys sections)
// ══════════════════════════════════════════════════════════════════
//
// The Keys screen groups identities into four sections by `authMethod`. These
// pure helpers are the ONE place that mapping lives, so the section badges, the
// header meta count, and the detail pane can never drift apart.

/// SSH KEYS section - software public-key identities.
List<Identity> sshKeysOf(List<Identity> ids) =>
    ids.where((i) => i.authMethod == 'publicKey').toList(growable: false);

/// PASSWORDS section - saved-per-host password identities, and those whose
/// password stays in a password manager (3.0).
List<Identity> passwordsOf(List<Identity> ids) => ids.where(isPasswordIdentity).toList(growable: false);

/// CERTIFICATES section - OpenSSH user certificates signed by a CA, and team
/// certificates (3.0), which were in no section and went missing
/// from the list once saved.
List<Identity> certificatesOf(List<Identity> ids) =>
    ids.where((i) => i.authMethod == 'certificate' || i.authMethod == 'teamCertificate').toList(growable: false);

/// SSH-AGENT KEYS section - hardware-token / agent-backed identities.
List<Identity> agentKeysOf(List<Identity> ids) =>
    ids.where((i) => i.authMethod == 'hardwareToken').toList(growable: false);

/// The header's "keys" number: every key-like identity (SSH keys +
/// certificates + agent keys), i.e. the sum of the three non-password section
/// badges. This is what fixes the double-count bug - passwords were previously
/// counted as keys. Defined as a SUM of the section counts (not "everything
/// that isn't a password") so that [keysMetaKeyCount] + [keysMetaPasswordCount]
/// is guaranteed to equal the sum of the four section badges exactly, even if a
/// stray identity carried an unrecognised authMethod. In the common case (no
/// certificates or agent keys) it equals the SSH KEYS badge.
int keysMetaKeyCount(List<Identity> ids) =>
    sshKeysOf(ids).length +
    certificatesOf(ids).length +
    agentKeysOf(ids).length;

/// The header's "saved passwords" number - the PASSWORDS section badge.
int keysMetaPasswordCount(List<Identity> ids) => passwordsOf(ids).length;

/// How many identities are authorised for unattended (headless) runs. Drives
/// the "unattended" summary chip in the Keys list header.
int keysUnattendedCount(List<Identity> ids) =>
    ids.where((i) => i.allowUnattended).length;

/// True when this identity is backed by an external ssh-agent / hardware token
/// (its private key never reaches us). Covers both the `usesAgent` flag and the
/// `hardwareToken` auth method so an agent-backed cert also counts.
bool isAgentIdentity(Identity id) =>
    id.usesAgent || id.authMethod == 'hardwareToken';

/// True when NO saved connection references this identity - i.e. its used-by
/// count is zero. Drives the amber "Unused" row badge and the "unused" chip.
bool isUnusedIdentity(String id, Map<String, int> usageCounts) =>
    (usageCounts[id] ?? 0) == 0;

/// The set of identity ids that COLLIDE with at least one OTHER identity on
/// either of two axes. EVERY member of a colliding group is returned (not just
/// one), so saving / importing the same thing twice flags ALL copies. The two
/// axes are UNIONED (a duplicate on EITHER counts) and the result is
/// de-duplicated by id:
///
///   * public-key FINGERPRINT - same key material. Empty / null fingerprints
///     never participate: password identities carry none, and their secrets
///     live in secure storage, out of reach of a list build.
///   * user@host + auth TYPE - the visible endpoint line SCOPED BY authMethod.
///     `Identity` has no host column, so the label IS the endpoint key (a
///     saved-password label reads like `root@192.168.20.10`), normalized (trimmed
///     + case-folded). Folding the auth TYPE into the key is what stops the
///     false positives: a saved password and an SSH key that merely SHARE a
///     display name (both 'Alex') can never be the same credential, so they
///     must NOT badge. Two same-named `root@192.168.20.10` saved passwords - which
///     carry no fingerprint and DO share an auth type - still flag. Empty
///     labels are ignored.
Set<String> duplicateIdentityIds(List<Identity> ids) {
  final byFingerprint = <String, List<String>>{};
  final byEndpoint = <String, List<String>>{};
  for (final i in ids) {
    // One key's, kept with base64's padding by an import before 3.0 or
    // without it, is the same key.
    final fp = fingerprintAsShown(i.publicKeyFingerprint?.trim() ?? '');
    if (fp.isNotEmpty) {
      (byFingerprint[fp] ??= <String>[]).add(i.id);
    }
    final endpoint = i.label.trim().toLowerCase();
    if (endpoint.isNotEmpty) {
      // Match key = auth type + user@host. authMethod is a fixed enum token
      // (no spaces), so a single space cleanly separates the two parts. Scoping
      // by authMethod means a key and a password that share a display name land
      // in different buckets and never collide.
      final key = '${i.authMethod} $endpoint';
      (byEndpoint[key] ??= <String>[]).add(i.id);
    }
  }
  final dupes = <String>{};
  for (final group in byFingerprint.values) {
    if (group.length > 1) dupes.addAll(group);
  }
  for (final group in byEndpoint.values) {
    if (group.length > 1) dupes.addAll(group);
  }
  return dupes;
}

/// How many identities are referenced by no connection at all.
int keysUnusedCount(List<Identity> ids, Map<String, int> usageCounts) =>
    ids.where((i) => isUnusedIdentity(i.id, usageCounts)).length;

/// Whether [id] is in the "In agent" filter: backed by an agent, or a key
/// of the vault the computer's SSH agent holds now ([systemAgent], the
/// fingerprints it holds: Add to agent, 3.0).
bool isInAgentFilter(Identity id, [Set<String> systemAgent = const {}]) =>
    isAgentIdentity(id) || keyIsInSystemAgent(id, systemAgent);

/// How many identities are in the "In agent" filter ([isInAgentFilter]).
int keysAgentCount(List<Identity> ids, [Set<String> systemAgent = const {}]) =>
    ids.where((i) => isInAgentFilter(i, systemAgent)).length;

// ══════════════════════════════════════════════════════════════════
// Row rendering helpers (pure)
// ══════════════════════════════════════════════════════════════════

/// A short, display-only fingerprint for dense list rows. The FULL value lives
/// in the detail pane (and is what the copy action puts on the clipboard).
String shortFingerprint(String? fp) {
  if (fp == null || fp.isEmpty) return '-';
  return fp.length > 24 ? '${fp.substring(0, 24)}…' : fp;
}

/// A public key line for one line of a narrow pane: its type, the start of
/// its key and its comment ("ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAA… deploy").
/// The whole line is what Copy puts on the clipboard.
String shortPublicLine(String line) {
  final parts = line.trim().split(RegExp(r'\s+'));
  if (parts.length < 2) return line.trim();
  final key = parts[1];
  final shown = key.length > 24 ? '${key.substring(0, 20)}…' : key;
  return [parts[0], shown, ...parts.skip(2)].join(' ');
}

/// Absolute, sortable-looking timestamp `YYYY-MM-DD HH:MM`: the tooltip over
/// when a key was added or last used, exact to the minute.
String formatDateTimeStamp(DateTime dt) {
  final l = dt.toLocal();
  String two(int n) => n.toString().padLeft(2, '0');
  return '${l.year}-${two(l.month)}-${two(l.day)} '
      '${two(l.hour)}:${two(l.minute)}';
}

// ══════════════════════════════════════════════════════════════════
// Detail-pane edit controller (full identity editor + dirty guard)
// ══════════════════════════════════════════════════════════════════

/// The key editor's unsaved edits, as [KeyEditController.snapshot] takes them
/// while the page is away (a terminal shown in its place), held in memory
/// only. Nothing secret is in it: not the password typed, nor a private key
/// or its passphrase, nor the public half of a key loaded and not saved
/// (which is nothing without its private half). The secrets of a saved key
/// are read again from where they are kept as its editor opens again.
@immutable
class KeyEditDraft {
  const KeyEditDraft({
    required this.original,
    required this.authMethod,
    required this.name,
    required this.username,
    required this.colorIndex,
    required this.colorValue,
    required this.allowUnattended,
    required this.passwordRef,
    required this.saveIn,
  });

  /// The key being edited, as it was opened; null for a new key.
  final Identity? original;
  final AuthMethod authMethod;
  final String name;
  final String username;
  final int colorIndex;
  final int? colorValue;
  final bool allowUnattended;

  /// Where a password manager keeps the password: which item, never the
  /// password itself.
  final String? passwordRef;

  /// Where a new key was to be saved.
  final SavePlace? saveIn;
}

/// Editor state for the 1.7 Keys detail pane.
///
/// A repository-free [ChangeNotifier] mirroring the Networks controller: it owns
/// the whole working identity draft (name, username, auth method, the secret
/// material, and the color label) plus the dirty flag, but performs NO database
/// or secure-storage I/O. The screen loads / saves through
/// `IdentityCrudNotifier` and calls [bind] / [bindNew] / [markSaved]; keeping
/// persistence out of here keeps the dirty-guard invariant unit-testable without
/// a live database.
///
/// The detail pane is the editor for BOTH new and existing identities (the
/// pre-1.7 modal `IdentityEditScreen` is no longer used for the desktop
/// new/edit-identity flow). There is deliberately no Simple / Advanced split for
/// Keys.
class KeyEditController extends ChangeNotifier {
  final TextEditingController nameController = TextEditingController();
  final TextEditingController usernameController = TextEditingController();
  final TextEditingController passwordController = TextEditingController();

  /// The last-saved identity, or null while creating a brand-new one.
  Identity? _original;
  Identity? get original => _original;

  /// True while composing a brand-new (unsaved) identity.
  bool _isCreating = false;
  bool get isCreating => _isCreating;

  /// An Orchard key this account reaches at Connect (3.0): its
  /// password and private key were not loaded, and are not shown.
  bool _secretsHidden = false;
  bool get secretsHidden => _secretsHidden;

  /// The key is in a Crate that asks again before its secrets are shown:
  /// hidden until the person confirms it is them ([showSecrets]).
  bool _askAgain = false;
  bool get askAgain => _askAgain;

  /// The secrets, once the person confirmed it is them: shown, and not a
  /// change to save.
  void showSecrets({String? password, String? privateKeyPem}) {
    _secretsHidden = false;
    _askAgain = false;
    _basePassword = password ?? '';
    this.privateKeyPem = privateKeyPem;
    passwordController.text = password ?? '';
    notifyListeners();
  }

  /// Working, non-text draft fields.
  AuthMethod authMethod = AuthMethod.password;
  int colorIndex = 0;

  /// Custom label colour (ARGB int). Non-null OVERRIDES [colorIndex], letting
  /// the user pick ANY colour. Null falls back to the index behaviour, and an
  /// identity DEFAULTS TO NO COLOUR (colorValue null + colorIndex 0).
  int? colorValue;

  /// Whether this identity is authorised for UNATTENDED (headless) runs. Only
  /// meaningful for a saved identity - the switch lives in the existing-identity
  /// block of the detail pane. Defaults to OFF (opt-in).
  bool allowUnattended = false;

  /// Working key material. On a plain edit these mirror the persisted row;
  /// [keyPassphrase] stays null unless the user loads a fresh key (so a save
  /// never rewrites the stored passphrase - matching the old modal).
  String? privateKeyPem;
  String? keyPassphrase;
  String? publicKeyFingerprint;
  String? keyType;
  String? publicKeyData;

  /// Where a password manager keeps the password (3.0): a valid
  /// reference's stored form, or null while none is set.
  String? passwordRef;

  /// Sets [passwordRef] from the reference editor.
  void setPasswordRef(String? value) {
    passwordRef = value;
    notifyListeners();
  }

  // ── Baselines captured at bind, for dirty tracking ────────────────
  String _baseName = '';
  String _baseUsername = '';
  String _basePassword = '';
  AuthMethod _baseAuth = AuthMethod.password;
  int _baseColor = 0;
  int? _baseColorValue;
  String? _baseFingerprint;
  String? _basePasswordRef;
  bool _baseAllowUnattended = false;

  KeyEditController() {
    nameController.addListener(_onFieldChanged);
    usernameController.addListener(_onFieldChanged);
    passwordController.addListener(_onFieldChanged);
  }

  void _onFieldChanged() {
    // Notify so the scaffold's title, dirty dot and Save button track edits.
    notifyListeners();
  }

  /// Agent-backed identities keep their key material outside our process, so it
  /// can never be edited here (only the name / username / color can).
  bool get usesAgent => _original?.usesAgent ?? false;

  /// Whether the auth method + its secret material are editable in the pane.
  /// Certificate + agent identities are name/username/color-only. A team
  /// certificate (3.0) holds no material, and may become a
  /// password or a key again.
  bool get canEditAuthMaterial =>
      !usesAgent &&
      (authMethod == AuthMethod.password ||
          authMethod == AuthMethod.publicKey ||
          authMethod == AuthMethod.teamCertificate ||
          authMethod == AuthMethod.passwordManager);

  /// Whether the working draft differs from the last-saved identity.
  bool get isDirty {
    if (_original == null && !_isCreating) return false;
    if (nameController.text != _baseName) return true;
    if (usernameController.text != _baseUsername) return true;
    if (colorIndex != _baseColor) return true;
    if (colorValue != _baseColorValue) return true;
    if (allowUnattended != _baseAllowUnattended) return true;
    // A key's own password, tried after the key (3.0, accounts per host):
    // set for every kind of key, its material editable here or not.
    if (kKeysWithPasswordAfter.contains(authMethod.name) && passwordController.text != _basePassword) {
      return true;
    }
    if (canEditAuthMaterial) {
      if (authMethod != _baseAuth) return true;
      if (authMethod == AuthMethod.password &&
          passwordController.text != _basePassword) {
        return true;
      }
      if (authMethod == AuthMethod.publicKey &&
          publicKeyFingerprint != _baseFingerprint) {
        return true;
      }
      if (authMethod == AuthMethod.passwordManager && passwordRef != _basePasswordRef) {
        return true;
      }
    }
    return false;
  }

  /// What a save does with the password saved with a key, where the draft is
  /// a key that may hold one (3.0, accounts per host; [keyPasswordOnSave]):
  /// the field changed only where it was. Null for any other kind.
  ({String? write, bool? afterKey, bool clear})? get keyPasswordSave =>
      kKeysWithPasswordAfter.contains(authMethod.name)
          ? keyPasswordOnSave(
              kind: authMethod.name,
              openedKind: _original?.authMethod,
              shown: _basePassword,
              text: passwordController.text,
            )
          : null;

  /// The trimmed working name, or null if empty (invalid - save is refused).
  String? get trimmedName {
    final t = nameController.text.trim();
    return t.isEmpty ? null : t;
  }

  /// The trimmed working username, or null if empty. Empty is invalid: the
  /// `Identities.username` column carries a min-length-1 CHECK.
  String? get trimmedUsername {
    final t = usernameController.text.trim();
    return t.isEmpty ? null : t;
  }

  // ── Edits (funnel through notify) ─────────────────────────────────

  void setAuthMethod(AuthMethod method) {
    if (authMethod == method) return;
    authMethod = method;
    notifyListeners();
  }

  void setColorIndex(int index) {
    // Picking a preset clears any custom colour so the index wins again.
    if (colorIndex == index && colorValue == null) return;
    colorIndex = index;
    colorValue = null;
    notifyListeners();
  }

  /// Persist an arbitrary custom label colour (ARGB int) that overrides the
  /// palette index.
  void setColorValue(int value) {
    if (colorValue == value) return;
    colorValue = value;
    notifyListeners();
  }

  /// Toggle the unattended-runs authorisation for the working draft. Persisted
  /// on the next Save (the screen calls through to
  /// `IdentityCrudNotifier.setAllowUnattended` so the change is audit-logged).
  void setAllowUnattended(bool value) {
    if (allowUnattended == value) return;
    allowUnattended = value;
    notifyListeners();
  }

  /// Adopt freshly generated / pasted / imported key material into the draft,
  /// with its public line made from it (kept when the key is saved: a key
  /// made here kept none, and could be neither installed on hosts nor
  /// exported but as its fingerprint).
  void setKeyMaterial({
    required String privateKeyPem,
    required String fingerprint,
    required String keyType,
    String? passphrase,
  }) {
    this.privateKeyPem = privateKeyPem;
    publicKeyFingerprint = fingerprint;
    this.keyType = keyType;
    keyPassphrase = passphrase;
    publicKeyData = publicKeyLineOf(privateKeyPem, passphrase: passphrase, comment: nameController.text.trim());
    notifyListeners();
  }

  /// Drop the loaded key material from the working draft (does not touch
  /// storage until the pane is saved).
  void clearKeyMaterial() {
    privateKeyPem = null;
    publicKeyFingerprint = null;
    keyType = null;
    keyPassphrase = null;
    publicKeyData = null;
    notifyListeners();
  }

  // ── Load / reset ──────────────────────────────────────────────────

  /// Point the editor at an existing [identity]. Secrets ([password] for
  /// password identities, [privateKeyPem] for key identities) are read from
  /// secure storage by the screen and passed in. Resets the dirty state.
  void bind(
    Identity identity, {
    String? password,
    String? privateKeyPem,
    String? keyPassphrase,
    bool secretsHidden = false,
    bool askAgain = false,
  }) {
    _original = identity;
    _isCreating = false;
    _secretsHidden = secretsHidden;
    _askAgain = askAgain;
    authMethod = AuthMethodX.fromDb(identity.authMethod);
    colorIndex = identity.colorIndex;
    colorValue = identity.colorValue;
    allowUnattended = identity.allowUnattended;
    this.privateKeyPem = privateKeyPem;
    this.keyPassphrase = keyPassphrase;
    publicKeyFingerprint = identity.publicKeyFingerprint;
    keyType = identity.keyType;
    publicKeyData = identity.publicKeyData;
    passwordRef = identity.passwordRef;

    _baseName = identity.label;
    _baseUsername = identity.username;
    _basePassword = password ?? '';
    _baseAuth = authMethod;
    _baseColor = identity.colorIndex;
    _baseColorValue = identity.colorValue;
    _baseFingerprint = identity.publicKeyFingerprint;
    _basePasswordRef = identity.passwordRef;
    _baseAllowUnattended = identity.allowUnattended;

    nameController.text = identity.label;
    usernameController.text = identity.username;
    passwordController.text = password ?? '';
    notifyListeners();
  }

  /// Start a blank new identity of [method] (password / SSH key). Resets dirty.
  void bindNew(AuthMethod method) {
    _secretsHidden = false;
    _askAgain = false;
    _original = null;
    _isCreating = true;
    authMethod = method;
    colorIndex = 0;
    colorValue = null;
    allowUnattended = false;
    privateKeyPem = null;
    keyPassphrase = null;
    publicKeyFingerprint = null;
    keyType = null;
    publicKeyData = null;
    passwordRef = null;

    _baseName = '';
    _baseUsername = '';
    _basePassword = '';
    _baseAuth = method;
    _baseColor = 0;
    _baseColorValue = null;
    _baseFingerprint = null;
    _basePasswordRef = null;
    _baseAllowUnattended = false;

    nameController.text = '';
    usernameController.text = '';
    passwordController.text = '';
    notifyListeners();
  }

  /// Clear the editor (nothing selected).
  void clear() {
    _original = null;
    _isCreating = false;
    authMethod = AuthMethod.password;
    colorIndex = 0;
    colorValue = null;
    allowUnattended = false;
    privateKeyPem = null;
    keyPassphrase = null;
    publicKeyFingerprint = null;
    keyType = null;
    publicKeyData = null;
    passwordRef = null;

    _baseName = '';
    _baseUsername = '';
    _basePassword = '';
    _baseAuth = AuthMethod.password;
    _baseColor = 0;
    _baseColorValue = null;
    _baseFingerprint = null;
    _basePasswordRef = null;
    _baseAllowUnattended = false;

    nameController.text = '';
    usernameController.text = '';
    passwordController.text = '';
    notifyListeners();
  }

  /// Assemble the full persistence row from the working draft. [id] is the
  /// existing id (edit) or a freshly minted one (create). Certificate + agent
  /// metadata and the created timestamp are carried through untouched from the
  /// bound row so an edit can never wipe them.
  Identity buildIdentity(String id) {
    final existing = _original;
    return Identity(
      id: id,
      label: nameController.text.trim(),
      username: usernameController.text.trim(),
      authMethod: authMethod.name,
      keyType: keyType,
      publicKeyFingerprint: publicKeyFingerprint,
      publicKeyData: publicKeyData,
      certSerial: existing?.certSerial,
      certKeyId: existing?.certKeyId,
      certPrincipals: existing?.certPrincipals,
      certCaFingerprint: existing?.certCaFingerprint,
      certValidBefore: existing?.certValidBefore,
      certValidAfter: existing?.certValidAfter,
      agentSocketPath: existing?.agentSocketPath,
      usesAgent: existing?.usesAgent ?? false,
      agentSource: existing?.agentSource,
      passwordRef: authMethod == AuthMethod.passwordManager ? passwordRef : null,
      colorIndex: colorIndex,
      colorValue: colorValue,
      isDefault: existing?.isDefault ?? false,
      allowUnattended: allowUnattended,
      // As a save leaves it (keyPasswordSave).
      passwordAfterKey: switch (keyPasswordSave) {
        null => false,
        final kept => kept.afterKey ?? existing?.passwordAfterKey ?? false,
      },
      createdAt: existing?.createdAt ?? DateTime.now(),
    );
  }

  /// After a successful save, adopt [saved] as the new baseline so the dirty
  /// flag clears and the pane reflects the persisted row.
  void markSaved(Identity saved) {
    _original = saved;
    _isCreating = false;
    authMethod = AuthMethodX.fromDb(saved.authMethod);
    colorIndex = saved.colorIndex;
    colorValue = saved.colorValue;
    allowUnattended = saved.allowUnattended;
    keyType = saved.keyType;
    publicKeyFingerprint = saved.publicKeyFingerprint;
    publicKeyData = saved.publicKeyData;
    passwordRef = saved.passwordRef;

    _baseName = saved.label;
    _baseUsername = saved.username;
    // The current password text is the just-persisted truth.
    _basePassword = passwordController.text;
    _baseAuth = authMethod;
    _baseColor = saved.colorIndex;
    _baseColorValue = saved.colorValue;
    _baseFingerprint = saved.publicKeyFingerprint;
    _basePasswordRef = saved.passwordRef;
    _baseAllowUnattended = saved.allowUnattended;

    // Normalize the text to the trimmed persisted values so trailing whitespace
    // can't re-dirty the form the instant after a save.
    if (nameController.text.trim() != saved.label) {
      nameController.text = saved.label;
    }
    if (usernameController.text.trim() != saved.username) {
      usernameController.text = saved.username;
    }
    notifyListeners();
  }

  // ── Kept while the page is away (memory only, nothing secret) ─────

  /// What the person changed, but for the secrets ([KeyEditDraft]), to be put
  /// back with [applyKept] when the page comes back.
  KeyEditDraft snapshot({SavePlace? saveIn}) => KeyEditDraft(
        original: _original,
        authMethod: authMethod,
        name: nameController.text,
        username: usernameController.text,
        colorIndex: colorIndex,
        colorValue: colorValue,
        allowUnattended: allowUnattended,
        passwordRef: passwordRef,
        saveIn: _isCreating ? saveIn : null,
      );

  /// Puts back what [snapshot] took, over the key as [bind] or [bindNew] just
  /// opened it (with its secrets, read again). What differs from the key as
  /// saved shows as unsaved; a change to a secret was not kept.
  void applyKept(KeyEditDraft d) {
    authMethod = d.authMethod;
    colorIndex = d.colorIndex;
    colorValue = d.colorValue;
    allowUnattended = d.allowUnattended;
    passwordRef = d.passwordRef;
    nameController.text = d.name;
    usernameController.text = d.username;
    notifyListeners();
  }

  /// The shared dirty guard the 1.7 spec wires into every leave-the-editor path
  /// (selecting another key, +New, nav-away). Returns true to PROCEED, false to
  /// ABORT. On "Save" it runs [onSave] and proceeds only if the save succeeded.
  /// Never autosaves on its own.
  Future<bool> confirmDiscardIfDirty(
    BuildContext context, {
    required Future<bool> Function() onSave,
  }) async {
    if (!isDirty) return true;
    final choice = await showZestDiscardDialog(context);
    switch (choice) {
      case DiscardChoice.cancel:
        return false;
      case DiscardChoice.discard:
        return true;
      case DiscardChoice.save:
        return onSave();
    }
  }

  @override
  void dispose() {
    nameController.removeListener(_onFieldChanged);
    usernameController.removeListener(_onFieldChanged);
    passwordController.removeListener(_onFieldChanged);
    nameController.dispose();
    usernameController.dispose();
    passwordController.dispose();
    super.dispose();
  }
}
