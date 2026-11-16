import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:lucide_icons/lucide_icons.dart';
import 'package:path/path.dart' as p;
import 'package:zestssh/features/cloud_import/csv/csv_hosts.dart';
import 'package:zestssh/features/cloud_import/csv/csv_import_view.dart' show CsvPicked;
import 'package:zestssh/features/cloud_import/import_away.dart';
import 'package:zestssh/features/cloud_import/import_detect.dart';
import 'package:zestssh/features/cloud_import/ui/import_hosts_entry.dart' show openCsvImport;
import 'package:zestssh/features/hosts/host_share_file.dart' show importHostShareFile;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/work_tabs_provider.dart';
import 'package:zestssh/router/routes.dart';
import 'package:zestssh/services/key_import_service.dart';
import 'package:zestssh/ui/screens/backup/backup_actions.dart' show restoreBackupFile;
import 'package:zestssh/ui/screens/connection/share_link_add.dart' show addShareLinkFromText;
import 'package:zestssh/ui/screens/desktop/dialogs/get_connected_dialogs.dart'
    show showDesktopSshConfigImport, toastImportOutcome;
import 'package:zestssh/ui/screens/identity/identity_edit_screen.dart' show IdentityEditScreen, InitialImportedKey;
import 'package:zestssh/ui/widgets/top_snackbar.dart';
import 'package:zestssh/ui/widgets/zest_dialog.dart';
import 'package:zestssh/ui/widgets/zest_sheet.dart';
import 'package:zestssh/utils/logger.dart';

// A file chosen to import, and where it goes: [importKindOf] says what it is,
// and every import takes it from there, with nothing to choose again. Import
// a file asks this directly; an importer picked by hand that gets another kind
// of file says so, and offers the right one ([routeIfOtherFile]). A private
// key's contents are read for the detector's yes or no, and again only by
// Keys' own import once the person says to.

/// A file chosen to import, and what it is.
class ImportFile {
  const ImportFile({required this.name, required this.kind, this.path, this.bytes, this.moreThanKey = false});

  /// Its name, without its folders.
  final String name;

  /// Where it is; null for text pasted.
  final String? path;

  /// What the detector found.
  final ImportKind kind;

  /// What was read of it (at most one byte more than a host file may be).
  /// Never kept for a private key: Keys' import reads it from [path].
  final List<int>? bytes;

  /// A private key, with other text beside it: the person may say it is
  /// something else ([importCanReadAnyway]), and only then is it read again.
  final bool moreThanKey;

  /// What it holds as the host file import takes it.
  CsvPicked? get picked => bytes == null ? null : (name: name, bytes: bytes!);
}

/// The [ImportFile] of [bytes], read from [path] or pasted. [rdp]: this
/// build offers RDP hosts (rdpOfferedProvider); where it does not, a Remote
/// Desktop file is nothing it knows, and is called that.
ImportFile importFileOf({required String name, String? path, required List<int> bytes, bool rdp = false}) =>
    _fileOf(importLookAt(bytes), name, path, bytes, rdp);

ImportFile _fileOf(
  ({ImportKind kind, bool moreThanKey}) look,
  String name,
  String? path,
  List<int> bytes,
  bool rdp,
) {
  final kind = look.kind == ImportKind.rdpFile && !rdp ? ImportKind.unknown : look.kind;
  return ImportFile(
    name: name,
    path: path,
    kind: kind,
    bytes: kind == ImportKind.privateKey ? null : bytes,
    moreThanKey: look.moreThanKey,
  );
}

/// [importFileOf], off the screen's thread where there is much to look at.
Future<ImportFile> importFileAway({
  required String name,
  String? path,
  required List<int> bytes,
  bool rdp = false,
}) async =>
    _fileOf(await _lookAway(bytes), name, path, bytes, rdp);

Future<({ImportKind kind, bool moreThanKey})> _lookAway(List<int> bytes) =>
    importWorkAway(bytes.length, () => importLookAt(bytes));

Future<List<int>> _readAsFarAsMatters(String path) async {
  final bytes = BytesBuilder(copy: false);
  await for (final chunk in File(path).openRead(0, kCsvMaxBytes + 1)) {
    bytes.add(chunk);
  }
  return bytes.takeBytes();
}

/// Reads as much of the file at [path] as can matter ([kCsvMaxBytes] and one
/// more byte, enough to tell one that is too large), and says what it is.
Future<ImportFile> readImportFile(String path, {bool rdp = false}) async =>
    importFileAway(name: p.basename(path), path: path, bytes: await _readAsFarAsMatters(path), rdp: rdp);

