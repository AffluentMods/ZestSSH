/// Pure, dependency-free parser for the OSC shell-integration sequences that
/// enrich command history (Phase 2b): exit code + duration from OSC 133 semantic
/// prompts, and the working directory from OSC 7 or iTerm2's
/// OSC 1337;CurrentDir= (4.0: the SFTP dock follows it too).
///
/// ZestSSH has no shell integration of its own, so these values only appear when
/// the REMOTE shell is configured to emit them (starship, iTerm2/FinalTerm shell
/// hooks, `vte`'s `__vte_prompt_command`, etc.). Plain shells emit nothing, in
/// which case this parser produces no events and the history UI shows "Not
/// recorded" - by design, never a guess.
///
/// The parser is a passive OBSERVER of the raw stdout stream: it never consumes,
/// rewrites or holds up the bytes the terminal renders. It only scans for
/// `ESC ] 133 ; ... (BEL|ST)` and `ESC ] 7 ; ...` (or `ESC ] 1337 ; CurrentDir=...`, BEL or ST) and turns them into
/// typed [ShellIntegrationEvent]s. Sequences split across stdout chunks are
/// carried across [addOutput] calls.
library;

sealed class ShellIntegrationEvent {
  const ShellIntegrationEvent();
}

/// `OSC 133 ; A` - a new prompt is being drawn.
class OscPromptStart extends ShellIntegrationEvent {
  const OscPromptStart();
}

/// `OSC 133 ; C` - the command has started executing (output begins). Used as
/// the duration start when present.
class OscCommandStart extends ShellIntegrationEvent {
  const OscCommandStart();
}

/// `OSC 133 ; D [ ; <exitCode> ]` - the command finished. [exitCode] is null
/// when the shell reported completion without a status.
class OscCommandEnd extends ShellIntegrationEvent {
  const OscCommandEnd(this.exitCode);
  final int? exitCode;
}

/// `OSC 7 ; file://<host>/<path>` or `OSC 1337 ; CurrentDir=<path>` - the
/// shell's current working directory.
class OscCwd extends ShellIntegrationEvent {
  const OscCwd(this.path);
  final String path;
}

/// Incremental scanner over one session's stdout for OSC 133 / OSC 7 / OSC 1337;CurrentDir.
class ShellIntegrationParser {
  String _carry = '';

  static const int _osc = 0x5d; // ']'

  /// A working directory is untrusted server output written to the local DB and
  /// shown in the reader: cap its length and strip control bytes.
  static const int _maxCwd = 4096;
  // C0 and C1 controls, and what makes a path read otherwise than it is: the
  // direction marks and overrides, and characters that take no room. The
  // folder is kept in the command history, which syncs, and is shown there
  // (found in a security review).
  static final RegExp _controlChars = RegExp(
      r'[\x00-\x1f\x7f-\x9f\u061c\u200b\u200e\u200f\u202a-\u202e\u2060\u2066-\u2069\ufeff]');

  /// A hard cap on a buffered, unterminated OSC sequence, so a stray `ESC ]`
  /// in binary output can never make the carry grow without bound.
  static const int _maxCarry = 8192;

