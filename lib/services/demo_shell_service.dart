import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:zestssh/services/ssh_service.dart';

/// A simulated shell for demo / App Store review purposes.
///
/// Provides a realistic terminal experience without requiring a real SSH
/// server, so Apple reviewers (and new users) can explore ZestSSH features.
class DemoShellService implements ShellService {
  final _stdoutController = StreamController<Uint8List>.broadcast();
  final _stderrController = StreamController<Uint8List>.broadcast();
  final _connectionStateController = StreamController<bool>.broadcast();
  bool _isConnected = false;
  bool _disposed = false;

  /// Current input line buffer.
  final _lineBuffer = StringBuffer();

  /// Cursor position within [_lineBuffer].
  int _cursorPos = 0;

  // ignore: unused_field
  int _cols = 80;
  // ignore: unused_field
  int _rows = 24;

  /// Command history.
  final _history = <String>[];
  int _historyIndex = -1;

  /// Simulated working directory.
  String _cwd = '/home/demo';

  /// Whether we're in the middle of an escape sequence.
  final _escBuffer = StringBuffer();
  bool _inEscape = false;

  @override
  Future<void> connect() async {
    _isConnected = true;
    _connectionStateController.add(true);

    // Simulate a brief connection delay
    await Future.delayed(const Duration(milliseconds: 300));

    _write(
      '\x1B[1;38;5;208m' // Bold orange
      '  ____          _   ____ ____  _   _ \r\n'
      ' |_  / ___  ___| |_/ ___/ ___|| | | |\r\n'
      '  / / / _ \\/ __| __\\___ \\___ \\| |_| |\r\n'
      ' /___\\___/\\___|\\__|____/____/ |_| |_|\r\n'
      '\x1B[0m\r\n'
      '\x1B[2m────────────────────────────────────────\x1B[0m\r\n'
      '\r\n'
      '  Welcome to the \x1B[1mZestSSH Demo Terminal\x1B[0m\r\n'
      '  Type \x1B[33mhelp\x1B[0m for available commands.\r\n'
      '\r\n'
      '\x1B[2m  This is a simulated shell for demonstration.\r\n'
      '  In normal use, you\'d be connected to a real server.\x1B[0m\r\n'
      '\r\n',
    );

    _writePrompt();
  }

