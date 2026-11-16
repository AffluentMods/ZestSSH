import 'dart:math' show min;

import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:flutter/widgets.dart' show StringCharacters;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/utils/hidden_characters.dart';

/// How worried the question before a command is. (Since a harmless
/// `docker exec frigate sh -c '...'` paste was told it could
/// do lasting harm.)
enum DangerLevel {
  /// It can destroy or lock out for good: a delete, a format, the host off.
  harm,

  /// It may well be fine, and what it runs is worth reading first.
  look,
}

/// What a risky command does, said in the app's language ([describe]), and in
/// a sentence with what to do about it ([explain]). (3.0: each was
/// a sentence in English.)
enum DangerKind {
  criticalDelete,
  forcedDeleteLongFlags,
  findDelete,
  rootGuardOff,
  formatDisk,
  wipeDisk,
  shred,
  diskWrite,
  ddOverwrite,
  diskRead,
  forkBomb,
  openPermissions,
  moveToNull,
  pipeToShell,
  decodeToShell,
  interpreterOneLiner,
  shellString,
  authorizedKeys,
  crontab,
  startupFile,
  shutdown,
  reboot,
  halt,
  powerOff,

  /// Longer than the rules read ([DangerousCommandService.kMaxRead]): what is in
  /// the rest is not known, so it is asked about as what it may be.
  tooLong;

  /// Whether it can do lasting harm or is only worth a look. A pipe into a
  /// shell stays harmful: what runs is not on the screen to be read.
  DangerLevel get level => switch (this) {
        DangerKind.interpreterOneLiner || DangerKind.shellString || DangerKind.diskRead => DangerLevel.look,
        _ => DangerLevel.harm,
      };

  /// What it does and what to do about it, in [t]'s language, quoting [match]:
  /// the part of the command it was found in ([DangerousCommandMatch.quotedIn]).
  String explain(AppLocalizations t, String match) => switch (this) {
        DangerKind.criticalDelete => t.dangerExplainCriticalDelete(match),
        DangerKind.forcedDeleteLongFlags => t.dangerExplainForcedDeleteLongFlags(match),
        DangerKind.findDelete => t.dangerExplainFindDelete(match),
        DangerKind.rootGuardOff => t.dangerExplainRootGuardOff(match),
        DangerKind.formatDisk => t.dangerExplainFormatDisk(match),
        DangerKind.wipeDisk => t.dangerExplainWipeDisk(match),
        DangerKind.shred => t.dangerExplainShred(match),
        DangerKind.diskWrite => t.dangerExplainDiskWrite(match),
        DangerKind.ddOverwrite => t.dangerExplainDdOverwrite(match),
        DangerKind.diskRead => t.dangerExplainDiskRead(match),
        DangerKind.forkBomb => t.dangerExplainForkBomb(match),
        DangerKind.openPermissions => t.dangerExplainOpenPermissions(match),
        DangerKind.moveToNull => t.dangerExplainMoveToNull(match),
        DangerKind.pipeToShell => t.dangerExplainPipeToShell(match),
        DangerKind.decodeToShell => t.dangerExplainDecodeToShell(match),
        DangerKind.interpreterOneLiner => t.dangerExplainInterpreterOneLiner(match),
        DangerKind.shellString => t.dangerExplainShellString(match),
        DangerKind.authorizedKeys => t.dangerExplainAuthorizedKeys(match),
        DangerKind.crontab => t.dangerExplainCrontab(match),
        DangerKind.startupFile => t.dangerExplainStartupFile(match),
        DangerKind.shutdown => t.dangerExplainShutdown(match),
        DangerKind.reboot => t.dangerExplainReboot(match),
        DangerKind.halt => t.dangerExplainHalt(match),
        DangerKind.powerOff => t.dangerExplainPowerOff(match),
        DangerKind.tooLong => t.dangerExplainTooLong(match),
      };

