import 'dart:io';

import 'package:drift/drift.dart' show Value;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show compute;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';
import 'package:uuid/uuid.dart';
import 'package:zestssh/database/daos/connections_dao.dart' show ConnectionWithDetails;
import 'package:zestssh/database/database.dart' show AppDatabase, ConnectionGroupsCompanion, Identity, PortForwardRulesCompanion;
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_file.dart' show ImportFile, readImportFile, routeIfOtherFile;
import 'package:zestssh/features/orchards/guardrails.dart' show mayExportScreenSpace;
import 'package:zestssh/features/orchards/rules/reveal_gate.dart' show mayShareSecretsOf;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/connection_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/identity_providers.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/services/connection_share_url_service.dart' show ParsedConnectionShare;
import 'package:zestssh/services/identity_secret_store.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/theme/app_colors.dart';
import 'package:zestssh/ui/screens/connection/incoming_share_dialog.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/redacted_text.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/services/sync_data_service.dart' show isLoopbackBind;

// A host shared as a `.zest` file (3.0; found while comparing
// the five versions). A phone's Share wrote one, and nothing in the app read
// one back: Import hosts did not offer it, and Restore, which takes `.zest`
// files, said it was not a backup. A computer could not write one. Now every
// device writes one (a phone to the share sheet, a computer where it is
// told) and reads one, from Import hosts and from Restore.

// ─── Sharing a host as a file ──────────────────────────────────────

/// Shares [item]'s host as a `.zest` file: a phone through the share sheet,
/// a computer saved where the person says ([toShareSheet] for tests). Its
/// password and its private key go in only where chosen, sealed under a
/// password typed twice.
Future<void> shareHostAsFile(
  BuildContext context,
  WidgetRef ref,
  ConnectionWithDetails item, {
  bool? toShareSheet,
}) async {
  final conn = item.connection;
  // An Orchard's hosts leave in a share only an owner makes (3.0).
  if (!mayExportScreenSpace(ref)) return;

  // The .zest file carries the host, and optionally the password and the
  // private key, and the label goes into the share subject: reveal gate
  // (spec 5) before anything is shown or written.
  if (!await confirmRevealWhileRecording(context, ref)) return;
  if (!context.mounted) return;

  // Show options dialog: what the key has to share, and nothing it has not.
  final identity = item.identity;
  final result = await showZestModal<ShareOptions>(
    context: context,
    size: ZestModalSize.compact,
    child: ShareOptionsDialog(
      connectionLabel: conn.label,
      offerPassword: identity != null && passwordInUseBy(identity),
      offerKey: identity != null && keepsPrivateKey(identity),
    ),
  );
  if (result == null || !context.mounted) return;

  // A key's password or private key from a Crate that asks again goes into
  // the file only once the person confirms it is them (3.0), and
  // is not read before then; declined, nothing is shared.
  if ((result.includePassword || result.includeKey) &&
      identity != null &&
      !await mayShareSecretsOf(context, ref, identity.id)) {
    return;
  }
  if (!context.mounted) return;

  final l10n = AppLocalizations.of(context)!;
  final sheet = toShareSheet ?? (Platform.isAndroid || Platform.isIOS);
  String? written;
  // Where a computer saved it, said once the file written for it is gone.
  String? savedTo;
  final sealed = result.encryptionPassword != null && result.encryptionPassword!.isNotEmpty;
  try {
    // Get port forward rules for this connection
    final pfDao = ref.read(portForwardRulesDaoProvider);
    final portForwardRules = await pfDao.getByConnection(conn.id);

    // Get secrets if requested
    final (:password, :privateKeyPem) = await shareSecretsOf(ref.read(identityCrudProvider), identity,
        password: result.includePassword, key: result.includeKey);

    written = await ConnectionShareService.exportConnection(
      connection: conn,
      identity: identity,
      portForwardRules: portForwardRules,
      password: password,
      privateKeyPem: privateKeyPem,
      encryptionPassword: result.encryptionPassword,
    );
    if (!context.mounted) return;

    final fileName = p.basename(written);
    if (sheet) {
      // Show clear export confirmation BEFORE the system share sheet -
      // users tapping "Cancel" on the share sheet were getting no
      // feedback that the export actually succeeded.
      showTopSnackBar(
        context,
        sealed ? l10n.homeExportedEncrypted(fileName) : l10n.homeExported(fileName),
        isSuccess: true,
        duration: const Duration(seconds: 4),
      );
      await Share.shareXFiles([XFile(written)], subject: l10n.homeShareSubject(conn.label));
      return;
    }

    // A computer: saved where the person says, then said where it went.
    final start = await _startFolder();
    if (!context.mounted) return;
    final target = await FilePicker.platform.saveFile(
      dialogTitle: l10n.hostShareSaveFile,
      fileName: fileName,
      initialDirectory: start,
      lockParentWindow: true,
    );
    if (target == null) return; // cancelled
    await File(written).copy(target);
    savedTo = target;
  } catch (e) {
    if (context.mounted) {
      showTopSnackBar(context, l10n.homeShareFailed, isError: true, details: '$e');
    }
  } finally {
    // The file written for the share, which may hold the password and the
    // key, is not left behind (on Android, not past the next start: the app
    // chosen in the share sheet may not have read it yet).
    if (written != null) {
      await (sheet ? ConnectionShareService.removeAfterShare(written) : ConnectionShareService.removeShareFile(written));
    }
  }
  if (savedTo == null || !context.mounted) return;
  await showFileSavedDialog(
    context,
    title: l10n.hostShareSaved,
    message: sealed ? l10n.hostShareSavedSealedBody : l10n.hostShareSavedBody,
    path: savedTo,
  );
}

