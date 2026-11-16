import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/passkeys/passkey_json.dart';
import 'package:zestssh/services/passkeys/passkey_platform.dart';
import 'package:zestssh/services/passkeys/windows_passkeys.dart';
import 'package:zestssh/services/passkeys/windows_webauthn.dart';

import 'passkey_fixtures.dart';

/// Windows' passkey ceremonies (3.3, A5): webauthn.dll through dart:ffi. The
/// dialog itself is never opened here; what is held is everything around
/// it: ZestSSH Cloud's options read into what the DLL is handed, those
/// structs laid out byte for byte as webauthn.h lays them out (the offsets
/// below are MSVC's for the Windows SDK 10.0.26100 header, printed by a
/// program compiled against it), what the DLL hands back read into the JSON
/// the server takes (held field by field to what the server's own software
/// authenticator writes, with the clientDataJSON the app writes byte for byte
/// the same), and each failure's meaning. On Windows the DLL is loaded and
/// asked its version and the names it gives the failures, which shows
/// nothing.
void main() {
  group('the options, read', () {
    test('a making of a passkey: the server\'s every field, and the clientDataJSON the server accepts', () {
      final fixture = softAuthenticator();
      final c = winCreationOf(at(fixture, ['creation_options']));
      expect(c.rpId, 'zestssh.com');
      expect(c.rpName, 'ZestSSH');
      expect(c.userId, List.generate(32, (i) => 0xa0 + i));
      expect(c.userName, 'river@example.com');
      expect(c.userDisplayName, 'river@example.com');
      expect(c.algorithms, [-7, -8, -257]);
      expect([for (final e in c.exclude) b64u(e.id)],
          ['UFFSU1RVVldYWVpbXF1eXw', 'YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8', 'cHFyc3R1dnd4eXp7fH1-f4CBgoM']);
      expect([for (final e in c.exclude) e.transports], [
        ['nfc', 'usb'],
        ['hybrid', 'internal'],
        ['smart-card'],
      ]);
      expect(c.timeoutMs, 300000);
      expect(c.attachment, kAttachmentAny);
      expect(c.preferResidentKey, isTrue);
      expect(c.requireResidentKey, isFalse);
      expect(c.userVerification, kUserVerificationPreferred);
      expect(c.attestation, kAttestationNone);
      expect(c.credProps, isTrue);
      expect(c.challenge, 'AQIDBAUGBwgJCgsMDQ4PEBESExQVFhcYGRobHB0eHyA');
      expect(c.clientData, bytesOf(at(fixture, ['web', 'registration', 'response'])['clientDataJSON']! as String));
    });

    test('a sign-in: the RP ID, the account\'s passkeys, and the clientDataJSON the server accepts', () {
      final fixture = softAuthenticator();
      final r = winAssertionRequestOf(at(fixture, ['web', 'request']));
      expect(r.rpId, 'zestssh.com');
      expect([for (final a in r.allow) b64u(a.id)], [at(fixture, ['web', 'registration'])['id']]);
      expect(r.allow.single.transports, ['hybrid', 'internal']);
      expect(r.timeoutMs, 120000);
      expect(r.userVerification, kUserVerificationPreferred);
      expect(r.clientData, bytesOf(at(fixture, ['web', 'authentication', 'response'])['clientDataJSON']! as String));
    });

    test('a passkey is never made or used for another site', () {
      final fixture = softAuthenticator();
      final creation = at(fixture, ['creation_options']);
      for (final options in [
        {...creation, 'rp': {'id': 'example.com', 'name': 'ZestSSH'}},
        {...creation, 'rp': {'id': 'evil.zestssh.com.example', 'name': 'ZestSSH'}},
      ]) {
        expect(() => winCreationOf(options),
            throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'security')));
      }
      expect(() => winAssertionRequestOf({...at(fixture, ['web', 'request']), 'rpId': 'accounts.example.com'}),
          throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'security')));
      // Where the options name none, it is zestssh.com's.
      expect(winAssertionRequestOf({...at(fixture, ['web', 'request'])}..remove('rpId')).rpId, 'zestssh.com');
    });

    test('what a passkey needs is there, or nothing is asked of Windows', () {
      final creation = at(softAuthenticator(), ['creation_options']);
      final user = creation['user']! as Map<String, Object?>;
      for (final options in [
        {...creation}..remove('challenge'),
        {...creation}..remove('rp'),
        {...creation}..remove('user'),
        {...creation, 'user': {...user}..remove('name')},
        {...creation, 'user': {...user, 'id': b64u(List.filled(65, 1))}},
      ]) {
        expect(() => winCreationOf(options), throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'failed')));
      }
    });

    test('WebAuthn\'s own rules where the server says less: algorithms, time, a passkey that signs in by itself', () {
      final creation = at(softAuthenticator(), ['creation_options']);
      final bare = winCreationOf({
        ...creation,
        'pubKeyCredParams': [],
        'timeout': 999999999,
        'authenticatorSelection': {'requireResidentKey': true, 'authenticatorAttachment': 'cross-platform'},
        'attestation': 'direct',
        'extensions': {},
        'user': {...creation['user']! as Map, 'displayName': ''},
      });
      expect(bare.algorithms, [-7, -257]);
      expect(bare.timeoutMs, 600000);
      expect(bare.requireResidentKey, isTrue);
      expect(bare.preferResidentKey, isFalse);
      expect(bare.attachment, kAttachmentCrossPlatform);
      expect(bare.attestation, kAttestationDirect);
      expect(bare.credProps, isFalse);
      expect(bare.userDisplayName, 'river@example.com');
      expect(winCreationOf({...creation}..remove('timeout')).timeoutMs, 300000);
      expect(winAssertionRequestOf({...at(softAuthenticator(), ['web', 'request']), 'timeout': 5}).timeoutMs, 10000);
    });

    test('transports as the DLL of each version knows them', () {
      expect(transportMask(['usb', 'nfc', 'ble', 'internal'], 1), 0x17);
      expect(transportMask(['hybrid', 'internal'], 5), kTransportInternal);
      expect(transportMask(['hybrid', 'internal'], 6), kTransportHybrid | kTransportInternal);
      expect(transportMask(['smart-card'], 8), 0);
      expect(transportMask(['smart-card'], 9), kTransportSmartCard);
      expect(transportMask(['bluetooth', 'cable'], 9), 0);
      expect(transportsOfMask(0x7f & ~kTransportTest), ['ble', 'hybrid', 'internal', 'nfc', 'smart-card', 'usb']);
      expect(attachmentOfTransport(kTransportInternal), 'platform');
      for (final t in [kTransportUsb, kTransportNfc, kTransportBle, kTransportHybrid, kTransportSmartCard]) {
        expect(attachmentOfTransport(t), 'cross-platform');
      }
      expect(attachmentOfTransport(0), isNull);
      expect(attachmentOfTransport(kTransportTest), isNull);
    });
  });

  group('the structs, laid out as webauthn.h lays them out', () {
    /// Writes a marker through [write] into a zeroed [size]-byte struct and
    /// holds that its bytes, and only they, are at [offset], [width] wide.
    void fieldAt(String what, int size, int offset, int width, void Function(Pointer<Uint8> buffer, int marker) write) {
      final buffer = calloc<Uint8>(size);
      try {
        final marker = width == 8 ? 0x0102030405060708 : 0x0a0b0c0d;
        write(buffer, marker);
        final little = ByteData(8)..setUint64(0, marker, Endian.little);
        final expected = Uint8List(size);
        for (var i = 0; i < width; i++) {
          expected[offset + i] = little.getUint8(i);
        }
        expect(buffer.asTypedList(size), expected, reason: what);
      } finally {
        calloc.free(buffer);
      }
    }

    Pointer<T> p<T extends NativeType>(int address) => Pointer<T>.fromAddress(address);

    test('their sizes', () {
      expect(sizeOf<WebAuthnRpEntityInformation>(), 32);
      expect(sizeOf<WebAuthnUserEntityInformation>(), 40);
      expect(sizeOf<WebAuthnClientData>(), 24);
      expect(sizeOf<WebAuthnCoseCredentialParameter>(), 24);
      expect(sizeOf<WebAuthnCoseCredentialParameters>(), 16);
      expect(sizeOf<WebAuthnCredential>(), 24);
      expect(sizeOf<WebAuthnCredentials>(), 16);
      expect(sizeOf<WebAuthnCredentialEx>(), 32);
      expect(sizeOf<WebAuthnCredentialList>(), 16);
      expect(sizeOf<WebAuthnExtension>(), 24);
      expect(sizeOf<WebAuthnExtensions>(), 16);
      expect(sizeOf<WebAuthnMakeCredentialOptions>(), 200);
      expect(sizeOf<WebAuthnGetAssertionOptions>(), 200);
      expect(sizeOf<WebAuthnCredentialAttestation>(), 192);
      expect(sizeOf<WebAuthnAssertion>(), 168);
    });

    test('what the app hands over: the RP, the user, the client data, the algorithms, a list of passkeys', () {
      WebAuthnRpEntityInformation rp(Pointer<Uint8> b) => b.cast<WebAuthnRpEntityInformation>().ref;
      fieldAt('rp.dwVersion', 32, 0, 4, (b, m) => rp(b).dwVersion = m);
      fieldAt('rp.pwszId', 32, 8, 8, (b, m) => rp(b).pwszId = p(m));
      fieldAt('rp.pwszName', 32, 16, 8, (b, m) => rp(b).pwszName = p(m));
      fieldAt('rp.pwszIcon', 32, 24, 8, (b, m) => rp(b).pwszIcon = p(m));

      WebAuthnUserEntityInformation user(Pointer<Uint8> b) => b.cast<WebAuthnUserEntityInformation>().ref;
      fieldAt('user.dwVersion', 40, 0, 4, (b, m) => user(b).dwVersion = m);
      fieldAt('user.cbId', 40, 4, 4, (b, m) => user(b).cbId = m);
      fieldAt('user.pbId', 40, 8, 8, (b, m) => user(b).pbId = p(m));
      fieldAt('user.pwszName', 40, 16, 8, (b, m) => user(b).pwszName = p(m));
      fieldAt('user.pwszIcon', 40, 24, 8, (b, m) => user(b).pwszIcon = p(m));
      fieldAt('user.pwszDisplayName', 40, 32, 8, (b, m) => user(b).pwszDisplayName = p(m));

      WebAuthnClientData data(Pointer<Uint8> b) => b.cast<WebAuthnClientData>().ref;
      fieldAt('clientData.dwVersion', 24, 0, 4, (b, m) => data(b).dwVersion = m);
      fieldAt('clientData.cbClientDataJSON', 24, 4, 4, (b, m) => data(b).cbClientDataJSON = m);
      fieldAt('clientData.pbClientDataJSON', 24, 8, 8, (b, m) => data(b).pbClientDataJSON = p(m));
      fieldAt('clientData.pwszHashAlgId', 24, 16, 8, (b, m) => data(b).pwszHashAlgId = p(m));

      WebAuthnCoseCredentialParameter param(Pointer<Uint8> b) => b.cast<WebAuthnCoseCredentialParameter>().ref;
      fieldAt('param.dwVersion', 24, 0, 4, (b, m) => param(b).dwVersion = m);
      fieldAt('param.pwszCredentialType', 24, 8, 8, (b, m) => param(b).pwszCredentialType = p(m));
      fieldAt('param.lAlg', 24, 16, 4, (b, m) => param(b).lAlg = m);
      WebAuthnCoseCredentialParameters params(Pointer<Uint8> b) => b.cast<WebAuthnCoseCredentialParameters>().ref;
      fieldAt('params.cCredentialParameters', 16, 0, 4, (b, m) => params(b).cCredentialParameters = m);
      fieldAt('params.pCredentialParameters', 16, 8, 8, (b, m) => params(b).pCredentialParameters = p(m));

      WebAuthnCredentialEx ex(Pointer<Uint8> b) => b.cast<WebAuthnCredentialEx>().ref;
      fieldAt('credentialEx.dwVersion', 32, 0, 4, (b, m) => ex(b).dwVersion = m);
      fieldAt('credentialEx.cbId', 32, 4, 4, (b, m) => ex(b).cbId = m);
      fieldAt('credentialEx.pbId', 32, 8, 8, (b, m) => ex(b).pbId = p(m));
      fieldAt('credentialEx.pwszCredentialType', 32, 16, 8, (b, m) => ex(b).pwszCredentialType = p(m));
      fieldAt('credentialEx.dwTransports', 32, 24, 4, (b, m) => ex(b).dwTransports = m);
      WebAuthnCredentialList list(Pointer<Uint8> b) => b.cast<WebAuthnCredentialList>().ref;
      fieldAt('credentialList.cCredentials', 16, 0, 4, (b, m) => list(b).cCredentials = m);
      fieldAt('credentialList.ppCredentials', 16, 8, 8, (b, m) => list(b).ppCredentials = p(m));

      WebAuthnCredential credential(Pointer<Uint8> b) => b.cast<WebAuthnCredential>().ref;
      fieldAt('credential.dwVersion', 24, 0, 4, (b, m) => credential(b).dwVersion = m);
      fieldAt('credential.cbId', 24, 4, 4, (b, m) => credential(b).cbId = m);
      fieldAt('credential.pbId', 24, 8, 8, (b, m) => credential(b).pbId = p(m));
      fieldAt('credential.pwszCredentialType', 24, 16, 8, (b, m) => credential(b).pwszCredentialType = p(m));
      WebAuthnExtension extension(Pointer<Uint8> b) => b.cast<WebAuthnExtension>().ref;
      fieldAt('extension.pwszExtensionIdentifier', 24, 0, 8, (b, m) => extension(b).pwszExtensionIdentifier = p(m));
      fieldAt('extension.cbExtension', 24, 8, 4, (b, m) => extension(b).cbExtension = m);
      fieldAt('extension.pvExtension', 24, 16, 8, (b, m) => extension(b).pvExtension = p(m));
    });

    test('WEBAUTHN_AUTHENTICATOR_MAKE_CREDENTIAL_OPTIONS, every version\'s fields', () {
      WebAuthnMakeCredentialOptions o(Pointer<Uint8> b) => b.cast<WebAuthnMakeCredentialOptions>().ref;
      final fields = <(String, int, int, void Function(Pointer<Uint8>, int))>[
        ('dwVersion', 0, 4, (b, m) => o(b).dwVersion = m),
        ('dwTimeoutMilliseconds', 4, 4, (b, m) => o(b).dwTimeoutMilliseconds = m),
        ('CredentialList.cCredentials', 8, 4, (b, m) => o(b).credentialList.cCredentials = m),
        ('CredentialList.pCredentials', 16, 8, (b, m) => o(b).credentialList.pCredentials = p(m)),
        ('Extensions.cExtensions', 24, 4, (b, m) => o(b).extensions.cExtensions = m),
        ('Extensions.pExtensions', 32, 8, (b, m) => o(b).extensions.pExtensions = p(m)),
        ('dwAuthenticatorAttachment', 40, 4, (b, m) => o(b).dwAuthenticatorAttachment = m),
        ('bRequireResidentKey', 44, 4, (b, m) => o(b).bRequireResidentKey = m),
        ('dwUserVerificationRequirement', 48, 4, (b, m) => o(b).dwUserVerificationRequirement = m),
        ('dwAttestationConveyancePreference', 52, 4, (b, m) => o(b).dwAttestationConveyancePreference = m),
        ('dwFlags', 56, 4, (b, m) => o(b).dwFlags = m),
        ('pCancellationId', 64, 8, (b, m) => o(b).pCancellationId = p(m)),
        ('pExcludeCredentialList', 72, 8, (b, m) => o(b).pExcludeCredentialList = p(m)),
        ('dwEnterpriseAttestation', 80, 4, (b, m) => o(b).dwEnterpriseAttestation = m),
        ('dwLargeBlobSupport', 84, 4, (b, m) => o(b).dwLargeBlobSupport = m),
        ('bPreferResidentKey', 88, 4, (b, m) => o(b).bPreferResidentKey = m),
        ('bBrowserInPrivateMode', 92, 4, (b, m) => o(b).bBrowserInPrivateMode = m),
        ('bEnablePrf', 96, 4, (b, m) => o(b).bEnablePrf = m),
        ('pLinkedDevice', 104, 8, (b, m) => o(b).pLinkedDevice = p(m)),
        ('cbJsonExt', 112, 4, (b, m) => o(b).cbJsonExt = m),
        ('pbJsonExt', 120, 8, (b, m) => o(b).pbJsonExt = p(m)),
        ('pPRFGlobalEval', 128, 8, (b, m) => o(b).pPRFGlobalEval = p(m)),
        ('cCredentialHints', 136, 4, (b, m) => o(b).cCredentialHints = m),
        ('ppwszCredentialHints', 144, 8, (b, m) => o(b).ppwszCredentialHints = p(m)),
        ('bThirdPartyPayment', 152, 4, (b, m) => o(b).bThirdPartyPayment = m),
        ('pwszRemoteWebOrigin', 160, 8, (b, m) => o(b).pwszRemoteWebOrigin = p(m)),
        ('cbPublicKeyCredentialCreationOptionsJSON', 168, 4,
            (b, m) => o(b).cbPublicKeyCredentialCreationOptionsJSON = m),
        ('pbPublicKeyCredentialCreationOptionsJSON', 176, 8,
            (b, m) => o(b).pbPublicKeyCredentialCreationOptionsJSON = p(m)),
        ('cbAuthenticatorId', 184, 4, (b, m) => o(b).cbAuthenticatorId = m),
        ('pbAuthenticatorId', 192, 8, (b, m) => o(b).pbAuthenticatorId = p(m)),
      ];
      for (final (name, offset, width, write) in fields) {
        fieldAt(name, 200, offset, width, write);
      }
    });

    test('WEBAUTHN_AUTHENTICATOR_GET_ASSERTION_OPTIONS, every version\'s fields', () {
      WebAuthnGetAssertionOptions o(Pointer<Uint8> b) => b.cast<WebAuthnGetAssertionOptions>().ref;
      final fields = <(String, int, int, void Function(Pointer<Uint8>, int))>[
        ('dwVersion', 0, 4, (b, m) => o(b).dwVersion = m),
        ('dwTimeoutMilliseconds', 4, 4, (b, m) => o(b).dwTimeoutMilliseconds = m),
        ('CredentialList.cCredentials', 8, 4, (b, m) => o(b).credentialList.cCredentials = m),
        ('CredentialList.pCredentials', 16, 8, (b, m) => o(b).credentialList.pCredentials = p(m)),
        ('Extensions.cExtensions', 24, 4, (b, m) => o(b).extensions.cExtensions = m),
        ('Extensions.pExtensions', 32, 8, (b, m) => o(b).extensions.pExtensions = p(m)),
        ('dwAuthenticatorAttachment', 40, 4, (b, m) => o(b).dwAuthenticatorAttachment = m),
        ('dwUserVerificationRequirement', 44, 4, (b, m) => o(b).dwUserVerificationRequirement = m),
        ('dwFlags', 48, 4, (b, m) => o(b).dwFlags = m),
        ('pwszU2fAppId', 56, 8, (b, m) => o(b).pwszU2fAppId = p(m)),
        ('pbU2fAppId', 64, 8, (b, m) => o(b).pbU2fAppId = p(m)),
        ('pCancellationId', 72, 8, (b, m) => o(b).pCancellationId = p(m)),
        ('pAllowCredentialList', 80, 8, (b, m) => o(b).pAllowCredentialList = p(m)),
        ('dwCredLargeBlobOperation', 88, 4, (b, m) => o(b).dwCredLargeBlobOperation = m),
        ('cbCredLargeBlob', 92, 4, (b, m) => o(b).cbCredLargeBlob = m),
        ('pbCredLargeBlob', 96, 8, (b, m) => o(b).pbCredLargeBlob = p(m)),
        ('pHmacSecretSaltValues', 104, 8, (b, m) => o(b).pHmacSecretSaltValues = p(m)),
        ('bBrowserInPrivateMode', 112, 4, (b, m) => o(b).bBrowserInPrivateMode = m),
        ('pLinkedDevice', 120, 8, (b, m) => o(b).pLinkedDevice = p(m)),
        ('bAutoFill', 128, 4, (b, m) => o(b).bAutoFill = m),
        ('cbJsonExt', 132, 4, (b, m) => o(b).cbJsonExt = m),
        ('pbJsonExt', 136, 8, (b, m) => o(b).pbJsonExt = p(m)),
        ('cCredentialHints', 144, 4, (b, m) => o(b).cCredentialHints = m),
        ('ppwszCredentialHints', 152, 8, (b, m) => o(b).ppwszCredentialHints = p(m)),
        ('pwszRemoteWebOrigin', 160, 8, (b, m) => o(b).pwszRemoteWebOrigin = p(m)),
        ('cbPublicKeyCredentialRequestOptionsJSON', 168, 4,
            (b, m) => o(b).cbPublicKeyCredentialRequestOptionsJSON = m),
        ('pbPublicKeyCredentialRequestOptionsJSON', 176, 8,
            (b, m) => o(b).pbPublicKeyCredentialRequestOptionsJSON = p(m)),
        ('cbAuthenticatorId', 184, 4, (b, m) => o(b).cbAuthenticatorId = m),
        ('pbAuthenticatorId', 192, 8, (b, m) => o(b).pbAuthenticatorId = p(m)),
      ];
      for (final (name, offset, width, write) in fields) {
        fieldAt(name, 200, offset, width, write);
      }
    });

    test('WEBAUTHN_CREDENTIAL_ATTESTATION and WEBAUTHN_ASSERTION, every version\'s fields', () {
      WebAuthnCredentialAttestation a(Pointer<Uint8> b) => b.cast<WebAuthnCredentialAttestation>().ref;
      final attestation = <(String, int, int, void Function(Pointer<Uint8>, int))>[
        ('dwVersion', 0, 4, (b, m) => a(b).dwVersion = m),
        ('pwszFormatType', 8, 8, (b, m) => a(b).pwszFormatType = p(m)),
        ('cbAuthenticatorData', 16, 4, (b, m) => a(b).cbAuthenticatorData = m),
        ('pbAuthenticatorData', 24, 8, (b, m) => a(b).pbAuthenticatorData = p(m)),
        ('cbAttestation', 32, 4, (b, m) => a(b).cbAttestation = m),
        ('pbAttestation', 40, 8, (b, m) => a(b).pbAttestation = p(m)),
        ('dwAttestationDecodeType', 48, 4, (b, m) => a(b).dwAttestationDecodeType = m),
        ('pvAttestationDecode', 56, 8, (b, m) => a(b).pvAttestationDecode = p(m)),
        ('cbAttestationObject', 64, 4, (b, m) => a(b).cbAttestationObject = m),
        ('pbAttestationObject', 72, 8, (b, m) => a(b).pbAttestationObject = p(m)),
        ('cbCredentialId', 80, 4, (b, m) => a(b).cbCredentialId = m),
        ('pbCredentialId', 88, 8, (b, m) => a(b).pbCredentialId = p(m)),
        ('Extensions.cExtensions', 96, 4, (b, m) => a(b).extensions.cExtensions = m),
        ('Extensions.pExtensions', 104, 8, (b, m) => a(b).extensions.pExtensions = p(m)),
        ('dwUsedTransport', 112, 4, (b, m) => a(b).dwUsedTransport = m),
        ('bEpAtt', 116, 4, (b, m) => a(b).bEpAtt = m),
        ('bLargeBlobSupported', 120, 4, (b, m) => a(b).bLargeBlobSupported = m),
        ('bResidentKey', 124, 4, (b, m) => a(b).bResidentKey = m),
        ('bPrfEnabled', 128, 4, (b, m) => a(b).bPrfEnabled = m),
        ('cbUnsignedExtensionOutputs', 132, 4, (b, m) => a(b).cbUnsignedExtensionOutputs = m),
        ('pbUnsignedExtensionOutputs', 136, 8, (b, m) => a(b).pbUnsignedExtensionOutputs = p(m)),
        ('pHmacSecret', 144, 8, (b, m) => a(b).pHmacSecret = p(m)),
        ('bThirdPartyPayment', 152, 4, (b, m) => a(b).bThirdPartyPayment = m),
        ('dwTransports', 156, 4, (b, m) => a(b).dwTransports = m),
        ('cbClientDataJSON', 160, 4, (b, m) => a(b).cbClientDataJSON = m),
        ('pbClientDataJSON', 168, 8, (b, m) => a(b).pbClientDataJSON = p(m)),
        ('cbRegistrationResponseJSON', 176, 4, (b, m) => a(b).cbRegistrationResponseJSON = m),
        ('pbRegistrationResponseJSON', 184, 8, (b, m) => a(b).pbRegistrationResponseJSON = p(m)),
      ];
      for (final (name, offset, width, write) in attestation) {
        fieldAt('attestation.$name', 192, offset, width, write);
      }

      WebAuthnAssertion s(Pointer<Uint8> b) => b.cast<WebAuthnAssertion>().ref;
      final assertion = <(String, int, int, void Function(Pointer<Uint8>, int))>[
        ('dwVersion', 0, 4, (b, m) => s(b).dwVersion = m),
        ('cbAuthenticatorData', 4, 4, (b, m) => s(b).cbAuthenticatorData = m),
        ('pbAuthenticatorData', 8, 8, (b, m) => s(b).pbAuthenticatorData = p(m)),
        ('cbSignature', 16, 4, (b, m) => s(b).cbSignature = m),
        ('pbSignature', 24, 8, (b, m) => s(b).pbSignature = p(m)),
        ('Credential.dwVersion', 32, 4, (b, m) => s(b).credential.dwVersion = m),
        ('Credential.cbId', 36, 4, (b, m) => s(b).credential.cbId = m),
        ('Credential.pbId', 40, 8, (b, m) => s(b).credential.pbId = p(m)),
        ('Credential.pwszCredentialType', 48, 8, (b, m) => s(b).credential.pwszCredentialType = p(m)),
        ('cbUserId', 56, 4, (b, m) => s(b).cbUserId = m),
        ('pbUserId', 64, 8, (b, m) => s(b).pbUserId = p(m)),
        ('Extensions.cExtensions', 72, 4, (b, m) => s(b).extensions.cExtensions = m),
        ('Extensions.pExtensions', 80, 8, (b, m) => s(b).extensions.pExtensions = p(m)),
        ('cbCredLargeBlob', 88, 4, (b, m) => s(b).cbCredLargeBlob = m),
        ('pbCredLargeBlob', 96, 8, (b, m) => s(b).pbCredLargeBlob = p(m)),
        ('dwCredLargeBlobStatus', 104, 4, (b, m) => s(b).dwCredLargeBlobStatus = m),
        ('pHmacSecret', 112, 8, (b, m) => s(b).pHmacSecret = p(m)),
        ('dwUsedTransport', 120, 4, (b, m) => s(b).dwUsedTransport = m),
        ('cbUnsignedExtensionOutputs', 124, 4, (b, m) => s(b).cbUnsignedExtensionOutputs = m),
        ('pbUnsignedExtensionOutputs', 128, 8, (b, m) => s(b).pbUnsignedExtensionOutputs = p(m)),
        ('cbClientDataJSON', 136, 4, (b, m) => s(b).cbClientDataJSON = m),
        ('pbClientDataJSON', 144, 8, (b, m) => s(b).pbClientDataJSON = p(m)),
        ('cbAuthenticationResponseJSON', 152, 4, (b, m) => s(b).cbAuthenticationResponseJSON = m),
        ('pbAuthenticationResponseJSON', 160, 8, (b, m) => s(b).pbAuthenticationResponseJSON = p(m)),
      ];
      for (final (name, offset, width, write) in assertion) {
        fieldAt('assertion.$name', 168, offset, width, write);
      }
    });
  });

  group('what the DLL is handed', () {
    List<int> bytesAt(Pointer<Uint8> p, int length) => p.asTypedList(length).toList();

    test('to make a passkey: every field the server asked, the version each DLL takes', () {
      final fixture = softAuthenticator();
      final c = winCreationOf(at(fixture, ['creation_options']));
      for (final (api, version, hybrid, smartCard) in [(1, 3, 0, 0), (3, 4, 0, 0), (6, 4, kTransportHybrid, 0), (9, 4, kTransportHybrid, kTransportSmartCard)]) {
        using((arena) {
          final args = makeCredentialArgs(arena, c, api);
          final rp = args.rp.ref;
          expect(rp.dwVersion, 1);
          expect(rp.pwszId.toDartString(), 'zestssh.com');
          expect(rp.pwszName.toDartString(), 'ZestSSH');
          expect(rp.pwszIcon, nullptr);

          final user = args.user.ref;
          expect(user.dwVersion, 1);
          expect(bytesAt(user.pbId, user.cbId), List.generate(32, (i) => 0xa0 + i));
          expect(user.pwszName.toDartString(), 'river@example.com');
          expect(user.pwszDisplayName.toDartString(), 'river@example.com');
          expect(user.pwszIcon, nullptr);

          final params = args.parameters.ref;
          expect(params.cCredentialParameters, 3);
          expect([for (var i = 0; i < 3; i++) params.pCredentialParameters[i].lAlg], [-7, -8, -257]);
          for (var i = 0; i < 3; i++) {
            expect(params.pCredentialParameters[i].dwVersion, 1);
            expect(params.pCredentialParameters[i].pwszCredentialType.toDartString(), 'public-key');
          }

          final data = args.clientData.ref;
          expect(data.dwVersion, 1);
          expect(data.pwszHashAlgId.toDartString(), 'SHA-256');
          expect(bytesAt(data.pbClientDataJSON, data.cbClientDataJSON),
              bytesOf(at(fixture, ['web', 'registration', 'response'])['clientDataJSON']! as String));

          final o = args.options.ref;
          expect(o.dwVersion, version, reason: 'API version $api');
          expect(o.dwTimeoutMilliseconds, 300000);
          expect(o.credentialList.cCredentials, 0);
          expect(o.extensions.cExtensions, 0);
          expect(o.dwAuthenticatorAttachment, kAttachmentAny);
          expect(o.bRequireResidentKey, 0);
          expect(o.dwUserVerificationRequirement, kUserVerificationPreferred);
          expect(o.dwAttestationConveyancePreference, kAttestationNone);
          expect(o.dwFlags, 0);
          expect(o.pCancellationId, nullptr);
          expect(o.bPreferResidentKey, version >= 4 ? 1 : 0);
          // Nothing of a version the app does not hand over.
          expect([o.dwEnterpriseAttestation, o.dwLargeBlobSupport, o.bBrowserInPrivateMode, o.bEnablePrf], [0, 0, 0, 0]);
          expect(o.pbPublicKeyCredentialCreationOptionsJSON, nullptr);

          final exclude = o.pExcludeCredentialList.ref;
          expect(exclude.cCredentials, 3);
          final entries = [for (var i = 0; i < 3; i++) exclude.ppCredentials[i].ref];
          expect([for (final e in entries) b64u(bytesAt(e.pbId, e.cbId))],
              ['UFFSU1RVVldYWVpbXF1eXw', 'YGFiY2RlZmdoaWprbG1ub3BxcnN0dXZ3eHl6e3x9fn8', 'cHFyc3R1dnd4eXp7fH1-f4CBgoM']);
          for (final e in entries) {
            expect(e.dwVersion, 1);
            expect(e.pwszCredentialType.toDartString(), 'public-key');
          }
          expect([for (final e in entries) e.dwTransports],
              [kTransportNfc | kTransportUsb, kTransportInternal | hybrid, smartCard]);
        });
      }
    });

    test('a passkey that must sign in by itself, where the server requires one, on every version', () {
      final creation = at(softAuthenticator(), ['creation_options']);
      final c = winCreationOf({
        ...creation,
        'authenticatorSelection': {'residentKey': 'required', 'userVerification': 'required'},
        'excludeCredentials': [],
      });
      using((arena) {
        final o = makeCredentialArgs(arena, c, 1).options.ref;
        expect(o.bRequireResidentKey, 1);
        expect(o.dwUserVerificationRequirement, kUserVerificationRequired);
        expect(o.pExcludeCredentialList, nullptr);
      });
    });

    test('to use one: the RP ID, the client data and the account\'s passkeys, as version 4', () {
      final fixture = softAuthenticator();
      final r = winAssertionRequestOf(at(fixture, ['web', 'request']));
      for (final (api, transports) in [(1, kTransportInternal), (9, kTransportInternal | kTransportHybrid)]) {
        using((arena) {
          final args = getAssertionArgs(arena, r, api);
          expect(args.rpId.toDartString(), 'zestssh.com');
          final data = args.clientData.ref;
          expect(bytesAt(data.pbClientDataJSON, data.cbClientDataJSON),
              bytesOf(at(fixture, ['web', 'authentication', 'response'])['clientDataJSON']! as String));
          expect(data.pwszHashAlgId.toDartString(), 'SHA-256');
          final o = args.options.ref;
          expect(o.dwVersion, 4);
          expect(o.dwTimeoutMilliseconds, 120000);
          expect(o.dwAuthenticatorAttachment, kAttachmentAny);
          expect(o.dwUserVerificationRequirement, kUserVerificationPreferred);
          expect(o.dwFlags, 0);
          expect(o.credentialList.cCredentials, 0);
          expect([o.pwszU2fAppId, o.pbU2fAppId.cast<Void>(), o.pCancellationId], [nullptr, nullptr, nullptr]);
          final allow = o.pAllowCredentialList.ref;
          expect(allow.cCredentials, 1);
          final only = allow.ppCredentials[0].ref;
          expect(b64u(bytesAt(only.pbId, only.cbId)), at(fixture, ['web', 'registration'])['id']);
          expect(only.dwTransports, transports, reason: 'API version $api');
        });
      }
    });
  });

  group('what the DLL hands back, read into what the server takes', () {
    /// A WEBAUTHN_CREDENTIAL_ATTESTATION of [version], as the DLL would hand
    /// one back, in [arena].
    Pointer<WebAuthnCredentialAttestation> attestation(
      Arena arena, {
      required int version,
      required List<int> id,
      required List<int> object,
      List<int> authData = const [],
      int used = 0,
      int supported = 0,
      int residentKey = 0,
    }) {
      Pointer<Uint8> bytes(List<int> data) {
        final p = arena<Uint8>(data.isEmpty ? 1 : data.length);
        p.asTypedList(data.length).setAll(0, data);
        return p;
      }

      final p = arena<WebAuthnCredentialAttestation>();
      p.ref
        ..dwVersion = version
        ..pwszFormatType = 'none'.toNativeUtf16(allocator: arena)
        ..cbAuthenticatorData = authData.length
        ..pbAuthenticatorData = bytes(authData)
        ..cbAttestationObject = object.length
        ..pbAttestationObject = bytes(object)
        ..cbCredentialId = id.length
        ..pbCredentialId = bytes(id)
        ..dwUsedTransport = used
        ..bResidentKey = residentKey
        ..dwTransports = supported;
      return p;
    }

    test('a passkey made with Windows Hello is, field by field, the response the server\'s authenticator wrote', () {
      final fixture = softAuthenticator();
      final registration = at(fixture, ['web', 'registration']);
      final c = winCreationOf(at(fixture, ['creation_options']));
      using((arena) {
        final made = readCredentialAttestation(attestation(
          arena,
          version: 8,
          id: bytesOf(registration['id']! as String),
          object: bytesOf(at(registration, ['response'])['attestationObject']! as String),
          used: kTransportInternal,
          supported: kTransportInternal | kTransportHybrid,
          residentKey: 1,
        ));
        final json = registrationJsonOf(made, c.clientData, credProps: c.credProps);
        expectSameFields(json, registration);
        expectSameFields(registrationResponseOf(json, challenge: c.challenge), registration);
      });
    });

    test('a security key\'s, from an older DLL, says what that version says', () {
      final fixture = softAuthenticator();
      final registration = at(fixture, ['security_key', 'registration']);
      final c = winCreationOf(at(fixture, ['creation_options']));
      using((arena) {
        final object = bytesOf(at(registration, ['response'])['attestationObject']! as String);
        final id = bytesOf(registration['id']! as String);
        // Version 4: the transport it was made over, and whether it signs in
        // by itself; no list of transports yet.
        final four = readCredentialAttestation(
            attestation(arena, version: 4, id: id, object: object, used: kTransportUsb, residentKey: 1));
        expectSameFields(registrationJsonOf(four, c.clientData, credProps: true), registration);
        // Version 1: neither, so neither is said.
        final one = readCredentialAttestation(attestation(arena, version: 1, id: id, object: object, used: kTransportUsb));
        final json = registrationJsonOf(one, c.clientData, credProps: true);
        expect(at(json, ['response'])['transports'], isEmpty);
        expect(json.containsKey('authenticatorAttachment'), isFalse);
        expect(json['clientExtensionResults'], <String, Object?>{});
      });
    });

    test('a credential id the DLL leaves out is read from the authenticator data', () {
      final registration = at(softAuthenticator(), ['web', 'registration']);
      final object = bytesOf(at(registration, ['response'])['attestationObject']! as String);
      // The attestation object's authData: rpIdHash, flags (AT set), counter,
      // AAGUID, the id's length and the id, then the key.
      final id = bytesOf(registration['id']! as String);
      final authData = <int>[
        ...List.filled(32, 7), 0x45, 0, 0, 0, 0, ...List.filled(16, 0), 0, id.length, ...id, 0xa5,
      ];
      using((arena) {
        final made = readCredentialAttestation(
            attestation(arena, version: 3, id: const [], object: object, authData: authData, used: kTransportInternal));
        expect(b64u(made.credentialId), registration['id']);
      });
      expect(credentialIdOfAuthData(Uint8List.fromList(authData.sublist(0, 37))), isNull);
      expect(credentialIdOfAuthData(Uint8List.fromList([...authData]..[32] = 0x05)), isNull);
    });

    test('a passkey\'s answer is, field by field, what the server\'s authenticator wrote', () {
      final fixture = softAuthenticator();
      for (final from in ['web', 'security_key']) {
        final authentication = at(fixture, [from, 'authentication']);
        final inner = at(authentication, ['response']);
        final r = winAssertionRequestOf(at(fixture, [from, 'request']));
        using((arena) {
          Pointer<Uint8> bytes(List<int> data) {
            final p = arena<Uint8>(data.length);
            p.asTypedList(data.length).setAll(0, data);
            return p;
          }

          final id = bytesOf(authentication['id']! as String);
          final authData = bytesOf(inner['authenticatorData']! as String);
          final signature = bytesOf(inner['signature']! as String);
          final handle = bytesOf(inner['userHandle']! as String);
          final p = arena<WebAuthnAssertion>();
          p.ref
            ..dwVersion = 4
            ..cbAuthenticatorData = authData.length
            ..pbAuthenticatorData = bytes(authData)
            ..cbSignature = signature.length
            ..pbSignature = bytes(signature)
            ..cbUserId = handle.length
            ..pbUserId = bytes(handle)
            ..dwUsedTransport = from == 'web' ? kTransportInternal : kTransportUsb;
          p.ref.credential
            ..dwVersion = 1
            ..cbId = id.length
            ..pbId = bytes(id)
            ..pwszCredentialType = 'public-key'.toNativeUtf16(allocator: arena);
          final json = authenticationJsonOf(readAssertion(p, r.allow), r.clientData);
          final expected = {...authentication, 'clientExtensionResults': <String, Object?>{}};
          expectSameFields(json, expected);
          expectSameFields(authenticationResponseOf(json, challenge: r.challenge), expected);

          // An authenticator may leave the id out where one passkey was
          // asked for: it is that one. And no user handle, none said.
          p.ref.credential.cbId = 0;
          p.ref.cbUserId = 0;
          final bare = authenticationJsonOf(readAssertion(p, r.allow), r.clientData);
          expect(bare['id'], authentication['id']);
          expect((bare['response']! as Map).containsKey('userHandle'), isFalse);
        });
      }
    });
  });

  group('what a failure means', () {
    test('the person cancelled, or the dialog closed or timed out: cancelled', () {
      for (final hr in [kNteUserCancelled, kHrCancelled, kHrTimeout]) {
        expect(windowsFailureOf(hr, 'NotAllowedError', signIn: true), isA<PasskeyCancelled>());
        // As the DLL hands an HRESULT back: a negative 32-bit number.
        expect(windowsFailureOf(hr.toSigned(32), 'NotAllowedError', signIn: false), isA<PasskeyCancelled>());
      }
    });

    test('each other one, the code a screen is written for, the HRESULT and its name the detail', () {
      final cases = <(int, String, bool, String)>[
        (kNteExists, 'InvalidStateError', false, 'invalid-state'),
        (kNteNotFound, 'NotAllowedError', true, 'no-credential'),
        (kNteDeviceNotFound, 'NotAllowedError', true, 'no-credential'),
        (kNteNotFound, 'NotAllowedError', false, 'failed'),
        (kNteInvalidParameter, 'NotSupportedError', false, 'unsupported'),
        (kNteNotSupported, 'ConstraintError', false, 'unsupported'),
        (kNteTokenKeysetStorageFull, 'ConstraintError', false, 'unsupported'),
        (kHrNotSupported, 'ConstraintError', true, 'unsupported'),
        (0x80070057, 'UnknownError', true, 'failed'),
      ];
      for (final (hr, name, signIn, code) in cases) {
        final error = windowsFailureOf(hr.toSigned(32), name, signIn: signIn);
        expect(error, isA<PasskeyError>().having((e) => e.code, 'code', code), reason: '$hr');
        expect((error as PasskeyError).detail,
            '0x${hr.toRadixString(16).toUpperCase().padLeft(8, '0')} $name');
      }
      expect((windowsFailureOf(0x80004005, null, signIn: true) as PasskeyError).detail, '0x80004005');
    });
  });

  group('WindowsPasskeys', () {
    test('makes a passkey through the DLL, in the app\'s window, and answers what the server takes', () async {
      final fixture = softAuthenticator();
      final registration = at(fixture, ['web', 'registration']);
      final dll = _FakeWebAuthn((asked) => WinOutcome.registered(WinRegistration(
            credentialId: Uint8List.fromList(bytesOf(registration['id']! as String)),
            attestationObject:
                Uint8List.fromList(bytesOf(at(registration, ['response'])['attestationObject']! as String)),
            transports: const ['hybrid', 'internal'],
            attachment: 'platform',
            residentKey: true,
          )));
      final made = await WindowsPasskeys(webAuthn: dll).create(at(fixture, ['creation_options']));
      expectSameFields(made, registration);
      expect(dll.windows, [0x5150]);
      expect((dll.asked.single as WinCreation).rpId, 'zestssh.com');
    });

    test('uses one, and answers what the server takes', () async {
      final fixture = softAuthenticator();
      final authentication = at(fixture, ['web', 'authentication']);
      final inner = at(authentication, ['response']);
      final dll = _FakeWebAuthn((asked) => WinOutcome.asserted(WinAssertion(
            credentialId: Uint8List.fromList(bytesOf(authentication['id']! as String)),
            authenticatorData: Uint8List.fromList(bytesOf(inner['authenticatorData']! as String)),
            signature: Uint8List.fromList(bytesOf(inner['signature']! as String)),
            userHandle: Uint8List.fromList(bytesOf(inner['userHandle']! as String)),
            attachment: 'platform',
          )));
      final used = await WindowsPasskeys(webAuthn: dll).get(at(fixture, ['web', 'request']));
      expectSameFields(used, {...authentication, 'clientExtensionResults': <String, Object?>{}});
    });

    test('says what each failure means', () async {
      final options = at(softAuthenticator(), ['web', 'request']);
      Future<Object?> failing(WinOutcome outcome) async {
        try {
          await WindowsPasskeys(webAuthn: _FakeWebAuthn((_) => outcome)).get(options);
        } catch (e) {
          return e;
        }
        return null;
      }

      expect(await failing(WinOutcome.failed(kNteUserCancelled.toSigned(32), 'NotAllowedError')),
          isA<PasskeyCancelled>());
      expect(await failing(WinOutcome.failed(kNteNotFound.toSigned(32), 'NotAllowedError')),
          isA<PasskeyError>().having((e) => e.code, 'code', 'no-credential'));
      expect(await failing(const WinOutcome.unavailable()),
          isA<PasskeyError>().having((e) => e.code, 'code', 'unsupported'));
      expect(await failing(const WinOutcome.broken('no assertion')),
          isA<PasskeyError>().having((e) => e.detail, 'detail', contains('no assertion')));
    });

    test('without webauthn.dll there are none: not available, and unsupported', () async {
      final none = WindowsPasskeys(webAuthn: _FakeWebAuthn((_) => fail('called'), version: 0));
      expect(await none.isAvailable(), isFalse);
      expect(await none.hasWindowsHello(), isFalse);
      await expectLater(none.create(at(softAuthenticator(), ['creation_options'])),
          throwsA(isA<PasskeyError>().having((e) => e.code, 'code', 'unsupported')));
      final some = WindowsPasskeys(webAuthn: _FakeWebAuthn((_) => fail('called'), version: 1, hello: true));
      expect(await some.isAvailable(), isTrue);
      expect(await some.hasWindowsHello(), isTrue);
    });

    test('one dialog at a time, and only with a window for it', () async {
      final options = at(softAuthenticator(), ['web', 'request']);
      final held = Completer<WinOutcome>();
      final passkeys = WindowsPasskeys(webAuthn: _FakeWebAuthn((_) => held.future));
      final first = passkeys.get(options);
      await expectLater(
          passkeys.get(options), throwsA(isA<PasskeyError>().having((e) => e.detail, 'detail', contains('open'))));
      held.complete(WinOutcome.failed(kNteUserCancelled.toSigned(32), 'NotAllowedError'));
      await expectLater(first, throwsA(isA<PasskeyCancelled>()));

      final windowless = WindowsPasskeys(webAuthn: _FakeWebAuthn((_) => fail('called'), window: 0));
      await expectLater(windowless.get(options),
          throwsA(isA<PasskeyError>().having((e) => e.detail, 'detail', contains('window'))));
    });
  });

  group('webauthn.dll on this PC', () {
    test('is loaded from System32 by its full path, never by its name alone', () {
      final source = File('lib/services/passkeys/windows_webauthn.dart').readAsStringSync();
      expect(source, contains(r"DynamicLibrary.open('$windowsRoot\\System32\\webauthn.dll')"));
      expect(RegExp(r"DynamicLibrary\.open\('webauthn").hasMatch(source), isFalse);
    });

    test('is there, of API version 1 or later, and names each failure as the mapping reads it', () {
      final dll = WebAuthnDll.open();
      expect(dll, isNotNull);
      expect(dll!.apiVersion(), greaterThanOrEqualTo(1));
      // The names webauthn.h says the DLL gives each HRESULT: the constants
      // here are the DLL's own.
      final names = {
        0: 'Success',
        kNteUserCancelled: 'NotAllowedError',
        kHrCancelled: 'NotAllowedError',
        kHrTimeout: 'NotAllowedError',
        kNteNotFound: 'NotAllowedError',
        kNteDeviceNotFound: 'NotAllowedError',
        kNteExists: 'InvalidStateError',
        kNteInvalidParameter: 'NotSupportedError',
        kNteNotSupported: 'ConstraintError',
        kNteTokenKeysetStorageFull: 'ConstraintError',
        kHrNotSupported: 'ConstraintError',
        0x80070057: 'UnknownError',
      };
      for (final entry in names.entries) {
        expect(dll.errorName(entry.key), entry.value, reason: '0x${entry.key.toRadixString(16)}');
      }
    }, skip: Platform.isWindows ? false : 'webauthn.dll is Windows\' own');
  });
}

/// webauthn.dll, played: [answer] is what each ceremony comes to.
class _FakeWebAuthn implements WindowsWebAuthn {
  _FakeWebAuthn(this.answer, {this.version = 9, this.window = 0x5150, this.hello = false});

  final FutureOr<WinOutcome> Function(Object asked) answer;
  final int version;
  final int window;
  final bool hello;
  final asked = <Object>[];
  final windows = <int>[];

  @override
  int apiVersion() => version;

  @override
  Future<bool> platformAuthenticator() async => hello;

  @override
  int windowHandle() => window;

  @override
  Future<WinOutcome> makeCredential(WinCreation c, int hwnd) async {
    asked.add(c);
    windows.add(hwnd);
    return answer(c);
  }

  @override
  Future<WinOutcome> getAssertion(WinAssertionRequest r, int hwnd) async {
    asked.add(r);
    windows.add(hwnd);
    return answer(r);
  }
}
