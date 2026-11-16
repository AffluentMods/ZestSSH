/// Cloud import (3.0): AWS EC2. Access keys sign each request here (AWS
/// Signature Version 4); they are never sent. Reads DescribeRegions, then
/// DescribeInstances in each region, the only two actions the import needs
/// (the read-only IAM policy the Connect step offers allows exactly those).
library;

import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:xml/xml.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/features/cloud_import/cloud_scans.dart';

/// The IAM policy the Connect step suggests: read the instance list, nothing
/// else.
const kAwsReadOnlyPolicy = '''{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": ["ec2:DescribeInstances", "ec2:DescribeRegions"],
      "Resource": "*"
    }
  ]
}''';

const _ec2Version = '2016-11-15';

/// An AWS SigV4 `Authorization` header for a request with no query string
/// whose [headers] (lower-case names) are all signed.
String awsSigV4({
  required String method,
  required String path,
  required Map<String, String> headers,
  required String payloadSha256,
  required String amzDate,
  required String accessKeyId,
  required String secretAccessKey,
  required String region,
  required String service,
}) {
  final names = headers.keys.map((k) => k.toLowerCase()).toList()..sort();
  final lower = {for (final e in headers.entries) e.key.toLowerCase(): e.value};
  final canonicalHeaders = names.map((k) => '$k:${lower[k]!.trim().replaceAll(RegExp(r'\s+'), ' ')}\n').join();
  final signedHeaders = names.join(';');
  final canonicalRequest = [method, path, '', canonicalHeaders, signedHeaders, payloadSha256].join('\n');
  final dateStamp = amzDate.substring(0, 8);
  final scope = '$dateStamp/$region/$service/aws4_request';
  final toSign = ['AWS4-HMAC-SHA256', amzDate, scope, c.sha256.convert(utf8.encode(canonicalRequest)).toString()].join('\n');
  List<int> hmac(List<int> key, String data) => c.Hmac(c.sha256, key).convert(utf8.encode(data)).bytes;
  final kSigning = hmac(hmac(hmac(hmac(utf8.encode('AWS4$secretAccessKey'), dateStamp), region), service), 'aws4_request');
  final signature = c.Hmac(c.sha256, kSigning).convert(utf8.encode(toSign)).toString();
  return 'AWS4-HMAC-SHA256 Credential=$accessKeyId/$scope, SignedHeaders=$signedHeaders, Signature=$signature';
}

/// `YYYYMMDD'T'HHMMSS'Z'` for [utc].
String awsDate(DateTime utc) {
  String two(int n) => n.toString().padLeft(2, '0');
  final t = utc.toUtc();
  return '${t.year.toString().padLeft(4, '0')}${two(t.month)}${two(t.day)}T${two(t.hour)}${two(t.minute)}${two(t.second)}Z';
}

final _region = RegExp(r'^[a-z]{2}(-[a-z]+)+-\d{1,2}$');

/// The regions typed (spaces or commas between), each checked; null when
/// one is not a region name.
List<String>? awsRegionsOf(String typed) {
  final parts = typed.split(RegExp(r'[\s,]+')).where((s) => s.isNotEmpty).toList();
  if (parts.any((p) => !_region.hasMatch(p))) return null;
  return parts.toSet().toList();
}

XmlDocument _xml(String text, CloudHttp http, String what) {
  try {
    return XmlDocument.parse(text);
  } on XmlException catch (e) {
    throw CloudError(CloudErrorKind.answer, detail: http.scrub('$what: not XML ($e)'));
  }
}

String? _text(XmlElement? e, String name) {
  final t = e?.getElement(name)?.innerText.trim();
  return t == null || t.isEmpty ? null : t;
}

/// The regions DescribeRegions lists (the account's enabled ones).
List<String> parseAwsRegions(XmlDocument doc) => [
      for (final item in doc.rootElement.getElement('regionInfo')?.findElements('item') ?? const <XmlElement>[])
        ?_regionOrNull(_text(item, 'regionName')),
    ];

String? _regionOrNull(String? s) => s != null && _region.hasMatch(s) ? s : null;

