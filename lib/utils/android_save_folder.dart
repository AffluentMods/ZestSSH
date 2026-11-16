import 'dart:io';

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path_provider/path_provider.dart';

/// The shared Download folder of an Android device.
const androidDownloadFolder = '/storage/emulated/0/Download';

/// Where an Android phone saves what the person asked for (a backup, a file
/// fetched from a host), found 16 October 2026 while comparing the five
/// versions: the shared Download folder ([androidDownloadFolder]) where
/// Android lets the app write there (Android 11 and later), else the app's own
/// folder on the shared storage (`Android/data/<app>/files`), which needs no
/// permission and which a file manager shows on Android 8 to 10: there the
/// Download folder takes a permission the app does not ask for, and every
/// backup and download to it failed. Whether the app may write there is
/// tried, with a file it removes at once. [shared], [own] and [documents] are
/// for tests.
Future<Directory> androidSaveFolder({
  @visibleForTesting Directory? shared,
  @visibleForTesting Future<Directory?> Function()? own,
  @visibleForTesting Future<Directory> Function()? documents,
}) async {
  final download = shared ?? Directory(androidDownloadFolder);
  if (await _mayWriteIn(download)) return download;
  try {
    final mine = await (own ?? getExternalStorageDirectory)();
    if (mine != null) return mine;
  } catch (_) {
    // No shared storage at all: the app's own documents, below.
  }
  return (documents ?? getApplicationDocumentsDirectory)();
}

/// A test's stand-in for the system [downloadSaveFolder] chooses for, named
/// as [Platform.operatingSystem] names it ('ios', 'macos', ...). Null in the
/// app.
@visibleForTesting
String? debugDownloadSaveSystem;

/// The system [downloadSaveFolder] chooses for.
String get downloadSaveSystem => debugDownloadSaveSystem ?? Platform.operatingSystem;

/// Whether [downloadSaveFolder] is the app's Documents on an iPhone or an
/// iPad, which the Files app shows as the ZestSSH folder: a message names
/// it so, since the device shows no path.
bool get downloadsGoToIosFiles => downloadSaveSystem == 'ios';

/// Where the file browser's plain Download saves a file on this device
/// ([os] is Platform.operatingSystem; the rest are for tests): on Android
/// [androidSaveFolder]; on an iPhone or iPad the app's Documents, which the
/// Files app shows (the app declares file sharing); on a computer the
/// system's Downloads folder, or the app's documents where there is none.
/// The folder is made when it is not there.
///
/// On iOS getDownloadsDirectory is never null: it names
/// `<container>/Downloads`, a folder the system does not make and Files does
/// not show, so the Documents fallback never ran and a plain Download went
/// nowhere a person could find it, or failed on the missing folder.
/// Only "Download and share" worked.
Future<Directory> downloadSaveFolder({
  @visibleForTesting String? os,
  @visibleForTesting Future<Directory> Function()? android,
  @visibleForTesting Future<Directory?> Function()? downloads,
  @visibleForTesting Future<Directory> Function()? documents,
}) async {
  final system = os ?? downloadSaveSystem;
  if (system == 'android') return (android ?? androidSaveFolder)();
  final Directory folder;
  if (system == 'ios') {
    folder = await (documents ?? getApplicationDocumentsDirectory)();
  } else {
    folder = await (downloads ?? getDownloadsDirectory)() ?? await (documents ?? getApplicationDocumentsDirectory)();
  }
  if (!await folder.exists()) await folder.create(recursive: true);
  return folder;
}

/// Whether a file can be made in [folder]: one is, and removed.
Future<bool> _mayWriteIn(Directory folder) async {
  final probe = File('${folder.path}/.zestssh-may-write-${DateTime.now().microsecondsSinceEpoch}');
  try {
    if (!await folder.exists()) return false;
    await probe.writeAsString('');
    return true;
  } catch (_) {
    return false;
  } finally {
    try {
      if (await probe.exists()) await probe.delete();
    } catch (_) {}
  }
}
