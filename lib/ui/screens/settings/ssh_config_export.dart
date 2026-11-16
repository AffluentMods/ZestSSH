import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/services/connection_share_service.dart';
import 'package:zestssh/ui/widgets/file_saved_dialog.dart';
import 'package:zestssh/ui/widgets/recording_reveal_gate.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// The file name an exported ssh_config is offered under.
const sshConfigFileName = 'zestssh_connections.config';

/// [connections] as an ssh_config file: one Host block each, with its
/// address and port (no user, password or key), dated [at].
String buildSshConfig(List<Connection> connections, DateTime at) {
  final buffer = StringBuffer()
    ..writeln('# Exported from ZestSSH')
    ..writeln('# ${at.toIso8601String()}')
    ..writeln();
  for (final conn in connections) {
    buffer
      ..writeln('Host ${conn.label.replaceAll(' ', '_')}')
      ..writeln('  HostName ${conn.host}')
      ..writeln('  Port ${conn.port}')
      ..writeln();
  }
  return buffer.toString();
}

/// "Connections as SSH config", from Settings and from Data settings (3.0:
/// each had its own copy). It was always written into the
/// documents folder (a computer's own Documents) and left there, then
/// offered to the share sheet, and a file that could not be written ended
/// the export with nothing said. Now a computer asks where it goes and shows
/// where it went; a phone shares it from a folder of its own, deleted once
/// the share sheet closes (on Android at the next start, see
/// [ConnectionShareService.removeAfterShare]); a file not written says so, with what was thrown.
///
/// Your Tree's hosts only, whatever space is on screen: an Orchard's hosts
/// never leave it in an export file (3.0).
Future<void> exportSshConfig(BuildContext context, WidgetRef ref) async {
  final l10n = AppLocalizations.of(context)!;
  // The export writes every label and host to a file: reveal gate (spec 5),
  // the same as the backup export.
  if (!await confirmRevealWhileRecording(context, ref)) return;
  if (!context.mounted) return;
  final connections = await ref.read(treeDatabaseProvider).connectionsDao.getAll();
  if (!context.mounted) return;
  if (connections.isEmpty) {
    showTopSnackBar(context, l10n.settingsNoConnectionsToExport);
    return;
  }
  final text = buildSshConfig(connections, DateTime.now());

  if (Platform.isAndroid || Platform.isIOS) {
    String? path;
    try {
      final temp = await getTemporaryDirectory();
      final folder = await Directory(temp.path).createTemp(ConnectionShareService.shareFolderPrefix);
      path = '${folder.path}${Platform.pathSeparator}$sshConfigFileName';
      await File(path).writeAsString(text, flush: true);
    } catch (e) {
      if (path != null) await ConnectionShareService.removeShareFile(path);
      if (context.mounted) showTopSnackBar(context, l10n.sshConfigNotSaved, isError: true, details: '$e');
      return;
    }
    try {
      if (!context.mounted) return;
      // Said before the share sheet, so it is seen even when the sheet is
      // dismissed at once.
      showTopSnackBar(context, l10n.settingsMobExportedConnections(connections.length),
          isSuccess: true, duration: const Duration(seconds: 4));
      await Share.shareXFiles([XFile(path)], text: l10n.settingsSshConfigExport);
    } finally {
      await ConnectionShareService.removeAfterShare(path);
    }
    return;
  }

  try {
    final start = await _startFolder();
    if (!context.mounted) return;
    final path = await FilePicker.platform.saveFile(
      dialogTitle: l10n.settingsSshConfigExport,
      fileName: sshConfigFileName,
      initialDirectory: start,
      lockParentWindow: true,
    );
    if (path == null) return; // cancelled
    final file = File(path);
    await file.writeAsString(text, flush: true);
    if (!context.mounted) return;
    await showFileSavedDialog(
      context,
      // Saved on this computer: nothing is left to send it to (the phone's
      // words go on to its share sheet).
      title: l10n.sshConfigSavedTitle(connections.length),
      message: l10n.sshConfigSavedBody,
      path: file.path,
    );
  } catch (e) {
    if (context.mounted) showTopSnackBar(context, l10n.sshConfigNotSaved, isError: true, details: '$e');
  }
}

/// Where the save dialog opens: Downloads, else Documents, else wherever the
/// system starts it. Only a convenience, so a system that cannot say ends
/// nothing (the export failed when Downloads could not be found).
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
