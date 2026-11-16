import 'dart:io';

import 'package:zest_ssh_core/zest_ssh_core.dart';
import 'package:zestssh/ui/screens/sftp/widgets/pane_file_source.dart';

/// Why a remembered folder could not be opened as-is.
enum RememberedFailure {
  /// The stored path is gone (or a parent of it is).
  gone,

  /// It exists but this account cannot list it.
  noAccess,
}

/// What [resolveRemembered] landed on.
class RememberedResolution {
  const RememberedResolution({
    required this.requested,
    required this.path,
    required this.climbed,
    this.failure,
  });

  /// The stored path we started from.
  final String requested;

  /// The listable directory to open, or null when nothing up to [maxClimb]
  /// levels above the stored path could be listed (caller opens home).
  final String? path;

  /// How many levels above [requested] [path] is (0 = exact).
  final int climbed;

  /// Why [requested] itself was not usable; null when it was.
  final RememberedFailure? failure;

  bool get exact => path != null && climbed == 0;
  bool get unreachable => path == null;
}

/// Resolve a remembered directory against a live source (remember-last-
/// folder spec, section 3): try it, then walk UP to the nearest existing
/// listable ancestor, at most [maxClimb] climbs (so at most `maxClimb + 1`
/// round trips), else give up. Never throws.
///
/// Each probe is a listing, not a stat: a listing IS the test that matters
/// (the pane is about to list it), it proves existence and readability in
/// one round trip, and the error it raises says which of the two failed.
Future<RememberedResolution> resolveRemembered(
  PaneFileSource source,
  String stored, {
  int maxClimb = 4,
}) async {
  var candidate = stored;
  RememberedFailure? firstFailure;
  for (var climbs = 0; climbs <= maxClimb; climbs++) {
    try {
      await source.list(candidate, includeHidden: true);
      return RememberedResolution(
        requested: stored,
        path: candidate,
        climbed: climbs,
        failure: firstFailure,
      );
    } catch (e) {
      firstFailure ??= classifyListFailure(e);
    }
    final parent = source.parentOf(candidate);
    if (parent == candidate || parent.isEmpty) break;
    candidate = parent;
  }
  return RememberedResolution(
    requested: stored,
    path: null,
    climbed: 0,
    failure: firstFailure ?? RememberedFailure.gone,
  );
}

/// Map a listing error to gone / no-access. Anything unrecognised counts as
/// gone: the honest reading of "we could not open it".
RememberedFailure classifyListFailure(Object e) {
  if (e is SftpStatusError) {
    return e.code == SftpStatusCode.permissionDenied
        ? RememberedFailure.noAccess
        : RememberedFailure.gone;
  }
  if (e is FileSystemException) {
    final code = e.osError?.errorCode;
    // EACCES (13) / EPERM (1) on POSIX; ERROR_ACCESS_DENIED (5) on Windows.
    if (code == 13 || code == 1 || (Platform.isWindows && code == 5)) {
      return RememberedFailure.noAccess;
    }
    final msg = e.message.toLowerCase();
    if (msg.contains('permission') || msg.contains('access')) {
      return RememberedFailure.noAccess;
    }
  }
  return RememberedFailure.gone;
}

/// A folder worth trying when a pane opens: the host default, marked as a
/// mere [suggestion] when it was seen under a different username (spec 2:
/// try it, fall back quietly, no notice).
class RememberedCandidate {
  const RememberedCandidate(this.path, {this.suggestion = false});
  final String path;
  final bool suggestion;
}
