// A server's host key that reached this device by sync or from a backup is
// pointed out the first time a person opens a session to that server. A run
// with nobody there (automation) connects through the same verifier: it
// trusts the key, as it is the one this device was given, but it must not
// count as the person having been told, or the notice is used up with nobody
// to see it.
import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' show Value, driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/desktop_providers.dart';
import 'package:zestssh/providers/settings_providers.dart';
import 'package:zestssh/providers/terminal_providers.dart';
import 'package:zestssh/utils/openssh_key_serializer.dart';
import 'package:zestssh/services/ssh_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  const host = 'web1.example.com';
  late AppDatabase db;
  late ProviderContainer container;
  final key = SSHHostKey(type: 'ssh-ed25519', bytes: Uint8List.fromList(List<int>.generate(51, (i) => (7 + i) & 0xff)));

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    final prefs = await SharedPreferences.getInstance();
    db = AppDatabase.forTesting(NativeDatabase.memory());
    final at = DateTime(2026, 11, 16);
    await db.into(db.connections).insert(ConnectionsCompanion.insert(id: 'h1', label: 'web1', host: host, createdAt: at, updatedAt: at));
    // As a sync or a restore leaves it: recorded on another device, not yet matched on this one.
    await db.knownHostsDao.upsertHost(KnownHostsCompanion(
      id: const Value('adopted'),
      host: const Value(host),
      port: const Value(22),
      keyType: Value(key.type),
      fingerprint: Value(OpenSSHKeySerializer.fingerprintFromBlob(key.bytes)),
      publicKeyBase64: Value(base64Encode(key.bytes)),
      firstSeen: Value(DateTime.utc(2026, 8, 14)),
      lastSeen: Value(DateTime.utc(2026, 8, 14)),
      recordedDevice: const Value('ANOTHER-PC'),
      locallyVerified: const Value(false),
    ));
    container = ProviderContainer(overrides: [
      databaseProvider.overrideWithValue(db),
      sharedPreferencesProvider.overrideWithValue(prefs),
      askBeforeTrustingKeysProvider.overrideWith((ref) => true),
    ]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  Future<bool> connect({required bool unattended}) => container
      .read(activeSessionsProvider.notifier)
      .debugHostKeyVerifier(connectionId: 'h1', dialedHost: host, dialedPort: 22, unattended: unattended)(host, 22, key);

  Future<bool> confirmedHere() async => (await db.knownHostsDao.findHost(host, 22, key.type))!.locallyVerified;

  test('a run with nobody there trusts a key that came by sync and leaves its notice for the person', () async {
    expect(await connect(unattended: true), isTrue);
    expect(await confirmedHere(), isFalse, reason: 'nobody was told: the notice is still owed');

    // The person's own first session: told, once.
    container.read(hostKeyProvenanceProvider.notifier).state = null;
    expect(await connect(unattended: false), isTrue);
    expect(container.read(hostKeyProvenanceProvider)?.device, 'ANOTHER-PC');
    expect(await confirmedHere(), isTrue);
  });
}
