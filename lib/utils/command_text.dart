/// The line ends of a command, as the place it goes to takes them.
///
/// A command the app keeps (a snippet, a host's start-up command, a workflow
/// step) may have been written or pasted on Windows, where a line ends in a
/// carriage return and a line feed. Typed at a prompt as it stands, each of
/// its lines is entered twice: the carriage return is Enter, and so is the
/// line feed. A snippet of several lines ran with an empty line after every
/// line (2.2.1: the text came out double spaced), and
/// a line that ends in a backslash to go on in the next was cut off there.
/// Handed whole to a shell instead of typed, the carriage return is taken
/// for the last character of each line's last word.
abstract final class CommandText {
  static final _lineEnd = RegExp(r'\r\n|\r|\n');
  static final _carriageReturn = RegExp(r'\r\n?');

  /// [command] as a keyboard types it at a prompt: one Enter (a carriage
  /// return) for every line end, whichever way the line ends in the text.
  /// Nothing is added: the last line waits for the person's own Enter,
  /// unless the text ends with a line end, which is that Enter.
  static String typed(String command) => command.replaceAll(_lineEnd, '\r');

  /// [command] typed and entered: as [typed], with one Enter at the end
  /// unless the text ends with a line end of its own, which is that Enter.
  static String entered(String command) {
    final keys = typed(command);
    return keys.endsWith('\r') ? keys : '$keys\r';
  }

  /// [command] for a shell that is handed it whole (run, not typed): its
  /// lines end in a line feed.
  static String script(String command) =>
      command.replaceAll(_carriageReturn, '\n');

  /// [command] as the app keeps it: its lines end in a line feed, wherever
  /// it was written.
  static String stored(String command) => script(command);

  static final _controlCharacter = RegExp(r'[\x00-\x1f\x7f-\x9f]');

  /// Whether [text], a name from a server or a file, or a value from a host's
  /// settings, may be typed into a shell: it holds no control character (C0,
  /// DEL or C1).
  ///
  /// Quotes do not help. What is typed into a terminal reaches its line editor
  /// as keys before any shell reads a quote: Ctrl-U wipes the line with its
  /// opening quote in it, Enter runs what follows, Ctrl-O runs the line, and
  /// the name on screen shows none of it (hostile server audit, 30 October
  /// 2026: a folder named `backup`, spaces, `\x15cmd\r` ran `cmd` through Open
  /// terminal here). Text that holds one is not typed, and the person is told.
  static bool mayBeTyped(String text) => !_controlCharacter.hasMatch(text);

  /// [text] with every control character taken out (C0, DEL and C1), for what
  /// has no exact form to keep and is typed all the same: text dragged onto a
  /// terminal, dictated words.
  static String withoutControlCharacters(String text) => text.replaceAll(_controlCharacter, '');

  /// [text] in single quotes, with a quote of its own closed, escaped and
  /// opened again, so that it cannot end the quotes.
  ///
  /// That is how a POSIX shell (sh, bash, zsh, dash, ksh) reads quotes, and
  /// no other: fish reads `\'` inside single quotes as a quote, PowerShell
  /// ends the string at `'` (and at a curly quote), and cmd.exe has no single
  /// quotes at all, so `&` there runs what follows. A name a server chose goes
  /// in only where [standsInAnyShell] holds.
  static String quoted(String text) => "'${text.replaceAll("'", r"'\''")}'";

  /// What a name or a path may hold to stand in single quotes in a command
  /// line, whichever shell reads it: letters (of any script), digits,
  /// combining marks, symbols such as an emoji, a space, and `. _ / + @ , :
  /// = ~ # ( ) [ ] -`. Each means nothing inside single quotes to sh, bash,
  /// zsh, fish, tcsh, PowerShell or Nushell, nor to cmd.exe, which reads
  /// them as they are. Left out on purpose: the quotes (`'`, `"` and the
  /// curly ones PowerShell takes for quotes), the backslash (fish's escape
  /// inside quotes), `& | ; < > ^ % ! $` and the backtick (cmd.exe's and
  /// PowerShell's operators, expansions and escapes), `* ?`, dashes other
  /// than the hyphen (PowerShell takes them for one), every control,
  /// formatting and spacing character other than the space, and modifier
  /// letters (`ʼ`, U+02BC, looks like a quote), but for the ones ordinary
  /// words of Japanese, Chinese, Thai and Lao hold, which no shell reads as
  /// anything: the iteration marks (`々 〱 〲 〳 〴 〵 〻 ゝ ゞ ヽ ヾ`), the long
  /// vowel mark `ー` and the halfwidth `ｰ ﾞ ﾟ`, and the repetition marks `ๆ`
  /// and `ໆ`. Without them a folder named `ダウンロード` got no cd command
  /// and a file named `データ.csv` no checksum (found in a code review).
  static final _anyShell = RegExp(
    r'^[A-Za-z0-9 ._/+@,:=~#()\[\]\p{Lu}\p{Ll}\p{Lt}\p{Lo}\p{Mn}\p{Mc}\p{Nd}\p{So}'
    r'\u0e46\u0ec6\u3005\u3031-\u3035\u303b\u309d\u309e\u30fc-\u30fe\uff70\uff9e\uff9f-]+$',
    unicode: true,
  );

  /// Whether [text], a name or a path a server listed (or anyone other than
  /// the person chose), may be put into a command line a host's shell reads,
  /// in single quotes ([quoted]): it holds only what [_anyShell] lets
  /// through, and does not start with `-`, which a program takes for an
  /// option.
  ///
  /// The app does not know which shell a host runs. A host whose account
  /// runs cmd.exe (Windows' OpenSSH, as it comes) read `big & calc & rem
  /// .bin` in quotes as three commands (found in a security
  /// review): a file of that name, on a share another person can write
  /// to, ran `calc` as whoever downloaded it, at the checksum after the
  /// download. A name with anything else in it is not put into a command:
  /// what needed the command says it could not be done, and why.
  static bool standsInAnyShell(String text) =>
      text.isNotEmpty && !text.startsWith('-') && _anyShell.hasMatch(text);

  /// The command that takes a shell into the folder [path]: the path in
  /// single quotes ([quoted]), so no name of a folder can end the quotes and
  /// be run as a command. Null where the path may not be typed at all
  /// ([mayBeTyped]), or holds what a shell other than a POSIX one could read
  /// as part of a command ([standsInAnyShell]).
  static String? cdInto(String path) =>
      mayBeTyped(path) && standsInAnyShell(path) ? 'cd ${quoted(path)}' : null;

  /// [paths] as a dropped file's path is typed: each in single quotes, with a
  /// space between them. Null where any of them may not be typed at all
  /// ([mayBeTyped]).
  static String? quotedPaths(Iterable<String> paths) =>
      paths.every(mayBeTyped) ? paths.map(quoted).join(' ') : null;
}
