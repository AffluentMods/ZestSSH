import 'package:zestssh/database/daos/connections_dao.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/utils/command_text.dart';

/// What inline autocomplete offers besides history (3.2):
/// saved snippets, saved hosts after
/// `ssh`, and files and folders on the host. Each gives the whole line with
/// the rest added, or null; nothing here sends anything or leaves the
/// device but a folder's listing asked of the host itself.

/// A saved snippet whose command starts with [typed] (and is longer), the
/// shortest first; snippets that ask for values (`{{name}}`) are left out,
/// since their words would be typed as they are.
String? completeFromSnippets(String typed, Iterable<Snippet> snippets) {
  if (typed.trim().isEmpty) return null;
  String? best;
  for (final s in snippets) {
    final command = s.command;
    if (command.contains('\n') || command.contains('{{')) continue;
    if (command.length <= typed.length || !command.startsWith(typed)) continue;
    if (best == null || command.length < best.length) best = command;
  }
  return best;
}

/// After `ssh `, a saved host as the command reaches it: `user@host` (the
/// user from its key, when it has one) or the host alone, with `-p port`
/// when it is not 22, whichever starts with what is typed after `ssh `.
/// Hosts in order of their last connection, newest first.
String? completeSshTarget(String typed, Iterable<ConnectionWithDetails> hosts) {
  const lead = 'ssh ';
  if (!typed.startsWith(lead)) return null;
  final rest = typed.substring(lead.length);
  if (rest.isEmpty || rest.contains(' ')) return null;
  final ordered = hosts.toList()
    ..sort((a, b) => (b.connection.lastConnected ?? DateTime(0)).compareTo(a.connection.lastConnected ?? DateTime(0)));
  for (final h in ordered) {
    final c = h.connection;
    if (c.protocol != 'ssh' || c.host.isEmpty) continue;
    final port = c.port == 22 ? '' : ' -p ${c.port}';
    final user = h.identity?.username;
    for (final target in [
      if (user != null && user.isNotEmpty) '$user@${c.host}$port',
      '${c.host}$port',
    ]) {
      // (A host or a user a shell would read as more than a name is no target:
      // a saved host can come from an import.)
      if (target.length > rest.length && target.startsWith(rest) && _plainSshTarget.hasMatch(target)) return '$lead$target';
    }
  }
  return null;
}

/// `user@host` or `host`, with a port or not, as nothing but that to a shell.
final _plainSshTarget = RegExp(r'^[\w.\-%:\[\]@+]+(?: -p \d+)?$');

/// The last word of [typed] when it is a path on the host this can list: one
/// starting with `/` or `~/` (a relative one would need the shell's folder).
/// Gives the folder to list, as SFTP names it (`~/` is its own folder, `.`),
/// and the start of the name being typed in it.
({String folder, String start, int at})? pathBeingTyped(String typed) {
  if (typed.isEmpty || typed.endsWith(' ')) return null;
  final at = typed.lastIndexOf(' ') + 1;
  final word = typed.substring(at);
  if (word.contains('"') || word.contains("'") || word.contains(r'\')) return null;
  final String path;
  if (word.startsWith('/')) {
    path = word;
  } else if (word.startsWith('~/')) {
    path = word.substring(2);
  } else {
    return null;
  }
  final slash = path.lastIndexOf('/');
  final folder = slash < 0 ? '.' : (slash == 0 ? '/' : path.substring(0, slash));
  return (folder: folder, start: path.substring(slash + 1), at: at);
}

/// The rest of the name being typed in [typed], from what its folder holds
/// ([names]: name, and whether it is a folder): the one name that starts
/// with it, a folder's with `/` after it; where several do, what they share.
/// Hidden names only once a `.` is typed.
///
/// The names are the server's to choose, and what this gives is typed as keys.
/// One with a control character in it is not offered at all
/// ([CommandText.mayBeTyped]). In any other, what a shell would act on is
/// escaped with a backslash, as a shell's own completion does: a name with a
/// space in it comes out as one word, and `$(id)` or `;cmd;` after spaces
/// enough to hide them is a part of a name when Enter comes.
String? completePath(String typed, List<(String name, bool folder)> names) {
  final p = pathBeingTyped(typed);
  if (p == null) return null;
  final start = p.start;
  final fit = [
    for (final n in names)
      if (n.$1.startsWith(start) &&
          n.$1 != '.' &&
          n.$1 != '..' &&
          (start.startsWith('.') || !n.$1.startsWith('.')) &&
          CommandText.mayBeTyped(n.$1))
        n,
  ];
  if (fit.isEmpty) return null;
  String rest;
  if (fit.length == 1) {
    rest = fit.single.$1.substring(start.length) + (fit.single.$2 ? '/' : '');
  } else {
    var shared = fit.first.$1;
    for (final n in fit.skip(1)) {
      var i = 0;
      while (i < shared.length && i < n.$1.length && shared[i] == n.$1[i]) {
        i++;
      }
      shared = shared.substring(0, i);
    }
    rest = shared.substring(start.length);
  }
  return rest.isEmpty ? null : '$typed${_shellEscaped(rest)}';
}

/// [text] with a backslash before each character a POSIX shell, fish or zsh
/// would act on in the middle of a word.
String _shellEscaped(String text) => text.replaceAllMapped(_shellActsOn, (m) => '\\${m[0]}');

final _shellActsOn = RegExp(r'''[\s\\'"`$&;|<>()*?\[\]{}!#~^]''');
