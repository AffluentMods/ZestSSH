'use strict';

// Writes soft_authenticator.json beside this file: ZestSSH Cloud's own
// passkey options (src/lib/passkeys.js, creationOptions and requestOptions)
// and the responses its software authenticator (test/helpers/
// soft_authenticator.js) gives them, which the server's tests show it
// accepts. The app's passkey tests beside it hold what each platform hands
// the server to these, field by field. Made-up account and keys only. Run
// from anywhere, with the backend's folder (it has node_modules) as the
// argument:
//
//   node test/services/passkeys/soft_authenticator_fixtures.js <the server's folder>

const crypto = require('crypto');
const fs = require('fs');
const path = require('path');

if (!process.argv[2]) {
  console.error('Name the folder of ZestSSH Cloud\'s server code (it has node_modules).');
  process.exit(2);
}
const backend = path.resolve(process.argv[2]);
const passkeys = require(path.join(backend, 'src', 'lib', 'passkeys.js'));
const { SoftAuthenticator, b64u } = require(path.join(backend, 'test', 'helpers', 'soft_authenticator.js'));

const bytes = (from, n) => Buffer.from(Array.from({ length: n }, (_, i) => (from + i) & 0xff));
const androidOrigin = `android:apk-key-hash:${b64u(crypto.createHash('sha256').update('made-up signing key').digest())}`;

const creation = passkeys.creationOptions({
  challenge: b64u(bytes(0x01, 32)),
  rpId: 'zestssh.com',
  userHandle: bytes(0xa0, 32),
  email: 'river@example.com',
  exclude: [
    { id: bytes(0x50, 16), transports: ['nfc', 'usb'] },
    { id: bytes(0x60, 32), transports: ['hybrid', 'internal'] },
    { id: bytes(0x70, 20), transports: ['smart-card'] },
  ],
});

/** A registration and a sign-in of one software authenticator. */
function ceremonies(authenticator) {
  const registration = authenticator.create(creation);
  const credential = authenticator.credentials[authenticator.credentials.length - 1];
  const request = passkeys.requestOptions({
    challenge: b64u(bytes(0x21, 32)),
    rpId: 'zestssh.com',
    allow: [{ id: credential.id, transports: registration.response.transports }],
  });
  return { registration, request, authentication: authenticator.get(request) };
}

const web = ceremonies(new SoftAuthenticator());
const android = ceremonies(new SoftAuthenticator({ origin: androidOrigin }));
const key = ceremonies(new SoftAuthenticator({ synced: false, counter: 7, transports: ['usb'], attachment: 'cross-platform' }));

const out = {
  made_with: "ZestSSH Cloud's src/lib/passkeys.js and test/helpers/soft_authenticator.js",
  android_origin: androidOrigin,
  creation_options: creation,
  web: web,
  android: android,
  security_key: key,
};
fs.writeFileSync(path.join(__dirname, 'soft_authenticator.json'), `${JSON.stringify(out, null, 2)}\n`);
console.log('wrote', path.join(__dirname, 'soft_authenticator.json'));
