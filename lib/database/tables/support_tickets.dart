import 'package:drift/drift.dart';

/// The tickets this device has sent: a private support ticket, or a bug
/// report or suggestion that became a public forum post. One row per ticket.
///
/// What makes a ticket readable is its [token], a random secret made on this
/// device when the ticket was sent. The server keeps only the SHA-256 of it,
/// so this row is the only place the token exists: whoever holds it reads
/// the ticket and may answer on it. That is why the table lives in the
/// SQLCipher database, like the report queue, and is device-local: never in
/// the synced blob and never in a `.zest` backup. It names no account and no
/// install, and two tickets cannot be linked to each other by their tokens.
@DataClassName('SupportTicketRow')
class SupportTickets extends Table {
  /// The nonce the ticket was sent with (uuid). The key here because it
  /// exists before the server has answered.
  TextColumn get nonce => text().withLength(min: 1, max: 64)();

  /// The server's id for the ticket, once it has arrived. Null while a
  /// support ticket written offline is still waiting to be sent.
  TextColumn get serverId => text().nullable()();

  /// The number people say out loud (#10042). Null until it has arrived.
  IntColumn get number => integer().nullable()();

  /// 32 random bytes, base64url. See the class comment.
  TextColumn get token => text().withLength(min: 43, max: 43)();

  /// `support`, `bug` or `suggestion`.
  TextColumn get type => text()();

  TextColumn get title => text()();

  /// `open` or `closed` as the server last said, or `gone` once the server
  /// no longer has it (a private ticket is deleted 90 days after it closed).
  TextColumn get status => text().withDefault(const Constant('open'))();

  /// Who is waited on, as the server last said: `staff`, `user` or null.
  TextColumn get awaiting => text().nullable()();

  /// The forum tags of a public report (a JSON list of names).
  TextColumn get tags => text().withDefault(const Constant('[]'))();

  /// The forum post of a public report. Always null for a support ticket.
  TextColumn get discordUrl => text().nullable()();

  /// Epoch milliseconds.
  IntColumn get createdAt => integer()();
  IntColumn get lastMessageAt => integer().nullable()();

  IntColumn get messageCount => integer().withDefault(const Constant(0))();

  /// The newest follow-up and who wrote it (`user` or `staff`), as the server
  /// last said. A reply is unread while this is a staff message that is not
  /// [lastSeenMessageId].
  TextColumn get lastMessageId => text().nullable()();
  TextColumn get lastMessageFrom => text().nullable()();

  /// The newest follow-up the person has had on screen.
  TextColumn get lastSeenMessageId => text().nullable()();

  /// The newest follow-up a notification was shown for, so one reply never
  /// notifies twice.
  TextColumn get notifiedMessageId => text().nullable()();

  /// The conversation as last read (JSON), so it can be read with no
  /// network: the opening text and the follow-ups.
  TextColumn get conversation => text().nullable()();

  /// A support ticket that has not reached the server yet: the request that
  /// will be sent (JSON). Null once it has arrived, and always null for a
  /// report (an unsent report waits in the report queue).
  TextColumn get pending => text().nullable()();

  /// Why a waiting ticket will not be sent again: `blocked`, `account`
  /// (the account was to be included and is no longer signed in) or
  /// `rejected`. Null while it is still being tried.
  TextColumn get sendError => text().nullable()();

  @override
  Set<Column> get primaryKey => {nonce};
}

/// Follow-ups written while the server could not be reached, kept until a
/// later try delivers them. Device-local, in the SQLCipher database, for the
/// same reason as the report queue: it is free text.
@DataClassName('TicketOutboxRow')
class TicketOutbox extends Table {
  /// The follow-up's own nonce (uuid): a retry is the same message on the
  /// server, never a second one.
  TextColumn get nonce => text().withLength(min: 1, max: 64)();

  /// The ticket it belongs to ([SupportTickets.nonce]).
  TextColumn get ticketNonce => text()();

  TextColumn get body => text()();

  /// Epoch milliseconds when it was written.
  IntColumn get createdAt => integer()();

  /// Why it will not be sent again: `closed`, `gone` or `rejected`. Null
  /// while it is still being tried. The text stays so it can be copied.
  TextColumn get error => text().nullable()();

  @override
  Set<Column> get primaryKey => {nonce};
}
