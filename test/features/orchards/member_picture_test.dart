import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:zestssh/features/orchards/member_picture.dart';
import 'package:zestssh/features/orchards/widgets/team_admin_ui.dart';

/// A member's picture loaded from any https address: their teammates' devices told
/// that server who they are and when they looked, with no limit on what came back
/// (found in a security review). Only the known hosts now, with a cap.
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  tearDown(() {
    debugMemberPictureClient = null;
    debugForgetMemberPictures();
  });

  group('where a picture may come from', () {
    for (final url in [
      'https://lh3.googleusercontent.com/a/ACg8ocJ-demo=s96-c',
      'https://LH5.GOOGLEUSERCONTENT.COM/a/demo',
      'https://appleid.cdn-apple.com/static/bin/demo.png',
      'https://www.apple.com/demo.png',
      'https://api.zestssh.com/v1/avatar/AbCdEf0123456789',
    ]) {
      test('$url: yes', () => expect(isKnownPictureAddress(url), isTrue));
    }
    for (final url in [
      'https://evil.example/alice.png',
      'https://images.example.com/alice.png',
      'https://googleusercontent.com.evil.example/a',
      'https://evilgoogleusercontent.com/a',
      'https://evil.example/lh3.googleusercontent.com/a',
      'https://lh3.googleusercontent.com:8443/a',
      'https://me@lh3.googleusercontent.com/a',
      'http://lh3.googleusercontent.com/a',
      'https://api.zestssh.com/v1/account',
      'https://api.zestssh.com.evil.example/v1/avatar/x',
      'javascript:alert(1)',
      'https:///no-host.png',
      '',
    ]) {
      test("'$url': no", () => expect(isKnownPictureAddress(url), isFalse));
    }
  });

  group('fetching one', () {
    const url = 'https://lh3.googleusercontent.com/a/demo';
    // The smallest PNG there is: one pixel.
    final onePixel = Uint8List.fromList([
      0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a, 0, 0, 0, 13, 0x49, 0x48, 0x44, 0x52, 0, 0, 0, 1, 0, 0, 0, 1, 8, 6, 0, 0, 0, 0x1f, 0x15, 0xc4,
      0x89, 0, 0, 0, 13, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9c, 0x63, 0xf8, 0xcf, 0xc0, 0xf0, 0x1f, 0, 5, 0, 1, 0xff, 0x8d, 0xb3, 0x37, 0x0b, 0, 0, 0,
      0, 0x49, 0x45, 0x4e, 0x44, 0xae, 0x42, 0x60, 0x82,
    ]);

    testWidgets('no request at all for an address it may not come from', (tester) async {
      var sent = 0;
      debugMemberPictureClient = MockClient((_) async {
        sent++;
        return http.Response.bytes(onePixel, 200);
      });
      expect(await memberPicture('https://evil.example/a.png'), isNull);
      expect(sent, 0);
    });

    testWidgets('a good one is given, fetched once, and no redirect is followed', (tester) async {
      await tester.runAsync(() async {
        final sent = <http.BaseRequest>[];
        debugMemberPictureClient = MockClient.streaming((r, _) async {
          sent.add(r);
          return http.StreamedResponse(Stream.value(onePixel), 200, contentLength: onePixel.length);
        });
        expect(await memberPicture(url), onePixel);
        expect(await memberPicture(url), onePixel);
        expect(sent, hasLength(1));
        expect((sent.single as http.Request).followRedirects, isFalse);
      });
    });

    testWidgets('a redirect, an error or a body past the cap is no picture, whatever its length says', (tester) async {
      await tester.runAsync(() async {
        for (final (i, respond) in <http.StreamedResponse Function()>[
          () => http.StreamedResponse(const Stream.empty(), 302, headers: {'location': 'https://evil.example/a.png'}),
          () => http.StreamedResponse(const Stream.empty(), 500),
          () => http.StreamedResponse(Stream.value(onePixel), 200, contentLength: kMaxMemberPictureBytes + 1),
          () => http.StreamedResponse(
              Stream.periodic(Duration.zero, (_) => Uint8List(1024 * 1024)).take(4), 200),
          () => http.StreamedResponse(Stream.value(Uint8List.fromList([1, 2, 3])), 200),
        ].indexed) {
          debugMemberPictureClient = MockClient.streaming((r, _) async => respond());
          expect(await memberPicture('$url/$i'), isNull, reason: 'case $i');
        }
      });
    });

    testWidgets('a picture that says it is huge is not decoded', (tester) async {
      await tester.runAsync(() async {
        final huge = Uint8List.fromList(onePixel);
        // Its first chunk says 30000 by 30000 (its check sum no longer matches: a
        // decoder that reads the size only does not look).
        ByteData.sublistView(huge).setUint32(16, 30000);
        ByteData.sublistView(huge).setUint32(20, 30000);
        debugMemberPictureClient = MockClient.streaming((r, _) async => http.StreamedResponse(Stream.value(huge), 200));
        expect(await memberPicture(url), isNull);
      });
    });
  });

  group('the face', () {
    Widget face(String? picture) => MaterialApp(home: Scaffold(body: TeamFace(name: 'Alice Example', picture: picture)));

    testWidgets('at an unknown address: the initials, and nothing is fetched', (tester) async {
      var sent = 0;
      debugMemberPictureClient = MockClient((_) async {
        sent++;
        return http.Response('', 404);
      });
      await tester.pumpWidget(face('https://evil.example/alice.png'));
      await tester.pump();
      expect(find.byKey(const ValueKey('team-face-picture')), findsNothing);
      expect(find.byType(TeamInitials), findsOneWidget);
      expect(sent, 0);
    });

    testWidgets('at a known one that does not load: the initials', (tester) async {
      debugMemberPictureClient = MockClient((_) async => http.Response('', 404));
      await tester.pumpWidget(face('https://lh3.googleusercontent.com/a/alice'));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump();
      expect(find.byKey(const ValueKey('team-face-picture')), findsOneWidget);
      expect(find.byType(TeamInitials), findsOneWidget);
      expect(find.byType(Image), findsNothing);
    });
  });
}