/// Where a computer's save dialog opens: Downloads, else Documents, else
/// wherever the system starts it.
Future<String?> _startFolder() async {
  try {
    final downloads = await getDownloadsDirectory();
    if (downloads != null) return downloads.path;
  } catch (_) {}
  try {
    return (await getApplicationDocumentsDirectory()).path;
  } catch (_) {
    return null;
  }
}

/// Whether [identity] keeps a private key in the app that a shared file may
/// carry: a key's, a certificate's (an agent's, a token's and a password
/// manager's stay where they are).
bool keepsPrivateKey(Identity identity) =>
    identity.authMethod == 'publicKey' || identity.authMethod == 'certificate';

/// What a shared host file carries of [identity]'s secrets, as its person
/// chose ([password], [key]): its private key, and its password where one is
/// in use (a password key's own, or one tried after a key; 3.0, accounts per
/// host). Never a password left from before the identity became a key.
@visibleForTesting
Future<({String? password, String? privateKeyPem})> shareSecretsOf(
  IdentityCrudNotifier crud,
  Identity? identity, {
  required bool password,
  required bool key,
}) async {
  if (identity == null) return (password: null, privateKeyPem: null);
  return (
    password: password && passwordInUseBy(identity) ? await crud.getPassword(identity.id) : null,
    privateKeyPem: key ? await crud.getPrivateKey(identity.id) : null,
  );
}

class ShareOptions {
  final bool includePassword;
  final bool includeKey;
  final String? encryptionPassword;

  const ShareOptions({
    required this.includePassword,
    required this.includeKey,
    this.encryptionPassword,
  });
}

/// What goes into a host's shared file. [offerPassword] and [offerKey] say
/// whether its key has a password in use and a private key to put in: a
/// choice of what is not there put nothing in, and sealed the file anyway.
class ShareOptionsDialog extends StatefulWidget {
  final String connectionLabel;
  final bool offerPassword;
  final bool offerKey;

  const ShareOptionsDialog({super.key, required this.connectionLabel, required this.offerPassword, required this.offerKey});

  @override
  State<ShareOptionsDialog> createState() => _ShareOptionsDialogState();
}

class _ShareOptionsDialogState extends State<ShareOptionsDialog> {
  bool _includePassword = false;
  bool _includeKey = false;
  final _encPasswordController = TextEditingController();
  // The password a share is sealed under is typed twice: a slip in it made a
  // file nobody could open.
  final _encPasswordAgainController = TextEditingController();

  bool get _needsEncryption => _includePassword || _includeKey;

  /// Why the encryption password is not taken, shown under it.
  String? _passwordError;

  /// The two passwords differ, said under the second.
  bool _passwordsDiffer = false;