  @override
  void write(Uint8List data) {
    if (!_isConnected || _disposed) return;

    for (var i = 0; i < data.length; i++) {
      final byte = data[i];

      // Handle escape sequences (arrow keys, etc.)
      if (_inEscape) {
        _escBuffer.writeCharCode(byte);
        final seq = _escBuffer.toString();

        // CSI sequences end with a letter
        if (seq.length >= 2 && byte >= 0x40 && byte <= 0x7E) {
          _handleEscapeSequence(seq);
          _inEscape = false;
          _escBuffer.clear();
        }
        continue;
      }

      if (byte == 0x1B) {
        // ESC
        _inEscape = true;
        _escBuffer.clear();
        continue;
      }

      switch (byte) {
        case 0x0D: // Enter
          _write('\r\n');
          final line = _lineBuffer.toString().trim();
          _lineBuffer.clear();
          _cursorPos = 0;
          if (line.isNotEmpty) {
            _history.add(line);
            _historyIndex = _history.length;
            _processCommand(line);
          } else {
            _writePrompt();
          }
        case 0x7F || 0x08: // Backspace
          if (_cursorPos > 0) {
            final current = _lineBuffer.toString();
            final before = current.substring(0, _cursorPos - 1);
            final after = current.substring(_cursorPos);
            _lineBuffer.clear();
            _lineBuffer.write(before);
            _lineBuffer.write(after);
            _cursorPos--;
            // Redraw: move back, rewrite from cursor, clear trailing, reposition
            _write('\x08$after \x1B[${after.length + 1}D');
          }
        case 0x03: // Ctrl+C
          _write('^C\r\n');
          _lineBuffer.clear();
          _cursorPos = 0;
          _writePrompt();
        case 0x04: // Ctrl+D
          if (_lineBuffer.isEmpty) {
            _write('logout\r\n');
            disconnect();
          }
        case 0x01: // Ctrl+A - beginning of line
          if (_cursorPos > 0) {
            _write('\x1B[${_cursorPos}D');
            _cursorPos = 0;
          }
        case 0x05: // Ctrl+E - end of line
          final remaining = _lineBuffer.length - _cursorPos;
          if (remaining > 0) {
            _write('\x1B[${remaining}C');
            _cursorPos = _lineBuffer.length;
          }
        case 0x0C: // Ctrl+L - clear screen
          _write('\x1B[2J\x1B[H');
          _writePrompt();
          _write(_lineBuffer.toString());
        case 0x15: // Ctrl+U - clear line
          if (_cursorPos > 0) {
            _write('\x1B[${_cursorPos}D\x1B[K');
            final after = _lineBuffer.toString().substring(_cursorPos);
            _lineBuffer.clear();
            _lineBuffer.write(after);
            _write(after);
            if (after.isNotEmpty) _write('\x1B[${after.length}D');
            _cursorPos = 0;
          }
        case 0x09: // Tab - basic autocomplete
          _handleTab();
        default:
          if (byte >= 0x20 && byte < 0x7F) {
            final char = String.fromCharCode(byte);
            final current = _lineBuffer.toString();
            final before = current.substring(0, _cursorPos);
            final after = current.substring(_cursorPos);
            _lineBuffer.clear();
            _lineBuffer.write(before);
            _lineBuffer.write(char);
            _lineBuffer.write(after);
            _cursorPos++;
            // Write char + rest of line, then move cursor back
            _write('$char$after');
            if (after.isNotEmpty) _write('\x1B[${after.length}D');
          }
      }
    }
  }

  void _handleEscapeSequence(String seq) {
    if (seq == '[A') {
      // Up arrow - history prev
      if (_history.isNotEmpty && _historyIndex > 0) {
        _historyIndex--;
        _replaceLineWith(_history[_historyIndex]);
      }
    } else if (seq == '[B') {
      // Down arrow - history next
      if (_historyIndex < _history.length - 1) {
        _historyIndex++;
        _replaceLineWith(_history[_historyIndex]);
      } else {
        _historyIndex = _history.length;
        _replaceLineWith('');
      }
    } else if (seq == '[C') {
      // Right arrow
      if (_cursorPos < _lineBuffer.length) {
        _cursorPos++;
        _write('\x1B[C');
      }
    } else if (seq == '[D') {
      // Left arrow
      if (_cursorPos > 0) {
        _cursorPos--;
        _write('\x1B[D');
      }
    } else if (seq == '[H' || seq == '[1~') {
      // Home
      if (_cursorPos > 0) {
        _write('\x1B[${_cursorPos}D');
        _cursorPos = 0;
      }
    } else if (seq == '[F' || seq == '[4~') {
      // End
      final remaining = _lineBuffer.length - _cursorPos;
      if (remaining > 0) {
        _write('\x1B[${remaining}C');
        _cursorPos = _lineBuffer.length;
      }
    } else if (seq == '[3~') {
      // Delete key
      if (_cursorPos < _lineBuffer.length) {
        final current = _lineBuffer.toString();
        final before = current.substring(0, _cursorPos);
        final after = current.substring(_cursorPos + 1);
        _lineBuffer.clear();
        _lineBuffer.write(before);
        _lineBuffer.write(after);
        _write('$after \x1B[${after.length + 1}D');
      }
    }
  }

  void _replaceLineWith(String newLine) {
    // Move to start of current input
    if (_cursorPos > 0) _write('\x1B[${_cursorPos}D');
    // Clear the line
    _write('\x1B[K');
    // Write new content
    _lineBuffer.clear();
    _lineBuffer.write(newLine);
    _cursorPos = newLine.length;
    _write(newLine);
  }

