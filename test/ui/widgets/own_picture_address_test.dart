import 'package:flutter_test/flutter_test.dart';
import 'package:zestssh/ui/widgets/profile_avatar.dart';

/// The person's own picture is fetched over https only (found in a
/// security review). Its address comes from their own sign-in or from ZestSSH
/// Cloud and was fetched whatever it was: a plain http address in clear, on
/// every start of the app.
void main() {
  test('an https address with a host is fetched', () {
    expect(ownPictureAllowed('https://lh3.googleusercontent.com/a/demo=s96-c'), isTrue);
    expect(ownPictureAllowed('https://api.example.com/v1/avatar/demo-token'), isTrue);
    expect(ownPictureAllowed('  https://pictures.example.com/demo.png  '), isTrue, reason: 'spaces around it are not part of it');
    expect(ownPictureAllowed('https://pictures.example.com:8443/demo.png'), isTrue, reason: 'a company may serve its pictures on a port of its own');
  });

  test('plain http, another scheme, no host, or a user name in it shows the initial', () {
    for (final not in [
      'http://pictures.example.com/demo.png',
      'HTTP://pictures.example.com/demo.png',
      'ftp://pictures.example.com/demo.png',
      'file:///C:/Users/demo/picture.png',
      'data:image/png;base64,AAAA',
      'javascript:alert(1)',
      'https:///demo.png',
      'https://demo:secret@pictures.example.com/demo.png',
      'pictures.example.com/demo.png',
      '',
      '   ',
      'https://',
    ]) {
      expect(ownPictureAllowed(not), isFalse, reason: not);
    }
  });
}