  @override
  void dispose() {
    _encPasswordController.dispose();
    _encPasswordAgainController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final l10n = AppLocalizations.of(context)!;
    // The shell (the dialog rules of 3.4): the host's name masked in
    // recording mode, Cancel and Share in the footer.
    return Consumer(
      builder: (context, ref, _) => ZestDialogShell(
        size: ZestModalSize.compact,
        tone: ZestDialogTone.neutral,
        icon: LucideIcons.share2,
        title: l10n.homeShareTitle(Redactable.host(widget.connectionLabel).displayIn(ref)),
        body: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              l10n.homeShareExportDesc,
              style: TextStyle(color: AppColors.textSecondary, fontSize: 13),
            ),
            const SizedBox(height: 16),
            if (widget.offerPassword)
              CheckboxListTile(
                title: Text(l10n.homeShareIncludePassword),
                subtitle: Text(
                  l10n.homeShareWillBeEncrypted,
                  style: const TextStyle(fontSize: 12),
                ),
                value: _includePassword,
                onChanged: (v) => setState(() => _includePassword = v!),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            if (widget.offerKey)
              CheckboxListTile(
                title: Text(l10n.homeShareIncludePrivateKey),
                subtitle: Text(
                  l10n.homeShareWillBeEncrypted,
                  style: const TextStyle(fontSize: 12),
                ),
                value: _includeKey,
                onChanged: (v) => setState(() => _includeKey = v!),
                contentPadding: EdgeInsets.zero,
                controlAffinity: ListTileControlAffinity.leading,
              ),
            if (_needsEncryption) ...[
              const SizedBox(height: 8),
              Text(
                l10n.homeShareSetEncryptionPassword,
                style: TextStyle(color: AppColors.textSecondary, fontSize: 12),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('share-encryption-password'),
                controller: _encPasswordController,
                obscureText: true,
                onChanged: (_) {
                  if (_passwordError != null) setState(() => _passwordError = null);
                },
                decoration: InputDecoration(
                  labelText: l10n.homeShareEncryptionPassword,
                  hintText: l10n.homeShareEncryptionPasswordHint,
                  errorText: _passwordError,
                ),
              ),
              const SizedBox(height: 8),
              TextFormField(
                key: const ValueKey('share-encryption-password-again'),
                controller: _encPasswordAgainController,
                obscureText: true,
                onChanged: (_) {
                  if (_passwordsDiffer) setState(() => _passwordsDiffer = false);
                },
                decoration: InputDecoration(
                  labelText: l10n.backupPasswordConfirmHint,
                  errorText: _passwordsDiffer ? l10n.backupPasswordMismatch : null,
                ),
              ),
            ],
          ],
        ),
        secondaryAction: (label: l10n.cancel, onPressed: () => Navigator.pop(context)),
        primaryKey: const ValueKey('share-options-go'),
        primaryAction: (label: l10n.homeShare, icon: null, onPressed: _share),
      ),
    );
  }

  void _share() {
    final l10n = AppLocalizations.of(context)!;
    // Said under the field (it was a notice for an empty one, and a
    // short one failed later with an English error).
    if (_needsEncryption && _encPasswordController.text.isEmpty) {
      setState(() => _passwordError = l10n.homeShareEncryptionRequired);
      return;
    }
    if (_needsEncryption && _encPasswordController.text.length < ConnectionShareService.minPasswordLength) {
      setState(() => _passwordError = l10n.settingsMobPasswordMin12);
      return;
    }
    if (_needsEncryption && _encPasswordAgainController.text != _encPasswordController.text) {
      setState(() => _passwordsDiffer = true);
      return;
    }
    Navigator.pop(
      context,
      ShareOptions(
        includePassword: _includePassword,
        includeKey: _includeKey,
        encryptionPassword: _needsEncryption ? _encPasswordController.text : null,
      ),
    );
  }
}

// ─── Adding a host from a file ─────────────────────────────────────