  void _handleTab() {
    final partial = _lineBuffer.toString();
    if (partial.isEmpty) return;

    final parts = partial.split(' ');
    if (parts.length == 1) {
      // Complete command name
      final matches = _commands.keys
          .where((c) => c.startsWith(parts[0]))
          .toList();
      if (matches.length == 1) {
        _replaceLineWith('${matches[0]} ');
      } else if (matches.length > 1) {
        _write('\r\n');
        _write(matches.join('  '));
        _write('\r\n');
        _writePrompt();
        _write(partial);
      }
    }
  }

  void _processCommand(String input) {
    final parts = input.split(RegExp(r'\s+'));
    final cmd = parts[0].toLowerCase();
    final args = parts.sublist(1);

    final handler = _commands[cmd];
    if (handler != null) {
      handler(args);
    } else {
      _write('\x1B[31m$cmd: command not found\x1B[0m\r\n');
      _write('\x1B[2mType \'help\' for available commands.\x1B[0m\r\n');
      _writePrompt();
    }
  }

  late final Map<String, void Function(List<String>)> _commands = {
    'help': _cmdHelp,
    'ls': _cmdLs,
    'pwd': _cmdPwd,
    'cd': _cmdCd,
    'whoami': _cmdWhoami,
    'echo': _cmdEcho,
    'cat': _cmdCat,
    'uname': _cmdUname,
    'date': _cmdDate,
    'clear': _cmdClear,
    'exit': _cmdExit,
    'logout': _cmdExit,
    'neofetch': _cmdNeofetch,
    'uptime': _cmdUptime,
    'df': _cmdDf,
    'free': _cmdFree,
    'ps': _cmdPs,
    'ssh': _cmdSsh,
    'ping': _cmdPing,
    'history': _cmdHistory,
    'touch': _cmdTouch,
    'mkdir': _cmdMkdir,
    'rm': _cmdRm,
    'man': _cmdMan,
    'top': _cmdTop,
    'htop': _cmdTop,
    'ifconfig': _cmdIfconfig,
    'ip': _cmdIfconfig,
    'curl': _cmdCurl,
    'wget': _cmdCurl,
    'vim': _cmdVim,
    'nano': _cmdVim,
    'grep': _cmdGrep,
    'id': _cmdId,
    'hostname': _cmdHostname,
    'env': _cmdEnv,
  };

  // ─── Command implementations ───

  void _cmdHelp(List<String> args) {
    _write(
      '\x1B[1;33mAvailable commands:\x1B[0m\r\n'
      '\r\n'
      '  \x1B[36mhelp\x1B[0m        Show this help message\r\n'
      '  \x1B[36mls\x1B[0m          List directory contents\r\n'
      '  \x1B[36mpwd\x1B[0m         Print working directory\r\n'
      '  \x1B[36mcd\x1B[0m          Change directory\r\n'
      '  \x1B[36mwhoami\x1B[0m      Print current user\r\n'
      '  \x1B[36mid\x1B[0m          Print user identity\r\n'
      '  \x1B[36mhostname\x1B[0m    Print hostname\r\n'
      '  \x1B[36mecho\x1B[0m        Print text to terminal\r\n'
      '  \x1B[36mcat\x1B[0m         Display file contents\r\n'
      '  \x1B[36muname\x1B[0m       Print system information\r\n'
      '  \x1B[36mdate\x1B[0m        Print current date/time\r\n'
      '  \x1B[36muptime\x1B[0m      Show system uptime\r\n'
      '  \x1B[36mdf\x1B[0m          Show disk usage\r\n'
      '  \x1B[36mfree\x1B[0m        Show memory usage\r\n'
      '  \x1B[36mps\x1B[0m          List running processes\r\n'
      '  \x1B[36mtop\x1B[0m         Show process activity\r\n'
      '  \x1B[36mifconfig\x1B[0m    Show network interfaces\r\n'
      '  \x1B[36mping\x1B[0m        Ping a host\r\n'
      '  \x1B[36mcurl\x1B[0m        Transfer data from URL\r\n'
      '  \x1B[36mgrep\x1B[0m        Search text patterns\r\n'
      '  \x1B[36mhistory\x1B[0m     Show command history\r\n'
      '  \x1B[36mneofetch\x1B[0m    System information\r\n'
      '  \x1B[36menv\x1B[0m         Show environment variables\r\n'
      '  \x1B[36mssh\x1B[0m         Info about SSH connections\r\n'
      '  \x1B[36mclear\x1B[0m       Clear the terminal\r\n'
      '  \x1B[36mexit\x1B[0m        Close the session\r\n'
      '\r\n'
      '\x1B[2mThis is a demo terminal. Add a real server\r\n'
      'connection for full SSH functionality.\x1B[0m\r\n',
    );
    _writePrompt();
  }

