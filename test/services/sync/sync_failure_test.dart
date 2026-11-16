import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/core/errors/error_codes.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/cloud_reach_provider.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/sync_providers.dart';
import 'package:zestssh/services/sync/sync_backend.dart';
import 'package:zestssh/services/sync/sync_provider_config.dart';
import 'package:zestssh/services/cloud/cloud_reach.dart';
import 'package:zestssh/services/sync/sync_failure.dart';
import 'package:zestssh/services/sync_service.dart';
import 'package:zestssh/utils/error_translator.dart';

/// Sync set to go to a WebDAV server of the person's own.
class _OwnStorage extends SyncProviderConfigNotifier {
  @override
  SyncProviderConfig build() => const SyncProviderConfig(kind: SyncBackendKind.webdav);
}

/// What stopped a step of sync, as the person is told (3.0, 8 October
/// 2026). Whatever a sync failed with was "Couldn't reach the sync server"
/// in one of six wordings: ZestSSH Cloud being down, storage of the person's
/// own being down, and a failure on the device that had nothing to do with
/// any server. Each is said as what it is, with its code.
void main() {
  const refused = SocketException('Connection refused');

  tearDown(() => currentCloudReach = null);

  group('sync to ZestSSH Cloud', () {
    test('no answer: how ZestSSH Cloud stands, with what was caught kept for the details', () {
      final said = SyncFailure.ofStore(refused, hosted: true);
      expect(said.message, '${gl10n.cloudNotResponding} (ZS-1101)');
      expect(said.detail, contains('Connection refused'));
      expect(SyncFailure.ofStore(TimeoutException('no answer'), hosted: true).message,
          '${gl10n.cloudNotResponding} (ZS-1101)');
      expect(SyncFailure.ofStore(http.ClientException('Connection reset'), hosted: true).message,
          '${gl10n.cloudNotResponding} (ZS-1101)');
    });

    test('the server answering with a fault of its own, as the sync code words it: said as that', () {
      final said = SyncFailure.ofStore(const SyncException('Status check failed: Server error (HTTP 503)'), hosted: true);
      expect(said.message, '${gl10n.cloudFault(503)} (ZS-1103)');
      expect(said.message, isNot(contains('Status check failed')), reason: 'English words of the code\'s own');
      expect(said.detail, contains('HTTP 503'));
      expect(SyncFailure.ofStore(const SyncException('Pull failed: server returned HTTP 502'), hosted: true).message,
          '${gl10n.cloudFault(502)} (ZS-1103)');
    });

    test('a connection that cannot be made secure: said as that', () {
      expect(SyncFailure.ofStore(const HandshakeException('CERTIFICATE_VERIFY_FAILED'), hosted: true).message,
          '${gl10n.cloudNotSecure} (ZS-1104)');
    });

    test('what the server said in so many words is left exactly as it was said', () {
      for (final said in [
        SyncKeysMismatchException(gl10n.syncKeysNoLongerMatch),
        SyncWasResetException(gl10n.syncWasReset),
        const SyncException('No sync data found'),
        const SyncException('Not signed in'),
        const SyncException('Pull failed: server returned HTTP 404'),
        const SyncConflictException(serverVersion: 9, expectedVersion: 8),
      ]) {
        expect(SyncFailure.ofStore(said, hosted: true), same(said));
      }
    });
  });

  group('sync to storage of the person\'s own', () {
    test('no answer: what the network said, and the code that says whose storage it is', () {
      final said = SyncFailure.ofStore(refused, hosted: false);
      expect(said.message,
          '${describeNetworkError(refused, subject: gl10n.errSubjectSyncServer).message} (ZS-1201)');
      expect(said.message, isNot(contains('ZestSSH Cloud')), reason: 'it is not ZestSSH Cloud that is down');
      expect(said.detail, contains('Connection refused'));
    });

    test('their server answering with a fault of its own: its words, with that code', () {
      final said = SyncFailure.ofStore(const SyncException('Status check failed: Server error (HTTP 503)'), hosted: false);
      expect(said.message, 'Status check failed: Server error (HTTP 503) (ZS-1201)');
      expect(said.detail, isNotNull);
    });

    test('what the store said in so many words is left exactly as it was said', () {
      const said = SyncException('Recovery key has not been configured for this sync store');
      expect(SyncFailure.ofStore(said, hosted: false), same(said));
    });
  });

  group('a failure on the device', () {
    test('is said as one, with what was caught kept for the details', () {
      final said = SyncFailure.onDevice(StateError('database is locked'));
      expect(said.message, '${gl10n.syncFailedOnDevice(gl10n.accountSyncNow)} (ZS-1202)');
      expect(said.message, isNot(contains(gl10n.errSubjectSyncServer)));
      expect(said.message, contains('"${gl10n.accountSyncNow}"'), reason: 'it names the button as the page names it');
      expect(said.detail, contains('database is locked'));
    });

    test('what already says what it is stays as it was said', () {
      final merge = SyncException(gl10n.syncMergeFailed, detail: 'schema 9999');
      expect(SyncFailure.onDevice(merge), same(merge));
    });
  });

  group('the Account page\'s own steps', () {
    Future<ProviderContainer> app() async {
      SharedPreferences.setMockInitialValues(const {});
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
      ]);
      addTearDown(container.dispose);
      return container;
    }

    test('say a failure the same way, by whose storage it was (ZestSSH Cloud, unless another is chosen)', () async {
      final container = await app();
      final status = container.read(syncStatusProvider.notifier);
      status.setErrorFrom(refused);
      expect(container.read(syncStatusProvider).error, '${gl10n.cloudNotResponding} (ZS-1101)');
      expect(container.read(syncStatusProvider).errorDetail, contains('Connection refused'));
      expect(status.messageOf(refused), '${gl10n.cloudNotResponding} (ZS-1101)');
      const said = SyncException('No sync data found');
      status.setErrorFrom(said);
      expect(container.read(syncStatusProvider).error, 'No sync data found');
    });

    test('with storage of their own chosen, a failure is said of that storage', () async {
      SharedPreferences.setMockInitialValues(const {});
      final container = ProviderContainer(overrides: [
        sharedPreferencesProvider.overrideWithValue(await SharedPreferences.getInstance()),
        syncProviderConfigProvider.overrideWith(_OwnStorage.new),
      ]);
      addTearDown(container.dispose);
      final status = container.read(syncStatusProvider.notifier);
      status.setErrorFrom(refused);
      expect(container.read(syncStatusProvider).error, endsWith('(ZS-1201)'));
      expect(container.read(syncStatusProvider).error, isNot(contains('ZestSSH Cloud')));
      expect(status.messageOf(refused), endsWith('(ZS-1201)'));
    });

    test('on its own, with nobody to say whose storage it is, the notifier takes it for ZestSSH Cloud', () {
      final status = SyncStatusNotifier();
      addTearDown(status.dispose);
      expect(status.messageOf(refused), '${gl10n.cloudNotResponding} (ZS-1101)');
      final own = SyncStatusNotifier(hosted: () => false);
      addTearDown(own.dispose);
      expect(own.messageOf(refused), endsWith('(${ErrorCodes.syncStoreUnreachable.code})'));
    });
  });

  group('the app\'s own knowledge of how the service stands', () {
    test('is the one every message asks, once the app has it, and is given up with it', () async {
      SharedPreferences.setMockInitialValues(const {});
      final container = ProviderContainer();
      expect(currentCloudReach, isNull);
      final reach = container.read(cloudReachProvider);
      expect(currentCloudReach, same(reach));
      reach.networkChanged(up: false);
      expect(SyncFailure.ofStore(refused, hosted: true).message, '${gl10n.cloudDeviceOffline} (ZS-1102)');
      container.dispose();
      expect(currentCloudReach, isNull);
    });

    test('its state reaches whatever shows it', () async {
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final seen = <CloudReach>[];
      container.listen(cloudReachStateProvider, (_, next) {
        final value = next.valueOrNull;
        if (value != null) seen.add(value.reach);
      }, fireImmediately: true);
      await Future<void>.delayed(Duration.zero);
      container.read(cloudReachProvider).heard(200);
      await Future<void>.delayed(Duration.zero);
      expect(seen, [CloudReach.unknown, CloudReach.answering]);
    });
  });
}
