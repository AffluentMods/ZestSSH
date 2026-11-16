import 'package:zestssh/ui/screens/sftp/widgets/overwrite_conflict_dialog.dart' show uniqueRenameFor;

/// The destination paths one drop (one transfer of files and folders between
/// the two panes) has given out, so that no two of its files are written to
/// one place.
///
/// Two names of the source can come to one name at the destination: a
/// server's `a:b` and `a_b` on Windows, `x` and `x.`, a name with a control
/// character and the same without it (safeChildName), and plain `Makefile`
/// and `makefile` where the destination's disk takes them for one name. The
/// files of a drop are written three at a time, so the first is not on the
/// disk yet when the second is looked at, and inside a folder the drop itself
/// just made nothing was looked at: the second replaced the first with no
/// question, and both wrote to one part file at once (found in a security
/// audit). The phone's batch download keeps such a set too.
///
/// A second claim of a path keeps both: it gets a name of its own, as "Keep
/// both" gives one, that neither the drop has given out nor the destination
/// holds.
class DropDestinationNames {
  /// [caseInsensitive]: the destination takes `A` and `a` for one name (this
  /// computer's disk on Windows and macOS).
  DropDestinationNames({required this.caseInsensitive});

  final bool caseInsensitive;
  final _taken = <String>{};

  String _key(String path) => caseInsensitive ? path.toLowerCase() : path;

  /// Whether this drop has given [path] out already.
  bool isTaken(String path) => _taken.contains(_key(path));

  /// Claims a place for [name] in [dir] and answers with the name to write
  /// to: [name] itself where the drop has not given it out, otherwise (or
  /// with [keepBoth], the person's answer for a file the destination holds)
  /// one of its own. [join] makes a path of the destination; [exists] asks
  /// the destination whether it holds one.
  Future<String> claim(
    String dir,
    String name, {
    required String Function(String dir, String name) join,
    required Future<bool> Function(String path) exists,
    bool keepBoth = false,
  }) async {
    var claimed = name;
    if (keepBoth || isTaken(join(dir, name))) {
      claimed = await uniqueRenameFor(
        name,
        exists: (candidate) async {
          final path = join(dir, candidate);
          return isTaken(path) || await exists(path);
        },
      );
    }
    _taken.add(_key(join(dir, claimed)));
    return claimed;
  }
}