/// Whether the person may say [file] is something else, though it has a private
/// key in it: the text holds more than the key, and its file can be read again.
/// What is only a key, and what was pasted, no.
bool importCanReadAnyway(ImportFile file) => file.kind == ImportKind.privateKey && file.moreThanKey && file.path != null;

/// [file] with what it holds, where that was not kept for the private key in it
/// and the person said it is something else all the same: all but the key
/// ([importWithoutKeys]). One larger than any import reads holds nothing: each
/// says it is too large by its size alone.
Future<ImportFile> importFileToRead(ImportFile file) async {
  if (file.bytes != null || !importCanReadAnyway(file)) return file;
  final bytes = await _readAsFarAsMatters(file.path!);
  if (bytes.length > kCsvMaxBytes) {
    return ImportFile(name: file.name, path: file.path, kind: ImportKind.unknown, bytes: Uint8List(bytes.length));
  }
  return importFileAway(
    name: file.name,
    path: file.path,
    bytes: await importWorkAway(bytes.length, () => importWithoutKeys(bytes)),
  );
}

/// The file the person chooses, and what it is; null when none was chosen.
Future<ImportFile?> pickImportFile(String title, {bool rdp = false}) async {
  final result = await FilePicker.platform.pickFiles(type: FileType.any, dialogTitle: title);
  final path = result?.files.singleOrNull?.path;
  return path == null ? null : readImportFile(path, rdp: rdp);
}

/// What [kind] is called, where a person chooses or is told.
String importKindName(ImportKind kind, AppLocalizations l10n) => switch (kind) {
      ImportKind.zestBackup => l10n.importKindBackup,
      ImportKind.zestHost => l10n.cloudImpZest,
      ImportKind.sshConfig => l10n.cloudImpSshConfig,
      ImportKind.puttyReg => l10n.importKindPutty,
      ImportKind.mobaxterm => 'MobaXterm',
      ImportKind.secureCrt => 'SecureCRT',
      ImportKind.fileZilla => 'FileZilla',
      ImportKind.winScp => 'WinSCP',
      ImportKind.mRemoteNg => 'mRemoteNG',
      ImportKind.remmina => 'Remmina',
      ImportKind.rdpFile => l10n.migrateRdpFileTitle,
      ImportKind.csv => l10n.cloudImpCsv,
      ImportKind.privateKey => l10n.importKindKey,
      ImportKind.publicKey => l10n.importKindPublicKey,
      ImportKind.knownHosts => 'known_hosts',
      ImportKind.shareLink => l10n.importKindLink,
      ImportKind.unknown => l10n.importFoundUnknown,
    };

/// What is said of a file found to be [kind], a question where it can be
/// imported.
String importFoundWords(ImportKind kind, AppLocalizations l10n) => switch (kind) {
      ImportKind.zestBackup => l10n.importFoundBackup,
      ImportKind.zestHost => l10n.importFoundHost,
      ImportKind.sshConfig => l10n.importFoundSshConfig,
      ImportKind.puttyReg => l10n.importFoundPutty,
      ImportKind.mobaxterm => l10n.importFoundMoba,
      ImportKind.secureCrt => l10n.importFoundCrt,
      ImportKind.fileZilla => l10n.importFoundFileZilla,
      ImportKind.winScp => l10n.importFoundWinScp,
      ImportKind.mRemoteNg => l10n.importFoundMRemoteNg,
      ImportKind.remmina => l10n.importFoundRemmina,
      ImportKind.rdpFile => l10n.importFoundRdpFile,
      ImportKind.csv => l10n.importFoundCsv,
      ImportKind.privateKey => l10n.importFoundKey,
      ImportKind.publicKey => l10n.importFoundPublicKey,
      ImportKind.knownHosts => l10n.importFoundKnownHosts,
      ImportKind.shareLink => l10n.importFoundLink,
      ImportKind.unknown => l10n.importFoundUnknown,
    };

/// The kinds a person may say a file is, where the detector could not tell or
/// was wrong. Not a public key or known_hosts, which nothing imports.
const kImportKindsToChoose = [
  ImportKind.sshConfig,
  ImportKind.puttyReg,
  ImportKind.mobaxterm,
  ImportKind.secureCrt,
  ImportKind.fileZilla,
  ImportKind.winScp,
  ImportKind.mRemoteNg,
  ImportKind.remmina,
  ImportKind.csv,
  ImportKind.zestBackup,
  ImportKind.zestHost,
  ImportKind.privateKey,
  ImportKind.shareLink,
];

