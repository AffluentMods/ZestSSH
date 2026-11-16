// ZestSSH 4.0 spike, developer only: "X program in a VNC tab". Over our SSH connection, one exec
// channel runs a small POSIX sh script on the host that starts a private TigerVNC Xvnc (a new X
// display it picks itself with -displayfd, no TCP for VNC or for X, its VNC socket in a fresh 0700
// folder, VNC security None: the folder is the lock, as for the user's own X socket; the X display
// itself takes only clients with a fresh MIT-MAGIC-COOKIE-1 kept in that folder, since Linux's
// abstract X socket has no file permissions and any account on the host could otherwise connect),
// runs the chosen program on it, and prints one line, `ZSX {"socket": ..., "display": ...}`. We then open a
// direct-streamlocal channel to that socket for the VNC engine. The script ends, and takes the
// Xvnc, the program and the folder with it, when the program exits or when we close the channel
// (its stdin ends), whichever comes first. Pure Dart (no Flutter).
import 'dart:async';
import 'dart:convert';

import 'package:zest_ssh_core/zest_ssh_core.dart';

/// $1 the program (a shell command line), $2 width, $3 height. Prints `ZSX {...}` once.
const xProgramScript = r'''
set -u
umask 077
fail() { printf 'ZSX {"error":"%s"}\n' "$1"; exit 1; }
command -v Xvnc >/dev/null 2>&1 || fail no-xvnc
command -v xauth >/dev/null 2>&1 || fail no-xauth
d=$(mktemp -d "${TMPDIR:-/tmp}/zestssh-x.XXXXXXXX") || fail no-tmp
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
  i=0
  while [ ! -s "$d/display" ] || [ ! -S "$d/vnc.sock" ]; do
    kill -0 "$xv" 2>/dev/null || { xv=; return 1; }
    i=$((i + 1)); [ "$i" -gt 200 ] && fail xvnc-timeout
    sleep 0.05
  done
  return 0
}
W=$2 H=$3
# The display's cookie: Xvnc loads every entry of its -auth file whatever its display number, so
# one is written before the number is known, and the program's entry after.
cookie=$(od -An -N16 -tx1 /dev/urandom | tr -d ' \n')
[ ${#cookie} -eq 32 ] || fail no-random
xauth -q -f "$d/Xauthority" add "zestssh/unix:0" . "$cookie" || fail xauth
# When /tmp/.X11-unix cannot take a socket (read-only, as WSLg mounts it), Linux's abstract
# socket alone (trying the folder first costs Xvnc about 1.2 s of retries there).
first=""
[ -d /tmp/.X11-unix ] && [ ! -w /tmp/.X11-unix ] && [ "$(uname -s)" = Linux ] && first="-nolisten unix"
start_xvnc "$first" || start_xvnc "-nolisten unix" || { tail -n 3 "$d/xvnc.log" >&2; fail xvnc-exited; }
n=$(head -n 1 "$d/display")
xauth -q -f "$d/Xauthority" add ":$n" . "$cookie" || fail xauth
DISPLAY=":$n" XAUTHORITY="$d/Xauthority" sh -c "$1" </dev/null >"$d/app.log" 2>&1 &
app=$!
printf 'ZSX {"socket":"%s","display":%s}\n' "$d/vnc.sock" "$n"
# Our side closing the channel ends stdin: stop then. (A background job's stdin is /dev/null
# unless redirected, hence fd 4.)
exec 4<&0
( cat <&4 >/dev/null; kill -TERM $$ 2>/dev/null ) &
w=$!
wait "$app"
printf 'ZSX {"exited":%s}\n' "$?"
''';

String shellQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// A started X program: the VNC socket to open, the display, and the channel that keeps it alive.
class XProgram {
  XProgram._(this.session, this.socketPath, this.display, this.lines);
  final SSHSession session;
  final String socketPath;
  final int display;

  /// Later `ZSX` lines (the program's exit).
  final Stream<Map<String, Object?>> lines;

  /// Ends it on the host (the script stops the Xvnc and removes its folder).
  void close() => session.close();

  static Future<XProgram> start(SSHClient ssh, String program, int width, int height,
      {Duration timeout = const Duration(seconds: 15)}) async {
    final command = 'exec sh -c ${shellQuote(xProgramScript)} zestssh-x '
        '${shellQuote(program)} $width $height';
    final session = await ssh.execute(command);
    final out = StreamController<Map<String, Object?>>.broadcast();
    final ready = Completer<Map<String, Object?>>();
    final err = StringBuffer();
    session.stderr.cast<List<int>>().transform(utf8.decoder).listen(err.write);
    session.stdout.cast<List<int>>().transform(utf8.decoder).transform(const LineSplitter()).listen((line) {
      if (!line.startsWith('ZSX ')) return;
      final m = jsonDecode(line.substring(4)) as Map<String, Object?>;
      if (!ready.isCompleted) {
        ready.complete(m);
      } else {
        out.add(m);
      }
    }, onDone: () {
      if (!ready.isCompleted) ready.completeError(StateError('the host script ended: ${err.toString().trim()}'));
      out.close();
    });
    final m = await ready.future.timeout(timeout, onTimeout: () {
      session.close();
      throw TimeoutException('no answer from the host script');
    });
    if (m['error'] != null) {
      session.close();
      throw StateError('could not start the X program: ${m['error']} ${err.toString().trim()}');
    }
    return XProgram._(session, m['socket']! as String, (m['display']! as num).toInt(), out.stream);
  }
}