  /// What it does, in [t]'s language.
  String describe(AppLocalizations t) => switch (this) {
        DangerKind.criticalDelete => t.dangerCriticalDelete,
        DangerKind.forcedDeleteLongFlags => t.dangerForcedDeleteLongFlags,
        DangerKind.findDelete => t.dangerFindDelete,
        DangerKind.rootGuardOff => t.dangerRootGuardOff,
        DangerKind.formatDisk => t.dangerFormatDisk,
        DangerKind.wipeDisk => t.dangerWipeDisk,
        DangerKind.shred => t.dangerShred,
        DangerKind.diskWrite => t.dangerDiskWrite,
        DangerKind.ddOverwrite => t.dangerDdOverwrite,
        DangerKind.diskRead => t.dangerDiskRead,
        DangerKind.forkBomb => t.dangerForkBomb,
        DangerKind.openPermissions => t.dangerOpenPermissions,
        DangerKind.moveToNull => t.dangerMoveToNull,
        DangerKind.pipeToShell => t.dangerPipeToShell,
        DangerKind.decodeToShell => t.dangerDecodeToShell,
        DangerKind.interpreterOneLiner => t.dangerInterpreterOneLiner,
        DangerKind.shellString => t.dangerShellString,
        DangerKind.authorizedKeys => t.dangerAuthorizedKeys,
        DangerKind.crontab => t.dangerCrontab,
        DangerKind.startupFile => t.dangerStartupFile,
        DangerKind.shutdown => t.dangerShutdown,
        DangerKind.reboot => t.dangerReboot,
        DangerKind.halt => t.dangerHalt,
        DangerKind.powerOff => t.dangerPowerOff,
        DangerKind.tooLong => t.dangerTooLong,
      };
}

class DangerousCommandMatch {
  final String pattern;

  /// What the matched command does.
  final DangerKind kind;

  /// Character offsets of the matched span within the checked text, so the
  /// UI can highlight the actual dangerous fragment instead of truncating a
  /// benign prefix. -1 when the offset is unknown.
  final int start;
  final int end;

  /// The words it was found in where they have no place in the text as it
  /// stands ([DangerousCommandService.checkFilled], with no offsets).
  final String? found;

  const DangerousCommandMatch(
    this.pattern,
    this.kind, {
    this.start = -1,
    this.end = -1,
    this.found,
  });

  /// The part of [command] it was found in, to quote in a sentence: on one
  /// line, with everything in it showing as what it is ([visibleCommand]), and
  /// short (a match can run over a long line), cut between characters. Empty
  /// where its place is not known.
  String quotedIn(String command) {
    final where = found ??
        (start < 0 || end <= start || start >= command.length
            ? ''
            : command.substring(start, end.clamp(0, command.length)));
    final part = where.replaceAll(RegExp(r'[\x00-\x1f\x7f\s]+'), ' ').trim();
    final letters = part.characters;
    return visibleCommand(
      letters.length <= kMaxQuoted ? part : '${letters.take(kMaxQuoted - 1).toString().trimRight()}…',
    );
  }

  /// The most of a command a sentence quotes.
  static const int kMaxQuoted = 48;
}

/// The worst level among [matches]: what the question before them says.
DangerLevel worstDangerLevel(Iterable<DangerousCommandMatch> matches) =>
    matches.any((m) => m.kind.level == DangerLevel.harm) ? DangerLevel.harm : DangerLevel.look;

