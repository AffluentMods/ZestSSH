import 'dart:convert';
import 'dart:typed_data';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/services/known_hosts_service.dart';
import 'package:zestssh/services/profiles/guest_tables.dart';
import 'package:zestssh/services/ssh_service.dart';

/// Bringing guest data into an account follows the host key rule of every restore (found
/// in a security review): the restore turned away a
/// second key type for a host the account confirmed under another, and the carry of
/// what the restore left then copied that row as it was, confirmed (found in a
/// later review). Someone else using guest data on the computer
/// accepts a man in the middle's ECDSA key for bastion:22; the account, which confirmed
/// bastion under ed25519, brings guest data in; the man in the middle offering only
/// ECDSA was then trusted with no question.
Uint8List _blob(String type, int seed) {
  final buf = BytesBuilder();
  void s(List<int> b) {
    buf.add([(b.length >> 24) & 255, (b.length >> 16) & 255, (b.length >> 8) & 255, b.length & 255]);
    buf.add(b);
  }

  s(utf8.encode(type));
  s(List<int>.generate(32, (i) => (i * 7 + seed) & 255));
  return buf.toBytes();
}

void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase account;
  late AppDatabase guest;
  setUp(() {
    account = AppDatabase.forTesting(NativeDatabase.memory());
    guest = AppDatabase.forTesting(NativeDatabase.memory());
  });
  tearDown(() async {
    await account.close();
    await guest.close();
  });

  final real = SSHHostKey(type: 'ssh-ed25519', bytes: _blob('ssh-ed25519', 1));
  final mitm = SSHHostKey(type: 'ecdsa-sha2-nistp256', bytes: _blob('ecdsa-sha2-nistp256', 99));

  Future<Set<(String, String?, bool)>> rowsOf(AppDatabase db, String host) async => {
        for (final r in await db.customSelect('SELECT key_type, via_scope, locally_verified FROM known_hosts WHERE host = ?', variables: [Variable(host)]).get())
          (r.read<String>('key_type'), r.read<String?>('via_scope'), r.read<bool>('locally_verified')),
      };

  test('a key type the account confirmed the host under another of stays out, and the man in the middle is a changed key', () async {
    final hosts = KnownHostsService(account.knownHostsDao);
    await hosts.trustHost('bastion.example.com', 22, real);
    expect((await hosts.verify('bastion.example.com', 22, mitm)).result, HostKeyVerifyResult.changed);
    await KnownHostsService(guest.knownHostsDao).trustHost('bastion.example.com', 22, mitm);

    await carryGuestTables(from: guest, into: account, taken: const {});

    expect(await rowsOf(account, 'bastion.example.com'), {('ssh-ed25519', null, true)});
    expect((await hosts.verify('bastion.example.com', 22, mitm)).result, HostKeyVerifyResult.changed);
    expect((await hosts.verify('bastion.example.com', 22, real)).result, HostKeyVerifyResult.trusted);
  });

  test('nor on another route of that host: through a jump host, as directly', () async {
    final hosts = KnownHostsService(account.knownHostsDao);
    await hosts.trustHost('bastion.example.com', 22, real);
    final theirs = KnownHostsService(guest.knownHostsDao);
    await theirs.trustHost('bastion.example.com', 22, mitm, viaScope: 'jump.example.com:22');
    await theirs.trustHost('bastion.example.com', 22, SSHHostKey(type: 'ssh-ed25519', bytes: _blob('ssh-ed25519', 50)), viaScope: 'jump.example.com:22');

    await carryGuestTables(from: guest, into: account, taken: const {});

    expect(await rowsOf(account, 'bastion.example.com'), {('ssh-ed25519', null, true)});
  });

  test("a host the account has not confirmed comes, but not as confirmed here: the account's first connection confirms it", () async {
    final theirs = KnownHostsService(guest.knownHostsDao);
    await theirs.trustHost('new.example.com', 2222, real);
    await theirs.trustHost('new.example.com', 2222, mitm);

    await carryGuestTables(from: guest, into: account, taken: const {});

    expect(await rowsOf(account, 'new.example.com'), {('ssh-ed25519', null, false), ('ecdsa-sha2-nistp256', null, false)});
    final hosts = KnownHostsService(account.knownHostsDao);
    expect((await hosts.verify('new.example.com', 2222, real)).result, HostKeyVerifyResult.trusted);
    expect(await rowsOf(account, 'new.example.com'), {('ssh-ed25519', null, true), ('ecdsa-sha2-nistp256', null, false)});
    // Confirmed under ed25519 now: the ECDSA key that came is a changed key, as for any restore.
    expect((await hosts.verify('new.example.com', 2222, mitm)).result, HostKeyVerifyResult.changed);
  });
}