  void _cmdLs(List<String> args) {
    final showAll = args.contains('-a') || args.contains('-la') || args.contains('-al');
    final longFormat = args.contains('-l') || args.contains('-la') || args.contains('-al');

    final files = <_FakeFile>[
      if (showAll) const _FakeFile('.',  'drwxr-xr-x', 'demo', 4096, 'Apr 15 10:00'),
      if (showAll) const _FakeFile('..', 'drwxr-xr-x', 'root', 4096, 'Apr  1 09:00'),
      if (showAll) const _FakeFile('.ssh',      'drwx------', 'demo', 4096, 'Mar 20 14:30'),
      if (showAll) const _FakeFile('.bashrc',   '-rw-r--r--', 'demo', 3771, 'Mar 20 14:30'),
      if (showAll) const _FakeFile('.profile',  '-rw-r--r--', 'demo',  807, 'Mar 20 14:30'),
      const _FakeFile('Documents',  'drwxr-xr-x', 'demo', 4096, 'Apr 12 16:45'),
      const _FakeFile('Downloads',  'drwxr-xr-x', 'demo', 4096, 'Apr 14 09:20'),
      const _FakeFile('projects',   'drwxr-xr-x', 'demo', 4096, 'Apr 10 11:00'),
      const _FakeFile('README.md',  '-rw-r--r--', 'demo', 2048, 'Apr 15 10:00'),
      const _FakeFile('server.log', '-rw-r--r--', 'demo', 8192, 'Apr 15 09:55'),
      const _FakeFile('deploy.sh',  '-rwxr-xr-x', 'demo',  512, 'Apr  8 17:30'),
    ];

    if (longFormat) {
      _write('total ${files.length * 4}\r\n');
      for (final f in files) {
        final size = f.size.toString().padLeft(5);
        final color = f.perms.startsWith('d') ? '\x1B[1;34m' : '';
        final reset = f.perms.startsWith('d') ? '\x1B[0m' : '';
        final exec = f.perms.contains('x') && !f.perms.startsWith('d') ? '\x1B[1;32m' : '';
        final execR = exec.isNotEmpty ? '\x1B[0m' : '';
        _write('${f.perms} 1 ${f.owner} ${f.owner} $size ${f.date} $color$exec${f.name}$execR$reset\r\n');
      }
    } else {
      final names = files.map((f) {
        if (f.perms.startsWith('d')) return '\x1B[1;34m${f.name}\x1B[0m';
        if (f.perms.contains('x')) return '\x1B[1;32m${f.name}\x1B[0m';
        return f.name;
      }).toList();
      // Simple column output
      final buf = StringBuffer();
      for (var i = 0; i < names.length; i++) {
        buf.write(names[i]);
        buf.write(i < names.length - 1 ? '  ' : '');
      }
      _write('${buf.toString()}\r\n');
    }
    _writePrompt();
  }

  void _cmdPwd(List<String> args) {
    _write('$_cwd\r\n');
    _writePrompt();
  }

