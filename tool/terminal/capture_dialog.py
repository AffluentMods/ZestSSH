#!/usr/bin/env python3
"""Record what a text dialog of the Debian package system (whiptail, the
program behind "Configuring ..." questions during an upgrade) writes to a
terminal, once as a plain Linux console (TERM=linux) and once as xterm
(TERM=xterm-256color, what the app announces to a server), so the bytes can
be replayed into the app's terminal emulator by
test/terminal/terminal_answers_test.dart.

Run on Linux (WSL is fine) with whiptail installed:

    python3 tool/terminal/capture_dialog.py /tmp/zest_dialog
    cp /tmp/zest_dialog/*.json test/terminal/fixtures/dialogs/

The dialog is started in a pty of a fixed size, drawn, and Enter is pressed
for it a moment later. Nothing is installed or configured: the dialog is a
made-up question with four made-up choices.

Why both: a Linux console has no second screen and its codes for hiding and
showing the cursor end in `ESC [ ? 1 c` and `ESC [ ? 0 c`. A terminal that
takes those for the question "what are you?" (`ESC [ c`) answers them, the
answer reaches the dialog as typed keys, and its first key is Escape.
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

ARGV = [
    'whiptail', '--title', 'Configuring demo',
    '--menu', 'What do you want to do about the file?', '16', '70', '4',
    'install', 'install the new version',
    'keep', 'keep the version installed',
    'diff', 'show the differences',
    'shell', 'start a shell',
]


def record(term):
    pid, fd = pty.fork()
    if pid == 0:
        env = {
            'TERM': term,
            'LANG': 'C.UTF-8',
            'LC_ALL': 'C.UTF-8',
            'PATH': '/usr/local/bin:/usr/bin:/bin',
            'HOME': '/tmp',
        }
        os.execvpe(ARGV[0], ARGV, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))
    data = b''
    pressed = False
    started = time.time()
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
        if not pressed and time.time() - started > 1.5:
            os.write(fd, b'\r')
            pressed = True
        if time.time() - started > 10:
            break
    try:
        os.waitpid(pid, 0)
    except ChildProcessError:
        pass
    return data


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/zest_dialog'
    os.makedirs(out, exist_ok=True)
    for term, name in (('linux', 'whiptail_linux'), ('xterm-256color', 'whiptail_xterm')):
        data = record(term)
        doc = {
            'name': name,
            'program': 'whiptail --title "Configuring demo" --menu ... (4 choices), '
                       'Enter pressed after it was drawn',
            'term': term,
            'rows': ROWS,
            'cols': COLS,
            'data': base64.b64encode(data).decode('ascii'),
        }
        path = os.path.join(out, name + '.json')
        with open(path, 'w', encoding='utf-8', newline='\n') as f:
            f.write(json.dumps(doc, indent=1) + '\n')
        print(name, len(data), 'bytes ->', path)


if __name__ == '__main__':
    main()