class DangerousCommandService {
  static const _patterns = <(String, DangerKind)>[
    // rm with recursive+force flags, however written (rf, fr, Rf, rvf, -r -f,
    // --recursive --force, -r --force, …) and wherever they stand, aimed at a
    // critical target as any of its arguments. Covers rm -rf /, rm -fr /,
    // rm -r -f /, rm -rf ~, rm -rf $HOME, rm -rf /home, rm -rf *, rm -rf .,
    // and the stray space of rm -rf ./build /* (input is lower-cased before
    // matching, so [a-z] also covers -R). Only the words of the same command
    // count (none past ; & | or a new line, unless a backslash carries the
    // line on), at most 64 of them, so a long paste is still checked
    // quickly. The flags as separate words, and a critical target after
    // another argument, were not caught (3.0: found while saying what each
    // rule finds). The target may stand in quotes, and the whole of it inside
    // those of `sh -c '...'` or a one-liner's `os.system("...")`: once those
    // were only worth a look, `sh -c 'rm -rf /'` was told nothing is known to
    // do harm (found in a review).
    (
      r'\brm' +
          _gap +
          r'(?=(?:[^\s;&|]+' +
          _gap +
          r'){0,64}?(?:-[a-z]{0,32}r|--recursive\b))(?=(?:[^\s;&|]+' +
          _gap +
          r'){0,64}?(?:-[a-z]{0,32}f|--force\b))(?:[^\s;&|]+' +
          _gap +
          r'''){0,64}?(?:\\?['"`]){0,16}(/|/\*|\*|~|\$home|\$\{home\}|/home|/etc|/usr|/var|/boot|/root|/bin|/lib|/opt|\.)(?=\\?['"`]|\s|/|[;&|)<>\[\]]|$)''',
      DangerKind.criticalDelete
    ),
    // Long-flag form: rm --recursive --force … (and --force --recursive),
    // whatever the target. It asked for a word character before the second
    // flag's dashes (\b--), so it never matched the flags as anyone writes
    // them, a space apart (3.0: found the same way). Both flags belong to the
    // same command (no ; & | or new line between), and the stretch looked
    // over is bounded, so a long paste made of rm is still checked quickly: each
    // flag is looked for once (`rm --force ` over and over took a second for every
    // 64 KB).
    (
      r'\brm[ \t]+(?![ \t])(?=(?:[^;&|\n]{0,800}[ \t])?--recursive\b)(?=(?:[^;&|\n]{0,800}[ \t])?--force\b)(?:[^;&|\n]{0,800}[ \t])?--(?:recursive|force)\b',
      DangerKind.forcedDeleteLongFlags
    ),
    // find given the root, a folder the system needs or the home folder, itself
    // and not a folder under it, as one of its paths, and deleting what it finds:
    // by -delete, -exec rm or xargs rm. (`find . -name x -delete`, `find /tmp
    // -delete` and `find /var/log -name x -delete` are every day's.) It looks for
    // the deleting first, and no further than the next find: a long paste of `find
    // /` took seconds without.
    (
      r'''\bfind[ \t]+(?![ \t])(?=(?:(?!find\b)[^;&\n]){0,500}?(?:-delete|-exec|xargs))(?:-[a-z0-9]{1,32}[ \t]+){0,8}(?:[^\s;&|<>-][^\s;&|<>]*[ \t]+){0,8}'''
      r'''\\?['"]?(?:/\*?|~/?|\$home/?|\$\{home\}/?|/(?:home|etc|usr|var|boot|root|bin|lib|opt)/?)\\?['"]?[ \t]'''
      r'''(?:(?:(?!find\b)[^;&|\n]){0,400}[ \t])?(?:-delete\b|-exec(?:dir)?[ \t]+(?:sudo[ \t]+)?(?:\S{0,200}/)?rm\b|\|[ \t]*(?:sudo[ \t]+)?xargs\b[^;&|\n]{0,100}[ \t](?:\S{0,200}/)?rm\b)''',
      DangerKind.findDelete
    ),
    // Disables GNU rm's built-in "refuse to delete /" guard - a red flag on
    // its own regardless of the target.
    (r'--no-preserve-root', DangerKind.rootGuardOff),
    // What a one-liner deletes with no rm to see: its question is only worth a
    // look, so what can be known of what it runs is read here.
    (
      r'''\b(?:rmtree|remove_tree|rm_rf|rmsync|rimraf)\b|\brm['"]\s*,\s*['"]-[a-z]{0,32}[rf]''',
      DangerKind.forcedDeleteLongFlags
    ),
    // mkfs.ext4, and mkfs -t ext4 as well, with what it is given (`man mkfs` is
    // no format).
    (r'\b(?:mkfs\.|(?:mkfs|mke2fs)[ \t]+\S)', DangerKind.formatDisk),
    // wipefs erases only with -a or -o: by itself it lists what is on the disk.
    (
      r'\bwipefs\b(?:(?!\bwipefs\b)[^;&|\n]){0,400}[ \t](?:-[a-z]{0,16}[ao][a-z]{0,16}\b|--all\b|--offset\b)',
      DangerKind.wipeDisk
    ),
    // shred of a device; with -u, of a path outside the folder it is run in. (In
    // the folder it is run in, it is what the person came to do.)
    (
      r'''\bshred\b(?:(?!\bshred\b)[^;&|\n]){0,400}[ \t]\\?['"]?/dev/(?!''' +
          _discards +
          r''')[^\s;&|'"]{0,200}|\bshred(?=(?:[ \t]+[^\s;&|<>]+){0,64}?[ \t]+(?:-[a-z]{0,16}u[a-z]{0,16}\b|--remove\b))(?=(?:[ \t]+[^\s;&|<>]+){0,64}?[ \t]+\\?['"]?(?:/|~|\$home|\$\{home\}|\.\./))[^;&|\n'"]{0,200}''',
      DangerKind.shred
    ),
    // The rules that look ahead for a second part stay within the command
    // (not past ; & | or a new line) and look a bounded way: each looked over
    // the whole rest of a line, so a long one-line paste of dd, mv or base64
    // took seconds to check (3.0, found with the rm rules).
    (r'''\bdd\b''' + _thisDd + r'''\bof=\\?['"]?/dev/''' + _aDisk, DangerKind.diskWrite),
    // Any other place dd is aimed at: a file (`of=/etc/fstab`), a name that may
    // be a disk (`of=$DISK`), something under /dev that is none. A redirect of
    // its own output is the same, >> as well (`dd if=/dev/zero>>/etc/passwd`),
    // whatever order its words are in (not `cat dd > out`, with no word of dd's
    // after it); 2> and >& are not, nor what throws it away. Only a plain line
    // aimed at what throws it away, or passes it on, is let off ([_excuses]):
    // `dd if=/dev/zero of=/dev/stdout | tee /dev/sda` went without a question.
    (
      r'''\bdd\b''' +
          _thisDd +
          r'''\bof=(?!\\?['"]?/dev/''' +
          _aDisk +
          r''')|\bdd\s+[a-z]{1,16}=''' +
          _thisDd +
          r'''(?<![02-9>])>>?(?![>&]|\s*\\?['"]?/dev/''' +
          _discards +
          r''')''',
      DangerKind.ddOverwrite
    ),
    // dd with nowhere to write to, or writing to what it is run with: it reads,
    // and passes it on.
    (
      r'''\bdd\s+if=(?!''' + _thisDd + r'''\bof=)|\bdd\b''' + _thisDd + r'''\bof=\\?['"]?/dev/(?:stdout|stderr|fd/\d{1,4})\b''',
      DangerKind.diskRead
    ),
    (r':\(\)\s*\{', DangerKind.forkBomb),
    (r'\bchmod\s+-R\s+777\b', DangerKind.openPermissions),
    (r'''>\s*\\?['"]?/dev/(sd|hd|vd|nvme|disk|mmcblk)''', DangerKind.diskWrite),
    (r'\bmv[ \t]+(?![ \t])[^;&|\n]{1,400}[ \t]/dev/null\b', DangerKind.moveToNull),
    // Pipe ANYTHING into a shell, independent of the fetcher. Catches
    // `curl … | sh`, `wget … | bash`, `… | sudo sh`, zsh/ksh/dash/ash, and
    // the shell named by its path or through env (`| /bin/sh`, `| sudo
    // /usr/bin/env bash`), which were not caught (found in a security review of
    // the client). What it looks over for a path stops at the
    // next | : a long paste of them took as long squared.
    (
      r'\|\s*(sudo\s+)?([^\s;|]{0,200}/)?(env\s+)?(ba|z|k|da|a)?sh\b',
      DangerKind.pipeToShell
    ),
    // What a command prints, run by a shell as a file: `bash <(curl …)`.
    (r'\b(ba|z|k|da|a)?sh\s+<\(', DangerKind.pipeToShell),
    // ...or as a string, where the words after -c are not on the screen to be
    // read: `sh -c "$(curl …)"`, `python3 -c "$(wget …)"`. (`eval "$(ssh-agent)"`
    // and its like are every day's: eval is told only of what it downloads.)
    (
      r'''\b(?:(?:(?:ba|z|k|da|a)?sh|python[23]?|perl|ruby|node)\s+-[ce]\s+\\?['"]?(?:\$\(|`)|eval\s+\\?['"]?(?:\$\(|`)\s*(?:curl|wget)\b)''',
      DangerKind.pipeToShell
    ),
    // Downloaded, then run in the same line: `curl … -o x; sh x`.
    (
      r'\b(curl|wget)\b(?:(?!\b(?:curl|wget)\b)[^\n]){0,400}?[;&]\s*(sudo\s+)?([^\s;&|]{0,200}/)?(ba|z|k|da|a)?sh\s',
      DangerKind.pipeToShell
    ),
    // Decode-then-execute: `base64 -d … | sh`, `xxd -r … | bash`, through
    // any pipes between (`base64 -d … | tee x | sh`), within the line.
    (
      r'\b(base64|xxd)\b(?:(?!\b(?:base64|xxd)\b)[^;&\n]){0,400}\|\s*\w{0,32}sh\b',
      DangerKind.decodeToShell
    ),
    // Inline interpreter one-liners: python -c, perl -e, ruby -e, node -e.
    (
      r'\b(python[23]?|perl|ruby|node)\s+-(c|e)\b',
      DangerKind.interpreterOneLiner
    ),
    // `sh -c "…"` / `bash -c "…"` - arbitrary command string.
    (r'\b(ba|z|k|da|a)?sh\s+-c\b', DangerKind.shellString),
    // Persistence: writing an attacker key into authorized_keys.
    (r'\bauthorized_keys\b', DangerKind.authorizedKeys),
    // Persistence: installing/removing a crontab, by an option, or from a file
    // where it starts a command (`crontab a`; `grep crontab x` is no crontab).
    (
      r'''\bcrontab\s+-|(?:^|[;&|\n(`'"]|\bsudo[ \t])[ \t]*(?:[^\s;&|(`'"]{0,200}/)?crontab[ \t]+[^\s;&|<>#-]''',
      DangerKind.crontab
    ),
    // Persistence: appending to a shell startup file.
    (
      r'''>>\s*\\?['"]?(?:~|\$home|\$\{home\})?/?\.(bash|zsh|profile)''',
      DangerKind.startupFile
    ),
    (r'\bshutdown\b', DangerKind.shutdown),
    // (Not /var/run/reboot-required, which says one is due.)
    (r'\breboot\b(?!-required)', DangerKind.reboot),
    (r'\binit\s+0\b', DangerKind.halt),
    (r'\bhalt\b', DangerKind.halt),
    (r'\bpoweroff\b', DangerKind.powerOff),
  ];

