import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/sftp/debounced_writer.dart';

void main() {
  group('DebouncedWriter (spec section 2)', () {
    test('ten rapid navigations are one write, the last one', () {
      fakeAsync((async) {
        final writes = <String>[];
        final w = DebouncedWriter(delay: const Duration(milliseconds: 1500));
        for (var i = 1; i <= 10; i++) {
          final path = '/srv/$i';
          w.schedule(({required bool quick}) async => writes.add(path));
          async.elapse(const Duration(milliseconds: 200));
        }
        expect(writes, isEmpty, reason: 'still inside the debounce window');
        async.elapse(const Duration(milliseconds: 1500));
        expect(writes, ['/srv/10']);
        w.dispose();
      });
    });

    test('a running transfer postpones the write instead of racing it', () {
      fakeAsync((async) {
        var transferring = true;
        var wrote = 0;
        final w = DebouncedWriter(
          delay: const Duration(seconds: 1),
          retry: const Duration(seconds: 3),
          canWriteNow: () => !transferring,
        );
        w.schedule(({required bool quick}) async {
          wrote++;
          expect(quick, isFalse);
        });
        async.elapse(const Duration(seconds: 2));
        expect(wrote, 0);
        transferring = false;
        async.elapse(const Duration(seconds: 3));
        expect(wrote, 1);
        w.dispose();
      });
    });

    test('flush writes at once, quick when a transfer holds the channel', () {
      fakeAsync((async) {
        var transferring = true;
        bool? sawQuick;
        final w = DebouncedWriter(canWriteNow: () => !transferring);
        w.schedule(({required bool quick}) async => sawQuick = quick);
        w.flush();
        async.flushMicrotasks();
        expect(sawQuick, isTrue);
        expect(w.hasPending, isFalse);

        transferring = false;
        w.schedule(({required bool quick}) async => sawQuick = quick);
        w.flush();
        async.flushMicrotasks();
        expect(sawQuick, isFalse);
        w.dispose();
      });
    });

    test('flush with nothing pending is a no-op and a throwing write is swallowed',
        () {
      fakeAsync((async) {
        final w = DebouncedWriter();
        w.flush();
        async.flushMicrotasks();
        w.schedule(({required bool quick}) async => throw StateError('db'));
        expect(() => w.flush(), returnsNormally);
        async.flushMicrotasks();
        w.dispose();
      });
    });

    test('dispose cancels a pending write', () {
      fakeAsync((async) {
        var wrote = 0;
        final w = DebouncedWriter(delay: const Duration(seconds: 1));
        w.schedule(({required bool quick}) async => wrote++);
        w.dispose();
        async.elapse(const Duration(seconds: 5));
        expect(wrote, 0);
      });
    });
  });
}
