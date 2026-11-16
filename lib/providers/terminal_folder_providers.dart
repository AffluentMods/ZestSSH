import 'package:flutter_riverpod/flutter_riverpod.dart';

/// The folder a session's terminal said it is in, by the session's id: the
/// last one its shell reported with OSC 7 or iTerm2's OSC 1337;CurrentDir=
/// (4.0, the SFTP dock's "Go to the terminal's folder" and "Follow the
/// terminal"). Null until the shell says one, which a plain shell never does
/// (see [kTerminalFolderBashLine]); cleared when the session ends or connects
/// again, its new shell saying its own. Free on every tier: it is only where
/// the terminal is, and is kept nowhere.
final terminalFolderProvider = StateProvider.family<String?, String>((ref, sessionId) => null);

/// A request to the files beside a session's terminal (the SFTP dock) to open
/// [path], the terminal's folder. [following] when "Follow the terminal" asked
/// it: a folder the host has not is then said once, not at every prompt.
class TerminalFolderRequest {
  TerminalFolderRequest(this.path, {this.following = false});

  final String path;
  final bool following;
}

/// The dock's requests to open the terminal's folder, by the session's id:
/// its header asks, its files open it (they know which pane shows the host).
/// Each request is an object of its own, so the same folder asked twice is
/// heard twice.
final terminalFolderRequestProvider = StateProvider.family<TerminalFolderRequest?, String>((ref, sessionId) => null);

/// What makes bash say its folder at each prompt, for ~/.bashrc on the host
/// (shown to copy where the terminal has said none). It keeps what
/// PROMPT_COMMAND already runs.
const kTerminalFolderBashLine =
    r'''PROMPT_COMMAND='printf "\e]7;file://%s%s\a" "$HOSTNAME" "$PWD"'"${PROMPT_COMMAND:+;$PROMPT_COMMAND}"''';

/// The same for zsh, for ~/.zshrc on the host.
const kTerminalFolderZshLine =
    r'''autoload -Uz add-zsh-hook; _zest_cwd() { printf '\e]7;file://%s%s\a' "$HOST" "$PWD"; }; add-zsh-hook precmd _zest_cwd''';
