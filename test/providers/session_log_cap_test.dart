import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/providers/terminal_providers.dart';

/// The per-session connection log is copied on every append (SessionState is
/// immutable), so it must stay bounded. Regression guard for the folder-upload
/// lag: an uncapped log fed by the SSH core's per-packet trace grew to
/// hundreds of thousands of lines, each append copying the whole list.
void main() {
  test('withLog keeps at most maxConnectionLogLines, dropping the oldest',
      () {
    var s = const SessionState(status: SessionStatus.connecting);
    const total = SessionState.maxConnectionLogLines + 100;
    for (var i = 0; i < total; i++) {
      s = s.withLog('m$i');
    }
    expect(s.connectionLog, hasLength(SessionState.maxConnectionLogLines));
    expect(s.connectionLog.first, 'm100');
    expect(s.connectionLog.last, 'm${total - 1}');
  });

  test('withLog below the cap appends without dropping', () {
    var s = const SessionState(status: SessionStatus.connecting);
    for (var i = 0; i < 10; i++) {
      s = s.withLog('m$i');
    }
    expect(s.connectionLog, hasLength(10));
    expect(s.connectionLog.first, 'm0');
  });
}