/// Whether [file] can go to the import of [kind]: a pasted text has no file to
/// read again, so what needs one cannot.
bool importCanTake(ImportFile file, ImportKind kind) => switch (kind) {
      ImportKind.publicKey || ImportKind.knownHosts || ImportKind.unknown => false,
      ImportKind.zestBackup || ImportKind.zestHost || ImportKind.privateKey => file.path != null,
      _ => file.bytes != null || importCanReadAnyway(file),
    };

/// Opens the import of [kind] for [file], with the file in hand, so nothing is
/// chosen again.
Future<void> openImportFile(BuildContext context, ImportFile found, ImportKind kind) async {
  final path = found.path;
  var file = found;
  // Said to be something else, though it has a private key in it: read now.
  if (kind != ImportKind.privateKey) {
    try {
      file = await importFileToRead(found);
    } catch (e) {
      AppLogger.warning('Import a file: it was not read again');
      if (context.mounted) {
        showTopSnackBar(context, AppLocalizations.of(context)!.csvImpUnreadable, isError: true, details: '$e');
      }
      return;
    }
    if (!context.mounted) return;
  }
  switch (kind) {
    case ImportKind.zestBackup:
      if (path != null) await restoreBackupFile(context, path);
    case ImportKind.zestHost:
      if (path != null) await importHostShareFile(context, path: path);
    case ImportKind.sshConfig:
      if (zestUsesSheets(context)) {
        await context.push(Routes.sshConfigImport, extra: file);
      } else {
        final o = await showDesktopSshConfigImport(context, file: file);
        if (o != null && context.mounted) toastImportOutcome(context, added: o.imported, failedLimit: o.failedLimit);
      }
    case ImportKind.puttyReg ||
          ImportKind.mobaxterm ||
          ImportKind.secureCrt ||
          ImportKind.fileZilla ||
          ImportKind.winScp ||
          ImportKind.mRemoteNg ||
          ImportKind.remmina ||
          ImportKind.rdpFile ||
          ImportKind.csv:
      await openCsvImport(context, kind: kind.hostFile!, picked: file.picked);
    case ImportKind.privateKey:
      if (path != null) await importKeyFile(context, path);
    case ImportKind.shareLink:
      final bytes = file.bytes;
      if (bytes != null) await addShareLinkFromText(context, importShareLinkOf(bytes) ?? decodeCsvBytes(bytes));
    case ImportKind.publicKey || ImportKind.knownHosts || ImportKind.unknown:
      // Nothing imports these: what they are was said where it was found.
      break;
  }
}

/// Opens Keys, where a key is added (a computer's page, a phone's screen).
void openKeysPage(BuildContext context) {
  if (zestUsesSheets(context)) {
    context.push(Routes.keys);
  } else {
    final container = ProviderScope.containerOf(context, listen: false);
    container.read(v3ActiveSessionTabProvider.notifier).state = null;
    container.read(activeSidebarNavProvider.notifier).state = NavSection.keys;
    container.read(workTabsProvider.notifier).clearActiveTab();
  }
}

/// [file] came to an importer the person chose, called [chosen], which takes
/// [takes]. Where it is something else, says so and offers the right import
/// (such as "This is a ZestSSH backup, not an SSH
/// config. Import it as a backup?"), and true: this importer does nothing more
/// with it, the screen it is in ([closes]) going away where the person said
/// yes. False where it is for this importer, or the detector could not tell:
/// the importer tries it, and says what it finds. [readsHere]: this importer can
/// read a text with a private key in it and more besides, where the person says
/// to ([importCanReadAnyway]): false then as well, and [importFileToRead] gives
/// it what it reads.
Future<bool> routeIfOtherFile(BuildContext context, ImportFile file,
    {required String chosen, required Set<ImportKind> takes, bool closes = true, bool readsHere = false}) async {
  if (file.kind == ImportKind.unknown || takes.contains(file.kind)) return false;
  final l10n = AppLocalizations.of(context)!;
  final kind = file.kind;
  final canImport = importCanTake(file, kind);
  final keys = kind == ImportKind.publicKey;
  final readsRest = readsHere && importCanReadAnyway(file);
  var readHere = false;
  final go = await ZestDialogShell.showModal<bool>(
    context,
    size: ZestModalSize.compact,
    tone: ZestDialogTone.info,
    icon: LucideIcons.fileQuestion,
    title: l10n.importWrongTitle(chosen),
    body: Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          canImport || keys || kind == ImportKind.knownHosts ? importFoundWords(kind, l10n) : l10n.importPastedOther,
          key: const ValueKey('import-other-file'),
          style: const TextStyle(fontSize: 13, height: 1.5),
        ),
        if (readsRest) ...[
          const SizedBox(height: 8),
          Text(l10n.importReadRestBody(chosen), key: const ValueKey('import-read-rest'), style: const TextStyle(fontSize: 13, height: 1.5)),
        ],
      ],
    ),
    primaryAction: canImport
        ? (label: l10n.importItAction, onPressed: () => Navigator.of(context).pop(true), icon: LucideIcons.download)
        : keys
            ? (label: l10n.importOpenKeys, onPressed: () => Navigator.of(context).pop(true), icon: LucideIcons.keyRound)
            : null,
    secondaryAction: (label: canImport || keys ? l10n.cancel : l10n.close, onPressed: () => Navigator.of(context).pop(false)),
    tertiaryAction: readsRest
        ? (
            label: l10n.importReadRest,
            onPressed: () {
              readHere = true;
              Navigator.of(context).pop(false);
            },
          )
        : null,
  );
  if (readHere) return false;
  if (go != true || !context.mounted) return true;
  // The navigator stays when the screen this was asked from goes.
  final navigator = Navigator.of(context);
  final outer = closes ? navigator.context : context;
  if (closes) navigator.pop();
  if (keys) {
    openKeysPage(outer);
  } else {
    await openImportFile(outer, file, kind);
  }
  return true;
}

