import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:zestssh/features/orchards/guardrails.dart' show isOrchardWriteRefused;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/connection_providers.dart' show connectionCrudProvider;
import 'package:zestssh/providers/pinned_hosts_provider.dart' show pinnedHostsProvider;
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Deletes the host [id], once asked, as a single delete does it: the host
/// and what hangs on it in one transaction, then its pin (pins are kept in
/// the app's settings, not the database, and would be left behind). Where it
/// could not go it says why, as the selection's Delete says it: a team
/// vault's refusal in the words every change refused there uses, anything
/// else with its details. The Hosts page on a computer and a host's own menu
/// on a phone delete through here; neither caught a refusal, which went
/// unsaid. True where the host went.
Future<bool> deleteOneHost(BuildContext context, WidgetRef ref, String id) async {
  final l10n = AppLocalizations.of(context)!;
  final crud = ref.read(connectionCrudProvider);
  final pins = ref.read(pinnedHostsProvider.notifier);
  try {
    await crud.delete(id);
  } catch (e) {
    if (context.mounted) {
      final refused = isOrchardWriteRefused(e);
      showTopSnackBar(
        context,
        refused ? l10n.orchardWriteNotAllowed : l10n.hostNotDeleted,
        isError: true,
        details: refused ? null : '$e',
      );
    }
    return false;
  }
  await pins.unpin(id);
  return true;
}
