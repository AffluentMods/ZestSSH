import 'dart:convert';

import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:xml/xml.dart';
import 'package:zestssh/features/cloud_import/cloud_aws.dart';
import 'package:zestssh/features/cloud_import/cloud_http.dart';
import 'package:zestssh/features/cloud_import/cloud_machine.dart';
import 'package:zestssh/services/sync/s3_sync_backend.dart';

/// Cloud import (3.0): AWS EC2. The signature matches AWS's published test
/// vectors and an independent implementation; the keys never travel; regions
/// and pages are read as documented.

const _key = 'AKIDEXAMPLE';
const _secret = 'wJalrXUtnFEMI/K7MDENG+bPxRfiCYEXAMPLEKEY';

String _sha(String s) => c.sha256.convert(utf8.encode(s)).toString();

String _instances(String region, List<String> ids, {String? next}) => '''<?xml version="1.0" encoding="UTF-8"?>
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
  <requestId>r</requestId>
  <reservationSet>
    <item>
      <instancesSet>
${ids.map((id) => '''        <item>
          <instanceId>$id</instanceId>
          <instanceState><code>16</code><name>running</name></instanceState>
          <privateIpAddress>10.0.0.${ids.indexOf(id) + 1}</privateIpAddress>
          <placement><availabilityZone>${region}a</availabilityZone></placement>
          <tagSet><item><key>Name</key><value>$id-name</value></item></tagSet>
        </item>''').join('\n')}
      </instancesSet>
    </item>
  </reservationSet>
  ${next == null ? '' : '<nextToken>$next</nextToken>'}
</DescribeInstancesResponse>''';

