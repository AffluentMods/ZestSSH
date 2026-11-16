#!/usr/bin/env python3
"""Record what everyday programs write to a terminal from start to exit, as
xterm (TERM=xterm-256color, what the app announces to a server) and as a
plain Linux console (TERM=linux, what the console of a container or a virtual
machine, or a serial line, announces), so the bytes can be replayed into the
app's terminal emulator by test/terminal/terminal_codes_test.dart.

Run on Linux (WSL is fine) with vim and nano installed:

    python3 tool/terminal/capture_programs.py /tmp/zest_programs
    cp /tmp/zest_programs/*.json test/terminal/fixtures/programs/

Each program is started in a pty of a fixed size on a made-up one-line file
in /tmp, left with its own quit key, and every byte it wrote is kept. Nothing
of the machine it runs on is in a recording: no process list, no host name,
no user name (which is why top is not among them).

What these show that a hand-written test would not think of: vim asking where
the cursor is after it sent a string and a code a terminal has to ignore (its
check whether the terminal is what it says it is); the codes for the keyboard
that vim sends with `>` and `?` in front; what reset really sends, which on a
Linux console ends in a code only that console knows.
"""
import base64
import fcntl
import json
import os
import pty
import select
import struct
import sys
import termios
import time

ROWS, COLS = 30, 100
NOTE = '/tmp/zest_probe_note.txt'

PROGRAMS = [
    # name, what it was, argv, keys to quit, the terminals to record it as
    ('vim', 'vim -u NONE on a one-line file, then :q!',
     ['vim', '-u', 'NONE', NOTE], [b':q!\r'], ('xterm-256color', 'linux')),
    ('nano', 'nano on a one-line file, then Ctrl+X',
     ['nano', '--ignorercfiles', NOTE], [b'\x18'], ('linux',)),
    ('reset', 'reset', ['reset'], [], ('xterm-256color', 'linux')),
    ('tput_init', 'tput init', ['tput', 'init'], [], ('xterm-256color',)),
]


def record(argv, keys, term, wait=1.2):
    pid, fd = pty.fork()
    if pid == 0:
        env = {'TERM': term, 'LANG': 'C.UTF-8', 'LC_ALL': 'C.UTF-8',
               'PATH': '/usr/local/bin:/usr/bin:/bin', 'HOME': '/tmp'}
        os.chdir('/tmp')
        os.execvpe(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    data = b''
    started = time.time()
    sent = 0
    while True:
        ready, _, _ = select.select([fd], [], [], 0.2)
        if ready:
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
        elapsed = time.time() - started
        if sent < len(keys) and elapsed > wait * (sent + 1):
            os.write(fd, keys[sent])
            sent += 1
        if elapsed > wait * (len(keys) + 4):
            break
    try:
        os.kill(pid, 9)
    except ProcessLookupError:
        pass
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return data


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/zest_programs'
    os.makedirs(out, exist_ok=True)
    with open(NOTE, 'w') as f:
        f.write('a made-up note\n')
    for name, what, argv, keys, terms in PROGRAMS:
        for term in terms:
            data = record(argv, keys, term)
            short = 'xterm' if term.startswith('xterm') else term
            doc = {
                'name': '%s_%s' % (name, short),
                'program': what,
                'term': term,
                'rows': ROWS,
                'cols': COLS,
                'data': base64.b64encode(data).decode('ascii'),
            }
            path = os.path.join(out, doc['name'] + '.json')
            with open(path, 'w', encoding='utf-8', newline='\n') as f:
                f.write(json.dumps(doc, indent=1) + '\n')
            print(doc['name'], len(data), 'bytes ->', path)


if __name__ == '__main__':
    main()
