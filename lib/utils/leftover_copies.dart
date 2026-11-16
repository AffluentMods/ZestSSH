import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:path/path.dart' as p;
import 'package:zestssh/utils/logger.dart';

/// Removes what the app left in this device's temporary folder where it was
/// ended in the middle of something, and says how many folders that was.
///
/// What the app puts there is removed once it is done with, and stayed for
/// good where the app was ended before that (it crashed, was ended from
/// outside, or the device lost its power):
///
/// - `zestssh_mosh_...`, holding `id_key`: the private key a Mosh or an
///   Eternal Terminal session signs in with, in the clear, kept while the
///   session lasts;
/// - `zest_sftp_xfer_...`, holding `xfer.bin`, and `zest_sftp_bridge_...`,
///   holding `bridge.bin`: a copy, in the clear, of a file being copied from
///   a host to another folder of it or to another host;
/// - from versions before 3.0, `zest_read_...` and `zest_write_...`, holding
///   `data.bin`: a copy, in the clear, of a file a file pane on a host read
///   for the editor, or an image to show, or saved. Nothing makes them any
///   more.
///
/// A copy still being fetched from a host stands as its `.zestpart`, with a
/// `.zestpart.meta` beside it.
///
/// Only what the app made is removed: a folder of one of those names,
/// straight in the temporary folder, that holds nothing but the files the
/// app puts there; and, of the kinds the app makes now, only one in which
/// nothing has changed for an hour ([leftoverAfter]), since the app may be
/// running a second time and using it (on Windows, a link that opens the app
/// starts it again). Anything else that bears the name is left alone, and so
/// is one that cannot be removed. Never throws. [now] is for tests.
Future<int> clearLeftoverCopies({@visibleForTesting DateTime? now}) async {
  final changedBefore = (now ?? DateTime.now()).subtract(leftoverAfter);
  var cleared = 0;
  try {
    await for (final entry in Directory.systemTemp.list(followLinks: false)) {
      if (entry is! Directory) continue;
      final name = p.basename(entry.path);
      final kind = _made.where((made) => name.startsWith(made.prefix)).firstOrNull;
      if (kind == null) continue;
      try {
        final inside = await entry.list(followLinks: false).toList();
        if (inside.any((held) => held is! File || !kind.files.contains(p.basename(held.path)))) continue;
        if (!kind.anyAge) {
          final changed = [for (final item in [entry, ...inside]) (await item.stat()).modified];
          if (changed.any((at) => !at.isBefore(changedBefore))) continue;
        }
        await entry.delete(recursive: true);
        cleared++;
      } catch (_) {
        // In use, or another account's: left where it is.
      }
    }
  } catch (_) {
    // A temporary folder that cannot be listed: there is nothing to do.
  }
  if (cleared > 0) AppLogger.info('Removed $cleared folders the app had left in the temporary folder');
  return cleared;
}

/// How long nothing in a folder the app makes now has changed before it is
/// taken to be left over ([clearLeftoverCopies]).
const leftoverAfter = Duration(hours: 1);

/// The folders the app makes in the temporary folder: what their names start
/// with, the files they hold, and whether one is removed whatever its age
/// (what nothing makes any more).
final _made = [
  (prefix: 'zest_read_', files: _fetched('data.bin'), anyAge: true),
  (prefix: 'zest_write_', files: _fetched('data.bin'), anyAge: true),
  (prefix: 'zestssh_mosh_', files: {'id_key'}, anyAge: false),
  (prefix: 'zest_sftp_xfer_', files: _fetched('xfer.bin'), anyAge: false),
  (prefix: 'zest_sftp_bridge_', files: _fetched('bridge.bin'), anyAge: false),
];

/// [file], and what stands in its place while it is fetched from a host.
Set<String> _fetched(String file) => {file, '$file.zestpart', '$file.zestpart.meta'};

/// Removes the copies the file picker made of files picked on a phone, to be
/// imported (a key, a backup, a shared host, snippets): it copies each one
/// into the app's own folders to be read from there (on Android into
/// `file_picker/` in the app's cache folder; on an iPhone into the app's
/// temporary folder, all of which it empties), and they stayed until the
/// system wanted the room. Run at start-up, when no file is being picked.
/// Never throws. [phone] is for tests.
Future<void> clearPickedCopies({@visibleForTesting bool? phone}) async {
  if (!(phone ?? (Platform.isAndroid || Platform.isIOS))) return;
  try {
    await FilePicker.platform.clearTemporaryFiles();
  } catch (_) {
    // A picker that cannot clear them: they stay, as they did.
  }
}
