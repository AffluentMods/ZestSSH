import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/services/sftp_error_messages.dart';
import 'package:zestssh/services/sftp_service.dart';

/// On a host without the one-step rename, an upload is put in place by SFTP's
/// own rename, which most servers refuse for a name that is taken. The file
/// that is there is then moved aside, and removed only once the new one is
/// under the name. It used to be removed first: where the second rename then
/// failed, or the connection ended in between, the name held no file at all;
/// and "failure", which SFTP version 3 answers for many things, counted as a
/// name that was taken.
void main() {
  /// A folder on a host: names and what each file holds. [fail] says, for the
  /// nth rename or remove asked of it (from 1), what it answers instead.
  ({Map<String, String> files, List<String> asked, Future<void> Function() put}) host(
    Map<String, String> files, {
    Map<int, Object> fail = const {},
    bool renameOverTaken = false,
  }) {
    final asked = <String>[];
    var n = 0;
    Future<void> rename(String from, String to) async {
      n++;
      asked.add('rename $from $to');
      if (fail[n] case final answer?) throw answer;
      if (!files.containsKey(from)) throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
      if (files.containsKey(to) && !renameOverTaken) throw SftpStatusError(SftpStatusCode.failure, 'Failure');
      files[to] = files.remove(from)!;
    }

    Future<void> remove(String name) async {
      n++;
      asked.add('remove $name');
      if (fail[n] case final answer?) throw answer;
      if (files.remove(name) == null) throw SftpStatusError(SftpStatusCode.noSuchFile, 'No such file');
    }

    Future<void> put() => SftpService.replaceByRename(
          rename: () => rename('conf.zestpart', 'conf'),
          moveAside: () async {
            try {
              await remove('conf.zestold');
            } catch (_) {}
            await rename('conf', 'conf.zestold');
          },
          putBack: () => rename('conf.zestold', 'conf'),
          discard: () => remove('conf.zestold'),
          setAside: (cause) => SftpSetAsideException('/etc/conf', '/etc/conf.zestold', '/etc/conf.zestpart', cause),
        );
    return (files: files, asked: asked, put: put);
  }

  test('a name that is taken: what is there is moved aside, the new file put in, and only then is the old one removed', () async {
    final h = host({'conf': 'old', 'conf.zestpart': 'new'});
    await h.put();
    expect(h.files, {'conf': 'new'});
    expect(h.asked, [
      'rename conf.zestpart conf',
      'remove conf.zestold',
      'rename conf conf.zestold',
      'rename conf.zestpart conf',
      'remove conf.zestold',
    ]);
  });

  test('a rename that works the first time moves and removes nothing', () async {
    final h = host({'conf': 'old', 'conf.zestpart': 'new'}, renameOverTaken: true);
    await h.put();
    expect(h.files, {'conf': 'new'});
    expect(h.asked, ['rename conf.zestpart conf']);
  });

  test('any other refusal of the first rename leaves the file where it is and the new content beside it', () async {
    for (final answer in <Object>[
      SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied'),
      SftpStatusError(SftpStatusCode.noSuchFile, 'No such file'),
      StateError('connection lost'),
    ]) {
      final h = host({'conf': 'old', 'conf.zestpart': 'new'}, fail: {1: answer});
      await expectLater(h.put(), throwsA(same(answer)));
      expect(h.files, {'conf': 'old', 'conf.zestpart': 'new'}, reason: '$answer');
      expect(h.asked, ['rename conf.zestpart conf']);
    }
  });

  test('"failure" for a reason that is not the name: the second rename fails too, and the file is put back', () async {
    // A full disk, say: the host answers "failure" both times.
    final full = SftpStatusError(SftpStatusCode.failure, 'Disk quota exceeded');
    final h = host({'conf': 'old', 'conf.zestpart': 'new'}, fail: {1: full, 4: full});
    await expectLater(h.put(), throwsA(same(full)));
    expect(h.files, {'conf': 'old', 'conf.zestpart': 'new'}, reason: 'the file is as it was, the new content beside it');
  });

  test('"failure" with nothing under the name to move aside: said as it was, and nothing is touched', () async {
    final refused = SftpStatusError(SftpStatusCode.failure, 'Failure');
    final h = host({'conf.zestpart': 'new'}, fail: {1: refused});
    await expectLater(h.put(), throwsA(same(refused)));
    expect(h.files, {'conf.zestpart': 'new'});
  });

  test('the connection ends after the file was moved aside: nothing is lost, and the error says where both are', () async {
    final lost = StateError('connection lost');
    final h = host({'conf': 'old', 'conf.zestpart': 'new'}, fail: {4: lost, 5: lost});
    Object? thrown;
    try {
      await h.put();
    } catch (e) {
      thrown = e;
    }
    expect(thrown, isA<SftpSetAsideException>());
    final e = thrown! as SftpSetAsideException;
    expect([e.remotePath, e.asidePath, e.stagedPath], ['/etc/conf', '/etc/conf.zestold', '/etc/conf.zestpart']);
    expect(e.cause, same(lost));
    expect(h.files, {'conf.zestold': 'old', 'conf.zestpart': 'new'}, reason: 'what the file held is still on the host');

    // And it is said to the person, in every language, with both names.
    final en = lookupAppLocalizations(const Locale('en'));
    L10nGlobal.update(en);
    expect(
        sftpErrorMessage(SftpSetAsideException('/etc/conf', '/etc/conf.zestold', '/etc/conf.zestpart',
            SftpStatusError(SftpStatusCode.connectionLost, 'Connection lost')), name: 'conf', op: SftpOp.upload, l10n: en),
        endsWith('On the server, "conf" was moved to conf.zestold to make room for the new file, and could not be put '
            'back. Nothing is lost: what it held is in conf.zestold, the new content in conf.zestpart, both beside it. '
            'Rename the one you want back to its name.'));
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      final said = sftpErrorMessage(e, name: 'conf', op: SftpOp.upload, l10n: t);
      expect(said, contains('conf.zestold'), reason: '$locale');
      expect(said, contains('conf.zestpart'), reason: '$locale');
    }
  });

  test('one left aside by an upload that broke off there does not stop the next upload', () async {
    final h = host({'conf': 'newer', 'conf.zestold': 'oldest', 'conf.zestpart': 'newest'});
    await h.put();
    expect(h.files, {'conf': 'newest'});
  });

  test('the old file that cannot be removed afterwards stays beside the new one, and the upload is done', () async {
    final h = host({'conf': 'old', 'conf.zestpart': 'new'},
        fail: {5: SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied')});
    await h.put();
    expect(h.files, {'conf': 'new', 'conf.zestold': 'old'});
  });

  test("the name a replaced file is set aside under: its own name and a tag of this upload's; a name too long for "
      "that is set aside as a hidden file of the upload's own in its folder", () {
    final a = SftpService.asideName('/etc/conf');
    final b = SftpService.asideName('/etc/conf');
    expect(a, matches(RegExp(r'^/etc/conf\.zestold-[0-9a-f]{8}$')));
    expect(a, isNot(b), reason: 'each upload its own');
    final long = '/srv/${'x' * 240}';
    final aside = SftpService.asideName(long);
    expect(aside, matches(RegExp(r'^/srv/\.zestold-[0-9a-f]{8}$')));
    // Counted in bytes: 80 three-byte characters are 240 bytes.
    expect(SftpService.asideName('/srv/${'中' * 80}'), matches(RegExp(r'^/srv/\.zestold-[0-9a-f]{8}$')));
    final fits = '/srv/${'x' * 238}';
    expect(SftpService.asideName(fits), startsWith('$fits.zestold-'), reason: '238 + 17 = 255 bytes still fits');
    expect(SftpService.asideName('relative-name'), matches(RegExp(r'^relative-name\.zestold-[0-9a-f]{8}$')));
  });
}
