// "Open an X program in a screen tab" (4.0): the host script, and the
// one line that runs it over SSH.
//
// One exec channel runs a small POSIX sh script on the person's SSH host. It
// starts a private TigerVNC Xvnc there (a display it picks itself, no TCP for
// VNC or for X, its VNC socket in a fresh 0700 folder; VNC security None, since
// the folder is the lock, as for the account's own X socket; the X display
// takes only clients with a fresh MIT-MAGIC-COOKIE-1 kept in that folder,
// since Linux's abstract X socket has no file permissions), runs the chosen
// program on it, and prints one line, `ZSX {"socket":...,"display":N}`. The
// app then opens a direct-streamlocal channel to that socket on the same SSH
// connection. The script ends, and takes the program, the Xvnc and the folder
// with it, when the program exits or when the app closes the channel (its
// stdin ends), whichever comes first; a run that was killed is cleared by the
// next one. It never runs sudo and installs nothing: where Xvnc or xauth is
// missing it says which package manager the host has, and the app shows the
// install command for the person to run.
//
// The line the login shell reads holds only fixed text: the script and the
// program travel as printf formats in which every byte but a few plain ones is
// an octal escape ([printfFormatOf]), so no quote, newline, `$`, backtick or
// `!` of either reaches bash, dash, zsh, fish or tcsh, and the program reaches
// the script as data ($2), never spliced into its text.
import 'dart:convert';

/// The script, run as `sh -c 'eval "$(printf "$1")"' zestssh-x SCRIPT
/// PROGRAM WIDTH HEIGHT` ([xProgramCommand]): $1 itself, $2 the
/// program (a shell command line, as printf formats both), $3 and $4 the
/// size. Prints `ZSX {...}` lines ([XProgramLine]).
const xProgramScript = r'''
  set -u
  umask 077
  fail() { printf 'ZSX {"error":"%s"}\n' "$1"; exit 1; }
  missing() {
    pm=
    for m in apt-get dnf yum pacman zypper; do
      if command -v "$m" >/dev/null 2>&1; then pm=$m; break; fi
    done
    printf 'ZSX {"error":"%s","pm":"%s"}\n' "$1" "$pm"
    exit 1
  }
  command -v Xvnc >/dev/null 2>&1 || missing no-xvnc
  command -v xauth >/dev/null 2>&1 || missing no-xauth
  prog=$(printf "$2")
  W=$3 H=$4
  case $W$H in ''|*[!0-9]*) fail bad-size ;; esac
  t=${TMPDIR:-/tmp}
  case $t in *[\"\\]*) t=/tmp ;; esac
  # Whether ps can tell this script by its name (procps, BSD ps).
  psok=
  ps -p $$ -o args= 2>/dev/null | grep -q zestssh-x && psok=1
  # What a run that was killed left (its script gone): its folder, and its
  # Xvnc. Only real folders of this account; only where ps can tell, so a live
  # run's folder is never taken.
  if [ -n "$psok" ]; then
    for f in "$t"/zestssh-x.*; do
      [ -d "$f" ] && [ ! -L "$f" ] && [ -O "$f" ] || continue
      p=$(cat "$f/pid" 2>/dev/null) || p=
      case $p in
        ''|*[!0-9]*)
          [ -n "$(find "$f" -prune -mmin +10 2>/dev/null)" ] && rm -rf "$f"
          continue ;;
      esac
      ps -p "$p" -o args= 2>/dev/null | grep -q zestssh-x && continue
      x=$(cat "$f/xvnc.pid" 2>/dev/null) || x=
      case $x in
        ''|*[!0-9]*) ;;
        *) [ "$(ps -p "$x" -o comm= 2>/dev/null)" = Xvnc ] && kill "$x" 2>/dev/null ;;
      esac
      rm -rf "$f"
    done
  fi
  d=$(mktemp -d "$t/zestssh-x.XXXXXXXX") || fail no-tmp
  printf '%s\n' "$$" >"$d/pid"
  xv= app= w=
  cleanup() {
    [ -n "$app" ] && kill "$app" 2>/dev/null
    [ -n "$xv" ] && kill "$xv" 2>/dev/null
    [ -n "$w" ] && kill "$w" 2>/dev/null
    [ -n "$xv" ] && wait "$xv" 2>/dev/null
    rm -rf "$d"
  }
  trap cleanup EXIT
  trap 'exit 0' HUP INT TERM
  # $1: more X server options. 0 when it is up, 1 when it stopped.
  start_xvnc() {
    rm -f "$d/display" "$d/vnc.sock"
    Xvnc -displayfd 3 3>"$d/display" -geometry "${W}x${H}" -depth 24 -desktop zestssh \
      -rfbport -1 -rfbunixpath "$d/vnc.sock" -rfbunixmode 0600 -SecurityTypes None \
      -nolisten tcp $1 -auth "$d/Xauthority" -AlwaysShared </dev/null >"$d/xvnc.log" 2>&1 &
    xv=$!
    printf '%s\n' "$xv" >"$d/xvnc.pid"
    i=0
    while [ ! -s "$d/display" ] || [ ! -S "$d/vnc.sock" ]; do
      kill -0 "$xv" 2>/dev/null || { xv=; return 1; }
      i=$((i + 1)); [ "$i" -gt 200 ] && fail xvnc-timeout
      sleep 0.05
    done
    return 0
  }
  # The display's cookie: Xvnc loads every entry of its -auth file whatever its
  # display number, so one is written before the number is known, and the
  # program's entry after.
  cookie=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
  [ ${#cookie} -eq 32 ] || fail no-random
  # (Through xauth's own "source" with "-", read from a pipe: as an argument the
  # cookie stood in xauth's command line, which every account of the host can
  # read while it runs, and the cookie is all that keeps them off the display.
  # printf is the shell's own, so it is in no command line either.)
  printf 'add %s . %s\n' "zestssh/unix:0" "$cookie" | xauth -q -f "$d/Xauthority" source - || fail xauth
  # Where /tmp/.X11-unix cannot take a socket (read-only, as WSLg mounts it),
  # Linux's abstract socket alone (trying the folder first costs Xvnc about
  # 1.2 s of retries there).
  first=""
  [ -d /tmp/.X11-unix ] && [ ! -w /tmp/.X11-unix ] && [ "$(uname -s)" = Linux ] && first="-nolisten unix"
  start_xvnc "$first" || start_xvnc "-nolisten unix" || { tail -n 3 "$d/xvnc.log" >&2; fail xvnc-exited; }
  n=$(head -n 1 "$d/display")
  case $n in ''|*[!0-9]*) fail xvnc-display ;; esac
  printf 'add %s . %s\n' ":$n" "$cookie" | xauth -q -f "$d/Xauthority" source - || fail xauth
  # The program's output goes to the channel's stderr: the app keeps its last
  # lines, and nothing grows in a file.
  DISPLAY=":$n" XAUTHORITY="$d/Xauthority" sh -c "$prog" </dev/null >&2 &
  app=$!
  # A program that is not there, or ends as it starts (one that hands its
  # window to one already running), is said before the ready line: the app
  # then says so instead of opening an empty screen.
  if [ -n "$psok" ]; then
    sleep 0.1
    case $(ps -p "$app" -o stat= 2>/dev/null) in
      ''|Z*) wait "$app"; printf 'ZSX {"exited":%s}\n' "$?"; exit 0 ;;
    esac
  fi
  printf 'ZSX {"socket":"%s","display":%s}\n' "$d/vnc.sock" "$n"
  # The app closing the channel ends stdin: stop then. (A background job's
  # stdin is /dev/null unless redirected, hence fd 4.)
  exec 4<&0
  ( cat <&4 >/dev/null; kill -TERM $$ 2>/dev/null ) &
  w=$!
  wait "$app"
  printf 'ZSX {"exited":%s}\n' "$?"
''';

