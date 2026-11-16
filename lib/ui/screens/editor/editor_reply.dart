import 'dart:convert';

import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart' show EditorBridge;
import 'package:zestssh/utils/type_name.dart';

/// A save or a reload of a popped-out editor that failed in the main window,
/// which owns the file's connection: what was said there, in the app's
/// language ([said]), and what was thrown ([thrown]), for the report.
class EditorFailure implements Exception, HasTypeName {
  const EditorFailure(this.said, this.thrown);

  final String said;
  final String thrown;

  @override
  String toString() => thrown;

  @override
  String get typeName => 'EditorFailure';
}

/// Why a save or a reload of [name] failed, [error] being what was thrown,
/// in the app's language: as the main window said it for a popped-out
/// editor, text that is not UTF-8 any more as such, else from [error].
String editorFailureSaid(Object error, {String? name, required SftpOp op}) {
  if (error is EditorFailure) return error.said;
  if (error is FormatException && op == SftpOp.download && name != null) return gl10n.sftpNotUtf8(name);
  return sftpErrorMessage(error, name: name, op: op);
}

/// What the main window answers a popped-out editor's save or reload with,
/// and how the editor reads it. (3.0: a failed save came back as
/// "error: " and the raw error, a read-only file as the English "read-only";
/// a failed reload came back as nothing, so it failed without a word, and
/// so did the reload of an empty file.)
abstract final class EditorReply {
  /// A save that worked.
  static String saved() => jsonEncode(const {'ok': true});

  /// What a reload read: [content], empty or not.
  static String content(String content) => jsonEncode({'content': content});

  /// A save or a reload that failed: [said] in the app's language, [raw]
  /// what was thrown.
  static String failed(String said, Object raw) => jsonEncode({'said': said, 'raw': '$raw'});

  /// The main window saves [content] through [bridge] (null when the editor
  /// is not known any more) and answers.
  static Future<String> answerSave(EditorBridge? bridge, String content) async {
    if (bridge == null || !bridge.canSave) return failed(gl10n.editorReadOnly, 'The file has no way to be saved');
    try {
      await bridge.save(content);
      return saved();
    } catch (e) {
      return failed(editorFailureSaid(e, name: bridge.fileName, op: SftpOp.upload), e);
    }
  }

  /// The main window reads the file again through [bridge] and answers.
  static Future<String> answerReload(EditorBridge? bridge) async {
    if (bridge == null || !bridge.canReload) return failed(gl10n.sftpErrOperationFailed, 'The file has no way to be read again');
    try {
      return content(await bridge.reload());
    } on StateError catch (e) {
      // Nothing was read (the file's text comes through callbacks that gave
      // none).
      return failed(gl10n.sftpErrOperationFailed, e.message);
    } catch (e) {
      return failed(editorFailureSaid(e, name: bridge.fileName, op: SftpOp.download), e);
    }
  }

  /// Reads the answer to a save: returns when it saved, else throws
  /// [EditorFailure].
  static void readSave(Object? reply) {
    final map = _map(reply);
    if (map['ok'] == true) return;
    throw _failure(map, reply);
  }

  /// Reads the answer to a reload: what it read, else throws
  /// [EditorFailure].
  static String readReload(Object? reply) {
    final map = _map(reply);
    final content = map['content'];
    if (content is String) return content;
    throw _failure(map, reply);
  }

  static Map<String, dynamic> _map(Object? reply) {
    if (reply is! String) return const {};
    try {
      final decoded = jsonDecode(reply);
      return decoded is Map<String, dynamic> ? decoded : const {};
    } on FormatException {
      return const {};
    }
  }

  static EditorFailure _failure(Map<String, dynamic> map, Object? reply) {
    final said = map['said'];
    final raw = map['raw'];
    if (said is String && said.isNotEmpty) {
      return EditorFailure(said, raw is String ? raw : '');
    }
    // (No answer that says why: the main window did not answer as it does.)
    return EditorFailure(gl10n.sftpErrOperationFailed, 'Unexpected answer from the main window: $reply');
  }
}
