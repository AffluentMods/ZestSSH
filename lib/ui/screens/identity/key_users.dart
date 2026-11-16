import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/models/redactable.dart';
import 'package:zestssh/providers/identity_providers.dart';

/// How many hosts the dialog that deletes a key names before "and N more".
const kKeyUsersNamed = 5;

/// The hosts that sign in with key [keyId], one line each, for the dialog
/// that deletes it: their names in the order the Keys page lists them, up to
/// [kKeyUsersNamed], then "and N more hosts" (in 4.0; before,
/// "This key is used by 3 hosts" named none of them). Empty when none
/// do, or when the hosts cannot be read (the dialog still says how many).
Future<List<String>> keyUsersLines(WidgetRef ref, AppLocalizations l10n, String keyId) async {
  final List<Connection> hosts;
  try {
    hosts = (await ref.read(identityUsageHostsProvider.future))[keyId] ?? const [];
  } catch (_) {
    return const [];
  }
  // Each by its name, else its address, masked while recording.
  return keyUsersLinesOf(l10n, [
    for (final c in hosts) c.label.isNotEmpty ? Redactable.host(c.label).display : Redactable.address(c.host).display,
  ]);
}

/// [keyUsersLines] of the hosts' [names]: up to [kKeyUsersNamed], then how
/// many more.
List<String> keyUsersLinesOf(AppLocalizations l10n, List<String> names) {
  if (names.length <= kKeyUsersNamed) return names;
  return [...names.take(kKeyUsersNamed), l10n.keyDeleteUsersMore(names.length - kKeyUsersNamed)];
}
