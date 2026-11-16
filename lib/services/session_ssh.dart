// The SSH connection a session's files can be reached through: an SSH
// session's own, or the one a remote screen is carried through (4.0, step 4:
// a screen's Files opens SFTP to the same machine over the screen's own SSH
// connection, nothing new to sign in to). Null for a session with no SSH
// connection in this process: Telnet, serial, a screen reached directly, a
// session running in the background connection worker.
import 'package:zestssh/features/screens/session/screen_shell_service.dart' show ScreenShellService;
import 'package:zestssh/services/ssh_service.dart';

SshService? sshServiceOfShell(Object? shell) => switch (shell) {
      SshService ssh => ssh,
      ScreenShellService screen => screen.carrier,
      _ => null,
    };
