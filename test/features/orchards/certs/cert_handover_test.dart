import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/certs/team_certificates.dart';

/// The two texts a certificate handover passes between devices (3.0): a
/// member's request, and the certificate an owner's device gives back. They
/// travel as a code from screen to camera or as a line of text through
/// whatever still works, so they have to read after a chat or a mail broke
/// them into lines and put words around them, and whatever does not read
/// has to be no request at all, never an error. Two devices of different
/// versions of the app have to agree on them too: the fixed texts below
/// must keep reading as they do.

Uint8List _b(int n, int seed) => Uint8List.fromList([for (var i = 0; i < n; i++) (seed + i * 7) & 0xff]);

const _orchard = '0b6d1c9e-3f1a-4b7c-8a55-6f2d1e7c9a10';
const _crate = '5e2a9f04-77c1-4d3b-b0f6-9c8d7e6f5a41';
const _id = 'b3c1f0de-5a4e-4c7b-9d2e-0f6a1c2d3e4f';
const _uid = 'u7Qm2xRk9LpVaT4nWc8YbZs1HdE3';

CertRequest _request({bool device = false, String id = _id, String uid = _uid, int at = 1791504000}) => CertRequest(
      id: id,
      uid: uid,
      keyVersion: 3,
      sshPublicKey: _b(32, 1),
      requestedAt: at,
      signature: _b(64, 9),
      deviceKey: device ? _b(32, 40) : null,
      deviceSignature: device ? _b(64, 77) : null,
    );

HandedRequest _handed({bool device = false}) =>
    HandedRequest(orchardId: _orchard, crateId: _crate, request: _request(device: device));

HandedCertificate _given({int length = 480}) =>
    HandedCertificate(orchardId: _orchard, crateId: _crate, requestId: _id, certificate: _b(length, 3));

void _same(HandedRequest? read, HandedRequest written) {
  expect(read, isNotNull);
  expect(read!.orchardId, written.orchardId);
  expect(read.crateId, written.crateId);
  expect(read.request.id, written.request.id);
  expect(read.request.uid, written.request.uid);
  expect(read.request.keyVersion, written.request.keyVersion);
  expect(read.request.requestedAt, written.request.requestedAt);
  expect(read.request.sshPublicKey, written.request.sshPublicKey);
  expect(read.request.signature, written.request.signature);
  expect(read.request.deviceKey, written.request.deviceKey);
  expect(read.request.deviceSignature, written.request.deviceSignature);
}

/// As the two devices write them, version 1. A device running a later
/// version of the app must still read what one running 3.0 shows it.
const _fixedRequest = 'zestssh-cert-ask:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAJDVlMmE5ZjA0LTc3YzEtNGQzYi1iMGY2LTljOGQ3ZTZmNWE0MQAkYjNjMWYwZGUtNWE0ZS00YzdiLTlkMmUtMGY2YTFjMmQzZTRmABx1N1FtMnhSazlMcFZhVDRuV2M4WWJaczFIZEUzAAAAAwAAAABqyC6AACABCA8WHSQrMjlAR05VXGNqcXh_ho2Um6KpsLe-xczT2gBACRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbi_xs3U2-Lp8Pf-BQwTGiEoLzY9REtSWWBnbnV8g4qRmJ-mrbS7wgAAAAA';
const _fixedRequestWithDevice = 'zestssh-cert-ask:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAJDVlMmE5ZjA0LTc3YzEtNGQzYi1iMGY2LTljOGQ3ZTZmNWE0MQAkYjNjMWYwZGUtNWE0ZS00YzdiLTlkMmUtMGY2YTFjMmQzZTRmABx1N1FtMnhSazlMcFZhVDRuV2M4WWJaczFIZEUzAAAAAwAAAABqyC6AACABCA8WHSQrMjlAR05VXGNqcXh_ho2Um6KpsLe-xczT2gBACRAXHiUsMzpBSE9WXWRrcnmAh46VnKOqsbi_xs3U2-Lp8Pf-BQwTGiEoLzY9REtSWWBnbnV8g4qRmJ-mrbS7wgAgKC82PURLUllgZ251fIOKkZifpq20u8LJ0Nfe5ezz-gEAQE1UW2JpcHd-hYyTmqGor7a9xMvS2eDn7vX8AwoRGB8mLTQ7QklQV15lbHN6gYiPlp2kq7K5wMfO1dzj6vH4_wY';
const _fixedCertificate = 'zestssh-cert-give:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAJDVlMmE5ZjA0LTc3YzEtNGQzYi1iMGY2LTljOGQ3ZTZmNWE0MQAkYjNjMWYwZGUtNWE0ZS00YzdiLTlkMmUtMGY2YTFjMmQzZTRmACgDChEYHyYtNDtCSVBXXmVsc3qBiI-WnaSrsrnAx87V3OPq8fj_Bg0U';