void main() {
  group('Signature Version 4', () {
    test('AWS\'s published vectors: get-vanilla and post-x-www-form-urlencoded', () {
      expect(
        awsSigV4(
          method: 'GET',
          path: '/',
          headers: {'host': 'example.amazonaws.com', 'x-amz-date': '20150830T123600Z'},
          payloadSha256: _sha(''),
          amzDate: '20150830T123600Z',
          accessKeyId: _key,
          secretAccessKey: _secret,
          region: 'us-east-1',
          service: 'service',
        ),
        'AWS4-HMAC-SHA256 Credential=AKIDEXAMPLE/20150830/us-east-1/service/aws4_request, SignedHeaders=host;x-amz-date, '
        'Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31',
      );
      expect(
        awsSigV4(
          method: 'POST',
          path: '/',
          headers: {'Content-Type': 'application/x-www-form-urlencoded', 'host': 'example.amazonaws.com', 'x-amz-date': '20150830T123600Z'},
          payloadSha256: _sha('Param1=value1'),
          amzDate: '20150830T123600Z',
          accessKeyId: _key,
          secretAccessKey: _secret,
          region: 'us-east-1',
          service: 'service',
        ),
        endsWith('SignedHeaders=content-type;host;x-amz-date, Signature=ff11897932ad3f4e8b18135d722051e5ac45fc38421b1da7b9d196a0fe09473a'),
      );
    });

    test('agrees with the sync\'s S3 signer on S3\'s header set', () {
      const date = '20260926T101500Z';
      final hash = _sha('');
      expect(
        awsSigV4(
          method: 'GET',
          path: '/bucket/zestssh-sync.json',
          headers: {'host': 'b.s3.amazonaws.com', 'x-amz-content-sha256': hash, 'x-amz-date': date},
          payloadSha256: hash,
          amzDate: date,
          accessKeyId: _key,
          secretAccessKey: _secret,
          region: 'eu-west-1',
          service: 's3',
        ),
        S3SyncBackend.signV4(
          method: 'GET',
          canonicalPath: '/bucket/zestssh-sync.json',
          host: 'b.s3.amazonaws.com',
          payloadHash: hash,
          amzDate: date,
          accessKeyId: _key,
          secretAccessKey: _secret,
          region: 'eu-west-1',
          service: 's3',
        ),
      );
    });

    test('the headers are signed in sorted order, however they are given', () {
      String sign(Map<String, String> headers) => awsSigV4(
            method: 'GET',
            path: '/',
            headers: headers,
            payloadSha256: _sha(''),
            amzDate: '20150830T123600Z',
            accessKeyId: _key,
            secretAccessKey: _secret,
            region: 'us-east-1',
            service: 'service',
          );
      expect(sign({'x-amz-date': '20150830T123600Z', 'Host': 'example.amazonaws.com'}),
          endsWith('SignedHeaders=host;x-amz-date, Signature=5fa00fa31553b73ebf1942676e86291e8372ff2a2260956d9b8aae1d763fbf31'));
    });

    test('dates', () {
      expect(awsDate(DateTime.utc(2026, 9, 6, 7, 5, 3)), '20260906T070503Z');
    });
  });

  test('regions typed: checked, spaces or commas between', () {
    expect(awsRegionsOf('us-east-1, eu-west-1  ap-southeast-2'), ['us-east-1', 'eu-west-1', 'ap-southeast-2']);
    expect(awsRegionsOf(''), isEmpty);
    expect(awsRegionsOf('us-east-1 evil.example'), isNull);
    expect(awsRegionsOf('us-gov-west-1'), ['us-gov-west-1']);
  });

  test('instances: the Name tag names it, aws: tags dropped, terminated left out, Windows marked', () {
    final page = parseAwsInstances(XmlDocument.parse('''
<DescribeInstancesResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
  <reservationSet>
    <item><instancesSet>
      <item>
        <instanceId>i-1</instanceId>
        <instanceState><name>running</name></instanceState>
        <ipAddress>203.0.113.14</ipAddress>
        <privateIpAddress>172.31.0.5</privateIpAddress>
        <placement><availabilityZone>us-east-1a</availabilityZone></placement>
        <tagSet>
          <item><key>Name</key><value>api-prod-1</value></item>
          <item><key>env</key><value>prod</value></item>
          <item><key>aws:autoscaling:groupName</key><value>x</value></item>
        </tagSet>
      </item>
      <item>
        <instanceId>i-2</instanceId>
        <instanceState><name>terminated</name></instanceState>
      </item>
      <item>
        <instanceId>i-3</instanceId>
        <instanceState><name>stopped</name></instanceState>
        <platform>windows</platform>
        <networkInterfaceSet><item><ipv6AddressesSet><item><ipv6Address>2600:1f18::5</ipv6Address></item></ipv6AddressesSet></item></networkInterfaceSet>
      </item>
    </instancesSet></item>
  </reservationSet>
  <nextToken>tok2</nextToken>
</DescribeInstancesResponse>'''), 'us-east-1');
    expect(page.next, 'tok2');
    expect(page.machines.map((m) => m.id), ['i-1', 'i-3']);
    final a = page.machines[0];
    expect(a.name, 'api-prod-1');
    expect(a.publicAddress, '203.0.113.14');
    expect(a.privateAddress, '172.31.0.5');
    expect(a.where, 'us-east-1a');
    expect(a.tags, ['env:prod']);
    final w = page.machines[1];
    expect(w.name, 'i-3', reason: 'no Name tag: the instance id');
    expect(w.os, CloudOs.windows);
    expect(w.running, isFalse);
    expect(w.publicAddress, '2600:1f18::5');
  });

  test('a scan: enabled regions, then each region page by page, every request signed and nothing secret sent', () async {
    final requests = <http.Request>[];
    final client = MockClient((req) async {
      requests.add(req);
      final body = Uri.splitQueryString(req.body);
      final region = req.url.host.split('.')[1];
      if (body['Action'] == 'DescribeRegions') {
        return http.Response('''<DescribeRegionsResponse xmlns="http://ec2.amazonaws.com/doc/2016-11-15/">
<regionInfo><item><regionName>eu-west-1</regionName></item><item><regionName>us-east-2</regionName></item><item><regionName>bad region</regionName></item></regionInfo>
</DescribeRegionsResponse>''', 200);
      }
      if (region == 'eu-west-1' && body['NextToken'] == null) return http.Response(_instances(region, ['i-a', 'i-b'], next: 'p2'), 200);
      if (region == 'eu-west-1') return http.Response(_instances(region, ['i-c']), 200);
      return http.Response(_instances(region, ['i-d']), 200);
    });
    final machines = await scanAws(
      CloudHttp(client),
      accessKeyId: 'ASIAIOSFODNN7EXAMPLE',
      secretAccessKey: _secret,
      sessionToken: 'IQoJb3JpZ2luX2VjEXAMPLE',
      now: () => DateTime.utc(2026, 9, 26, 10, 15),
    );
    expect(machines.map((m) => m.id).toSet(), {'i-a', 'i-b', 'i-c', 'i-d'});
    expect(requests.first.url.host, 'ec2.us-east-1.amazonaws.com');
    for (final r in requests) {
      expect(r.method, 'POST');
      expect(r.headers['Authorization'], startsWith('AWS4-HMAC-SHA256 Credential=ASIAIOSFODNN7EXAMPLE/20260926/'));
      expect(r.headers['Authorization'], contains('SignedHeaders=content-type;host;x-amz-date;x-amz-security-token'));
      expect(r.headers['X-Amz-Security-Token'], 'IQoJb3JpZ2luX2VjEXAMPLE');
      expect(r.body, isNot(contains(_secret)));
      expect(r.headers.values.join(' '), isNot(contains(_secret)));
    }
    final second = requests.firstWhere((r) => Uri.splitQueryString(r.body)['NextToken'] == 'p2');
    expect(second.url.host, 'ec2.eu-west-1.amazonaws.com');
  });

  test('the first page of a region is signed exactly as an independent implementation signs it', () async {
    http.Request? seen;
    final client = MockClient((req) async {
      seen = req;
      return http.Response(_instances('eu-west-1', const []), 200);
    });
    await scanAws(CloudHttp(client),
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE', secretAccessKey: _secret, regions: ['eu-west-1'], now: () => DateTime.utc(2026, 9, 26, 10, 15));
    expect(seen!.body, 'Version=2016-11-15&Action=DescribeInstances&MaxResults=1000');
    expect(seen!.headers['Content-Type'], 'application/x-www-form-urlencoded; charset=utf-8');
    // From scratchpad sigv4_ref.py (Python hmac/hashlib).
    expect(seen!.headers['Authorization'],
        'AWS4-HMAC-SHA256 Credential=AKIAIOSFODNN7EXAMPLE/20260926/eu-west-1/ec2/aws4_request, SignedHeaders=content-type;host;x-amz-date, '
        'Signature=6490c2cb1072b939949788c732947858a546d1c4927b3ba6e57cb18084d36776');
  });

  test('keys are checked first; a refusal says so with the secret blanked', () async {
    var calls = 0;
    await expectLater(
      scanAws(CloudHttp(MockClient((req) async {
        calls++;
        return http.Response('', 200);
      })), accessKeyId: 'not a key', secretAccessKey: _secret),
      throwsA(isA<CloudError>().having((e) => e.kind, 'kind', CloudErrorKind.signIn)),
    );
    expect(calls, 0);
    try {
      await scanAws(
        CloudHttp(MockClient((req) async => http.Response(
            '<Response><Errors><Error><Code>AuthFailure</Code><Message>bad $_secret</Message></Error></Errors></Response>', 401))),
        accessKeyId: 'AKIAIOSFODNN7EXAMPLE',
        secretAccessKey: _secret,
        regions: ['eu-west-1'],
      );
      fail('no error');
    } on CloudError catch (e) {
      expect(e.kind, CloudErrorKind.signIn);
      expect(e.detail, contains('AuthFailure'));
      expect(e.detail, isNot(contains(_secret)));
    }
  });
}
