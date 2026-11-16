import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_secure_storage_platform_interface/flutter_secure_storage_platform_interface.dart';
import 'package:flutter_test/flutter_test.dart';
// ignore: depend_on_referenced_packages
import 'package:plugin_platform_interface/plugin_platform_interface.dart';
import 'package:zestssh/features/notifications/models/app_notification.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/profiles/mac_keychain.dart';
import 'package:zestssh/ui/widgets/mac_keychain_notice.dart';

/// The plugin on a Mac, where the person says no to what [denied] names.
class _Plugin extends FlutterSecureStoragePlatform with MockPlatformInterfaceMixin {
  bool Function(String name) denied = (_) => true;

  @override
  Future<String?> read({required String key, required Map<String, String> options}) async {
    if (denied(key)) {
      throw PlatformException(code: 'Unexpected security result code', message: 'Code: -128, Message: made up', details: -128);
    }
    return 'a made-up value';
  }

  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// Said while the app is up, on a Mac (3.3.2): macOS did not let ZestSSH read one of
/// its saved keys. One notice however many it said no to, with what to do, the
/// code, Try again and the details to copy; nothing ever said it before, and the
/// next try of whatever wanted the key brought macOS's question up again.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late _Plugin plugin;
  late MacKeychain store;
  late List<AppNotification> shown;
  late List<String> removed;
  late int after;
  late MacKeychainNotice notice;

  setUp(() {
    plugin = _Plugin();
    store = MacKeychain(plugin);
    shown = [];
    removed = [];
    after = 0;
    notice = MacKeychainNotice(denials: store.denials, show: shown.add, remove: removed.add, afterTryAgain: () => after++)
      ..start();
  });

  tearDown(() => notice.stop());

  Future<void> sayNo(String name) => expectLater(store.read(key: name, options: const {}), throwsA(isA<KeychainAccessDenied>()));

  test('says it once, with what to do, its code, Try again and the details', () async {
    expect(shown, isEmpty);
    await sayNo('p.a.sync_dek');
    await sayNo('p.a.identity_key_1');
    expect(shown, hasLength(1), reason: 'one notice for every no until Try again');
    final said = shown.single;
    expect(said.id, MacKeychainNotice.id);
    expect(said.title, '${gl10n.macKeychainDeniedTitle} (ZS-1913)');
    expect(said.body, contains(gl10n.macKeychainDeniedBody));
    expect(said.body, contains('flutter_secure_storage_service'));
    expect(said.severity, NotificationSeverity.warning);
    expect(said.dismissAfter, Duration.zero, reason: 'it waits for the person');
    expect(said.actionLabel, gl10n.macKeychainTryAgain);
    expect(said.details, contains('Code: ZS-1913'));
    expect(said.details, contains('KeychainAccessDenied(-128)'));
    expect(said.details, isNot(contains('sync_dek')), reason: 'no item is named');
  });

  test('Try again: the notice goes, macOS is asked again, what waited goes on, and a new no is said again', () async {
    await sayNo('p.a.sync_dek');
    shown.single.onAction!();
    expect(removed, [MacKeychainNotice.id]);
    expect(store.denials.any, isFalse);
    expect(after, 1);

    plugin.denied = (_) => false;
    expect(await store.read(key: 'p.a.sync_dek', options: const {}), 'a made-up value');
    expect(shown, hasLength(1));

    plugin.denied = (_) => true;
    await sayNo('p.a.sync_dek');
    expect(shown, hasLength(2));
  });

  test('a no from before the app listened is said as it starts', () async {
    notice.stop();
    await sayNo('orchard_owners_v1');
    final later = <AppNotification>[];
    MacKeychainNotice(denials: store.denials, show: later.add, remove: (_) {}).start();
    expect(later, hasLength(1));
  });

  test('the app listens on a Mac, and Try again lets sync go on', () {
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('final denials = keychainDenials;'));
    expect(app, contains('_keychainNotice = MacKeychainNotice('));
    expect(app, contains('_autoSync?.triggerSync()'));
    expect(app, contains('_keychainNotice?.stop();'));
  });
}
