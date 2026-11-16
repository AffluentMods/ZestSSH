import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/run/run_on_hosts.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/services/key_import_service.dart' show publicKeyLineNamed;

// Install a key on hosts (3.0, installing a
// key on the hosts it is to sign in to): a key's public
// key added to the authorized keys of the account each host is signed in to
// as, on many hosts at once, as `ssh-copy-id` adds it, with each host's
// result: added, there already, or not added and why. It is a run on hosts
// (run_on_hosts.dart) of its own: the hosts are signed in to as their
// sessions would be, a host whose sessions its team watches is not run on,
// and one whose sessions its team logs has the install logged.

/// What is run on a host to add a key: `ssh-copy-id`'s own steps, under
/// `sh` whatever the account's login shell is. The key comes on its standard
/// input (never in the command); a file that holds it already (its type and
/// key, whatever comment or options with it) is left as it is; otherwise it
/// is added at the end, after a line end where the file does not end in one.
/// The folder and the file are made where they are not, readable by the
/// account alone, and SELinux is told of them where it is there. It says
/// [kKeyAdded] or [kKeyThere]; anything else is a key not added.
const kInstallKeyCommand = "exec sh -c 'umask 077; "
    r'IFS= read -r key || [ -n "$key" ] || exit 3; set -f; set -- $key; [ -n "$2" ] || exit 4; '
    r'cd || exit 5; mkdir -p .ssh || exit 6; f=.ssh/authorized_keys; '
    r'if [ -f "$f" ] && grep -qF -- "$1 $2" "$f"; then echo ZESTSSH_KEY_THERE; exit 0; fi; '
    r'if [ -s "$f" ] && [ -n "$(tail -c 1 "$f")" ]; then echo >> "$f" || exit 7; fi; '
    r'printf "%s\n" "$key" >> "$f" || exit 7; '
    r'if command -v restorecon >/dev/null 2>&1; then restorecon -F .ssh "$f" >/dev/null 2>&1; fi; '
    "echo ZESTSSH_KEY_ADDED'";

/// What [kInstallKeyCommand] says when it added the key.
const kKeyAdded = 'ZESTSSH_KEY_ADDED';

/// What [kInstallKeyCommand] says when the key was there already.
const kKeyThere = 'ZESTSSH_KEY_THERE';

/// How installing a key on one host ended.
enum KeyInstallEnd {
  /// Added to the account's authorized keys.
  added,

  /// The account's authorized keys held it already: left as they were.
  there,

  /// The command ran and did not add it (or did not say so).
  notAdded,
}

/// The line [key] is installed as: its public key, as an `authorized_keys`
/// line, with nothing after it; null where it has none.
String? installLineOf(Identity key) => installLine(key.publicKeyData);

/// [publicLine] as the line a key is installed as: one line of a type and a
/// key at least, an RSA key named by its type ([publicKeyLineNamed]); null
/// where it is not one.
String? installLine(String? publicLine) {
  final line = publicLine?.trim();
  if (line == null || line.isEmpty || line.contains('\n') || line.contains('\r')) return null;
  return line.split(RegExp(r'\s+')).length < 2 ? null : publicKeyLineNamed(line);
}

/// How [h], a host's part in installing a key, ended; null while it goes,
/// and where it did not run to its end (it failed, or was stopped).
KeyInstallEnd? keyInstallEndOf(HostRun h) {
  if (h.state != HostRunState.done) return null;
  if (h.exitCode == 0 && h.signal == null) {
    if (h.output.contains(kKeyAdded)) return KeyInstallEnd.added;
    if (h.output.contains(kKeyThere)) return KeyInstallEnd.there;
  }
  return KeyInstallEnd.notAdded;
}

/// Whether a host has the key now: added, or there already.
bool keyInstalledOn(HostRun h) => switch (keyInstallEndOf(h)) {
      KeyInstallEnd.added || KeyInstallEnd.there => true,
      _ => false,
    };

/// What a host's part in installing a key is called, as a few words.
String keyInstallWords(HostRun h, AppLocalizations l10n) {
  final user = h.user ?? '';
  return switch (keyInstallEndOf(h)) {
    KeyInstallEnd.added => l10n.installKeyAdded(user),
    KeyInstallEnd.there => l10n.installKeyThere(user),
    KeyInstallEnd.notAdded => l10n.installKeyNotAdded,
    null => switch (h.state) {
        HostRunState.running => l10n.installKeyInstalling,
        _ => hostRunStateWords(h, l10n),
      },
  };
}
