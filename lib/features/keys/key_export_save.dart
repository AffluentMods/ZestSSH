// Exporting a key on a computer: the files are saved where the person
// says in the system's save dialog, as every other export of a computer is (a
// host's file, the SSH config, the recovery kit). It went through the share
// sheet, a phone's way: on Linux the share plugin throws for files, so no key
// could be exported at all; on Windows the Share window opens and the call
// returns at once, and the files, written to a folder of temporary files, were
// deleted under it.
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Asks where a file named [fileName] goes: the path chosen, or null where the
/// person cancelled. The app's is [pickKeyFileWithSaveDialog].
typedef KeySavePicker = Future<String?> Function({required String title, required String fileName});

/// The system's save dialog, opened in Downloads (else Documents, else where
/// the system starts it), as a host's file is saved.
Future<String?> pickKeyFileWithSaveDialog({required String title, required String fileName}) async {
  String? start;
  try {
    start = (await getDownloadsDirectory())?.path;
  } catch (_) {}
  if (start == null) {
    try {
      start = (await getApplicationDocumentsDirectory()).path;
    } catch (_) {}
  }
  return FilePicker.platform.saveFile(
    dialogTitle: title,
    fileName: fileName,
    initialDirectory: start,
    lockParentWindow: true,
  );
}

/// Whether [name] is a private key's file: every exported file but the public
/// key's (`.pub`).
bool isPrivateKeyFileName(String name) => !name.toLowerCase().endsWith('.pub');

/// Saves exported key [files] (each a name and what it holds, the first the
/// one the person is asked about) on a computer: [pick] asks where the first
/// goes, and every other is written beside it. A public key exported with its
/// private key is named after the path chosen (`id_ed25519` and
/// `id_ed25519.pub`, as `ssh-keygen` names them), whatever the person called
/// the file. A file beside the first is never written over one that is there:
/// it takes a free name ("name (2).pub").
///
/// A private key's file is kept to its person where the system has file
/// modes (0600 on Linux and macOS, as `ssh` wants it): [restrict] does that,
/// [keepToOwner] in the app.
///
/// Returns the paths written, the first first; null where the person
/// cancelled, with nothing written. Throws what writing threw; a file half
/// written is then removed.
Future<List<String>?> saveKeyFilesOnComputer(
  Map<String, List<int>> files, {
  required KeySavePicker pick,
  required String title,
  Future<void> Function(String path) restrict = keepToOwner,
}) async {
  assert(files.isNotEmpty);
  final first = files.keys.first;
  final chosen = await pick(title: title, fileName: first);
  if (chosen == null || chosen.isEmpty) return null;
  final written = <String>[];
  try {
    for (final MapEntry(key: name, value: bytes) in files.entries) {
      final String path;
      if (name == first) {
        path = chosen;
      } else {
        // Beside the first: named after it where it is its public key.
        final wanted = name == '$first.pub' ? '$chosen.pub' : p.join(p.dirname(chosen), name);
        path = await _freeName(wanted);
      }
      final file = File(path);
      written.add(path);
      if (isPrivateKeyFileName(name)) {
        // Made empty and kept to its person before the key is in it.
        await file.writeAsBytes(const [], flush: true);
        await restrict(path);
      }
      await file.writeAsBytes(bytes, flush: true);
    }
    return written;
  } catch (_) {
    for (final path in written) {
      try {
        await File(path).delete();
      } catch (_) {}
    }
    rethrow;
  }
}

/// [path], or the first of "name (2).ext", "name (3).ext"... that no file has.
Future<String> _freeName(String path) async {
  if (!await File(path).exists()) return path;
  final dir = p.dirname(path);
  final ext = p.extension(path);
  final base = p.basenameWithoutExtension(path);
  for (var n = 2;; n++) {
    final next = p.join(dir, '$base ($n)$ext');
    if (!await File(next).exists()) return next;
  }
}

/// Keeps the file at [path] to the account that owns it (0600) on Linux and
/// macOS; on Windows a file in the person's folders is theirs already. Never
/// throws: a file system with no modes keeps the file as it is.
Future<void> keepToOwner(String path) async {
  if (!(Platform.isLinux || Platform.isMacOS)) return;
  try {
    await Process.run('chmod', ['600', path]);
  } catch (_) {}
}
