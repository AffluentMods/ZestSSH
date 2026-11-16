import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xterm/xterm.dart';
import 'package:zestssh/features/snippets/run_snippet.dart';
import 'package:zestssh/providers/settings_providers.dart';

/// A snippet picked from the list inside a session (on a phone, and in a
/// session window of its own): typed at the prompt, and entered when the
/// person has "Press Enter after pasting a snippet" on. Its line ends are
/// typed as one Enter each, however the snippet was written.
void main() {
  late Terminal terminal;
  late StringBuffer typed;

  setUp(() {
    terminal = Terminal();
    typed = StringBuffer();
    terminal.onOutput = typed.write;
  });

  ProviderContainer settings({required bool pressEnter}) {
    final container = ProviderContainer(overrides: [
      autoExecuteSnippetsProvider.overrideWith((ref) => pressEnter),
    ]);
    addTearDown(container.dispose);
    return container;
  }

  test('with the setting off it is typed and waits for Enter', () {
    typePickedSnippet(settings(pressEnter: false).read, terminal, 'df -h');
    expect(typed.toString(), 'df -h');
  });

  test('with the setting on it is entered', () {
    typePickedSnippet(settings(pressEnter: true).read, terminal, 'df -h');
    expect(typed.toString(), 'df -h\r');
  });

  test('a snippet written on Windows gets one Enter per line, off or on', () {
    const written = 'cd /srv/app\r\nnpm ci\r\nnpm run build';
    typePickedSnippet(settings(pressEnter: false).read, terminal, written);
    expect(typed.toString(), 'cd /srv/app\rnpm ci\rnpm run build');

    typed.clear();
    typePickedSnippet(settings(pressEnter: true).read, terminal, written);
    expect(typed.toString(), 'cd /srv/app\rnpm ci\rnpm run build\r');
  });

  test('a snippet that ends with a line end is entered once, not twice', () {
    typePickedSnippet(settings(pressEnter: true).read, terminal, 'uptime\r\n');
    expect(typed.toString(), 'uptime\r');
  });

  test('the setting is read each time, not kept', () {
    final container = settings(pressEnter: false);
    typePickedSnippet(container.read, terminal, 'a');
    container.read(autoExecuteSnippetsProvider.notifier).state = true;
    typePickedSnippet(container.read, terminal, 'b');
    expect(typed.toString(), 'ab\r');
  });
}