  /// What lies between the words of a command: spaces, and lines a backslash
  /// carries on. (Written so that a long run of spaces costs no room to go back
  /// in: `rm` and a megabyte of them threw a stack overflow in a release build.)
  static const _gap = r'(?:[ \t]|\\\r?\n)[ \t]*(?:\\\r?\n[ \t]*){0,16}';

  /// What dd's words are looked for in: its own command, and up to the next dd, which
  /// is looked at by itself. A long paste of `dd ` looked over the same stretch for
  /// each one.
  static const _thisDd = r'(?:(?!\bdd\b)[^;&|\n]){0,400}';

  /// After /dev/: what throws away what it is given. Nothing is lost by writing
  /// there, and nothing of it reaches anything else.
  static const _discards = r'(?:null|zero|full|random|urandom)\b';

  /// After /dev/: a disk, to say so of it. Everything but what throws it away, a
  /// stream or a terminal, or a file in /dev/shm.
  static const _aDisk = r'(?!(?:null|zero|full|random|urandom|stdout|stderr|tty\d{0,4}|pts/\d{1,4}|fd/\d{1,4})\b|shm/)';

  /// What may stand before a command that is let off, and after it.
  static const _sudo = r'^\s*(?:sudo\s+)?';
  static const _lineEnd = r'\s*$';

