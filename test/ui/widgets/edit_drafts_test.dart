import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/spaces.dart';
import 'package:zestssh/ui/widgets/edit_drafts.dart';

/// The one store every desktop editor keeps its unsaved edits in while its
/// page is away (a terminal shown in its place): in memory, by the key of what
/// was edited, in the space it was edited in.
void main() {
  test(
    'the draft open as the page went comes back once, and is then the page\'s',
    () {
      final drafts = EditDrafts<String>();
      drafts.keep('rule-1', 'edited');
      expect(drafts.isEmpty, isFalse);
      expect(drafts.takeOpen(), 'edited');
      expect(drafts.isEmpty, isTrue);
      expect(drafts.takeOpen(), isNull);
    },
  );

  test(
    'a draft kept in one space does not come back in another, and is let go',
    () {
      final let = <String>[];
      final drafts = EditDrafts<String>(onForget: let.add);
      drafts.keep('key-1', 'personal edit', scope: const TreeSpace());
      expect(drafts.takeOpen(scope: const OrchardSpace('acme')), isNull);
      expect(drafts.isEmpty, isTrue);
      expect(let, ['personal edit']);

      drafts.keep('key-1', 'team edit', scope: const OrchardSpace('acme'));
      expect(drafts.takeOpen(scope: const OrchardSpace('acme')), 'team edit');
      expect(let, ['personal edit'], reason: 'taken, not let go');
    },
  );

  test('forget and a draft kept over another let the old one go', () {
    final let = <String>[];
    final drafts = EditDrafts<String>(onForget: let.add);
    drafts.keep('a', 'first');
    drafts.keep('a', 'second');
    expect(let, ['first']);
    drafts.forget('a');
    expect(let, ['first', 'second']);
    expect(drafts.openKey, isNull);
    expect(drafts.isEmpty, isTrue);
  });

  test(
    'the provider lets everything go when it is built again (a change of profile)',
    () {
      final let = <String>[];
      final provider = editDraftsProvider<String>(onForget: let.add);
      final container = ProviderContainer();
      addTearDown(container.dispose);
      container.read(provider).keep('x', 'kept');
      container.invalidate(provider);
      expect(container.read(provider).isEmpty, isTrue);
      expect(let, ['kept']);
    },
  );
}