/// Adds the host shared in the `.zest` file at [path], picked here where it
/// is not given. A file that is not a shared host is said to be so (a backup
/// as a backup); one sealed under a password asks for it until it opens the
/// file or the person stops; then what the file holds is shown before it is
/// added ([IncomingShareDialog.file]). It goes into your Tree, whatever space
/// is on screen, with its forwards saved but not started.
Future<void> importHostShareFile(BuildContext context, {String? path}) async {
  final l10n = AppLocalizations.of(context)!;
  var file = path;
  if (file == null) {
    final pick = await FilePicker.platform.pickFiles(type: FileType.any, dialogTitle: l10n.cloudImpZest);
    file = pick == null || pick.files.isEmpty ? null : pick.files.single.path;
    if (file == null) return;
  }
  final chosen = file;

  // No more of it than a host file may be, looked at off the screen's thread:
  // this may be any file at all.
  final ImportFile found;
  try {
    found = await readImportFile(chosen);
  } catch (e) {
    if (context.mounted) {
      showTopSnackBar(
        context,
        l10n.settingsImportFailed(sftpErrorMessage(e, name: p.basename(chosen), op: SftpOp.download)),
        isError: true,
        details: '$e',
      );
    }
    return;
  }
  if (!context.mounted) return;
  if (found.kind != ImportKind.zestHost) {
    // A backup is a .zest file as well, and it may be anything else: said, and
    // offered where it goes.
    if (found.kind != ImportKind.unknown) {
      await routeIfOtherFile(context, found, chosen: l10n.cloudImpZest, takes: const {}, closes: false);
      return;
    }
    showTopSnackBar(context, l10n.hostShareNotShare, isError: true);
    return;
  }

  // Read in a worker: a sealed file's password is stretched 600,000 times,
  // seconds on a phone, which would stop the screen.
  Future<ZestImportData?> read(String? password) => compute(_readShareFile, (chosen, password));

  ZestImportData? data;
  Object? failure;
  if (ConnectionShareService.isSealedShare(found.bytes ?? const [])) {
    final opened = await showZestInputDialog(
      context: context,
      title: l10n.hostShareSealedTitle,
      icon: LucideIcons.lock,
      fieldLabel: l10n.homeShareEncryptionPassword,
      obscureText: true,
      confirmLabel: l10n.accountImportAction,
      validator: (value) => value.isEmpty ? l10n.homeShareEncryptionRequired : null,
      onConfirm: (value) async {
        try {
          data = await read(value);
        } catch (e) {
          // Opened, and not a host after all: said once the prompt closes.
          failure = e;
          return null;
        }
        return data == null ? l10n.hostShareWrongPassword : null;
      },
    );
    if (opened == null) return;
  } else {
    try {
      data = await read(null);
    } catch (e) {
      failure = e;
    }
  }
  if (!context.mounted) return;
  final shared = data;
  if (shared == null) {
    showTopSnackBar(context, l10n.hostShareNotShare, isError: true, details: failure == null ? null : '$failure');
    return;
  }

  if (!await IncomingShareDialog.showFile(context, shared)) return;
  if (!context.mounted) return;
  final container = ProviderScope.containerOf(context, listen: false);
  try {
    await addSharedHost(
      container.read(treeDatabaseProvider),
      container.read(secureStorageProvider),
      shared,
    );
    if (context.mounted) showTopSnackBar(context, l10n.qrScanConnectionAdded, isSuccess: true);
  } catch (e, stack) {
    if (context.mounted) {
      showTopSnackBar(context, l10n.sharedConnectionSaveFailed, isError: true, details: '$e\n$stack');
    }
  }
}

/// The shared host in the file [args].$1, opened with the password
/// [args].$2: run in a worker by [importHostShareFile].
Future<ZestImportData?> _readShareFile((String, String?) args) =>
    ConnectionShareService.importConnection(args.$1, decryptionPassword: args.$2);