  /// Only speaks of what it names, and runs nothing: `last reboot`, `which
  /// poweroff`, `grep reboot /var/log/syslog`, `man shutdown`. man with no option
  /// (`man -P reboot ls` runs reboot).
  static const _speaksOf = _sudo +
      r'(?:(?:info|which|whereis|whatis|apropos|type|last|lastb|grep|egrep|fgrep)\s|man(?:\s+\d\w{0,3})?\s+[^\s-]\S{0,200}\s*$)';

  /// One operand of dd that is not its output.
  static const _ddOperands = r'(?:\s+(?!of=)[a-z]{1,16}=\S*){0,16}';

  static const _readsKeys =
      _sudo + r'(?:cat|less|more|head|tail|wc|grep|egrep|fgrep|ls|stat|file|diff|md5sum|sha1sum|sha256sum)\s';
  static const _readsCrontab = '${_sudo}crontab(?:\\s+-u\\s+\\S{1,200})?\\s+-l(?:\\s+-u\\s+\\S{1,200})?$_lineEnd';

  /// dd aimed at what throws it away or passes it on, and nothing else on the line.
  /// (Passing it on, it is still told of as a copy, [DangerKind.diskRead].)
  static const _ddAtNoFile =
      '${_sudo}dd$_ddOperands\\s+of=/dev/(?:null|zero|full|random|urandom|stdout|stderr|fd/\\d{1,4})$_ddOperands$_lineEnd';
  static const _cancelsShutdown = '$_speaksOf|${_sudo}shutdown\\s+(?:-c|--help)$_lineEnd';
  static const _helpOfReboot = '$_speaksOf|${_sudo}reboot\\s+--help$_lineEnd';
  static const _helpOfHalt = '$_speaksOf|${_sudo}halt\\s+--help$_lineEnd';
  static const _helpOfPowerOff = '$_speaksOf|${_sudo}poweroff\\s+--help$_lineEnd';

