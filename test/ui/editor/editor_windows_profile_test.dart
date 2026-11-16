import 'dart:convert';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/account_sign_out.dart' show signOutAccountWith;
import 'package:zestssh/providers/auth_providers.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/profile_providers.dart';
import 'package:zestssh/providers/purchase_providers.dart';
import 'package:zestssh/services/account/device_sessions.dart';
import 'package:zestssh/services/account_secrets.dart';
import 'package:zestssh/services/profiles/active_profile.dart';
import 'package:zestssh/services/profiles/keychain.dart';
import 'package:zestssh/services/profiles/profile_manager.dart';
import 'package:zestssh/services/profiles/profile_preferences.dart';
import 'package:zestssh/services/secret_seal.dart';
import 'package:zestssh/ui/screens/editor/editor_document.dart';
import 'package:zestssh/ui/screens/editor/editor_drafts.dart';
import 'package:zestssh/ui/screens/editor/editor_windows.dart';
import 'package:zestssh/ui/screens/editor/editor_workspace.dart';

import '../../helpers/fake_editor_source.dart';
import '../../services/profiles/profile_world.dart';

class _Pro extends StateNotifier<bool> implements ProStatusNotifier {
  _Pro() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Juiced extends StateNotifier<bool> implements CloudSyncStatusNotifier {
  _Juiced() : super(false);
  @override
  Future<void> refresh() async {}
  @override
  void signedOut() {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

class _Devices implements DeviceSessionService {
  @override
  Future<void> signOutHere({Duration within = const Duration(seconds: 6)}) async {}
  @override
  Future<void> forget() async {}
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}

/// The windows' plugin as the main window sees it: windows opened, closed,
/// and what each was handed.
class _Backend implements EditorWindowBackend {
  final open = <int>[];
  final closed = <int>[];
  final editKeys = <int, String>{};
  int _next = 7;

  @override
  Future<int> createWindow(String payload) async {
    final id = _next++;
    editKeys[id] = (jsonDecode(payload) as Map)['editKey'] as String;
    open.add(id);
    return id;
  }

  @override
  Future<void> place(int id, Rect frame, String title) async {}
  @override
  Future<void> focus(int id) async {}
  @override
  Future<Object?> invoke(int id, String method, [Object? arguments]) async => 'ok';
  @override
  Future<List<int>> windowIds() async => List.of(open);
  @override
  Future<void> close(int id) async {
    open.remove(id);
    closed.add(id);
  }
}

/// Found in a 3.4.1 security review: the editor's windows of their own outlived a
/// sign-out or a change of account. The file stayed on screen and editable,
/// each keystroke's draft went into the profile then on screen (guest data
/// after a sign-out, another account's after a switch), and the next
/// person's files opened in that window beside the last person's tabs. Now
/// every change of profile closes them and forgets their tabs, a window's
/// drafts go only to the profile that opened it, and the main window's own
/// editor is emptied as before.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late ProfileWorld world;
  late _Backend backend;
  late Future<void> Function(String) endBefore;

  setUp(() async {
    L10nGlobal.update(lookupAppLocalizations(const Locale('en')));
    world = await ProfileWorld.create();
    endBefore = ProfileController.endSession;
    ProfileController.endSession = (_) async {};
    backend = _Backend();
  });
  tearDown(() async {
    ProfileController.endSession = endBefore;
    EditorWindows.instance
      ..reset()
      ..backend = const PluginEditorWindowBackend()
      ..drafts = null
      ..profile = () => Profiles.current?.id;
    await world.dispose();
  });

  ProviderContainer app(AppDatabase db) {
    final c = ProviderContainer(overrides: [
      sharedPreferencesProvider.overrideWithValue(ProfilePreferences.instance!),
      secureStorageProvider.overrideWithValue(ProfileKeychain(world.device)),
      isProProvider.overrideWith((ref) => _Pro()),
      isCloudSyncProvider.overrideWith((ref) => _Juiced()),
      deviceSessionServiceProvider.overrideWithValue(_Devices()),
    ]);
    c.read(databaseSessionProvider.notifier).seed(db);
    addTearDown(c.dispose);
    // As main.dart wires the editor's windows to the app.
    EditorWindows.instance
      ..reset()
      ..backend = backend
      ..drafts = () {
        try {
          return c.read(editorDraftStoreProvider);
        } catch (_) {
          return null;
        }
      };
    return c;
  }

  Future<void> signIn(ProviderContainer c, ProfileController profiles, String uid) async {
    final label = '$uid@example.com';
    await profiles.openForAccount(uid: uid, label: label, bearer: 'fresh-$uid');
    final store = c.read(secureStorageProvider);
    await AccountSecret.sessionToken.write(store, 'session-of-$uid');
    await store.write(key: 'session_uid', value: uid);
    await store.write(key: 'session_email', value: label);
    c.read(desktopSessionProvider.notifier).state = UserProfile(uid: uid, email: label);
    await profiles.sessionKept();
  }

  Future<(ProfileManager, ProviderContainer, ProfileController)> signedIn(String uid) async {
    final manager = world.launch();
    await manager.start();
    final guest = await manager.openCurrent();
    SecretSeal.openTree = guest;
    final c = app(guest);
    final profiles = c.read(profileControllerProvider);
    await signIn(c, profiles, uid);
    expect(manager.currentEntry!.uid, uid);
    return (manager, c, profiles);
  }

  String draftCall(String op, String identity, [String text = '']) => jsonEncode({
        'op': op,
        'identity': identity,
        'team': null,
        if (op == 'write')
          'draft': EditorDraft(text: text, encoding: 'utf8', lineBreak: 'lf', baseHash: null, keptAt: DateTime.now())
              .toJson(),
      });

  /// A file of the profile on screen, popped out to a window of its own: its
  /// window's id.
  Future<int> popOut(FakeEditorSource source) async {
    final doc = EditorDocument.fromBytes(source, source.bytes);
    addTearDown(doc.dispose);
    expect(await EditorWindows.instance.send(doc), EditorMoveResult.moved);
    final id = backend.open.last;
    expect(await EditorWindows.instance.handle('editorInit', backend.editKeys[id], id), contains('db_password'));
    return id;
  }

  /// Nothing of window [id] or its tab is left, and nothing it sends reaches
  /// the profile on screen now.
  Future<void> expectGone(ProviderContainer c, int id, FakeEditorSource source) async {
    final windows = EditorWindows.instance;
    expect(backend.closed, contains(id), reason: 'the window closes with the profile that opened it');
    expect(windows.hasWindows, isFalse);
    expect(await windows.windowShowing(source.identity), isNull);
    expect(await windows.windowForNewFile(), isNull, reason: "the next person's files never open in it");
    expect(windows.bridge(backend.editKeys[id]!), isNull, reason: 'its tab, and the way to its host, are forgotten');
    expect(await windows.handle('editorDraft', draftCall('write', source.identity, 'db_password=team-only\nedited\n'), id),
        '');
    expect(await c.read(editorDraftStoreProvider).read(source.identity), isNull,
        reason: "a draft of the profile before never lands in this one's database");
    expect(await windows.handle('editorDraft', draftCall('read', source.identity), id), '');
    expect(await windows.handle('editorInit', backend.editKeys[id], id), '');
  }

  test('a sign-out closes the editor windows of their own; a draft one sends after it lands nowhere', () async {
    final (manager, c, _) = await signedIn('alex');
    final alex = manager.currentEntry!.id;
    final source = FakeEditorSource('/etc/app/secret.conf', text: 'db_password=team-only\n');
    final id = await popOut(source);
    // While alex is on screen, the window's drafts are alex's.
    expect(await EditorWindows.instance.handle('editorDraft', draftCall('write', source.identity, 'typed\n'), id), 'ok');
    expect((await c.read(editorDraftStoreProvider).read(source.identity))?.text, 'typed\n');

    await signOutAccountWith(c.read);
    expect(manager.currentEntry!.uid, isNull, reason: 'guest data now');
    expect(manager.currentEntry!.id, isNot(alex));
    await expectGone(c, id, source);
    await c.read(databaseSessionProvider)!.close();
  });

  test("a switch to another account closes them; the next account's files open in none of them", () async {
    final (manager, c, profiles) = await signedIn('alex');
    final alex = manager.currentEntry!.id;
    await profiles.nextSignInIs(mine: true);
    await signIn(c, profiles, 'sam');
    final sam = manager.currentEntry!.id;
    final source = FakeEditorSource('/etc/app/secret.conf', text: 'db_password=team-only\n');
    final id = await popOut(source);

    await profiles.switchTo(alex);
    expect(manager.currentEntry!.id, alex);
    await expectGone(c, id, source);

    // Back to sam: the window is not there again, and sam's draft store holds
    // nothing a window sent while alex was on screen.
    await profiles.switchTo(sam);
    expect(EditorWindows.instance.hasWindows, isFalse);
    expect(await c.read(editorDraftStoreProvider).read(source.identity), isNull);
    await c.read(databaseSessionProvider)!.close();
  });

  test('to guest data and back: a window opened in the profile before answers nothing in the next', () async {
    final (manager, c, profiles) = await signedIn('alex');
    final source = FakeEditorSource('/srv/notes.txt', text: 'db_password=team-only\n');
    final id = await popOut(source);
    await profiles.switchToGuest();
    expect(manager.currentEntry!.uid, isNull);
    await expectGone(c, id, source);
    await c.read(databaseSessionProvider)!.close();
  });

  test("the main window's own editor tabs go at a change of profile, as before", () async {
    final (manager, c, profiles) = await signedIn('alex');
    final source = FakeEditorSource('/etc/app/secret.conf', text: 'db_password=team-only\n');
    final before = c.read(editorWorkspaceProvider);
    before.add(EditorDocument.fromBytes(source, source.bytes));
    expect(before.docs, hasLength(1));

    await profiles.switchToGuest();
    expect(manager.currentEntry!.uid, isNull);
    expect(before.docs, isEmpty, reason: 'nothing of the profile before stays in memory');
    expect(c.read(editorWorkspaceProvider).docs, isEmpty);
    expect(survivesAChange, isNot(contains(editorWorkspaceProvider)));
    await c.read(databaseSessionProvider)!.close();
  });

  test("a window's drafts are refused once the profile that opened it is no longer on screen, closed or not", () async {
    // The belt to the braces: even a window the change did not reach (its
    // close lost) keeps no draft in another profile.
    var current = 'profile-a';
    final kept = _Store();
    EditorWindows.instance
      ..reset()
      ..backend = backend
      ..profile = (() => current)
      ..drafts = () => kept;
    final source = FakeEditorSource('/etc/app/secret.conf', text: 'db_password=team-only\n');
    final id = await popOut(source);
    expect(await EditorWindows.instance.handle('editorDraft', draftCall('write', source.identity, 'a\n'), id), 'ok');
    expect(kept.kept, hasLength(1));
    kept.kept.clear();

    current = 'profile-b';
    expect(await EditorWindows.instance.handle('editorDraft', draftCall('write', source.identity, 'b\n'), id), '');
    expect(await EditorWindows.instance.handle('editorDraft', draftCall('read', source.identity), id), '');
    expect(kept.kept, isEmpty, reason: 'dropped, never moved');
    // A call from a window the registry does not know is answered nothing.
    current = 'profile-a';
    expect(await EditorWindows.instance.handle('editorDraft', draftCall('write', source.identity, 'c\n'), 99), '');
    expect(kept.kept, isEmpty);
  });
}

class _Store implements EditorDraftStore {
  final kept = <String, EditorDraft>{};
  @override
  Future<EditorDraft?> read(String identity, {String? team}) async => kept[identity];
  @override
  Future<void> write(String identity, EditorDraft draft, {String? team}) async => kept[identity] = draft;
  @override
  Future<void> remove(String identity, {String? team}) async => kept.remove(identity);
  @override
  Future<void> forgetOld({DateTime? now}) async {}
}
