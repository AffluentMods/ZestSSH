import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/services/sftp_service.dart';

/// On a host without the one-step rename, an upload is put in place by SFTP's
/// own rename; a name that is taken is removed first. Every refusal of the
/// first rename removed the file: a host that said "permission denied" twice
/// was left with no file under the name (found in a review).
void main() {
  Future<List<String>> run(List<Object?> renameAnswers) async {
    final done = <String>[];
    var call = 0;
    try {
      await SftpService.replaceByRename(
        rename: () async {
          final answer = renameAnswers[call++];
          done.add('rename');
          if (answer != null) throw answer;
        },
        remove: () async => done.add('remove'),
      );
      done.add('ok');
    } catch (e) {
      done.add('threw ${e is SftpStatusError ? e.code : e.runtimeType}');
    }
    return done;
  }

  test('a name that is taken is removed and the rename made again', () async {
    expect(await run([SftpStatusError(SftpStatusCode.failure, 'Failure'), null]), ['rename', 'remove', 'rename', 'ok']);
    expect(await run([SftpStatusError(11, 'File already exists'), null]), ['rename', 'remove', 'rename', 'ok']);
  });

  test('any other refusal leaves the file where it is', () async {
    expect(await run([SftpStatusError(SftpStatusCode.permissionDenied, 'Permission denied')]), ['rename', 'threw 3']);
    expect(await run([SftpStatusError(SftpStatusCode.noSuchFile, 'No such file')]), ['rename', 'threw 2']);
    expect(await run([StateError('connection lost')]), ['rename', 'threw StateError']);
  });

  test('a rename that works the first time removes nothing', () async {
    expect(await run([null]), ['rename', 'ok']);
  });
}
