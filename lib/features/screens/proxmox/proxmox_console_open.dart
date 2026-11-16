// Remote screens (4.0): "Open console" on a phone.
import 'package:flutter/widgets.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:zestssh/database/database.dart' show Connection;
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/providers/purchase_providers.dart' show freeSessionLimit;
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/ui/widgets/top_snackbar.dart';

/// Opens [host]'s Proxmox console on a phone, as an X program is: a session
/// of its own, its screen pushed; said where the plan's session limit stops it.
Future<void> openConsoleOnPhone(BuildContext context, Connection host) async {
  final id = ProviderScope.containerOf(context, listen: false).read(activeSessionsProvider.notifier).startConsole(host);
  if (id == null) {
    showTopSnackBar(context, AppLocalizations.of(context)!.homeFreeSessionLimitSnack(freeSessionLimit), isError: true);
    return;
  }
  await context.push('/terminal/$id');
}
