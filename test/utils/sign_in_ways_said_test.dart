import 'package:flutter/widgets.dart' show Locale;
import 'package:flutter_test/flutter_test.dart';
import 'package:zest_ssh_core/dartssh2.dart';
import 'package:zestssh/l10n/generated/app_localizations.dart';
import 'package:zestssh/l10n/l10n_global.dart';
import 'package:zestssh/providers/terminal_providers.dart' show connectionFailureText, jumpHostFailureText;
import 'package:zestssh/services/jump_host_failure.dart';
import 'package:zestssh/utils/error_translator.dart';

/// What a refused sign-in says, by what was tried and what the server takes
/// (3.0, the SSH core's audit).
///
/// A sign-in that the server refused said one thing, whatever it was: "The
/// server refused the sign-in: it accepted nothing that was offered." The
/// app has had a sentence for a key that the server rejected, with where to
/// look on the server, and one for a password that it rejected: neither
/// could be told from the other, since the failure did not say what had
/// been tried. And a sign-in with a password at a server that takes only
/// keys was said the same way, where the fact is that there was nothing to
/// offer it. (What the SSH core keeps of a sign-in:
/// packages/zest_ssh_core/test/src/ssh_userauth_methods_test.dart.)
void main() {
  final en = lookupAppLocalizations(const Locale('en'));

  setUp(() => L10nGlobal.update(en));
  tearDown(() => L10nGlobal.update(en));

  SSHAuthFailError refused({List<String> tried = const [], List<String>? takes}) =>
      SSHAuthFailError('All authentication methods failed', methodsTried: tried, serverTakes: takes);

  ConnectionError said(Object e, {String? username = 'deploy', String? host = 'web-01'}) =>
      ConnectionError.translate(connectionFailureText(e), host: host, port: 22, username: username);

  test('a key that the server refused, and nothing else tried: the key, with where to look on the server', () {
    final shown = said(refused(tried: ['publickey'], takes: ['publickey']));
    expect(shown.type, ConnectionErrorType.authKeyRejected);
    expect(shown.title, 'Key authentication failed');
    expect(shown.description, 'The server rejected your SSH key. (deploy@web-01)');
    expect(shown.tip, en.errKeyAuthFailedTip);
    expect(shown.tip, contains('authorized_keys'));
    // What was tried and what the server takes is kept, for whoever reads the details.
    expect(shown.rawError,
        'SSHAuthFailError(All authentication methods failed) [tried: publickey] [the server takes: publickey]');
    expect(said(refused(tried: ['publickey'], takes: ['publickey']), username: null).description,
        'The server rejected your SSH key. (web-01)');
  });

  test('a password that the server refused: the password, also where it was given as an answer to a question', () {
    for (final tried in [
      ['password'],
      ['password', 'keyboard-interactive'],
    ]) {
      final shown = said(refused(tried: tried, takes: tried));
      expect(shown.type, ConnectionErrorType.authPasswordFailed, reason: '$tried');
      expect(shown.title, 'Incorrect password');
      expect(shown.description, 'The password was rejected by web-01.');
      expect(shown.tip, en.errIncorrectPasswordTip);
    }
    expect(said(refused(tried: ['password'], takes: ['password']), host: null).description,
        en.errIncorrectPasswordDesc(en.errFallbackServerLower));
  });

  test('a key and a password, or the answers to its questions alone: it accepted nothing that was offered', () {
    for (final tried in [
      ['publickey', 'password'],
      ['publickey', 'keyboard-interactive'],
      // Its questions may have been for a code, and not for the password.
      ['keyboard-interactive'],
    ]) {
      final shown = said(refused(tried: tried, takes: tried));
      expect(shown.type, ConnectionErrorType.authFailed, reason: '$tried');
      expect(shown.title, 'Authentication failed');
      expect(shown.description, 'The server refused the sign-in: it accepted nothing that was offered. (deploy@web-01)');
      expect(shown.tip, en.errAuthFailedTip);
    }
  });

  test('a server that takes nothing this sign-in has: what it takes, and that nothing was sent to it', () {
    final onlyKeys = said(refused(takes: ['publickey']));
    expect(onlyKeys.type, ConnectionErrorType.authFailed);
    expect(onlyKeys.title, 'Authentication failed');
    expect(
      onlyKeys.description,
      'The server takes only this for a sign-in: a key. This sign-in has none of it, so nothing was sent to the '
      'server. (deploy@web-01)',
    );
    expect(onlyKeys.tip, en.errAuthFailedTip);
    expect(onlyKeys.rawError, 'SSHAuthFailError(All authentication methods failed) [tried: ] [the server takes: publickey]');

    // Several ways, one of them with no word of the app's own.
    expect(
      said(refused(takes: ['publickey', 'password', 'keyboard-interactive', 'gssapi-with-mic'])).description,
      'The server takes only this for a sign-in: a key, a password, answers to its own questions, gssapi-with-mic. '
      'This sign-in has none of it, so nothing was sent to the server. (deploy@web-01)',
    );
    // A server that takes nothing at all for this user.
    expect(said(refused(takes: const [])).description,
        'The server takes no way of signing in for this user, so nothing was sent to it. (deploy@web-01)');
    expect(said(refused(takes: const []), host: null).description,
        'The server takes no way of signing in for this user, so nothing was sent to it.');
  });

  test('what else the server takes is said where it takes more than was tried', () {
    expect(said(refused(tried: ['publickey'], takes: ['publickey', 'password'])).description,
        'The server rejected your SSH key. (deploy@web-01) The server also takes: a password.');
    expect(
      said(refused(tried: ['password', 'keyboard-interactive'], takes: ['publickey', 'password', 'keyboard-interactive']))
          .description,
      'The password was rejected by web-01. The server also takes: a key.',
    );
    expect(
      said(refused(tried: ['publickey', 'password'], takes: ['publickey', 'password', 'keyboard-interactive', 'hostbased']))
          .description,
      'The server refused the sign-in: it accepted nothing that was offered. (deploy@web-01) The server also takes: '
      'answers to its own questions, hostbased.',
    );
  });

  test('a failure that says nothing of ways is said as before', () {
    for (final plain in [
      SSHAuthFailError('All authentication methods failed'),
      SSHAuthFailError('Max authentication attempts (20) exceeded'),
    ]) {
      final shown = said(plain);
      expect(shown.type, ConnectionErrorType.authFailed);
      expect(shown.description, 'The server refused the sign-in: it accepted nothing that was offered. (deploy@web-01)');
      expect(shown.rawError, '$plain');
    }
  });

  test('what a server calls its ways is its own text: only what a name of the protocol can be is kept, and shown', () {
    final esc = String.fromCharCode(0x1b);
    final shown = said(refused(takes: [
      'publickey',
      'a]b',
      'x$esc[2J',
      'with space',
      'a,b',
      '',
      'y' * 65,
      'ok-name_1.0+x@example.com',
    ]));
    expect(
      shown.description,
      'The server takes only this for a sign-in: a key, ok-name_1.0+x@example.com. This sign-in has none of it, so '
      'nothing was sent to the server. (deploy@web-01)',
    );
    expect(shown.rawError,
        'SSHAuthFailError(All authentication methods failed) [tried: ] [the server takes: publickey,ok-name_1.0+x@example.com]');
    // A server that names very many: the first ten.
    final many = said(refused(takes: [for (var i = 0; i < 40; i++) 'way-$i']));
    expect(many.rawError, endsWith('[the server takes: ${[for (var i = 0; i < 10; i++) 'way-$i'].join(',')}]'));
    // Text that only looks like what is kept of a sign-in is not read as that.
    final looks = ConnectionError.translate(
        'SSHAuthFailError(the server said [tried: ] [the server takes: nothing] and more)',
        host: 'web-01', username: 'deploy');
    expect(looks.description, 'The server refused the sign-in: it accepted nothing that was offered. (deploy@web-01)');
  });

  test('of a jump host on the way too', () {
    final failure = JumpHostFailure(
      label: 'vpn-gateway',
      host: '192.168.10.23',
      port: 22,
      username: 'deploy',
      stage: JumpStage.signIn,
      cause: refused(takes: ['publickey']),
    );
    expect(
      jumpHostFailureText(en, failure),
      'Signing in to the jump host vpn-gateway did not work. The server takes only this for a sign-in: a key. This '
      'sign-in has none of it, so nothing was sent to the server. (deploy@192.168.10.23)',
    );
  });

  test('every language says them its own way, with its own words for the ways and between them', () {
    for (final locale in AppLocalizations.supportedLocales) {
      final l10n = lookupAppLocalizations(locale);
      L10nGlobal.update(l10n);
      final ways = [l10n.errSignInWayKey, l10n.errSignInWayPassword, l10n.errSignInWayQuestions];
      expect(ways.toSet(), hasLength(3), reason: '$locale');
      final only = said(refused(takes: ['publickey', 'password', 'keyboard-interactive']), host: null).description;
      expect(only, l10n.errSignInTakesOnly(ways.join(l10n.listSeparator)), reason: '$locale');
      for (final way in ways) {
        expect(only, contains(way), reason: '$locale');
      }
      final also = said(refused(tried: ['keyboard-interactive'], takes: ['keyboard-interactive', 'publickey']), host: null)
          .description;
      expect(also, '${l10n.errSignInRefusedDesc} ${l10n.errSignInAlsoTakes(l10n.errSignInWayKey)}', reason: '$locale');
      expect(said(refused(takes: const []), host: null).description, l10n.errSignInTakesNothing, reason: '$locale');
      if (locale.languageCode == 'en') continue;
      expect(l10n.errSignInTakesOnly('x'), isNot(en.errSignInTakesOnly('x')), reason: '$locale');
      expect(l10n.errSignInTakesNothing, isNot(en.errSignInTakesNothing), reason: '$locale');
      expect(l10n.errSignInAlsoTakes('x'), isNot(en.errSignInAlsoTakes('x')), reason: '$locale');
      for (var i = 0; i < 3; i++) {
        expect(ways[i], isNot([en.errSignInWayKey, en.errSignInWayPassword, en.errSignInWayQuestions][i]),
            reason: '$locale');
      }
    }
  });
}