/// The longest file read as a private key (the keys an SSH config names are
/// held to the same).
const kMaxKeyFileBytes = 64 * 1024;

/// Keys' import of the private key at [path]: a passphrase asked for where it
/// has one, up to three times, then the key's editor with the key in it, as
/// Keys' own Import from a file leaves it. What cannot be read is said, with
/// the details to copy.
Future<void> importKeyFile(BuildContext context, String path) async {
  final read = await readKeyFileToImport(context, path);
  if (read == null || !context.mounted) return;
  await IdentityEditScreen.showAdaptive(
    context,
    key: InitialImportedKey(
      privatePem: read.key.privatePem,
      fingerprint: read.key.fingerprint,
      keyType: read.key.keyType,
      label: read.name,
      passphrase: read.passphrase,
    ),
  );
}

/// What Keys' import read of a private key file: the key, the passphrase it
/// opened with (none where it has none), and the name it is given, the file's
/// without its extension.
typedef KeyFileRead = ({ImportedKey key, String? passphrase, String name});

/// [importKeyFile] as far as the key, for an editor of the caller's own (a
/// computer's Keys page takes a key file dropped on it into the editor beside
/// its list, 4.0): a passphrase asked for where it has one, up to three times.
/// Null where the key was not read, which is said with the details to copy, or
/// its passphrase was not given.
Future<KeyFileRead?> readKeyFileToImport(BuildContext context, String path) async {
  final l10n = AppLocalizations.of(context)!;
  try {
    // No key is anywhere near this long: what is, is not read into memory.
    if (await File(path).length() > kMaxKeyFileBytes) throw const FormatException('Longer than any private key');
    final content = utf8.decode(await File(path).readAsBytes(), allowMalformed: true);
    final service = KeyImportService();
    // A form it cannot read is said at once, before any question of a passphrase.
    if (!service.readsForm(content)) throw const FormatException('Not a form of private key this reads');
    final ppk = service.isPpkFormat(content);
    ImportedKey? imported;
    String? passphrase;
    if (service.isEncrypted(content)) {
      String? problem;
      for (var attempt = 0; attempt < 3 && imported == null; attempt++) {
        if (!context.mounted) return null;
        final typed = await showZestInputDialog(
          context: context,
          title: l10n.identityKeyPassphrase,
          subtitle: l10n.identityEditKeyEncryptedSubtitle,
          icon: LucideIcons.lock,
          fieldLabel: l10n.identityPassphrase,
          obscureText: true,
          confirmLabel: l10n.passphrasePromptUnlock,
          initialError: problem,
        );
        if (typed == null) return null;
        try {
          imported = ppk
              ? await service.importPpkKeyInBackground(content, typed)
              : service.importOpenSSHKey(content, typed);
          passphrase = typed;
        } catch (e) {
          if (!KeyImportService.isPassphraseError('$e')) rethrow;
          problem = l10n.identityIncorrectPassphrase;
        }
      }
      if (imported == null) {
        if (context.mounted) showTopSnackBar(context, l10n.identityImportFailed(l10n.identityDecryptFailed), isError: true);
        return null;
      }
    } else {
      imported = ppk ? service.importPpkKey(content, null) : service.importOpenSSHKey(content, null);
    }
    return (key: imported, passphrase: passphrase, name: p.basenameWithoutExtension(path));
  } catch (e) {
    AppLogger.warning('Import a file: the key was not read');
    if (context.mounted) {
      showTopSnackBar(context, KeyImportService.problemSaid(e, l10n), isError: true, details: '$e');
    }
    return null;
  }
}
