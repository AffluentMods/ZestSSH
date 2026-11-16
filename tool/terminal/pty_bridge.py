#!/usr/bin/env python3
"""Run a program in a terminal of its own (a pty) and pass everything through:
what this process is sent on its input goes to the program as typed, what
the program writes comes out on this process's output, byte for byte.

    python3 tool/terminal/pty_bridge.py TERM ROWS COLS -- program [args...]

It lets a test on any machine put the app's terminal emulator in front of a
real program on Linux (WSL is fine): test/terminal/live_programs_test.dart
feeds the output into the emulator and sends the emulator's own answers back
as typing, the way a session does. That is the only way to see what a
program does with what the emulator answers: a recording is of a program that
was answered by something else.

The program gets TERM as given, a UTF-8 locale and nothing else of this
machine's environment. When it ends, this process ends with its exit code
(128 + the signal if it was killed).
"""
import fcntl
import os
import pty
import select
import struct
import sys
import termios


def main():
    if len(sys.argv) < 6 or sys.argv[4] != '--':
        sys.stderr.write(__doc__)
        return 64
    term, rows, cols = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
    argv = sys.argv[5:]

    pid, fd = pty.fork()
    if pid == 0:
        env = {'TERM': term, 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
               'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': '/tmp'}
        os.chdir('/tmp')
        try:
            os.execvpe(argv[0], argv, env)
        except OSError as e:
            sys.stderr.write('cannot run %s: %s\n' % (argv[0], e))
            os._exit(127)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', rows, cols, 0, 0))

    stdin = sys.stdin.buffer.fileno()
    stdout = sys.stdout.buffer
    watching = [fd, stdin]
    while True:
        try:
            ready, _, _ = select.select(watching, [], [])
        except InterruptedError:
            continue
        if stdin in ready:
            data = os.read(stdin, 65536)
            if data:
                os.write(fd, data)
            else:
                watching.remove(stdin)
        if fd in ready:
            try:
                data = os.read(fd, 65536)
            except OSError:
                break
            if not data:
                break
            stdout.write(data)
            stdout.flush()

    _, status = os.waitpid(pid, 0)
    if os.WIFEXITED(status):
        return os.WEXITSTATUS(status)
    return 128 + os.WTERMSIG(status)


if __name__ == '__main__':
    sys.exit(main())
