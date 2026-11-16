import 'package:drift/drift.dart' show driftRuntimeOptions;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/database/database.dart';
import 'package:zestssh/features/tickets/ticket_models.dart';
import 'package:zestssh/features/tickets/ticket_similar.dart';

/// The Support Hub's "Before you send": which of the reports on this device
/// look like what is being written. Words only, on this device.
void main() {
  driftRuntimeOptions.dontWarnAboutMultipleDatabases = true;

  late AppDatabase db;
  setUp(() => db = AppDatabase.forTesting(NativeDatabase.memory()));
  tearDown(() => db.close());

  var made = 0;
  Future<SupportTicketRow> ticket(String title, {String body = '', TicketType type = TicketType.bug, int? at}) async {
    made++;
    final nonce = 'ticket-$made';
    await db.into(db.supportTickets).insert(SupportTicketsCompanion.insert(
          nonce: nonce,
          token: List.filled(43, 'a').join(),
          type: type.wire,
          title: title,
          createdAt: at ?? DateTime(2026, 10, 1).millisecondsSinceEpoch + made,
        ));
    await db.customStatement(
        'UPDATE support_tickets SET conversation = ? WHERE nonce = ?', [TicketConversation(body: body).encode(), nonce]);
    return (await (db.select(db.supportTickets)..where((t) => t.nonce.equals(nonce))).getSingle());
  }

  test('nothing typed, nothing close', () async {
    final t = await ticket('Split pane loses focus');
    expect(similarTickets([t], TicketType.bug, ''), isEmpty);
    expect(similarTickets([t], TicketType.bug, '   '), isEmpty);
    // Words too small or too common to say anything.
    expect(similarTickets([t], TicketType.bug, 'it is a the and'), isEmpty);
  });

  test('close means words in common, in the subject or the text, whatever their case', () async {
    final a = await ticket('Split pane loses focus', body: 'After an SFTP upload the terminal takes no keys.');
    final b = await ticket('Theme preview flickers', body: 'On resize.');
    final found = similarTickets([a, b], TicketType.bug, 'TERMINAL takes no keys after an upload');
    expect(found.map((t) => t.nonce), [a.nonce]);
  });

  test('only of the same kind: a bug is not close to a private ticket', () async {
    final bug = await ticket('Upload loses focus');
    final help = await ticket('Upload loses focus', type: TicketType.support);
    final idea = await ticket('Upload loses focus', type: TicketType.suggestion);
    final all = [bug, help, idea];
    expect(similarTickets(all, TicketType.bug, 'upload loses focus').map((t) => t.nonce), [bug.nonce]);
    expect(similarTickets(all, TicketType.support, 'upload loses focus').map((t) => t.nonce), [help.nonce]);
    expect(similarTickets(all, TicketType.suggestion, 'upload loses focus').map((t) => t.nonce), [idea.nonce]);
  });

  test('one word is enough while only a word or two has been typed; then it takes two and a quarter', () async {
    final t = await ticket('Terminal loses focus');
    expect(similarTickets([t], TicketType.bug, 'terminal'), hasLength(1));
    expect(similarTickets([t], TicketType.bug, 'terminal stops'), hasLength(1));
    expect(similarTickets([t], TicketType.bug, 'terminal stops taking keys'), isEmpty, reason: 'one word in common of four');
    expect(similarTickets([t], TicketType.bug, 'terminal focus stops taking keys'), hasLength(1), reason: 'two of five');
    expect(
      similarTickets([t], TicketType.bug, 'terminal focus alpha bravo charlie delta echo foxtrot golf'),
      isEmpty,
      reason: 'two of nine is under a quarter',
    );
  });

  test('the closest first, the newest among equals, three at most', () async {
    final closest = await ticket('Upload loses focus in a split pane');
    final older = await ticket('Upload loses focus');
    final newer = await ticket('Upload loses focus');
    final last = await ticket('Upload loses focus');
    final fifth = await ticket('Upload loses focus');
    final found = similarTickets([older, newer, closest, last, fifth], TicketType.bug, 'upload loses focus split pane');
    expect(found, hasLength(3));
    expect(found.first.nonce, closest.nonce);
    expect(found[1].nonce, fifth.nonce);
    expect(found[2].nonce, last.nonce);
  });

  test('letters of any alphabet are words', () async {
    final t = await ticket('Терминал теряет фокус');
    expect(similarTickets([t], TicketType.bug, 'терминал теряет'), hasLength(1));
  });
}