  /// What a rule finds and no question is needed for, because the command only
  /// reads it or only speaks of it. Only for a line that is one plain command and
  /// nothing else ([_notPlain]): what is said of the words around one is no good
  /// once a line can run more than one thing, `man $(reboot)`, `man x\rreboot`,
  /// `crontab -r # -l`, `dd if=/dev/sda of=/dev/stdout | nc example.com 1` (the
  /// review's list). Anything else is asked.
  static final _excuses = <DangerKind, RegExp>{
    DangerKind.authorizedKeys: RegExp(_readsKeys),
    DangerKind.crontab: RegExp(_readsCrontab),
    DangerKind.ddOverwrite: RegExp(_ddAtNoFile),
    DangerKind.shutdown: RegExp(_cancelsShutdown),
    DangerKind.reboot: RegExp(_helpOfReboot),
    DangerKind.halt: RegExp(_helpOfHalt),
    DangerKind.powerOff: RegExp(_helpOfPowerOff),
  };

  /// What makes a line anything but one plain command: what ends a command or
  /// starts another, a substitution, a redirect, a comment, a quote, a backslash,
  /// a line end, any control character (a paste may type them).
  static final _notPlain = RegExp(r'''[$`();&|<>#'"\\\x00-\x1f\x7f]''');

  /// A CR with no new line after it. In a paste it is Enter: Terminal.paste makes
  /// every line end one.
  static final _loneCr = RegExp(r'\r(?!\n)');

  /// The most of a text the rules read. They run where the person is waiting, on
  /// what may be a megabyte of clipboard made to be slow (`rm ` over and over, half
  /// a second for this much with the rules compiled as a release build has them, on
  /// a desktop; a megabyte took three). The rest is not read, and that is asked about
  /// ([DangerKind.tooLong]), in red, because it may be anything. A script of this
  /// length is rare; a command is never one.
  static const int kMaxRead = 1 << 17;

