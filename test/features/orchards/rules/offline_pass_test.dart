import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/features/orchards/certs/cert_handover.dart';
import 'package:zestssh/features/orchards/rules/offline_pass.dart';

/// An offline pass, below everything that needs an Orchard: the two texts
/// that carry it between devices (a member's request, and the pass an
/// owner's device gives back), the bytes that are signed, and a pass as a
/// device holds it. The texts go from screen to camera or through a chat,
/// so they have to read after a chat or a mail broke them into lines, and
/// whatever does not read has to be no pass at all, never an error. Two
/// devices of different versions of the app have to agree on them: the
/// fixed texts below must keep reading as they do. What an owner's device
/// signs and what a member's device keeps is in
/// test/features/orchards/pass_handover_service_test.dart.

Uint8List _b(int n, int seed) => Uint8List.fromList([for (var i = 0; i < n; i++) (seed + i * 7) & 0xff]);

const _orchard = '0b6d1c9e-3f1a-4b7c-8a55-6f2d1e7c9a10';
const _crate = '5e2a9f04-77c1-4d3b-b0f6-9c8d7e6f5a41';
const _uid = 'u7Qm2xRk9LpVaT4nWc8YbZs1HdE3';
const _owner = 'k3Tz8vNc1BwYpQ6mXr5JdLs0FgH2';
const _at = 1791504000;

PassRequest _request({String uid = _uid, int at = _at, int key = 32, int signature = 64}) =>
    PassRequest(uid: uid, keyVersion: 3, deviceKey: _b(key, 40), askedAt: at, signature: _b(signature, 9));

HandedPassRequest _asked({String crate = _crate}) =>
    HandedPassRequest(orchardId: _orchard, crateId: crate, request: _request());

OfflinePass _pass({String uid = _uid, String by = _owner, int until = _at + 86400, int made = _at}) => OfflinePass(
      uid: uid,
      deviceKey: _b(32, 40),
      until: until,
      madeAt: made,
      by: by,
      byKeyVersion: 2,
      signature: _b(64, 77),
    );

HandedPass _given({String crate = _crate}) => HandedPass(orchardId: _orchard, crateId: crate, pass: _pass());

void _sameRequest(HandedPassRequest? read, HandedPassRequest written) {
  expect(read, isNotNull);
  expect((read!.orchardId, read.crateId), (written.orchardId, written.crateId));
  expect((read.request.uid, read.request.keyVersion, read.request.askedAt),
      (written.request.uid, written.request.keyVersion, written.request.askedAt));
  expect(read.request.deviceKey, written.request.deviceKey);
  expect(read.request.signature, written.request.signature);
}

void _samePass(HandedPass? read, HandedPass written) {
  expect(read, isNotNull);
  expect((read!.orchardId, read.crateId), (written.orchardId, written.crateId));
  final a = read.pass, b = written.pass;
  expect((a.uid, a.until, a.madeAt, a.by, a.byKeyVersion), (b.uid, b.until, b.madeAt, b.by, b.byKeyVersion));
  expect(a.deviceKey, b.deviceKey);
  expect(a.signature, b.signature);
}

