import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_health.dart';
import 'package:zestssh/services/sync_service.dart';

/// What is said of a sync that is failing, wherever it is said (the status
/// bar, the Tree's row in the switcher, the Account page): what stopped it
/// and, while the app keeps trying by itself, that it does, so that nobody
/// thinks a server that is down for a while is theirs to do something about.
/// [unknown] stands in where nothing is known of what stopped it.
///
/// A message that ends in a code keeps it at the end. And where the message
/// itself already says that the app keeps at it (ZestSSH Cloud not
/// responding: "... and ZestSSH keeps checking"), it is not said twice.
String syncFailingText(SyncHealthState health, AppLocalizations l10n, {required String unknown}) {
  final problem = health.problem ?? unknown;
  if (!health.retrying) return problem;
  final (bare, code) = ErrorCodes.withoutCode(problem);
  if (code == ErrorCodes.cloudNotResponding) return problem;
  final said = l10n.syncFailingKeepsTrying(bare);
  return code == null ? said : ErrorCodes.withCode(said, code);
}

/// What is said when a restore with a recovery key did not go through:
/// [keyDidNotWork] only for a key the store refused. A store that could not
/// be asked says nothing of the key, and is said as what it is, in the words
/// the Account page gives the same failure ([hosted]: whether the store is
/// ZestSSH Cloud). Either way it ends in its code.
String recoveryRestoreFailedText(Object error, String keyDidNotWork, {required bool hosted}) =>
    error is SyncRecoveryKeyWrongException
        ? ErrorCodes.withCode(keyDidNotWork, ErrorCodes.recoveryKeyRefused)
        : SyncFailure.ofStore(error, hosted: hosted).message;