  /// Makes every rule run out of room, as one might on a text no test has found.
  @visibleForTesting
  static bool debugRulesRunOutOfRoom = false;

  /// The patterns, compiled once. (They were compiled anew for every line
  /// checked: a paste of many lines into a broadcast paid for each.)
  static final List<(RegExp, String, DangerKind)> _compiled = [
    for (final (pattern, kind) in _patterns) (RegExp(pattern, caseSensitive: false), pattern, kind),
  ];

  static List<DangerousCommandMatch> check(String text) {
    var unread = text.length > kMaxRead;
    // (A lone CR ends a command for every rule, as a new line does. One for one:
    // what is found keeps its place in the text.)
    final lower = (unread ? text.substring(0, kMaxRead) : text).toLowerCase().replaceAll(_loneCr, '\n');
    final plain = !_notPlain.hasMatch(lower);
    final matches = <DangerousCommandMatch>[];
    for (final (regExp, pattern, kind) in _compiled) {
      // firstMatch (not hasMatch) so we can report WHERE the dangerous
      // fragment is - the dialog highlights that span instead of blindly
      // truncating to the first 200 chars.
      try {
        if (debugRulesRunOutOfRoom) throw const StackOverflowError();
        final m = regExp.firstMatch(lower);
        if (m != null && !(plain && (_excuses[kind]?.hasMatch(lower) ?? false))) {
          matches.add(DangerousCommandMatch(
            pattern,
            kind,
            start: m.start,
            end: m.end,
          ));
        }
      } on StackOverflowError {
        // A rule that ran out of room to go back in has not read the text.
        unread = true;
      }
    }
    if (unread) {
      matches.add(DangerousCommandMatch('', DangerKind.tooLong, found: text.substring(0, min(text.length, 200))));
    }
    return matches;
  }

  /// [check] of a command with values filled in. Every value goes to the shell
  /// in quotes, and the rules do not read past them: `rm -rf '/'`, what a
  /// snippet's `rm -rf ${DIR}` comes to with DIR `/`, passed as harmless. It is
  /// read with its quotes taken away as well, and a line a backslash carries on
  /// joined to the next (`find / -name x \` and `-delete` under it, as a page of
  /// instructions writes it, is one command); what only that finds has no place
  /// in the text as it stands (its offsets are -1), and keeps the words it was
  /// found in for the sentence that quotes them.
  static List<DangerousCommandMatch> checkFilled(String text) {
    final matches = check(text);
    final read = text.length > kMaxRead ? text.substring(0, kMaxRead) : text;
    final bare = read.replaceAll(_quotes, '').replaceAll(_carriedOn, ' ');
    if (bare == read) return matches;
    final kinds = {for (final m in matches) m.kind};
    return [
      ...matches,
      for (final m in check(bare))
        if (!kinds.contains(m.kind))
          DangerousCommandMatch(m.pattern, m.kind, found: bare.substring(m.start, m.end.clamp(0, bare.length))),
    ];
  }

  static final _quotes = RegExp('[\'"]');
  static final _carriedOn = RegExp(r'\\(?:\r\n?|\n)');

  /// [matches], found in what a command runs ([runs]), as a question that shows
  /// it as [shown] speaks of them, its masked values out of sight (a value typed
  /// with dots). Each has its place in [shown] where the rules find it there too.
  /// One they find only in what runs (`rm -rf ${DIR:secret}`, given `/`) stays,
  /// with [shown] for its words, never the words it was found in: they hold the
  /// value.
  static List<DangerousCommandMatch> asShown(String runs, String shown, List<DangerousCommandMatch> matches) {
    if (runs == shown) return matches;
    final inShown = checkFilled(shown);
    return [
      for (final m in matches)
        inShown.where((s) => s.kind == m.kind).firstOrNull ?? DangerousCommandMatch(m.pattern, m.kind, found: shown),
    ];
  }
}