/// As the two devices write them, version 1. A device running a later
/// version of the app must still read what one running 3.0 shows it.
const _fixedRequest = 'zestssh-pass-ask:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAJDVlMmE5ZjA0LTc3YzEtNGQzYi1iMGY2LTljOGQ3ZTZmNWE0MQAcdTdRbTJ4Ums5THBWYVQ0bldjOFliWnMxSGRFMwAAAAMAAAAAasgugAAgKC82PURLUllgZ251fIOKkZifpq20u8LJ0Nfe5ezz-gEAQAkQFx4lLDM6QUhPVl1ka3J5gIeOlZyjqrG4v8bN1Nvi6fD3_gUMExohKC82PURLUllgZ251fIOKkZifpq20u8I';
const _fixedRequestForAll = 'zestssh-pass-ask:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAASoAHHU3UW0yeFJrOUxwVmFUNG5XYzhZYlpzMUhkRTMAAAADAAAAAGrILoAAICgvNj1ES1JZYGdudXyDipGYn6attLvCydDX3uXs8_oBAEAJEBceJSwzOkFIT1ZdZGtyeYCHjpWco6qxuL_GzdTb4unw9_4FDBMaISgvNj1ES1JZYGdudXyDipGYn6attLvC';
const _fixedPass = 'zestssh-pass-give:1:ACQwYjZkMWM5ZS0zZjFhLTRiN2MtOGE1NS02ZjJkMWU3YzlhMTAAJDVlMmE5ZjA0LTc3YzEtNGQzYi1iMGY2LTljOGQ3ZTZmNWE0MQAcdTdRbTJ4Ums5THBWYVQ0bldjOFliWnMxSGRFMwAgKC82PURLUllgZ251fIOKkZifpq20u8LJ0Nfe5ezz-gEAAAAAasmAAAAAAABqyC6AABxrM1R6OHZOYzFCd1lwUTZtWHI1SmRMczBGZ0gyAAAAAgBATVRbYmlwd36FjJOaoaivtr3Ey9LZ4Ofu9fwDChEYHyYtNDtCSVBXXmVsc3qBiI-WnaSrsrnAx87V3OPq8fj_Bg';