  /// Feed a decoded stdout chunk; returns the shell-integration events it
  /// completed. Cheap: a chunk with no `ESC ]` allocates nothing beyond the scan.
  List<ShellIntegrationEvent> addOutput(String chunk) {
    final events = <ShellIntegrationEvent>[];
    final s = _carry.isEmpty ? chunk : (_carry + chunk);
    _carry = '';
    var i = 0;
    while (i < s.length) {
      final esc = s.indexOf('\x1b', i);
      if (esc == -1) break;
      if (esc + 1 >= s.length) {
        _carry = s.substring(esc); // lone trailing ESC: might begin an OSC
        break;
      }
      if (s.codeUnitAt(esc + 1) != _osc) {
        i = esc + 1; // some other escape (CSI etc.); keep scanning
        continue;
      }
      // OSC starts at [esc]. Find the terminator (BEL, or ST = ESC backslash) in
      // a SINGLE forward scan bounded by _maxCarry. Computing indexOf for both
      // terminators every iteration would rescan to end-of-string on a stream of
      // unterminated OSC starts (a malicious server controls stdout), making this
      // quadratic; the bound also caps the work per sequence. OSC 133/7 payloads
      // are short, so anything longer than the cap is not a real sequence.
      final limit =
          (esc + 2 + _maxCarry) < s.length ? esc + 2 + _maxCarry : s.length;
      var k = esc + 2;
      int termIdx = -1;
      int termLen = 0;
      while (k < limit) {
        final ch = s.codeUnitAt(k);
        if (ch == 0x07 /* BEL */) {
          termIdx = k;
          termLen = 1;
          break;
        }
        if (ch == 0x1b /* ESC */ &&
            k + 1 < s.length &&
            s.codeUnitAt(k + 1) == 0x5c /* backslash */) {
          termIdx = k;
          termLen = 2;
          break;
        }
        k++;
      }
      if (termIdx != -1) {
        _emit(s.substring(esc + 2, termIdx), events);
        i = termIdx + termLen;
      } else if (k >= s.length) {
        _carry = s.substring(esc); // genuine split at chunk end: carry it
        break;
      } else {
        i = k; // hit the cap with no terminator: not a real OSC, skip past it
      }
    }
    return events;
  }

  void _emit(String payload, List<ShellIntegrationEvent> out) {
    if (payload.startsWith('133;')) {
      final rest = payload.substring(4);
      if (rest.startsWith('A')) {
        out.add(const OscPromptStart());
      } else if (rest.startsWith('C')) {
        out.add(const OscCommandStart());
      } else if (rest.startsWith('D')) {
        int? code;
        final semi = rest.indexOf(';');
        if (semi != -1) {
          // "D;<code>" or "D;<code>;<extra>" - take the first field.
          code = int.tryParse(rest.substring(semi + 1).split(';').first.trim());
        }
        out.add(OscCommandEnd(code));
      }
      // "133;B" (end of prompt / start of command line) is not needed: the
      // command text itself is reconstructed by CommandCapture, not from OSC.
    } else if (payload.startsWith('7;')) {
      final path = _cwdFromFileUri(payload.substring(2));
      if (path != null) out.add(OscCwd(path));
    } else if (payload.startsWith(_iterm2CurrentDir)) {
      // iTerm2's own way of saying the folder (its shell integration, and
      // tools that copy it): the path as it is, not a URI.
      final path = _cleanCwd(payload.substring(_iterm2CurrentDir.length));
      if (path != null) out.add(OscCwd(path));
    }
  }

  static const _iterm2CurrentDir = '1337;CurrentDir=';

  /// A Windows host's folder: a drive and a slash either way.
  static final RegExp _windowsRoot = RegExp(r'^[A-Za-z]:[\\/]');

  /// `file://host/path/to/dir` -> `/path/to/dir` (percent-decoded). Returns null
  /// for anything that is not a file URI with a path.
  static String? _cwdFromFileUri(String uri) {
    if (!uri.startsWith('file://')) return null;
    final afterScheme = uri.substring('file://'.length);
    final slash = afterScheme.indexOf('/'); // skip the host segment
    if (slash == -1) return null;
    var path = afterScheme.substring(slash);
    try {
      path = Uri.decodeFull(path);
    } catch (_) {
      // Leave the raw path if it is not valid percent-encoding.
    }
    // Strip control bytes (decodeFull can re-introduce %00/%1b from a crafted
    // URI) and cap the length before it reaches the DB / UI.
    return _cleanCwd(path);
  }

  /// [path] without control bytes or what makes it read otherwise than it is,
  /// cut to [_maxCwd]; null when nothing of it is left, or when it is no
  /// absolute folder (a POSIX one, or a Windows host's `C:/...` or `C:\...`).
  static String? _cleanCwd(String path) {
    path = path.replaceAll(_controlChars, '');
    if (path.length > _maxCwd) path = path.substring(0, _maxCwd);
    if (path.isEmpty) return null;
    final absolute = path.startsWith('/') || _windowsRoot.hasMatch(path);
    return absolute ? path : null;
  }

  /// Drop any buffered partial sequence (e.g. when the session closes).
  void reset() => _carry = '';
}