  void _cmdCd(List<String> args) {
    if (args.isEmpty || args[0] == '~') {
      _cwd = '/home/demo';
    } else if (args[0] == '..') {
      final parts = _cwd.split('/');
      if (parts.length > 2) {
        parts.removeLast();
        _cwd = parts.join('/');
      } else {
        _cwd = '/';
      }
    } else if (args[0] == '/') {
      _cwd = '/';
    } else if (args[0].startsWith('/')) {
      _cwd = args[0];
    } else {
      _cwd = '$_cwd/${args[0]}';
    }
    _writePrompt();
  }

  void _cmdWhoami(List<String> args) {
    _write('demo\r\n');
    _writePrompt();
  }

  void _cmdEcho(List<String> args) {
    _write('${args.join(' ')}\r\n');
    _writePrompt();
  }

  void _cmdCat(List<String> args) {
    if (args.isEmpty) {
      _write('cat: missing file operand\r\n');
      _writePrompt();
      return;
    }

    switch (args[0]) {
      case 'README.md':
        _write(
          '# ZestSSH Demo Server\r\n'
          '\r\n'
          'Welcome to the ZestSSH demo environment!\r\n'
          '\r\n'
          'This simulated terminal demonstrates ZestSSH\'s capabilities:\r\n'
          '- Full terminal emulation with ANSI color support\r\n'
          '- Command history (Up/Down arrows)\r\n'
          '- Line editing (Left/Right, Home/End, Ctrl+A/E)\r\n'
          '- Tab completion\r\n'
          '- Keyboard shortcuts (Ctrl+C, Ctrl+L, Ctrl+U)\r\n'
          '\r\n'
          'To connect to a real server, go back and add a\r\n'
          'new SSH connection with your server details.\r\n',
        );
      case 'server.log':
        _write(
          '[2026-04-15 09:50:01] INFO  Server started on port 22\r\n'
          '[2026-04-15 09:50:01] INFO  Host key loaded: ssh-ed25519\r\n'
          '[2026-04-15 09:50:02] INFO  Listening for connections...\r\n'
          '[2026-04-15 09:52:15] INFO  Connection from 192.168.1.42\r\n'
          '[2026-04-15 09:52:16] INFO  User \'demo\' authenticated\r\n'
          '[2026-04-15 09:55:00] INFO  Session active, 3 min uptime\r\n',
        );
      case 'deploy.sh':
        _write(
          '#!/bin/bash\r\n'
          '# Deploy script for production\r\n'
          'set -euo pipefail\r\n'
          '\r\n'
          'echo "Building project..."\r\n'
          'npm run build\r\n'
          '\r\n'
          'echo "Deploying to production..."\r\n'
          'rsync -avz ./dist/ prod:/var/www/app/\r\n'
          '\r\n'
          'echo "Deploy complete!"\r\n',
        );
      case '.bashrc':
        _write(
          '# ~/.bashrc: executed by bash for non-login shells.\r\n'
          'export PATH=\$HOME/bin:\$PATH\r\n'
          'export EDITOR=vim\r\n'
          'alias ll=\'ls -la\'\r\n'
          'alias gs=\'git status\'\r\n'
          'PS1=\'\\u@\\h:\\w\\\$ \'\r\n',
        );
      default:
        _write('cat: ${args[0]}: No such file or directory\r\n');
    }
    _writePrompt();
  }

  void _cmdUname(List<String> args) {
    if (args.contains('-a')) {
      _write('Linux demo-server 6.1.0-18-amd64 #1 SMP x86_64 GNU/Linux\r\n');
    } else {
      _write('Linux\r\n');
    }
    _writePrompt();
  }