/// Saves the host [shared] in your Tree ([tree], its secrets in [storage]),
/// and returns its id. Its user becomes a key of its own: with the private
/// key and the password that came with it (the password then tried after the
/// key), or asking for a password at sign-in where none came. It goes into
/// the group named [group] (made where your Tree has none of that name), with
/// [tags]. Its forwards are saved, never started on their own. All of it or
/// none.
Future<String> addSharedHost(AppDatabase tree, FlutterSecureStorage storage, ZestImportData shared,
    {String? group, List<String> tags = const []}) {
  final keys = IdentityCrudNotifier(tree.identitiesDao, IdentitySecretStore.forDatabase(tree, storage), tree.connectionsDao);
  final hosts = ConnectionCrudNotifier(tree.connectionsDao, tree.portForwardRulesDao, tree.connectionTagsDao);
  return tree.transaction(() async {
    String? identityId;
    final user = shared.username;
    if (user != null) {
      final pem = shared.privateKeyPem;
      final password = shared.password;
      ImportedKey? key;
      if (pem != null) {
        try {
          key = KeyImportService().importOpenSSHKey(pem);
        } catch (_) {
          // Sealed under a passphrase the file does not carry: asked for at
          // sign-in, as a key added any other way is.
        }
      }
      final label = shared.identityLabel ?? user;
      identityId = await keys.create(
        label: label,
        username: user,
        authMethod: pem != null ? 'publicKey' : 'password',
        keyType: key?.keyType ?? (pem != null ? shared.keyType : null),
        publicKeyFingerprint: key?.fingerprint,
        publicKeyData: pem == null ? null : publicKeyLineOf(pem, comment: label),
        password: password,
        privateKeyPem: pem,
        passwordAfterKey: pem != null && password != null,
        colorIndex: shared.identityColorIndex,
      );
    }
    String? groupId;
    final groupName = group?.trim() ?? '';
    if (groupName.isNotEmpty) {
      final named = (await tree.connectionGroupsDao.getAll())
          .where((g) => g.name.toLowerCase() == groupName.toLowerCase())
          .firstOrNull;
      groupId = named?.id;
      if (groupId == null) {
        groupId = const Uuid().v4();
        await tree.connectionGroupsDao.insertGroup(
            ConnectionGroupsCompanion.insert(id: groupId, name: groupName, createdAt: DateTime.now()));
      }
    }
    final id = await hosts.create(
      label: shared.label,
      host: shared.host,
      port: shared.port,
      identityId: identityId,
      groupId: groupId,
      colorIndex: shared.colorIndex,
      protocol: shared.protocol,
      zlibCompression: shared.zlibCompression,
      keepAliveSeconds: shared.keepAliveSeconds,
    );
    if (tags.isNotEmpty) await tree.connectionTagsDao.setTagsForConnection(id, tags);
    for (final f in shared.portForwards) {
      await tree.portForwardRulesDao.insertRule(PortForwardRulesCompanion(
        id: Value(const Uuid().v4()),
        connectionId: Value(id),
        type: Value(f.type),
        // On this device alone, as a restored forward is: one someone shared
        // bound to all addresses (0.0.0.0) opened its port to the network the
        // moment it was started (found in a
        // security review). Turned outward by hand only, as any forward is.
        bindAddress: Value(isLoopbackBind(f.bindAddress) ? f.bindAddress : '127.0.0.1'),
        bindPort: Value(f.bindPort),
        remoteHost: Value(f.remoteHost),
        remotePort: Value(f.remotePort),
        label: Value(f.label),
        // Never started on their own: a file someone sent does not open a
        // tunnel, even once the host is added.
        autoStart: const Value(false),
        createdAt: Value(DateTime.now()),
      ));
    }
    return id;
  });
}

/// Saves the host a share link or a scanned code holds ([share], which
/// [ConnectionShareUrlService.tryParse] read) as [addSharedHost] saves a
/// file's: into your Tree, whatever space is on screen, with its user, its
/// group and its tags as the dialog showed them, its forwards not started.
/// (It went into the space on screen, an Orchard too, past what its rules
/// allow and into no Crate, without its user, group or tags.) Its identity
/// hint names a key of yours to pick after, and is not one.
Future<String> addLinkedHost(AppDatabase tree, FlutterSecureStorage storage, ParsedConnectionShare share) =>
    addSharedHost(
      tree,
      storage,
      ZestImportData(
        label: share.label,
        host: share.host,
        port: share.port,
        protocol: 'ssh',
        colorIndex: 0,
        zlibCompression: false,
        keepAliveSeconds: 0,
        username: share.user,
        portForwards: [
          for (final f in share.forwards)
            ZestPortForward(
              type: f.type,
              bindAddress: f.bindAddress,
              bindPort: f.bindPort,
              remoteHost: f.remoteHost,
              remotePort: f.remotePort,
              autoStart: false,
              label: f.label,
            ),
        ],
      ),
      group: share.groupHint,
      tags: share.tags,
    );

/// Restore was given a host shared as a file, not a backup ([path]): says
/// so, and adds the host where the person asks.
Future<void> offerHostShareFromRestore(BuildContext context, String path) async {
  final l10n = AppLocalizations.of(context)!;
  final add = await ZestConfirmDialog.show(
    context,
    tone: ZestDialogTone.info,
    title: l10n.settingsImportBackup,
    body: l10n.backupIsHostShare,
    confirmLabel: l10n.hostShareAddIt,
  );
  if (add != true || !context.mounted) return;
  await importHostShareFile(context, path: path);
}
