import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/export/event_export.dart';
import 'package:zestssh/features/orchards/export/event_exporter.dart';
import 'package:zestssh/features/orchards/export/export_settings.dart';

/// Event export (3.0): where events may go (https, or plain http
/// to the person's own network), the one header sent along, what the
/// sending device keeps and how, and the request itself.

/// A device's secure storage.
class _Keychain implements FlutterSecureStorage {
  final values = <String, String>{};

  @override
  dynamic noSuchMethod(Invocation invocation) {
    final key = invocation.namedArguments[#key] as String?;
    switch (invocation.memberName) {
      case #read:
        return Future<String?>.value(values[key]);
      case #write:
        values[key!] = invocation.namedArguments[#value] as String;
        return Future<void>.value();
      case #delete:
        values.remove(key);
        return Future<void>.value();
    }
    return super.noSuchMethod(invocation);
  }
}

void main() {
  test('an address: https anywhere, plain http only on the own network, a host, no fragment', () {
    ({String? url, ExportAddressProblem? problem}) of(String text) {
      final a = ExportDestination.address(text);
      return (url: a.url?.toString(), problem: a.problem);
    }

    for (final good in [
      'https://logs.example.com/ingest',
      'https://logs.example.com',
      'https://logs.example.com:8088/services/collector/raw?sourcetype=_json&index=main',
      'HTTPS://LOGS.EXAMPLE.COM/x',
      'https://user:secret@logs.example.com/x',
      'https://203.0.113.9/in',
      'https://[2001:db8::1]:8443/in',
      // Plain http: this device, and the own network.
      'http://localhost:8088/in',
      'http://127.0.0.1:9000/',
      'http://[::1]:9000/in',
      'http://10.0.5.20:8088/services/collector/raw',
      'http://192.168.1.50/in',
      'http://collector.lan/in',
      'http://collector/in',
    ]) {
      expect(of(good).problem, isNull, reason: good);
      expect(of(good).url, Uri.parse(good).toString(), reason: good);
    }
    // Spaces around it are not part of it.
    expect(of('  https://logs.example.com/in \n').url, 'https://logs.example.com/in');

    expect(of('').problem, ExportAddressProblem.empty);
    expect(of('   ').problem, ExportAddressProblem.empty);
    for (final bad in [
      'logs.example.com/ingest',
      'logs.example.com',
      'https://',
      'https:///ingest',
      'ftp://logs.example.com/in',
      'file:///etc/passwd',
      'mailto:ops@example.com',
      'https://logs.example.com/in#top',
      'https://logs example.com/in',
      'https://logs.example.com/a b',
      'https://logs.example.com/in\tx',
      'https://${'a' * 2100}.example.com/',
    ]) {
      expect(of(bad).problem, ExportAddressProblem.notAnAddress, reason: bad);
      expect(of(bad).url, isNull);
    }
    for (final plain in [
      'http://logs.example.com/in',
      'http://203.0.113.9/in',
      'http://8.8.8.8/',
      'http://2130706433/',
      'http://[2001:db8::1]/in',
    ]) {
      expect(of(plain).problem, ExportAddressProblem.notSecure, reason: plain);
      expect(of(plain).url, isNull);
    }
    // The longest address there is, and one more.
    final longest = 'https://logs.example.com/${'a' * (ExportDestination.maxAddress - 25)}';
    expect(longest.length, ExportDestination.maxAddress);
    expect(of(longest).problem, isNull);
    expect(of('${longest}a').problem, ExportAddressProblem.notAnAddress);
  });

  test('the header: both a name and a value or neither, a name a header can have, a value on one line', () {
    expect(ExportDestination.header(null, null), isNull);
    expect(ExportDestination.header('', '  '), isNull);
    expect(ExportDestination.header('Authorization', 'Splunk 0123-abcd'), isNull);
    expect(ExportDestination.header(' DD-API-KEY ', ' abc '), isNull);
    expect(ExportDestination.header("X-!#\$%&'*+.^_`|~-9", 'v'), isNull);
    expect(ExportDestination.header('Authorization', null), ExportHeaderProblem.half);
    expect(ExportDestination.header('Authorization', ' '), ExportHeaderProblem.half);
    expect(ExportDestination.header(null, 'token'), ExportHeaderProblem.half);
    for (final name in ['X Token', 'X:Token', 'Größe', 'X\nY', 'a(b)', '"q"', 'x' * 65]) {
      expect(ExportDestination.header(name, 'v'), ExportHeaderProblem.name, reason: name);
    }
    expect(ExportDestination.header('x' * 64, 'v'), isNull);
    // What the request sets itself is not for a person to set.
    for (final own in ['Content-Type', 'content-length', 'HOST', 'Transfer-Encoding', 'connection']) {
      expect(ExportDestination.header(own, 'v'), ExportHeaderProblem.name, reason: own);
    }
    for (final value in ['a\nb', 'a\rb', 'a\tb', 'tökén', 'a\u0000b', 'a\u007fb', 'v' * 4097]) {
      expect(ExportDestination.header('X-Token', value), ExportHeaderProblem.value, reason: jsonEncode(value));
    }
    expect(ExportDestination.header('X-Token', 'v' * 4096), isNull);
    expect(ExportDestination.header('X-Token', 'Bearer a.b-c_d~e+f/g=='), isNull);
  });

  test('a destination from what a person typed, and what a request to it carries', () {
    final plain = ExportDestination.of(' https://logs.example.com/in ', ExportFormat.lines)!;
    expect((plain.url.toString(), plain.format, plain.headerName, plain.headerValue),
        ('https://logs.example.com/in', ExportFormat.lines, null, null));
    expect(plain.headers, {'Content-Type': 'application/x-ndjson'});
    final withToken = ExportDestination.of('https://logs.example.com/in', ExportFormat.array,
        headerName: ' Authorization ', headerValue: ' Splunk abc ')!;
    expect((withToken.headerName, withToken.headerValue), ('Authorization', 'Splunk abc'));
    expect(withToken.headers, {'Content-Type': 'application/json', 'Authorization': 'Splunk abc'});
    expect(ExportDestination.of('https://logs.example.com/in', ExportFormat.lines, headerName: '', headerValue: '')!.headers,
        {'Content-Type': 'application/x-ndjson'});
    // Refused as a whole when either part is.
    expect(ExportDestination.of('http://logs.example.com/in', ExportFormat.lines), isNull);
    expect(ExportDestination.of('', ExportFormat.lines), isNull);
    expect(ExportDestination.of('https://logs.example.com/in', ExportFormat.lines, headerName: 'X'), isNull);
    expect(ExportDestination.of('https://logs.example.com/in', ExportFormat.lines, headerName: 'Host', headerValue: 'x'),
        isNull);

    // Kept and read back.
    expect(withToken.toJson(), {
      'url': 'https://logs.example.com/in',
      'format': 'array',
      'header_name': 'Authorization',
      'header_value': 'Splunk abc',
    });
    expect(plain.toJson(), {'url': 'https://logs.example.com/in', 'format': 'lines'});
    final back = ExportDestination.fromJson(jsonDecode(jsonEncode(withToken.toJson())))!;
    expect(back.toJson(), withToken.toJson());
    expect(ExportDestination.fromJson(plain.toJson())!.toJson(), plain.toJson());
    for (final bad in <Object?>[
      null,
      'https://logs.example.com/in',
      {'format': 'lines'},
      {'url': 'https://logs.example.com/in'},
      {'url': 'https://logs.example.com/in', 'format': 'csv'},
      {'url': 7, 'format': 'lines'},
      {'url': 'http://logs.example.com/in', 'format': 'lines'},
      {'url': 'https://logs.example.com/in', 'format': 'lines', 'header_name': 7, 'header_value': 'x'},
      {'url': 'https://logs.example.com/in', 'format': 'lines', 'header_name': 'X', 'header_value': 7},
      {'url': 'https://logs.example.com/in', 'format': 'lines', 'header_name': 'X'},
    ]) {
      expect(ExportDestination.fromJson(bad), isNull, reason: '$bad');
    }
  });

  test('what the sending device keeps: the key, the address and where activity starts, in the secure storage, '
      'listed for each account', () async {
    final keychain = _Keychain();
    final store = ExportSettingsStore(keychain);
    final to = ExportDestination.of('https://logs.example.com/in', ExportFormat.lines,
        headerName: 'Authorization', headerValue: 'Splunk abc')!;
    final settings = ExportSettings(seed: Uint8List.fromList(List.filled(32, 9)), destination: to, activityFrom: 17);
    expect(await store.read('uid-a', 'o-1'), isNull);
    expect(await store.orchards('uid-a'), isEmpty);
    expect(keychain.values, isEmpty, reason: 'looking keeps nothing');

    await store.write('uid-a', 'o-1', settings);
    expect(keychain.values.keys.toSet(), {'orchard_export_v1.uid-a', 'orchard_export_v1.uid-a.o-1'});
    expect((ExportSettingsStore.listKey('uid-a'), ExportSettingsStore.storageKey('uid-a', 'o-1')),
        ('orchard_export_v1.uid-a', 'orchard_export_v1.uid-a.o-1'));
    expect(jsonDecode(keychain.values['orchard_export_v1.uid-a.o-1']!), {
      'v': 1,
      'seed': base64Encode(List.filled(32, 9)),
      'to': to.toJson(),
      'activity_from': 17,
    });
    final back = (await store.read('uid-a', 'o-1'))!;
    expect(back.seed, settings.seed);
    expect(back.activityFrom, 17);
    expect(back.destination.toJson(), to.toJson());
    expect(await store.orchards('uid-a'), {'o-1'});
    // Beside it, a note of how far the device got: kept as it is written,
    // and nothing that reads as settings or is listed.
    expect(ExportSettingsStore.sentKey('uid-a', 'o-1'), 'orchard_export_v1.uid-a.o-1.sent');
    expect(await store.readSent('uid-a', 'o-1'), isNull);
    await store.writeSent('uid-a', 'o-1', 'as far as this');
    expect(keychain.values['orchard_export_v1.uid-a.o-1.sent'], 'as far as this');
    expect(await store.readSent('uid-a', 'o-1'), 'as far as this');
    expect(await store.readSent('uid-a', 'o-2'), isNull);
    expect(await store.readSent('uid-b', 'o-1'), isNull);
    expect(await store.orchards('uid-a'), {'o-1'});
    expect((await store.read('uid-a', 'o-1'))!.activityFrom, 17);
    // Each account and each Orchard has its own.
    expect(await store.read('uid-b', 'o-1'), isNull);
    expect(await store.read('uid-a', 'o-2'), isNull);
    expect(await store.orchards('uid-b'), isEmpty);
    await store.write('uid-a', 'o-2', settings);
    await store.write('uid-a', 'o-1', settings);
    await store.write('uid-b', 'o-1', settings);
    expect(await store.orchards('uid-a'), {'o-1', 'o-2'});
    expect(jsonDecode(keychain.values['orchard_export_v1.uid-a']!), ['o-1', 'o-2']);
    expect(await store.orchards('uid-b'), {'o-1'});

    // Forgotten: the entry goes, its note with it, and the list no longer
    // names it; the last one takes the list with it.
    await store.writeSent('uid-b', 'o-1', 'someone else');
    await store.forget('uid-a', 'o-1');
    expect(await store.read('uid-a', 'o-1'), isNull);
    expect(await store.readSent('uid-a', 'o-1'), isNull);
    expect(await store.readSent('uid-b', 'o-1'), 'someone else');
    keychain.values.remove('orchard_export_v1.uid-b.o-1.sent');
    expect(await store.orchards('uid-a'), {'o-2'});
    expect((await store.read('uid-b', 'o-1'))!.activityFrom, 17);
    await store.forget('uid-a', 'o-2');
    await store.forget('uid-a', 'never-kept');
    expect(keychain.values.keys.toSet(), {'orchard_export_v1.uid-b', 'orchard_export_v1.uid-b.o-1'});

    // Listed first: an entry is never there without being listed, should
    // the app stop in between.
    final order = <String>[];
    final watched = _Recording(keychain, order);
    await ExportSettingsStore(watched).write('uid-c', 'o-9', settings);
    expect(order, ['orchard_export_v1.uid-c', 'orchard_export_v1.uid-c.o-9']);

    // The list is kept in one order, whatever order the Orchards were set
    // up in: the same Orchards are the same text.
    for (final id in ['o-9', 'o-1', 'o-5']) {
      await store.write('uid-d', id, settings);
    }
    expect(keychain.values['orchard_export_v1.uid-d'], jsonEncode(['o-1', 'o-5', 'o-9']));
    await store.forget('uid-d', 'o-1');
    await store.write('uid-d', 'o-0', settings);
    expect(keychain.values['orchard_export_v1.uid-d'], jsonEncode(['o-0', 'o-5', 'o-9']));

    // What does not read as settings is none; a list that is not one is empty.
    for (final bad in [
      'not json',
      '[]',
      jsonEncode({'v': 2, 'seed': base64Encode(List.filled(32, 9)), 'to': to.toJson(), 'activity_from': 0}),
      jsonEncode({'v': 1, 'seed': base64Encode(List.filled(31, 9)), 'to': to.toJson(), 'activity_from': 0}),
      jsonEncode({'v': 1, 'seed': 'not base64 !', 'to': to.toJson(), 'activity_from': 0}),
      jsonEncode({'v': 1, 'seed': 7, 'to': to.toJson(), 'activity_from': 0}),
      jsonEncode({'v': 1, 'seed': base64Encode(List.filled(32, 9)), 'to': {'url': 'x'}, 'activity_from': 0}),
      jsonEncode({'v': 1, 'seed': base64Encode(List.filled(32, 9)), 'to': to.toJson(), 'activity_from': -1}),
      jsonEncode({'v': 1, 'seed': base64Encode(List.filled(32, 9)), 'to': to.toJson(), 'activity_from': '0'}),
      jsonEncode({'v': 1, 'seed': base64Encode(List.filled(32, 9)), 'to': to.toJson()}),
    ]) {
      keychain.values['orchard_export_v1.uid-b.o-1'] = bad;
      expect(await store.read('uid-b', 'o-1'), isNull, reason: bad);
    }
    expect(ExportSettings.fromText(null), isNull);
    expect(ExportSettings.fromText(settings.toText())!.activityFrom, 17);
    keychain.values['orchard_export_v1.uid-b'] = 'not json';
    expect(await store.orchards('uid-b'), isEmpty);
    keychain.values['orchard_export_v1.uid-b'] = jsonEncode({'o-1': true});
    expect(await store.orchards('uid-b'), isEmpty);
    keychain.values['orchard_export_v1.uid-b'] = jsonEncode(['o-1', 7, null, 'o-2']);
    expect(await store.orchards('uid-b'), {'o-1', 'o-2'});
  });

  group('the request', () {
    final to = ExportDestination.of('https://logs.example.com/in?x=1', ExportFormat.lines,
        headerName: 'Authorization', headerValue: 'Splunk abc')!;

    test('a POST of the body as it is, with the header, that follows no redirect; taken when the answer is 2xx',
        () async {
      final seen = <http.Request>[];
      ExportPost post(int status, {String body = 'ok'}) => httpExportPost(
            client: MockClient((request) async {
              seen.add(request);
              return http.Response(body, status);
            }),
          );
      final delivery = await post(200)(to, '{"a":"zoë"}\n');
      expect((delivery.ok, delivery.status, delivery.failure), (true, 200, null));
      final sent = seen.single;
      expect((sent.method, '${sent.url}'), ('POST', 'https://logs.example.com/in?x=1'));
      expect(sent.followRedirects, isFalse, reason: 'the header is for that address, and no other');
      expect(sent.headers['Content-Type'], 'application/x-ndjson');
      expect(sent.headers['Authorization'], 'Splunk abc');
      expect(utf8.decode(sent.bodyBytes), '{"a":"zoë"}\n');

      for (final ok in [200, 201, 202, 204, 299]) {
        final d = await post(ok, body: '')(to, 'x');
        expect((d.ok, d.status), (true, ok), reason: '$ok');
      }
      for (final refused in [199, 300, 301, 302, 307, 400, 401, 403, 404, 413, 429, 500, 503]) {
        final d = await post(refused, body: 'why it was refused: a secret')(to, 'x');
        expect((d.ok, d.failure, d.status), (false, ExportFailure.refused, refused), reason: '$refused');
      }
    });

    test('what goes wrong is said by its kind, and never thrown', () async {
      ExportPost failing(Object error) => httpExportPost(client: MockClient((request) async => throw error));
      Future<(bool, ExportFailure?, int?)> of(Object error) async {
        final d = await failing(error)(to, 'x');
        return (d.ok, d.failure, d.status);
      }

      expect(await of(TimeoutException('slow')), (false, ExportFailure.timeout, null));
      expect(await of(const HandshakeException('bad certificate')), (false, ExportFailure.certificate, null));
      expect(await of(const TlsException('tls')), (false, ExportFailure.certificate, null));
      expect(await of(const SocketException('no route')), (false, ExportFailure.unreachable, null));
      expect(await of(http.ClientException('closed')), (false, ExportFailure.other, null));
      expect(await of(StateError('anything else')), (false, ExportFailure.other, null));

      // An answer that never comes is given up on.
      final never = httpExportPost(
        client: MockClient((request) => Completer<http.Response>().future),
        timeout: const Duration(milliseconds: 50),
      );
      final d = await never(to, 'x');
      expect((d.ok, d.failure), (false, ExportFailure.timeout));

      // Once the receiver said whether it took them, what it writes after
      // that changes nothing: a text that breaks off, or never ends.
      for (final (status, taken) in [(200, true), (500, false)]) {
        final broken = httpExportPost(
          client: MockClient.streaming((request, body) async =>
              http.StreamedResponse(Stream<List<int>>.error(const SocketException('reset')), status)),
        );
        expect((await broken(to, 'x')).ok, taken, reason: '$status, then the line broke');
        final endless = httpExportPost(
          client: MockClient.streaming(
              (request, body) async => http.StreamedResponse(StreamController<List<int>>().stream, status)),
          timeout: const Duration(milliseconds: 50),
        );
        final answer = await endless(to, 'x');
        expect((answer.ok, answer.status), (taken, status), reason: '$status, then nothing more');
      }
    });

    test('plain http goes to the own network only; anywhere else nothing is sent', () async {
      final seen = <http.Request>[];
      final post = httpExportPost(
        client: MockClient((request) async {
          seen.add(request);
          return http.Response('', 204);
        }),
      );
      // (A destination kept from before, or made by hand: the request holds
      // to the rule itself.)
      final outside = ExportDestination(url: Uri.parse('http://logs.example.com/in'));
      final d = await post(outside, 'x');
      expect((d.ok, d.failure), (false, ExportFailure.unreachable));
      expect(seen, isEmpty);
      final inside = ExportDestination.of('http://10.0.5.20:8088/in', ExportFormat.array)!;
      expect((await post(inside, '[]')).ok, isTrue);
      expect('${seen.single.url}', 'http://10.0.5.20:8088/in');
      expect(seen.single.headers['Content-Type'], 'application/json');
    });
  });
}

/// A keychain that notes the order entries are written in.
class _Recording implements FlutterSecureStorage {
  _Recording(this._inner, this.order);

  final _Keychain _inner;
  final List<String> order;

  @override
  dynamic noSuchMethod(Invocation invocation) {
    if (invocation.memberName == #write) order.add(invocation.namedArguments[#key] as String);
    return _inner.noSuchMethod(invocation);
  }
}
