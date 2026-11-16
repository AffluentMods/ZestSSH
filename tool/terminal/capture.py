#!/usr/bin/env python3
"""Record what real full-screen programs send to a terminal while they are
scrolled, so the bytes can be replayed into the app's terminal emulator by
test/terminal/real_program_replay_test.dart.

Run on Linux (WSL is fine) with vim, nano and less installed:

    python3 tool/terminal/capture.py /tmp/zest_capture
    cp /tmp/zest_capture/*.json test/terminal/fixtures/

Each program is started in a pty of a fixed size with TERM=xterm-256color
(what the app announces to a server). Keys are sent one step at a time, and
after every step the program is told to repaint its whole screen. The output
is cut into segments: the bytes of the step itself, then the bytes of the
repaint. A repaint draws the same screen from scratch, so a correct emulator
shows the same screen before and after it; a difference is an emulator bug in
how the step was drawn (scroll regions, inserted and deleted lines, erases).

Everything is recorded under a neutral folder with a made-up sample file, so
a fixture never carries the name or the paths of the machine it was made on.
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

ROWS, COLS = 40, 120


def sample_python(path):
    lines = ['#!/usr/bin/env python3',
             '"""Sample module: orders for a small shop."""',
             'import os', 'import sys', 'from dataclasses import dataclass', '']
    for i in range(1, 61):
        lines += [
            '@dataclass',
            f'class Order{i}:',
            f'    """Order number {i} with a total and a note."""',
            f'    total: float = {i}.5',
            f'    note: str = "order {i}: paid in full"',
            '',
            '    def describe(self, prefix="#"):  # returns a label',
            f'        if self.total > {i * 3} and prefix != None:',
            '            return f"{prefix}{self.total:.2f} " + self.note',
            '        return None',
            '',
        ]
    with open(path, 'w') as f:
        f.write('\n'.join(lines) + '\n')


def run(out, name, argv, steps, repaint, quit_keys, cwd):
    env = {
        'TERM': 'xterm-256color',
        'LANG': 'C.UTF-8',
        'HOME': cwd,
        'PATH': os.environ.get('PATH', '/usr/bin:/bin'),
        'USER': 'alex',
        'LOGNAME': 'alex',
    }
    pid, fd = pty.fork()
    if pid == 0:
        os.chdir(cwd)
        os.execvpe(argv[0], argv, env)
    fcntl.ioctl(fd, termios.TIOCSWINSZ, struct.pack('HHHH', ROWS, COLS, 0, 0))

    def drain(quiet):
        """Everything the program sends until it has been quiet for [quiet]."""
        data = b''
        deadline = time.time() + quiet
        while True:
            left = deadline - time.time()
            if left <= 0:
                break
            ready, _, _ = select.select([fd], [], [], left)
            if not ready:
                break
            try:
                chunk = os.read(fd, 65536)
            except OSError:
                break
            if not chunk:
                break
            data += chunk
            deadline = time.time() + quiet
        return data

    def segment(label, kind, data):
        return {'label': label, 'kind': kind,
                'data': base64.b64encode(data).decode()}

    segments = [segment('start', 'step', drain(1.5))]
    # The first repaint gives every later comparison a clean base.
    os.write(fd, repaint)
    segments.append(segment('start', 'repaint', drain(0.5)))
    for label, keys in steps:
        os.write(fd, keys)
        segments.append(segment(label, 'step', drain(0.4)))
        os.write(fd, repaint)
        segments.append(segment(label, 'repaint', drain(0.4)))
    os.write(fd, quit_keys)
    drain(0.5)
    try:
        os.kill(pid, 9)
    except OSError:
        pass
    try:
        os.waitpid(pid, 0)
    except OSError:
        pass
    os.close(fd)
    with open(os.path.join(out, f'{name}.json'), 'w') as f:
        json.dump({'name': name, 'rows': ROWS, 'cols': COLS,
                   'program': ' '.join(os.path.basename(a) for a in argv),
                   'segments': segments}, f)
    total = sum(len(base64.b64decode(s['data'])) for s in segments)
    print(f'{name}: {len(segments)} segments, {total} bytes')


def main():
    out = sys.argv[1] if len(sys.argv) > 1 else '/tmp/zest_capture'
    os.makedirs(out, exist_ok=True)
    work = os.path.join(out, 'work')
    os.makedirs(work, exist_ok=True)

    def fresh(name):
        path = os.path.join(work, name)
        sample_python(path)
        return name  # programs run in `work`, so only the bare name shows

    def ctrl(c):
        return bytes([ord(c) & 0x1f])

    vim_steps = [
        ('ctrl-e x1', ctrl('e')),
        ('ctrl-e x5', ctrl('e') * 5),
        ('ctrl-y x3', ctrl('y') * 3),
        ('ctrl-d', ctrl('d')),
        ('ctrl-u', ctrl('u')),
        ('ctrl-f', ctrl('f')),
        ('ctrl-b', ctrl('b')),
        ('j x70', b'j' * 70),
        ('k x45', b'k' * 45),
        ('G', b'G'),
        ('ctrl-y x10', ctrl('y') * 10),
        ('gg', b'gg'),
        ('50%', b'50%'),
        ('zt', b'zt'),
        ('zb', b'zb'),
        ('dd x3', b'dd' * 3),
        ('O new line', b'Onew line here\x1b'),
        ('u x4', b'uuuu'),
        ('search and n n n', b'/describe\r' + b'nnn'),
        ('ctrl-e x4 again', ctrl('e') * 4),
    ]
    vim = ['vim', '-n', '-u', 'NONE', '-i', 'NONE', '-N', '-c', 'syntax on']
    vim_quit = b'\x1b:qa!\r'
    run(out, 'vim_plain', vim + ['-c', 'set number', fresh('a.py')],
        vim_steps, ctrl('l'), vim_quit, work)
    # A colour scheme with its own background, a cursor line and a colour
    # column: every blank cell has a colour the terminal has to keep.
    run(out, 'vim_scheme',
        vim + ['-c', 'set number cursorline colorcolumn=80',
               '-c', 'colorscheme desert', fresh('b.py')],
        vim_steps, ctrl('l'), vim_quit, work)
    # True colour.
    run(out, 'vim_truecolor',
        vim + ['-c', 'set termguicolors number cursorline',
               '-c', 'colorscheme slate', fresh('c.py')],
        vim_steps, ctrl('l'), vim_quit, work)

    down, up = b'\x1b[B', b'\x1b[A'
    nano_steps = [
        ('down x45', down * 45),
        ('up x20', up * 20),
        ('page down', ctrl('v')),
        ('page down x2', ctrl('v') * 2),
        ('page up', ctrl('y')),
        ('scroll line down x4', b'\x1b+' * 4),
        ('scroll line up x2', b'\x1b-' * 2),
        ('end of file', b'\x1b/'),
        ('start of file', b'\x1b\\'),
        ('down x80', down * 80),
        ('cut line x3', ctrl('k') * 3),
        ('paste', ctrl('u')),
        ('type a line', b'# typed line\r'),
    ]
    # nano's own Ctrl+L re-centres the view; `refresh` only repaints it.
    rc = os.path.join(work, 'nanorc')
    with open(rc, 'w') as f:
        f.write('include "/usr/share/nano/*.nanorc"\n'
                'bind ^T refresh main\n')
    nano_quit = ctrl('x') + b'n'
    run(out, 'nano_plain',
        ['nano', f'--rcfile={rc}', '-l', fresh('d.py')],
        nano_steps, ctrl('t'), nano_quit, work)

    less_steps = [
        ('j x10', b'j' * 10),
        ('k x4', b'k' * 4),
        ('space', b' '),
        ('b', b'b'),
        ('d', b'd'),
        ('u', b'u'),
        ('G', b'G'),
        ('g', b'g'),
        ('search', b'/describe\r'),
        ('n n', b'nn'),
        ('k x30', b'k' * 30),
    ]
    run(out, 'less_plain', ['less', fresh('e.py')],
        less_steps, b'r', b'q', work)


if __name__ == '__main__':
    main()
