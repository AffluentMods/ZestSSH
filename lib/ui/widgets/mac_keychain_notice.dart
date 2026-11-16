import 'package:flutter/foundation.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/utils/error_report.dart';

/// Says, while the app is up, that macOS did not let ZestSSH read one of its own
/// saved keys (3.3.2; ZS-1913): what to do (Try again, then Always Allow and the
/// Mac's login password), that it repeats after each update until the Mac app is
/// signed by Apple, that the flutter_secure_storage_service items are never to be
/// deleted, and the details to copy. One notice, however many items macOS said no
/// to; it goes when Try again is chosen, and comes again only for a new no.
///
/// Try again clears what was said no to ([KeychainDenials.tryAgain]): work that
/// waited (sync, a team's rounds) goes on, and macOS asks again where it reads.
/// What Try again on the notice does for sync: the store sync uses is read
/// again ([readAgain]), and only then does sync go on ([sync], which may have
/// nothing to run), whether the read worked or not (3.4.2: the hosted default
/// stood for the store for the whole run).
Future<void> readAgainThenSync({required Future<void> Function() readAgain, required Future<void>? Function() sync}) async {
  try {
    await readAgain();
  } finally {
    final running = sync();
    if (running != null) await running;
  }
}

class MacKeychainNotice {
  MacKeychainNotice({required this.denials, required this.show, required this.remove, this.afterTryAgain});

  final KeychainDenials denials;

  /// Puts a notice on screen ([NotificationCenter.show]), and takes it off.
  final void Function(AppNotification notice) show;
  final void Function(String id) remove;

  /// Run once Try again was chosen: what waited may go now (a sync).
  final VoidCallback? afterTryAgain;

  static const id = 'mac-keychain-denied';

  bool _shown = false;
  bool _listening = false;

  /// Listens from now on, and says at once what was said no to before (a read
  /// at the start that did not stop it).
  void start() {
    if (_listening) return;
    _listening = true;
    denials.addListener(_changed);
    _changed();
  }

  void stop() {
    if (!_listening) return;
    _listening = false;
    denials.removeListener(_changed);
  }

  void _changed() {
    if (!denials.any) {
      if (_shown) remove(id);
      _shown = false;
      return;
    }
    if (_shown) return;
    _shown = true;
    final title = ErrorCodes.withCode(gl10n.macKeychainDeniedTitle, ErrorCodes.macKeychainDenied);
    show(AppNotification(
      id: id,
      title: title,
      body: '${gl10n.macKeychainDeniedBody}\n\n${gl10n.macKeychainDeniedWhy}',
      summary: [gl10n.macKeychainDeniedBody],
      severity: NotificationSeverity.warning,
      // It waits for the person: nothing that needs those keys goes on until then.
      dismissAfter: Duration.zero,
      actionLabel: gl10n.macKeychainTryAgain,
      onAction: tryAgain,
      details: ErrorReport.build(what: title, where: 'Reading a saved key from the macOS keychain', error: denials.last),
    ));
  }

  /// The notice's Try again.
  void tryAgain() {
    if (_shown) remove(id);
    _shown = false;
    denials.tryAgain();
    afterTryAgain?.call();
  }
}