void main() {
  test('a request reads back as it was written, with a device named and without', () {
    for (final device in [false, true]) {
      final written = _handed(device: device);
      final text = written.toText();
      expect(text, startsWith(kHandedRequestPrefix));
      expect(text, matches(RegExp(r'^zestssh-cert-ask:1:[A-Za-z0-9_-]+$')), reason: 'one word, safe in a link or a chat');
      _same(HandedRequest.fromText(text), written);
    }
    // What it is signed over is what the member's device signed: the same
    // request in the same Crate of the same Orchard.
    final read = HandedRequest.fromText(_handed(device: true).toText())!;
    expect(read.request.message(orchardId: read.orchardId, crateId: read.crateId),
        _request(device: true).message(orchardId: _orchard, crateId: _crate));
  });

  test('a certificate reads back as it was written', () {
    final written = _given();
    final text = written.toText();
    expect(text, matches(RegExp(r'^zestssh-cert-give:1:[A-Za-z0-9_-]+$')));
    final read = HandedCertificate.fromText(text)!;
    expect(read.orchardId, _orchard);
    expect(read.crateId, _crate);
    expect(read.requestId, _id);
    expect(read.certificate, written.certificate);
  });

  test('the texts of version 1 read as they always did', () {
    expect(_handed().toText(), _fixedRequest);
    expect(_handed(device: true).toText(), _fixedRequestWithDevice);
    expect(_given(length: 40).toText(), _fixedCertificate);
    _same(HandedRequest.fromText(_fixedRequest), _handed());
    _same(HandedRequest.fromText(_fixedRequestWithDevice), _handed(device: true));
    expect(HandedCertificate.fromText(_fixedCertificate)!.certificate, _b(40, 3));
  });

  test('its first words say what a text is', () {
    final ask = _handed().toText();
    final give = _given().toText();
    expect(handedKindOf(ask), HandedKind.request);
    expect(handedKindOf(give), HandedKind.certificate);
    expect(handedKindOf('Here it is: $give'), HandedKind.certificate);
    expect(handedKindOf(''), isNull);
    expect(handedKindOf('ssh-ed25519 AAAAC3NzaC1lZDI1NTE5AAAAIA deploy@web-01'), isNull);
    // Both in one text: the one that comes first.
    expect(handedKindOf('$ask\n$give'), HandedKind.request);
    expect(handedKindOf('$give\n$ask'), HandedKind.certificate);
    // A request is no certificate, and the other way round.
    expect(HandedCertificate.fromText(ask), isNull);
    expect(HandedRequest.fromText(give), isNull);
  });

  test('a text that came through a chat or a mail still reads', () {
    final written = _handed(device: true);
    final text = written.toText();
    String broken(String s, int every, String by) =>
        [for (var i = 0; i < s.length; i += every) s.substring(i, i + every > s.length ? s.length : i + every)].join(by);
    // (Only what follows the first words may be broken: they are what the
    // text is found by.)
    String withBody(String Function(String body) change) =>
        '$kHandedRequestPrefix${change(text.substring(kHandedRequestPrefix.length))}';
    final variants = <String, String>{
      'spaces around': '   $text  ',
      'a line break at the end': '$text\n',
      'lines of 40 letters': withBody((b) => broken(b, 40, '\n')),
      'lines broken the Windows way': withBody((b) => broken(b, 64, '\r\n')),
      'a space every 76 letters': withBody((b) => broken(b, 76, ' ')),
      'tabs and blank lines': withBody((b) => broken(b, 50, '\n\t\n')),
      'words before it': 'Hi, the server is down, can you sign this for me?\n\n$text',
      'words after it, on a line of their own': '$text\nThanks!',
      'words after it, on the same line': '$text Thanks!',
      'in quotes': '"$text"',
      'in angle brackets': '<$text>',
      'a full stop after it': '$text.',
      'a quoted mail': withBody((b) => broken(b, 60, '\n')).split('\n').map((l) => '    $l').join('\n'),
    };
    for (final v in variants.entries) {
      _same(HandedRequest.fromText(v.value), written);
      expect(handedKindOf(v.value), HandedKind.request, reason: v.key);
    }
    final given = _given();
    final body = given.toText().substring(kHandedCertificatePrefix.length);
    final back = HandedCertificate.fromText(
        'Here you go:\n$kHandedCertificatePrefix${broken(body, 48, '\n')}\nIt lasts an hour.');
    expect(back!.certificate, given.certificate);
    expect(back.requestId, _id);
  });

  test('cut short anywhere, a text is nothing at all, and never an error', () {
    for (final text in [_handed().toText(), _handed(device: true).toText(), _given().toText()]) {
      for (var n = 0; n < text.length; n++) {
        final cut = text.substring(0, n);
        expect(HandedRequest.fromText(cut), isNull, reason: '$n of ${text.length} letters');
        expect(HandedCertificate.fromText(cut), isNull, reason: '$n of ${text.length} letters');
      }
    }
  });

  test('with a letter changed, a text is another one or none, and never an error', () {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    for (final text in [_handed(device: true).toText(), _given(length: 120).toText()]) {
      final prefix = text.startsWith(kHandedRequestPrefix) ? kHandedRequestPrefix : kHandedCertificatePrefix;
      for (var i = prefix.length; i < text.length; i++) {
        final other = letters[(letters.indexOf(text[i]) + 1 + i) % letters.length];
        final changed = text.replaceRange(i, i + 1, other == text[i] ? 'A' : other);
        final asked = HandedRequest.fromText(changed);
        final given = HandedCertificate.fromText(changed);
        // What still reads says something else than what was written,
        // which the signatures in it are there to catch.
        if (asked != null) expect(asked.toText(), isNot(text), reason: 'letter $i');
        if (given != null) expect(given.toText(), isNot(text), reason: 'letter $i');
      }
    }
    // And what is no such text at all.
    for (final junk in [
      '',
      ' ',
      kHandedRequestPrefix,
      kHandedCertificatePrefix,
      '$kHandedRequestPrefix!!!',
      '${kHandedRequestPrefix}A',
      '${kHandedRequestPrefix}AA',
      '$kHandedCertificatePrefix====',
      'zestssh-fp:1:AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
      '-----BEGIN OPENSSH PRIVATE KEY-----',
    ]) {
      expect(HandedRequest.fromText(junk), isNull, reason: junk);
      expect(HandedCertificate.fromText(junk), isNull, reason: junk);
    }
  });

  test('a text of another version is not read', () {
    final ask = _handed().toText().replaceFirst(':1:', ':2:');
    final give = _given().toText().replaceFirst(':1:', ':2:');
    expect(HandedRequest.fromText(ask), isNull);
    expect(HandedCertificate.fromText(give), isNull);
    expect(handedKindOf(ask), isNull);
    expect(handedKindOf(give), isNull);
  });

  test('what does not have the size of the thing it says it is, is not read', () {
    HandedRequest of(CertRequest r, {String orchard = _orchard, String crate = _crate}) =>
        HandedRequest(orchardId: orchard, crateId: crate, request: r);
    CertRequest sized({int key = 32, int signature = 64, int? deviceKey, int? deviceSignature}) => CertRequest(
          id: _id,
          uid: _uid,
          keyVersion: 1,
          sshPublicKey: _b(key, 1),
          requestedAt: 1791504000,
          signature: _b(signature, 2),
          deviceKey: deviceKey == null ? null : _b(deviceKey, 3),
          deviceSignature: deviceSignature == null ? null : _b(deviceSignature, 4),
        );
    final bad = <String, HandedRequest>{
      'a key of 31 bytes': of(sized(key: 31)),
      'a key of 33 bytes': of(sized(key: 33)),
      'no key': of(sized(key: 0)),
      'a signature of 63 bytes': of(sized(signature: 63)),
      'a signature of 65 bytes': of(sized(signature: 65)),
      'no signature': of(sized(signature: 0)),
      'a device with no signature of its own': of(sized(deviceKey: 32)),
      'a device signature with no device': of(sized(deviceSignature: 64)),
      'a device key of 31 bytes': of(sized(deviceKey: 31, deviceSignature: 64)),
      'a device signature of 63 bytes': of(sized(deviceKey: 32, deviceSignature: 63)),
      'no Orchard': of(sized(), orchard: ''),
      'no Crate': of(sized(), crate: ''),
      'no request id': of(_request(id: '')),
      'nobody asking': of(_request(uid: '')),
      'an Orchard name of 129 letters': of(sized(), orchard: 'o' * 129),
      'a time no clock shows': of(_request(at: 0x20000000000000)),
    };
    for (final b in bad.entries) {
      expect(HandedRequest.fromText(b.value.toText()), isNull, reason: b.key);
    }
    // The sizes that are right at the edge do read.
    _same(HandedRequest.fromText(of(sized(), orchard: 'o' * 128).toText()), of(sized(), orchard: 'o' * 128));
    _same(HandedRequest.fromText(of(_request(at: 0x1fffffffffffff)).toText()), of(_request(at: 0x1fffffffffffff)));
    _same(HandedRequest.fromText(of(_request(at: 0)).toText()), of(_request(at: 0)));

    expect(HandedCertificate.fromText(_given(length: 0).toText()), isNull, reason: 'no certificate in it');
    expect(HandedCertificate.fromText(_given(length: kHandedCertificateMax + 1).toText()), isNull);
    expect(HandedCertificate.fromText(_given(length: kHandedCertificateMax).toText()), isNotNull);
    expect(
      HandedCertificate.fromText(
          HandedCertificate(orchardId: _orchard, crateId: _crate, requestId: '', certificate: _b(40, 1)).toText()),
      isNull,
    );
    // A name that is no text.
    final raw = BytesBuilder()
      ..add([0, 2, 0xc3, 0x28])
      ..add([0, 1, 0x63])
      ..add([0, 1, 0x72])
      ..add([0, 1, 0x01]);
    expect(
      HandedCertificate.fromText('$kHandedCertificatePrefix${base64Url.encode(raw.takeBytes()).replaceAll('=', '')}'),
      isNull,
    );
  });

  test('a text longer than anything of ours is not looked at', () {
    final text = _handed().toText();
    expect(HandedRequest.fromText('${' ' * (kHandedTextMax - text.length)}$text'), isNotNull);
    expect(HandedRequest.fromText('${' ' * (kHandedTextMax - text.length + 1)}$text'), isNull);
    expect(HandedCertificate.fromText('${'x' * kHandedTextMax}${_given().toText()}'), isNull);
  });

  test('both stay short enough to show as a code a camera reads', () {
    // What a request holds does not grow with the team; a certificate grows
    // with the user names in it, and ours are a few hundred bytes.
    expect(_handed().toText().length, lessThan(400));
    expect(_handed(device: true).toText().length, lessThan(520));
    expect(_given(length: 520).toText().length, lessThan(900));
  });
}