  void _cmdDate(List<String> args) {
    final now = DateTime.now();
    final days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
    _write('${days[now.weekday - 1]} ${months[now.month - 1]} ${now.day.toString().padLeft(2)} '
        '${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')} UTC ${now.year}\r\n');
    _writePrompt();
  }

  void _cmdClear(List<String> args) {
    _write('\x1B[2J\x1B[H');
    _writePrompt();
  }

  void _cmdExit(List<String> args) {
    _write('logout\r\n');
    _write('\x1B[2mConnection to demo.zestssh.com closed.\x1B[0m\r\n');
    disconnect();
  }

  void _cmdNeofetch(List<String> args) {
    _write(
      '\x1B[38;5;208m        _____         \x1B[0m  \x1B[1mdemo\x1B[0m@\x1B[1mdemo-server\x1B[0m\r\n'
      '\x1B[38;5;208m       /     \\        \x1B[0m  \x1B[2m───────────────────\x1B[0m\r\n'
      '\x1B[38;5;208m      /  Z    \\       \x1B[0m  \x1B[33mOS:\x1B[0m      Debian GNU/Linux 12 x86_64\r\n'
      '\x1B[38;5;208m     /    e    \\      \x1B[0m  \x1B[33mHost:\x1B[0m    ZestSSH Demo Server\r\n'
      '\x1B[38;5;208m    /      s    \\     \x1B[0m  \x1B[33mKernel:\x1B[0m  6.1.0-18-amd64\r\n'
      '\x1B[38;5;208m   /        t    \\    \x1B[0m  \x1B[33mUptime:\x1B[0m  42 days, 7 hours\r\n'
      '\x1B[38;5;208m  /               \\   \x1B[0m  \x1B[33mShell:\x1B[0m   bash 5.2.15\r\n'
      '\x1B[38;5;208m  \\      SSH      /   \x1B[0m  \x1B[33mCPU:\x1B[0m     Intel Xeon E5-2680 (4)\r\n'
      '\x1B[38;5;208m   \\             /    \x1B[0m  \x1B[33mMemory:\x1B[0m  1.2 GiB / 8.0 GiB (15%)\r\n'
      '\x1B[38;5;208m    \\___________ /     \x1B[0m  \x1B[33mDisk:\x1B[0m    12G / 80G (15%)\r\n'
      '\r\n'
      '  \x1B[40m  \x1B[41m  \x1B[42m  \x1B[43m  \x1B[44m  \x1B[45m  \x1B[46m  \x1B[47m  \x1B[0m\r\n'
      '\r\n',
    );
    _writePrompt();
  }

  void _cmdUptime(List<String> args) {
    final now = DateTime.now();
    _write(' ${now.hour.toString().padLeft(2, '0')}:${now.minute.toString().padLeft(2, '0')}:'
        '${now.second.toString().padLeft(2, '0')} up 42 days,  7:15,  1 user,  load average: 0.08, 0.12, 0.09\r\n');
    _writePrompt();
  }

  void _cmdDf(List<String> args) {
    _write(
      'Filesystem      Size  Used Avail Use% Mounted on\r\n'
      '/dev/sda1        80G   12G   64G  16% /\r\n'
      'tmpfs           4.0G     0  4.0G   0% /dev/shm\r\n'
      '/dev/sda2       200G   45G  145G  24% /home\r\n',
    );
    _writePrompt();
  }

  void _cmdFree(List<String> args) {
    _write(
      '               total        used        free      shared  buff/cache   available\r\n'
      'Mem:         8192000     1228800     5120000       32000     1843200     6656000\r\n'
      'Swap:        2097152           0     2097152\r\n',
    );
    _writePrompt();
  }

  void _cmdPs(List<String> args) {
    _write(
      '  PID TTY          TIME CMD\r\n'
      '    1 ?        00:00:03 systemd\r\n'
      '  234 ?        00:00:01 sshd\r\n'
      '  456 ?        00:00:00 cron\r\n'
      '  789 pts/0    00:00:00 bash\r\n'
      ' 1024 pts/0    00:00:00 ps\r\n',
    );
    _writePrompt();
  }

  void _cmdSsh(List<String> args) {
    _write(
      '\x1B[33mYou\'re already in a terminal!\x1B[0m\r\n'
      '\r\n'
      'To connect to a real SSH server:\r\n'
      '  1. Go back to the home screen\r\n'
      '  2. Tap \x1B[1m+\x1B[0m to add a new host\r\n'
      '  3. Enter your server\'s address, port, and credentials\r\n'
      '  4. Tap the host to start a session\r\n'
      '\r\n'
      'ZestSSH supports SSH, Mosh, Telnet, and Serial protocols.\r\n',
    );
    _writePrompt();
  }

  void _cmdPing(List<String> args) {
    if (args.isEmpty) {
      _write('ping: usage: ping [-c count] host\r\n');
      _writePrompt();
      return;
    }
    final host = args.last;
    _write('PING $host (192.0.2.34) 56(84) bytes of data.\r\n');
    // Show a few lines then "stop"
    for (var i = 1; i <= 3; i++) {
      final ms = 12 + (i * 3);
      _write('64 bytes from $host: icmp_seq=$i ttl=56 time=${ms}ms\r\n');
    }
    _write('\r\n--- $host ping statistics ---\r\n');
    _write('3 packets transmitted, 3 received, 0% packet loss\r\n');
    _write('rtt min/avg/max = 15/21/27 ms\r\n');
    _writePrompt();
  }

  void _cmdHistory(List<String> args) {
    for (var i = 0; i < _history.length; i++) {
      _write('  ${(i + 1).toString().padLeft(4)}  ${_history[i]}\r\n');
    }
    _writePrompt();
  }

  void _cmdTouch(List<String> args) {
    if (args.isEmpty) {
      _write('touch: missing file operand\r\n');
    }
    // Silently "succeed"
    _writePrompt();
  }

  void _cmdMkdir(List<String> args) {
    if (args.isEmpty) {
      _write('mkdir: missing operand\r\n');
    }
    _writePrompt();
  }

  void _cmdRm(List<String> args) {
    if (args.isEmpty) {
      _write('rm: missing operand\r\n');
    } else if (args.contains('-rf') && args.any((a) => a == '/' || a == '/*')) {
      _write('\x1B[31mNice try! 😄\x1B[0m\r\n');
    }
    _writePrompt();
  }

  void _cmdMan(List<String> args) {
    if (args.isEmpty) {
      _write('What manual page do you want?\r\n');
    } else {
      _write('No manual entry for ${args[0]}\r\n');
      _write('\x1B[2mThis is a demo terminal - use \'help\' instead.\x1B[0m\r\n');
    }
    _writePrompt();
  }

  void _cmdTop(List<String> args) {
    _write(
      'top - 10:30:00 up 42 days,  1 user,  load average: 0.08, 0.12, 0.09\r\n'
      'Tasks:  72 total,   1 running,  71 sleeping,   0 stopped\r\n'
      '%Cpu(s):  2.1 us,  0.8 sy,  0.0 ni, 96.8 id,  0.3 wa\r\n'
      'MiB Mem :   8000.0 total,   5000.0 free,   1200.0 used,   1800.0 buff\r\n'
      'MiB Swap:   2048.0 total,   2048.0 free,      0.0 used,   6500.0 avail\r\n'
      '\r\n'
      '  PID USER      PR  NI    VIRT    RES  %CPU  %MEM     TIME+ COMMAND\r\n'
      '  234 root      20   0   12960   5632   0.3   0.1   0:01.20 sshd\r\n'
      '  789 demo      20   0    8240   4480   0.0   0.1   0:00.10 bash\r\n'
      '  456 root      20   0    6176   2816   0.0   0.0   0:00.05 cron\r\n'
      '\r\n'
      '\x1B[2mPress \'q\' to quit (simulated)\x1B[0m\r\n',
    );
    _writePrompt();
  }

  void _cmdIfconfig(List<String> args) {
    _write(
      'eth0: flags=4163<UP,BROADCAST,RUNNING,MULTICAST>  mtu 1500\r\n'
      '        inet 10.0.2.15  netmask 255.255.255.0  broadcast 10.0.2.255\r\n'
      '        inet6 fe80::a00:27ff:fe8e:9c3a  prefixlen 64  scopeid 0x20\r\n'
      '        ether 08:00:27:8e:9c:3a  txqueuelen 1000  (Ethernet)\r\n'
      '        RX packets 15234  bytes 12845678 (12.2 MiB)\r\n'
      '        TX packets 8456  bytes 1023456 (999.4 KiB)\r\n'
      '\r\n'
      'lo: flags=73<UP,LOOPBACK,RUNNING>  mtu 65536\r\n'
      '        inet 127.0.0.1  netmask 255.0.0.0\r\n'
      '        loop  txqueuelen 1000  (Local Loopback)\r\n',
    );
    _writePrompt();
  }

  void _cmdCurl(List<String> args) {
    if (args.isEmpty) {
      _write('curl: no URL specified\r\n');
    } else {
      _write(
        '  % Total    % Received\r\n'
        '100  1256  100  1256    0     0  12560      0 --:--:-- --:--:-- --:--:-- 12682\r\n'
        '{"status":"ok","message":"ZestSSH demo endpoint"}\r\n',
      );
    }
    _writePrompt();
  }

  void _cmdVim(List<String> args) {
    _write('\x1B[2mText editors are not available in the demo terminal.\r\n');
    _write('In a real SSH session, your server\'s editors will work normally.\x1B[0m\r\n');
    _writePrompt();
  }

  void _cmdGrep(List<String> args) {
    if (args.isEmpty) {
      _write('Usage: grep PATTERN [FILE]\r\n');
    } else {
      _write('\x1B[2mgrep operates on real files. Try: cat README.md\x1B[0m\r\n');
    }
    _writePrompt();
  }

  void _cmdId(List<String> args) {
    _write('uid=1000(demo) gid=1000(demo) groups=1000(demo),27(sudo)\r\n');
    _writePrompt();
  }

  void _cmdHostname(List<String> args) {
    _write('demo-server\r\n');
    _writePrompt();
  }

  void _cmdEnv(List<String> args) {
    _write(
      'USER=demo\r\n'
      'HOME=/home/demo\r\n'
      'SHELL=/bin/bash\r\n'
      'PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin\r\n'
      'LANG=en_US.UTF-8\r\n'
      'TERM=xterm-256color\r\n'
      'SSH_CLIENT=192.168.1.42 54321 22\r\n'
      'SSH_CONNECTION=192.168.1.42 54321 10.0.2.15 22\r\n'
      'LOGNAME=demo\r\n'
      'HOSTNAME=demo-server\r\n',
    );
    _writePrompt();
  }

  // ─── Prompt & output helpers ───

  void _writePrompt() {
    final dir = _cwd == '/home/demo' ? '~' : _cwd;
    _write('\x1B[1;32mdemo\x1B[0m@\x1B[1;34mdemo-server\x1B[0m:\x1B[1;36m$dir\x1B[0m\$ ');
  }

  void _write(String text) {
    if (_disposed) return;
    _stdoutController.add(Uint8List.fromList(utf8.encode(text)));
  }

  @override
  void resize(int width, int height) {
    _cols = width;
    _rows = height;
  }

  @override
  Stream<Uint8List> get stdout => _stdoutController.stream;

  @override
  Stream<Uint8List> get stderr => _stderrController.stream;

  @override
  Future<void> disconnect() async {
    if (_disposed) return;
    _disposed = true;
    _isConnected = false;
    _connectionStateController.add(false);
    _stdoutController.close();
    _stderrController.close();
    _connectionStateController.close();
  }

  @override
  bool get isConnected => _isConnected;

  // The demo shell never "drops" - closing it is always intentional.
  @override
  bool get exitedCleanly => true;

  @override
  bool get isEncryptedSsh => false;

  @override
  Stream<bool> get connectionState => _connectionStateController.stream;
}

class _FakeFile {
  final String name;
  final String perms;
  final String owner;
  final int size;
  final String date;

  const _FakeFile(this.name, this.perms, this.owner, this.size, this.date);
}
