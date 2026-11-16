import 'package:drift/native.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/providers/core_providers.dart';
import 'package:zestssh/providers/snippet_providers.dart';

/// A snippet is kept with line feeds between its lines, wherever it was
/// written. Text pasted on Windows ends its lines in a carriage return and a
/// line feed; kept that way it went to every other device that way, and was
/// typed there with two Enters for every line.
void main() {
  late AppDatabase db;
  late ProviderContainer container;

  setUp(() {
    db = AppDatabase.forTesting(NativeDatabase.memory());
    container = ProviderContainer(
        overrides: [databaseProvider.overrideWithValue(db)]);
  });

  tearDown(() async {
    container.dispose();
    await db.close();
  });

  SnippetCrudNotifier crud() => container.read(snippetCrudProvider);

  Future<String> commandOf(String id) async =>
      (await db.snippetsDao.getById(id))!.command;

  test('a new snippet written on Windows is kept with line feeds', () async {
    final id = await crud().create(
        label: 'Deploy', command: '(\r\nset -e\r\nnpm ci\r\n)');
    expect(await commandOf(id), '(\nset -e\nnpm ci\n)');
  });

  test('a new snippet written anywhere else is kept as it is', () async {
    final a = await crud().create(label: 'Two', command: 'cd /srv\nls -la');
    final b = await crud().create(label: 'One', command: 'uptime');
    expect(await commandOf(a), 'cd /srv\nls -la');
    expect(await commandOf(b), 'uptime');
  });

  test('saving the editor keeps line feeds', () async {
    final id = await crud().create(label: 'Deploy', command: 'uptime');
    await crud().updateFull(
      id: id,
      label: 'Deploy',
      command: 'cd /srv\r\nls -la\r\n',
      category: null,
      confirmBeforeRun: false,
      metadata: null,
    );
    expect(await commandOf(id), 'cd /srv\nls -la\n');
  });

  test('changing only the command keeps line feeds', () async {
    final id = await crud().create(label: 'Deploy', command: 'uptime');
    await crud().update(id: id, command: 'a\r\nb\rc');
    expect(await commandOf(id), 'a\nb\nc');
  });

  test('changing something else leaves the command alone', () async {
    final id = await crud().create(label: 'Deploy', command: 'a\nb');
    await crud().update(id: id, label: 'Deploy twice');
    expect(await commandOf(id), 'a\nb');
    expect((await db.snippetsDao.getById(id))!.label, 'Deploy twice');
  });

  test('nothing but the line ends of the command is changed', () async {
    const command = "printf '%s\\n' \"a\tb\"  # trailing spaces stay  ";
    final id = await crud().create(label: ' Name\r\n', command: command);
    expect(await commandOf(id), command);
    expect((await db.snippetsDao.getById(id))!.label, ' Name\r\n',
        reason: 'only the command is a command');
  });
}
