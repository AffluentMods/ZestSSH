import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What a failure to reach a server says (3.0). What was being
/// reached is named in the app's language (the sync server and the host
/// were named in English), a sentence that begins with it begins with a
/// capital ("the server refused the connection."), and the sentences fit
/// any subject in every language. Addresses here are made up.
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  // One failure of each kind, as the system words it.
  const kinds = {
    'dns': "ClientException with SocketException: Failed host lookup: 'sync.example.com'",
    'refused': 'SocketException: Connection refused (OS Error: Connection refused, errno = 111)',
    'timeout': 'TimeoutException after 0:00:20.000000: Future not completed',
    'tls': 'HandshakeException: Handshake error in client (OS Error: CERTIFICATE_VERIFY_FAILED)',
    'unreachable': 'SocketException: Network is unreachable (OS Error: Network is unreachable, errno = 101)',
    'other': 'Bad state: something odd',
  };

  String say(String raw, {String? subject}) => describeNetworkError(raw, subject: subject).message;

  test('each kind says what happened, and a sentence that begins with the server begins with a capital', () {
    expect(say(kinds['dns']!), "Can't find the server. Check the address and that you're online.");
    expect(say(kinds['refused']!), 'The server refused the connection. It may be offline, or the port may be wrong.');
    expect(say(kinds['timeout']!),
        "The server didn't respond in time. It may be down, or a firewall may be blocking it.");
    expect(say(kinds['tls']!),
        "Couldn't make a secure connection to the server. Its security certificate couldn't be verified.");
    expect(say(kinds['unreachable']!), "Couldn't reach the server. Check your internet or VPN connection.");
    expect(say(kinds['other']!), "Couldn't reach the server. It may be down or unreachable.");
  });

  test('what was being reached is named in the app\'s language', () {
    expect(say(kinds['refused']!, subject: en.errSubjectSyncServer), startsWith('The sync server refused the connection.'));
    expect(say(kinds['dns']!, subject: en.errSubjectHost), startsWith("Can't find the host."));
    expect(say(kinds['dns']!, subject: '  '), startsWith("Can't find the server."));
    final de = lookupAppLocalizations(const Locale('de'));
    L10nGlobal.update(de);
    expect(say(kinds['tls']!, subject: de.errSubjectSyncServer),
        'Keine sichere Verbindung möglich: der Sync-Server. Das Sicherheitszertifikat konnte nicht überprüft werden.');
    expect(say(kinds['refused']!, subject: de.errSubjectSyncServer), startsWith('Der Sync-Server hat die Verbindung abgelehnt.'));
    final ru = lookupAppLocalizations(const Locale('ru'));
    L10nGlobal.update(ru);
    expect(say(kinds['unreachable']!, subject: ru.errSubjectSyncServer),
        'Нет связи: сервер синхронизации. Проверьте подключение к интернету или VPN.');
    expect(say(kinds['refused']!, subject: ru.errSubjectHost),
        'Соединение отклонено: хост. Возможно, адрес недоступен или порт указан неверно.');
  });

  test('the raw text is kept for the details, without who signs in where', () {
    final f = describeNetworkError('ClientException: Connection refused, uri=https://demo:hunter2@dav.northwind.example/x');
    expect(f.detail, contains('https://***@dav.northwind.example/x'));
    expect(f.detail, isNot(contains('hunter2')));
  });

  test('in every language every kind is said with its subject, beginning with a capital where the script has them', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final t = lookupAppLocalizations(locale);
      L10nGlobal.update(t);
      for (final subject in [null, t.errSubjectSyncServer, t.errSubjectHost]) {
        for (final raw in kinds.values) {
          final msg = say(raw, subject: subject);
          final named = (subject ?? t.errFallbackServerLower).toLowerCase();
          expect(msg.toLowerCase(), contains(named), reason: '$locale: $msg');
          final first = msg.substring(0, 1);
          expect(first, first.toUpperCase(), reason: '$locale: $msg');
          if (locale.languageCode != 'en') expect(msg, isNot(contains(' the ')), reason: '$locale: $msg');
        }
      }
    }
  });
}