/// [xProgramScript] as sh reads it: with LF line ends, whatever a checkout
/// of this file on Windows made of them (a CR would end up in every command).
final String xProgramScriptText = xProgramScript.replaceAll('\r\n', '\n');

/// The longest program line taken, in UTF-8 bytes.
const xProgramMaxBytes = 1024;

/// The bytes left as they are in a printf format: letters, digits, space and
/// a few marks no shell or printf reads inside single quotes. (`-` is not one:
/// a format that began with it would be read as an option.)
bool _plain(int b) =>
    (b >= 0x30 && b <= 0x39) ||
    (b >= 0x41 && b <= 0x5a) ||
    (b >= 0x61 && b <= 0x7a) ||
    b == 0x20 ||
    b == 0x5f || // _
    b == 0x2e || // .
    b == 0x2f || // /
    b == 0x2c || // ,
    b == 0x3a || // :
    b == 0x3d || // =
    b == 0x2b || // +
    b == 0x40; // @

/// [text] as a printf format that prints it byte for byte: every byte but the
/// plain ones as a three-digit octal escape (POSIX printf: `\ddd`).
String printfFormatOf(String text) {
  final out = StringBuffer();
  for (final b in utf8.encode(text)) {
    if (_plain(b)) {
      out.writeCharCode(b);
    } else {
      out
        ..write(r'\')
        ..write(b.toRadixString(8).padLeft(3, '0'));
    }
  }
  return out.toString();
}

/// What printf prints for a format made by [printfFormatOf] (tests).
String printfFormatDecoded(String format) {
  final bytes = <int>[];
  for (var i = 0; i < format.length; i++) {
    final c = format.codeUnitAt(i);
    if (c == 0x5c) {
      bytes.add(int.parse(format.substring(i + 1, i + 4), radix: 8));
      i += 3;
    } else {
      bytes.add(c);
    }
  }
  return utf8.decode(bytes);
}

/// The exec command that runs [program] in a private Xvnc of [width] by
/// [height] on the host ([xProgramScript]). Only fixed text, the two printf
/// formats inside single quotes, and the two numbers.
String xProgramCommand(String program, int width, int height) {
  if (xProgramProblem(program) != null) throw ArgumentError('not a program line');
  if (width < 1 || height < 1) throw ArgumentError('no size');
  return "exec sh -c 'eval \"\$(printf \"\$1\")\"' zestssh-x "
      "'${printfFormatOf(xProgramScriptText)}' '${printfFormatOf(program)}' $width $height";
}

/// Why [program] is not taken as a program line, or null.
enum XProgramProblem { empty, tooLong, controlCharacters }

/// Why [program] is not a program line: empty (or only spaces), longer than
/// [xProgramMaxBytes], or with a control character (a newline, a tab, an
/// escape: it is one line, as typed in a terminal). Null where it is one.
XProgramProblem? xProgramProblem(String program) {
  if (program.trim().isEmpty) return XProgramProblem.empty;
  if (utf8.encode(program).length > xProgramMaxBytes) return XProgramProblem.tooLong;
  for (final r in program.runes) {
    if (r < 0x20 || r == 0x7f || (r >= 0x80 && r < 0xa0) || r == 0x2028 || r == 0x2029) {
      return XProgramProblem.controlCharacters;
    }
  }
  return null;
}

/// The program's own name in [program]: its first word, past `VAR=value`
/// settings and `env`, `exec`, `nohup`, as a file name (`/usr/bin/xterm -fa
/// Mono` is `xterm`). What labels and logs say, never the whole line, whose
/// arguments may name anything.
String xProgramName(String program) {
  final words = program.trim().split(RegExp(r'\s+'));
  for (final w in words) {
    if (w.isEmpty) continue;
    if (RegExp(r'^[A-Za-z_][A-Za-z0-9_]*=').hasMatch(w)) continue;
    if (w == 'env' || w == 'exec' || w == 'nohup' || w == 'command') continue;
    final unquoted = w.replaceAll(RegExp('''['"]'''), '');
    final slash = unquoted.lastIndexOf('/');
    final name = slash >= 0 ? unquoted.substring(slash + 1) : unquoted;
    if (name.isEmpty) continue;
    return name.length > 40 ? name.substring(0, 40) : name;
  }
  return 'X';
}

/// One `ZSX` line of the script.
sealed class XProgramLine {
  const XProgramLine();

  /// The line [line] says, or null for any other line (or a broken one).
  static XProgramLine? parse(String line) {
    if (!line.startsWith('ZSX ')) return null;
    final Object? m;
    try {
      m = jsonDecode(line.substring(4));
    } on FormatException {
      return null;
    }
    if (m is! Map<String, Object?>) return null;
    final error = m['error'];
    if (error is String) {
      final pm = m['pm'];
      return XProgramError(error, pm is String && pm.isNotEmpty ? pm : null);
    }
    final exited = m['exited'];
    if (exited is num) return XProgramExited(exited.toInt());
    final socket = m['socket'];
    final display = m['display'];
    if (socket is String && socket.startsWith('/') && display is num) {
      return XProgramReady(socket, display.toInt());
    }
    return null;
  }
}

/// The private Xvnc is up and the program started: the VNC socket to open.
final class XProgramReady extends XProgramLine {
  const XProgramReady(this.socket, this.display);
  final String socket;
  final int display;
}

/// The script stopped before the program ran: [error] (`no-xvnc`,
/// `no-xauth`, `no-tmp`, `xvnc-exited`, `xvnc-timeout`, ...), and for a
/// missing tool the host's package manager [pm] (`apt-get`, `dnf`, `yum`,
/// `pacman`, `zypper`), where it has one of them.
final class XProgramError extends XProgramLine {
  const XProgramError(this.error, this.pm);
  final String error;
  final String? pm;

  /// Whether a tool the script needs is missing on the host.
  bool get toolMissing => error == 'no-xvnc' || error == 'no-xauth';
}

/// The program ended with [status].
final class XProgramExited extends XProgramLine {
  const XProgramExited(this.status);
  final int status;
}

/// The command that installs Xvnc and xauth with the package manager [pm],
/// for the person to run on the host (the app never runs it); null where the
/// host has none of those it knows.
String? xProgramInstallCommand(String? pm) => switch (pm) {
      'apt-get' || 'apt' => _installApt,
      'dnf' => _installDnf,
      'yum' => _installYum,
      'pacman' => _installPacman,
      'zypper' => _installZypper,
      _ => null,
    };

const _installApt = 'sudo apt install tigervnc-standalone-server xauth';
const _installDnf = 'sudo dnf install tigervnc-server-minimal xorg-x11-xauth';
const _installYum = 'sudo yum install tigervnc-server-minimal xorg-x11-xauth';
const _installPacman = 'sudo pacman -S tigervnc xorg-xauth';
const _installZypper = 'sudo zypper install xorg-x11-Xvnc xauth';

/// Every command [xProgramInstallCommand] gives: where a failure is said, the
/// one in its text is shown on a line of its own, with a button that copies it.
const xProgramInstallCommands = [_installApt, _installDnf, _installYum, _installPacman, _installZypper];
