import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';

import 'passkey_fixtures.dart';

/// The JSON every platform's passkey ceremony passes through (3.3; the
/// two-step contract, sections 3.3, 3.4 and 4): ZestSSH Cloud's options as a
/// system is handed them, and a system's answer as the server reads it
/// (base64url without padding, id is rawId, the type public-key, a
/// clientDataJSON of the ceremony and challenge asked for), held to the
/// server's own options and its software authenticator's responses.
void main() {
  group('base64url', () {
    test('is written without padding and read back only as written', () {
      expect(b64u([0xfb, 0xff, 0xbf]), '-_-_');
      expect(b64u([0x61]), 'YQ');
      expect(fromB64u('YQ'), [0x61]);
      expect(fromB64u('-_-_'), [0xfb, 0xff, 0xbf]);
      for (final refused in ['', 'YQ==', '+/+/', 'YR', 'Y', 'Y Q', 7, null]) {
        expect(fromB64u(refused), isNull, reason: '$refused');
      }
      expect(fromB64u(b64u(List.filled(33, 1)), max: 32), isNull);
    });

    test('a system\'s answer is read in either alphabet, padded or not', () {
      expect(fromAnyBase64('YQ=='), [0x61]);
      expect(fromAnyBase64('YQ'), [0x61]);
      expect(fromAnyBase64('+/+/'), [0xfb, 0xff, 0xbf]);
      expect(fromAnyBase64('-_-_'), [0xfb, 0xff, 0xbf]);
      for (final refused in ['', '=', 'Y', 'Y Q', 'YQ===', 7, null]) {
        expect(fromAnyBase64(refused), isNull, reason: '$refused');
      }
    });
  });

  group('the options a phone is handed', () {
    test('are the server\'s, with the passkeys to leave out each with the transports a phone knows', () {
      final options = at(softAuthenticator(), ['creation_options']);
      final handed = creationOptionsForPlatform(options);
      expectSameFields(handed, {
        ...options,
        'excludeCredentials': [
          {'type': 'public-key', 'id': 'UFFSU1RVVldYWVpbXF1eXw', 'transports': ['nfc', 'usb']},
          {'type': 'public-key', 'id': 'YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8', 'transports': ['hybrid', 'internal']},
          // Windows' smart-card is one Android's parser has refused: a hint
          // only, so the passkey is looked for everywhere.
          {'type': 'public-key', 'id': 'cHFyc3R1dnd4eXp7fH1-f4CBgoM'},
        ],
      });
    });

    test('carry no null anywhere, and no credential that is not one', () {
      final options = at(softAuthenticator(), ['creation_options'])
        ..['hints'] = null
        ..['excludeCredentials'] = [
          {'type': 'public-key', 'id': 'UFFSU1RVVldYWVpbXF1eXw', 'transports': null},
          {'type': 'public-key', 'id': 'not base64url!'},
          {'type': 'password', 'id': 'UFFSU1RVVldYWVpbXF1eXw'},
          'UFFSU1RVVldYWVpbXF1eXw',
        ];
      (options['user']! as Map)['displayName'] = null;
      final handed = creationOptionsForPlatform(options);
      expect(handed.containsKey('hints'), isFalse);
      expect((handed['user']! as Map).containsKey('displayName'), isFalse);
      expect(handed['excludeCredentials'], [
        {'type': 'public-key', 'id': 'UFFSU1RVVldYWVpbXF1eXw'},
      ]);
      expect(jsonEncode(handed), isNot(contains('null')));
    });

    test('for a sign-in, are the server\'s, the account\'s passkeys as listed', () {
      final options = at(softAuthenticator(), ['web', 'request']);
      expectSameFields(requestOptionsForPlatform(options), options);
      final none = requestOptionsForPlatform({...options, 'allowCredentials': []});
      expect(none.containsKey('allowCredentials'), isFalse);
    });

    test('have a challenge, or none is handed on', () {
      final options = at(softAuthenticator(), ['creation_options']);
      expect(challengeOf(options), 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA');
      for (final challenge in [null, '', 'AQID', 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA=', 42]) {
        expect(
          () => challengeOf({...options, 'challenge': challenge}),
          throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'failed')),
          reason: '$challenge',
        );
      }
    });
  });

  group('the clientDataJSON the app writes itself (Windows)', () {
    test('is, byte for byte, what the server\'s own authenticator writes and the server accepts', () {
      final fixture = softAuthenticator();
      final made = clientDataJson(
        type: 'webauthn.create',
        challenge: at(fixture, ['creation_options'])['challenge']! as String,
        origin: 'https://zestssh.com',
      );
      expect(made, bytesOf(at(fixture, ['web', 'registration', 'response'])['clientDataJSON']! as String));
      final used = clientDataJson(
        type: 'webauthn.get',
        challenge: at(fixture, ['web', 'request'])['challenge']! as String,
        origin: 'https://zestssh.com',
      );
      expect(used, bytesOf(at(fixture, ['web', 'authentication', 'response'])['clientDataJSON']! as String));
      expect(utf8.decode(used), isNot(contains('topOrigin')));
    });
  });

  group('a new passkey a system hands over', () {
    const challenge = 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA';

    test('is what the server reads, as the server\'s own authenticator wrote it', () {
      final fixture = softAuthenticator();
      for (final from in ['web', 'android', 'security_key']) {
        final registration = at(fixture, [from, 'registration']);
        expectSameFields(registrationResponseOf(jsonEncode(registration), challenge: challenge), registration);
        expectSameFields(registrationResponseOf(registration, challenge: challenge), registration);
      }
    });

    test('padded, or in the standard alphabet, is written back as the server reads it', () {
      final registration = at(softAuthenticator(), ['android', 'registration']);
      String bent(String b64u) {
        final standard = b64u.replaceAll('-', '+').replaceAll('_', '/');
        return standard.padRight((standard.length + 3) ~/ 4 * 4, '=');
      }

      final inner = registration['response']! as Map<String, Object?>;
      final answer = {
        ...registration,
        'id': bent(registration['id']! as String),
        'response': {
          ...inner,
          'clientDataJSON': bent(inner['clientDataJSON']! as String),
          'attestationObject': bent(inner['attestationObject']! as String),
        },
      };
      expectSameFields(registrationResponseOf(answer, challenge: challenge), registration);
    });

    test('with its id only in rawId, or its extension results left out, is made whole', () {
      final registration = at(softAuthenticator(), ['web', 'registration']);
      final answer = {...registration}
        ..remove('id')
        ..remove('clientExtensionResults')
        ..['authenticatorAttachment'] = 'somewhere';
      final read = registrationResponseOf(answer, challenge: challenge);
      expect(read['id'], registration['rawId']);
      expect(read['clientExtensionResults'], <String, Object?>{});
      expect(read.containsKey('authenticatorAttachment'), isFalse);
      // Only rawId, padded and in the standard alphabet, as some providers give it.
      final standard = (registration['rawId']! as String).replaceAll('-', '+').replaceAll('_', '/');
      final padded = {...registration, 'rawId': standard.padRight((standard.length + 3) ~/ 4 * 4, '=')}..remove('id');
      expectSameFields(registrationResponseOf(padded, challenge: challenge), registration);
    });

    test('is refused when it lacks what the server needs, or answers another ceremony or challenge', () {
      final registration = at(softAuthenticator(), ['web', 'registration']);
      final inner = registration['response']! as Map<String, Object?>;
      final otherCredential = b64u(List.filled(16, 9));
      final refused = <String, Object?>{
        'not JSON': '{"id":',
        'not an object': '[1]',
        'no credential id': {...registration}
          ..remove('id')
          ..remove('rawId'),
        'id is not rawId': {...registration, 'rawId': otherCredential},
        'not a public key': {...registration, 'type': 'password'},
        'no response': {...registration, 'response': 'none'},
        'no attestationObject': {
          ...registration,
          'response': {...inner}..remove('attestationObject'),
        },
        'another ceremony': {
          ...registration,
          'response': {
            ...inner,
            'clientDataJSON': b64u(clientDataJson(type: 'webauthn.get', challenge: challenge, origin: 'https://zestssh.com')),
          },
        },
        'another challenge': {
          ...registration,
          'response': {
            ...inner,
            'clientDataJSON': b64u(clientDataJson(
                type: 'webauthn.create', challenge: b64u(List.filled(32, 7)), origin: 'https://zestssh.com')),
          },
        },
        'unreadable clientDataJSON': {
          ...registration,
          'response': {...inner, 'clientDataJSON': b64u(utf8.encode('{not json'))},
        },
      };
      for (final entry in refused.entries) {
        expect(
          () => registrationResponseOf(entry.value, challenge: challenge),
          throwsA(isA<PasskeyError>()
              .having((e) => e.code, 'code', 'failed')
              .having((e) => e.detail, 'detail', contains(entry.key))),
          reason: entry.key,
        );
      }
    });
  });

  group('a passkey\'s answer a system hands over', () {
    const challenge = 'ISIjJCUmJygpKissLS4vMDEyMzQ1Njc4OTo7PD0-P0A';

    test('is what the server reads, as the server\'s own authenticator wrote it', () {
      final fixture = softAuthenticator();
      for (final from in ['web', 'android', 'security_key']) {
        final authentication = at(fixture, [from, 'authentication']);
        expectSameFields(authenticationResponseOf(jsonEncode(authentication), challenge: challenge), authentication);
      }
    });

    test('with an empty user handle has none; with one the server cannot read is refused', () {
      final authentication = at(softAuthenticator(), ['web', 'authentication']);
      final inner = authentication['response']! as Map<String, Object?>;
      final empty = authenticationResponseOf({
        ...authentication,
        'response': {...inner, 'userHandle': ''},
      }, challenge: challenge);
      expect((empty['response']! as Map).containsKey('userHandle'), isFalse);
      expect(
        () => authenticationResponseOf({
          ...authentication,
          'response': {...inner, 'userHandle': 'not base64!'},
        }, challenge: challenge),
        throwsA(isA<PasskeyError>().having((e) => e.detail, 'detail', contains('userHandle'))),
      );
    });

    test('without a signature, or for a registration, is refused', () {
      final authentication = at(softAuthenticator(), ['web', 'authentication']);
      final inner = authentication['response']! as Map<String, Object?>;
      expect(
        () => authenticationResponseOf({
          ...authentication,
          'response': {...inner}..remove('signature'),
        }, challenge: challenge),
        throwsA(isA<PasskeyError>().having((e) => e.detail, 'detail', contains('signature'))),
      );
      final registration = at(softAuthenticator(), ['web', 'registration']);
      expect(
        () => authenticationResponseOf(registration, challenge: 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA'),
        throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'failed')),
      );
    });
  });
}