void main() {
  test('a request and a pass read back as they were written, for a Crate and for all of an Orchard', () {
    for (final crate in [_crate, kAllOfOrchard]) {
      final asked = _asked(crate: crate);
      final ask = asked.toText();
      expect(ask, matches(RegExp(r'^zestssh-pass-ask:1:[A-Za-z0-9_-]+$')), reason: 'one word, safe in a chat');
      _sameRequest(HandedPassRequest.fromText(ask), asked);
      final given = _given(crate: crate);
      final give = given.toText();
      expect(give, matches(RegExp(r'^zestssh-pass-give:1:[A-Za-z0-9_-]+$')));
      _samePass(HandedPass.fromText(give), given);
    }
    // What is read is signed over the same bytes as what was written.
    final read = HandedPassRequest.fromText(_asked().toText())!;
    expect(read.request.message(orchardId: read.orchardId, crateId: read.crateId),
        _request().message(orchardId: _orchard, crateId: _crate));
    final back = HandedPass.fromText(_given().toText())!;
    expect(back.pass.message(orchardId: back.orchardId, crateId: back.crateId),
        _pass().message(orchardId: _orchard, crateId: _crate));
  });

  test('the texts of version 1 read as they always did', () {
    expect(_asked().toText(), _fixedRequest);
    expect(_asked(crate: kAllOfOrchard).toText(), _fixedRequestForAll);
    expect(_given().toText(), _fixedPass);
    _sameRequest(HandedPassRequest.fromText(_fixedRequest), _asked());
    _sameRequest(HandedPassRequest.fromText(_fixedRequestForAll), _asked(crate: kAllOfOrchard));
    _samePass(HandedPass.fromText(_fixedPass), _given());
  });

  test('what is signed names everything a pass is good for, and nothing reads as something else', () {
    final request = _request().message(orchardId: _orchard, crateId: _crate);
    final pass = _pass().message(orchardId: _orchard, crateId: _crate);
    // Another Orchard, another Crate, all of the Orchard, another member,
    // another device, another moment, other keys: other bytes each time.
    final requests = <List<int>>[
      request,
      _request().message(orchardId: 'another', crateId: _crate),
      _request().message(orchardId: _orchard, crateId: 'another'),
      _request().message(orchardId: _orchard, crateId: kAllOfOrchard),
      _request(uid: 'someone-else').message(orchardId: _orchard, crateId: _crate),
      _request(at: _at + 1).message(orchardId: _orchard, crateId: _crate),
      PassRequest(uid: _uid, keyVersion: 4, deviceKey: _b(32, 40), askedAt: _at, signature: _b(64, 9))
          .message(orchardId: _orchard, crateId: _crate),
      PassRequest(uid: _uid, keyVersion: 3, deviceKey: _b(32, 41), askedAt: _at, signature: _b(64, 9))
          .message(orchardId: _orchard, crateId: _crate),
    ];
    final passes = <List<int>>[
      pass,
      _pass().message(orchardId: 'another', crateId: _crate),
      _pass().message(orchardId: _orchard, crateId: 'another'),
      _pass().message(orchardId: _orchard, crateId: kAllOfOrchard),
      _pass(uid: 'someone-else').message(orchardId: _orchard, crateId: _crate),
      _pass(by: 'another-owner').message(orchardId: _orchard, crateId: _crate),
      _pass(until: _at + 86401).message(orchardId: _orchard, crateId: _crate),
      _pass(made: _at + 1).message(orchardId: _orchard, crateId: _crate),
      OfflinePass(
              uid: _uid, deviceKey: _b(32, 41), until: _at + 86400, madeAt: _at, by: _owner, byKeyVersion: 2, signature: _b(64, 77))
          .message(orchardId: _orchard, crateId: _crate),
      OfflinePass(
              uid: _uid, deviceKey: _b(32, 40), until: _at + 86400, madeAt: _at, by: _owner, byKeyVersion: 3, signature: _b(64, 77))
          .message(orchardId: _orchard, crateId: _crate),
    ];
    String hex(List<int> bytes) => bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
    expect({...requests.map(hex), ...passes.map(hex)}, hasLength(requests.length + passes.length));
    // The signature itself is no part of what it covers.
    expect(
        PassRequest(uid: _uid, keyVersion: 3, deviceKey: _b(32, 40), askedAt: _at, signature: _b(64, 1))
            .message(orchardId: _orchard, crateId: _crate),
        request);
    // A name that ends where the next begins is not the same two names
    // cut elsewhere.
    expect(hex(_request(uid: 'ab').message(orchardId: 'o', crateId: 'c')),
        isNot(hex(_request(uid: 'b').message(orchardId: 'o', crateId: 'ca'))));
    expect(String.fromCharCodes(request.sublist(4, 4 + kPassRequestLabel.length)), kPassRequestLabel);
    expect(String.fromCharCodes(pass.sublist(4, 4 + kOfflinePassLabel.length)), kOfflinePassLabel);
  });

  test('its first words say what a text is, and a text of one kind is none of the others', () {
    final ask = _asked().toText();
    final give = _given().toText();
    expect(handedKindOf(ask), HandedKind.passRequest);
    expect(handedKindOf(give), HandedKind.pass);
    expect(handedKindOf('Here is your pass: $give'), HandedKind.pass);
    // Several in one text: the one that comes first.
    expect(handedKindOf('$ask\n$give'), HandedKind.passRequest);
    expect(handedKindOf('$give\n$ask'), HandedKind.pass);
    const certAsk = '${kHandedRequestPrefix}AAAA';
    const certGive = '${kHandedCertificatePrefix}AAAA';
    expect(handedKindOf('$certAsk $ask'), HandedKind.request);
    expect(handedKindOf('$ask $certGive'), HandedKind.passRequest);
    expect(handedKindOf('$certGive $give'), HandedKind.certificate);
    for (final kind in HandedKind.values) {
      expect(handedKindOf('${kind.prefix}AAAA'), kind);
    }
    expect({for (final k in HandedKind.values) k.prefix}, hasLength(4));
    // A request is no pass, and neither is a certificate or its request.
    expect(HandedPass.fromText(ask), isNull);
    expect(HandedPassRequest.fromText(give), isNull);
    expect(HandedRequest.fromText(ask), isNull);
    expect(HandedCertificate.fromText(give), isNull);
    expect(HandedCertificate.fromText(ask), isNull);
    expect(HandedRequest.fromText(give), isNull);
  });

  test('a text that came through a chat or a mail still reads', () {
    String broken(String s, int every, String by) =>
        [for (var i = 0; i < s.length; i += every) s.substring(i, i + every > s.length ? s.length : i + every)].join(by);
    for (final (text, prefix) in [(_asked().toText(), kHandedPassRequestPrefix), (_given().toText(), kHandedPassPrefix)]) {
      String withBody(String Function(String body) change) => '$prefix${change(text.substring(prefix.length))}';
      final variants = <String, String>{
        'spaces around': '   $text  ',
        'a line break at the end': '$text\n',
        'lines of 40 letters': withBody((b) => broken(b, 40, '\n')),
        'lines broken the Windows way': withBody((b) => broken(b, 64, '\r\n')),
        'a space every 76 letters': withBody((b) => broken(b, 76, ' ')),
        'words before it': 'I am at the plant until Friday, can you sign this?\n\n$text',
        'words after it, on the same line': '$text Thanks!',
        'in quotes': '"$text"',
        'a full stop after it': '$text.',
        'a quoted mail': withBody((b) => broken(b, 60, '\n')).split('\n').map((l) => '    $l').join('\n'),
      };
      for (final v in variants.entries) {
        if (prefix == kHandedPassRequestPrefix) {
          _sameRequest(HandedPassRequest.fromText(v.value), _asked());
        } else {
          _samePass(HandedPass.fromText(v.value), _given());
        }
      }
    }
  });

  test('cut short or with a letter changed, a text is another one or none, and never an error', () {
    const letters = 'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_';
    for (final (text, prefix) in [(_asked().toText(), kHandedPassRequestPrefix), (_given().toText(), kHandedPassPrefix)]) {
      for (var n = 0; n < text.length; n++) {
        final cut = text.substring(0, n);
        expect(HandedPassRequest.fromText(cut), isNull, reason: '$n of ${text.length} letters');
        expect(HandedPass.fromText(cut), isNull, reason: '$n of ${text.length} letters');
      }
      for (var i = prefix.length; i < text.length; i++) {
        final other = letters[(letters.indexOf(text[i]) + 1 + i) % letters.length];
        final changed = text.replaceRange(i, i + 1, other == text[i] ? 'A' : other);
        // What still reads says something else than what was written,
        // which the signature in it is there to catch.
        final asked = HandedPassRequest.fromText(changed);
        final given = HandedPass.fromText(changed);
        if (asked != null) expect(asked.toText(), isNot(text), reason: 'letter $i');
        if (given != null) expect(given.toText(), isNot(text), reason: 'letter $i');
      }
    }
    for (final junk in [
      '',
      kHandedPassRequestPrefix,
      kHandedPassPrefix,
      '$kHandedPassPrefix!!!',
      '${kHandedPassPrefix}AA',
      '$kHandedPassRequestPrefix====',
      _asked().toText().replaceFirst(':1:', ':2:'),
      _given().toText().replaceFirst(':1:', ':2:'),
    ]) {
      expect(HandedPassRequest.fromText(junk), isNull, reason: junk);
      expect(HandedPass.fromText(junk), isNull, reason: junk);
    }
    expect(handedKindOf(_given().toText().replaceFirst(':1:', ':2:')), isNull, reason: 'another version is not read');
  });

  test('what does not have the size of the thing it says it is, is not read', () {
    HandedPassRequest ask(PassRequest r, {String orchard = _orchard, String crate = _crate}) =>
        HandedPassRequest(orchardId: orchard, crateId: crate, request: r);
    final badRequests = <String, HandedPassRequest>{
      'a device key of 31 bytes': ask(_request(key: 31)),
      'a device key of 33 bytes': ask(_request(key: 33)),
      'no device': ask(_request(key: 0)),
      'a signature of 63 bytes': ask(_request(signature: 63)),
      'a signature of 65 bytes': ask(_request(signature: 65)),
      'no Orchard': ask(_request(), orchard: ''),
      'no Crate, and not all of it either': ask(_request(), crate: ''),
      'nobody asking': ask(_request(uid: '')),
      'a time no clock shows': ask(_request(at: 0x20000000000000)),
      'an Orchard name of 129 letters': ask(_request(), orchard: 'o' * 129),
    };
    for (final b in badRequests.entries) {
      expect(HandedPassRequest.fromText(b.value.toText()), isNull, reason: b.key);
    }
    _sameRequest(HandedPassRequest.fromText(ask(_request(), orchard: 'o' * 128).toText()), ask(_request(), orchard: 'o' * 128));

    HandedPass give(OfflinePass p, {String orchard = _orchard, String crate = _crate}) =>
        HandedPass(orchardId: orchard, crateId: crate, pass: p);
    OfflinePass sized({int key = 32, int signature = 64, String uid = _uid, String by = _owner, int until = _at}) =>
        OfflinePass(
            uid: uid,
            deviceKey: _b(key, 1),
            until: until,
            madeAt: _at,
            by: by,
            byKeyVersion: 1,
            signature: _b(signature, 2));
    final badPasses = <String, HandedPass>{
      'a device key of 31 bytes': give(sized(key: 31)),
      'no device': give(sized(key: 0)),
      'a signature of 63 bytes': give(sized(signature: 63)),
      'no signature': give(sized(signature: 0)),
      'for nobody': give(sized(uid: '')),
      'signed by nobody': give(sized(by: '')),
      'no Orchard': give(sized(), orchard: ''),
      'no Crate': give(sized(), crate: ''),
      'an end no clock shows': give(sized(until: 0x20000000000000)),
    };
    for (final b in badPasses.entries) {
      expect(HandedPass.fromText(b.value.toText()), isNull, reason: b.key);
    }
    _samePass(HandedPass.fromText(give(sized(until: 0x1fffffffffffff)).toText()), give(sized(until: 0x1fffffffffffff)));
  });

  test('both stay short enough to show as a code a camera reads', () {
    expect(_asked().toText().length, lessThan(340));
    expect(_given().toText().length, lessThan(400));
  });

  group('a pass as a device holds it', () {
    const day = 86400;
    const hour = 3600;
    const pass = HeldPass(until: _at + day, madeAt: _at, by: _owner);

    test('holds up to its last second, and a clock turned back does not bring it back', () {
      expect(pass.holdsAt(_at, _at), isTrue);
      expect(pass.holdsAt(_at + day, _at + day), isTrue, reason: 'its last second');
      expect(pass.holdsAt(_at + day + 1, _at + day + 1), isFalse);
      // The clock reads earlier than it has read: what counts is the
      // furthest it read.
      expect(pass.holdsAt(_at + hour, _at + day + 1), isFalse);
      expect(pass.holdsAt(_at + hour, _at + day), isTrue);
      // A clock that has read nothing yet (a device just set up).
      expect(pass.holdsAt(_at + hour, 0), isTrue);
    });

    test('says so in its last quarter, a day ahead at the most', () {
      expect(pass.warningBefore, const Duration(hours: 6));
      expect(const HeldPass(until: _at + 8 * hour, madeAt: _at, by: _owner).warningBefore, const Duration(hours: 2));
      expect(const HeldPass(until: _at + 7 * day, madeAt: _at, by: _owner).warningBefore, const Duration(days: 1));
      expect(const HeldPass(until: _at + 4 * day, madeAt: _at, by: _owner).warningBefore, const Duration(days: 1));
      expect(const HeldPass(until: _at, madeAt: _at + hour, by: _owner).warningBefore, Duration.zero,
          reason: 'one that ends before it was made warns of nothing');
      expect(pass.endsSoonAt(_at + 18 * hour - 1, 0), isFalse);
      expect(pass.endsSoonAt(_at + 18 * hour, 0), isTrue);
      expect(pass.endsSoonAt(_at + day, 0), isTrue);
      expect(pass.endsSoonAt(_at + day + 1, 0), isFalse, reason: 'ended: no longer about to');
      // By the furthest the clock has read, as for holding.
      expect(pass.endsSoonAt(_at + hour, _at + 20 * hour), isTrue);
      expect(pass.endsSoonAt(_at + 20 * hour, _at + day + 1), isFalse);
    });

    test('is kept as what it is, and what was kept of anything else is no pass', () {
      final kept = pass.toStored();
      final read = HeldPass.fromStored(kept)!;
      expect((read.until, read.madeAt, read.by), (_at + day, _at, _owner));
      for (final junk in <String?>[
        null,
        '',
        'not json',
        '[]',
        '7',
        '{}',
        '{"until":"soon","made":1,"by":"x"}',
        '{"until":1,"made":null,"by":"x"}',
        '{"until":1,"made":1,"by":7}',
        '{"until":1.5,"made":1,"by":"x"}',
      ]) {
        expect(HeldPass.fromStored(junk), isNull, reason: '$junk');
      }
    });
  });
}
