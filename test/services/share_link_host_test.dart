// A host from a share link or a scanned code (found while
// adding a host shared as a file): it was saved into the space on screen, an
// Orchard too (past what its rules allow, into no Crate), and without the
// user, the group and the tags its dialog had shown. It goes into your Tree
// now, as a file's host does, with them; its forwards are saved and never
// started on their own.

import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/hosts/host_share_file.dart';
import 'package:zestssh/services/connection_share_url_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;
  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  ParsedConnectionShare read(Uri uri) => ConnectionShareUrlService.tryParse(uri)!;

  test('into your Tree with its user, its group and its tags, its forwards saved and not started', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final share = read(ConnectionShareUrlService.buildShareUrl(
      label: 'web 01',
      host: 'web-01.example.com',
      port: 2222,
      user: 'deploy',
      identityHint: 'deploy key',
      groupHint: 'Prod',
      tags: ['web', 'eu'],
      forwards: const [
        SharedForward(type: 'local', bindAddress: '127.0.0.1', bindPort: 8080, remoteHost: 'db.internal', remotePort: 80, label: 'web'),
      ],
    ));
    final id = await addLinkedHost(db, const FlutterSecureStorage(), share);
    final host = (await db.connectionsDao.getById(id))!;
    expect((host.label, host.host, host.port, host.protocol), ('web 01', 'web-01.example.com', 2222, 'ssh'));
    final key = (await db.identitiesDao.getById(host.identityId!))!;
    // Its user, asking for a password at sign-in; the hint names a key of
    // yours to pick, and is not one.
    expect((key.username, key.authMethod, key.label), ('deploy', 'password', 'deploy'));
    expect((await db.connectionGroupsDao.getById(host.groupId!))!.name, 'Prod');
    expect((await db.connectionTagsDao.getTagsForConnection(id)).toSet(), {'web', 'eu'});
    final forwards = await db.portForwardRulesDao.getByConnection(id);
    expect([for (final f in forwards) (f.type, f.bindPort, f.remoteHost, f.remotePort, f.label, f.autoStart)],
        [('local', 8080, 'db.internal', 80, 'web', false)]);

    // A second host of that group, in any case, goes into the same one; one
    // with no user has no key.
    final again = await addLinkedHost(db, const FlutterSecureStorage(),
        read(ConnectionShareUrlService.buildShareUrl(label: 'web 02', host: 'web-02.example.com', port: 22, groupHint: 'prod')));
    final second = (await db.connectionsDao.getById(again))!;
    expect(second.groupId, host.groupId);
    expect(await db.connectionGroupsDao.getAll(), hasLength(1));
    expect(second.identityId, isNull);
  });

  test('an address alone (add-host) is added as it came, in no group', () async {
    final db = AppDatabase.forTesting(NativeDatabase.memory());
    addTearDown(db.close);
    final id = await addLinkedHost(
        db, const FlutterSecureStorage(), read(Uri.parse('zestssh://add-host?host=192.0.2.10&port=2200&user=ops&label=Lab')));
    final host = (await db.connectionsDao.getById(id))!;
    expect((host.label, host.host, host.port, host.groupId), ('Lab', '192.0.2.10', 2200, null));
    expect((await db.identitiesDao.getById(host.identityId!))!.username, 'ops');
    expect(await db.connectionTagsDao.getTagsForConnection(id), isEmpty);
  });

  test('the app and the scanner add a link\'s host through it, into your Tree, whatever space is on screen', () {
    // An opened link and a pasted one (Import hosts, Paste a share link) go
    // through one confirmation and save (addShareLinkHost).
    final app = File('lib/app.dart').readAsStringSync();
    expect(app, contains('await addShareLinkHost(navContext, share, sourceUri);'));
    expect(app, isNot(contains('addLinkedHost(')));
    final link = File('lib/ui/screens/connection/share_link_add.dart').readAsStringSync();
    expect(link, contains('await IncomingShareDialog.show(context, payload: share, sourceUri: sourceUri);'));
    expect(link,
        contains('await addLinkedHost(container.read(treeDatabaseProvider), container.read(secureStorageProvider), share);'));
    final import = File('lib/features/cloud_import/ui/import_hosts_entry.dart').readAsStringSync();
    expect(import, contains('await addShareLinkHost(context, link.share!, link.uri!);'));
    final scan = File('lib/ui/screens/connection/qr_scan_screen.dart').readAsStringSync();
    expect(scan, contains('addLinkedHost(ref.read(treeDatabaseProvider), ref.read(secureStorageProvider), share);'));
    expect(scan, isNot(contains('connectionCrudProvider')));
  });
}
