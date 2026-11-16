import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/services/connection_share_url_service.dart';

/// Share (a host's link and QR code, from its edit screen) for a host whose
/// name, key name, group, tag or forward label holds a character the link's
/// parser refuses in a name (' " ` \ < >): the link was built, read back by
/// the app's own parser, refused, and the sheet showed "Invalid argument(s):
/// Constructed share URL failed parser validation" in place of the code
/// (found in a review). The parser stays as strict; the link
/// carries look-alike characters.
void main() {
  test("a host named Mom's NAS can be shared, and reads as Mom's NAS", () {
    final uri = ConnectionShareUrlService.buildShareUrl(label: "Mom's NAS", host: 'nas.home.arpa', port: 22);
    final back = ConnectionShareUrlService.tryParse(uri)!;
    expect(back.label, 'Mom\u2019s NAS');
    expect(back.host, 'nas.home.arpa');
  });

  test("a host whose key is named Bob's key, in a group and with tags and a forward that quote, can be shared", () {
    final uri = ConnectionShareUrlService.buildShareUrl(
      label: 'web1',
      host: 'web1.example.com',
      port: 22,
      identityHint: "Bob's key",
      groupHint: 'Team "A"',
      tags: const ['a<b>', r'c\d', '`e`'],
      forwards: const [
        SharedForward(
            type: 'local', bindAddress: '127.0.0.1', bindPort: 8080, remoteHost: 'localhost', remotePort: 80, label: "Bob's app"),
      ],
    );
    final back = ConnectionShareUrlService.tryParse(uri)!;
    expect(back.identityHint, 'Bob\u2019s key');
    expect(back.groupHint, 'Team \u201DA\u201D');
    expect(back.tags, ['a\u2039b\u203A', 'c\uFF3Cd', '\u2018e\u2018']);
    expect(back.forwards.single.label, 'Bob\u2019s app');
  });

  test('a name with controls, spoofing characters or over 128 characters is carried cleaned and cut', () {
    final long = 'x' * 200;
    final uri = ConnectionShareUrlService.buildShareUrl(
      label: 'ab\u202Ecd\u0007',
      host: 'h.example.com',
      port: 22,
      identityHint: long,
      groupHint: '\u200B',
      tags: const ['\u0001', 'ok'],
    );
    final back = ConnectionShareUrlService.tryParse(uri)!;
    expect(back.label, 'abcd');
    expect(back.identityHint, 'x' * 128);
    expect(back.groupHint, isNull, reason: 'nothing of it is left to show');
    expect(back.tags, ['ok']);
  });

  test('a name cut at 128 never splits a character in two', () {
    final label = '${'x' * 127}\u{1F600}';
    final back = ConnectionShareUrlService.tryParse(
        ConnectionShareUrlService.buildShareUrl(label: label, host: 'h.example.com', port: 22))!;
    expect(back.label, 'x' * 127);
  });

  test('a link made by hand with a quote in a name is still refused', () {
    final uri = Uri.parse("zestssh://add-host?host=h.example.com&label=Mom's");
    expect(ConnectionShareUrlService.tryParse(uri), isNull);
  });
}