/// The instances in one DescribeInstances page, and the next page's token.
({List<CloudMachine> machines, String? next}) parseAwsInstances(XmlDocument doc, String region) {
  final out = <CloudMachine>[];
  final reservations = doc.rootElement.getElement('reservationSet')?.findElements('item') ?? const <XmlElement>[];
  for (final r in reservations) {
    for (final i in r.getElement('instancesSet')?.findElements('item') ?? const <XmlElement>[]) {
      final id = _text(i, 'instanceId');
      if (id == null) continue;
      final state = _text(i.getElement('instanceState'), 'name');
      if (state == 'terminated' || state == 'shutting-down') continue;
      String? name;
      final tags = <String>[];
      for (final t in i.getElement('tagSet')?.findElements('item') ?? const <XmlElement>[]) {
        final key = _text(t, 'key');
        if (key == null || key.startsWith('aws:')) continue;
        final value = _text(t, 'value');
        if (key == 'Name') {
          name = value;
        } else {
          tags.add(value == null ? key : '$key:$value');
        }
      }
      String? v6;
      for (final nic in i.getElement('networkInterfaceSet')?.findElements('item') ?? const <XmlElement>[]) {
        for (final a in nic.getElement('ipv6AddressesSet')?.findElements('item') ?? const <XmlElement>[]) {
          v6 ??= cloudIpOrNull(_text(a, 'ipv6Address'));
        }
      }
      final platform = '${_text(i, 'platform') ?? ''} ${_text(i, 'platformDetails') ?? ''}'.toLowerCase();
      final cleaned = cleanCloudText(name);
      out.add(CloudMachine(
        provider: CloudProvider.aws,
        id: id,
        name: cleaned.isEmpty ? id : cleaned,
        publicAddress: cloudIpOrNull(_text(i, 'ipAddress')) ?? v6,
        privateAddress: cloudIpOrNull(_text(i, 'privateIpAddress')),
        where: cleanCloudText(_text(i.getElement('placement'), 'availabilityZone') ?? region, max: 32),
        tags: cleanCloudTags(tags),
        os: platform.contains('windows') ? CloudOs.windows : CloudOs.linux,
        running: state == 'running' || state == 'pending',
      ));
    }
  }
  return (machines: out, next: _text(doc.rootElement, 'nextToken'));
}

/// Every instance the keys can see, in [regions] or (none given) in every
/// region the account has enabled.
Future<List<CloudMachine>> scanAws(
  CloudHttp http, {
  required String accessKeyId,
  required String secretAccessKey,
  String sessionToken = '',
  List<String> regions = const [],
  DateTime Function() now = DateTime.now,
  int parallel = 4,
}) async {
  final keyId = accessKeyId.trim();
  final secret = secretAccessKey.trim();
  final session = sessionToken.trim();
  if (!RegExp(r'^[A-Z0-9]{16,128}$').hasMatch(keyId) || secret.isEmpty) {
    throw CloudError(CloudErrorKind.signIn, detail: 'An access key ID is letters and digits, like AKIAIOSFODNN7EXAMPLE.');
  }
  http.hide(secret);
  if (session.isNotEmpty) http.hide(session);

  Future<XmlDocument> call(String region, Map<String, String> params) async {
    final host = 'ec2.$region.amazonaws.com';
    final body = {'Version': _ec2Version, ...params}.entries.map((e) => '${Uri.encodeQueryComponent(e.key)}=${Uri.encodeQueryComponent(e.value)}').join('&');
    final date = awsDate(now());
    final signed = {
      'content-type': 'application/x-www-form-urlencoded; charset=utf-8',
      'host': host,
      'x-amz-date': date,
      if (session.isNotEmpty) 'x-amz-security-token': session,
    };
    final auth = awsSigV4(
      method: 'POST',
      path: '/',
      headers: signed,
      payloadSha256: c.sha256.convert(utf8.encode(body)).toString(),
      amzDate: date,
      accessKeyId: keyId,
      secretAccessKey: secret,
      region: region,
      service: 'ec2',
    );
    final text = await http.send(
      'POST',
      Uri.https(host, '/'),
      headers: {
        'Content-Type': signed['content-type']!,
        'X-Amz-Date': date,
        if (session.isNotEmpty) 'X-Amz-Security-Token': session,
        'Authorization': auth,
      },
      body: body,
    );
    return _xml(text, http, 'EC2 ${params['Action']}');
  }

  final where = regions.isNotEmpty ? regions : parseAwsRegions(await call('us-east-1', {'Action': 'DescribeRegions'}));
  final out = <CloudMachine>[];
  var nextRegion = 0;
  Future<void> worker() async {
    while (nextRegion < where.length) {
      final region = where[nextRegion++];
      String? token;
      for (var n = 0; n < kCloudMaxPages; n++) {
        final page = parseAwsInstances(
          await call(region, {'Action': 'DescribeInstances', 'MaxResults': '1000', 'NextToken': ?token}),
          region,
        );
        out.addAll(page.machines);
        token = page.next;
        if (token == null) break;
      }
    }
  }

  await Future.wait([for (var w = 0; w < parallel; w++) worker()]);
  return out;
}
