#!/usr/bin/env node
// Makes the keys the ZestSSH status service signs with, and prints them.
//
//   node tool/make_keys.mjs            two keys, named k1 and k2
//   node tool/make_keys.mjs k3         one more, named as given
//
// Each key has two halves:
//
//   PRIVATE  signs. It goes into the Worker as a secret, and nowhere else:
//            not into a file in a repository, not into a chat, not to
//            anyone. Whoever holds it can make the app believe ZestSSH Cloud
//            is down (which holds an Orchard's offline limit open for as
//            long as the app allows, and nothing more than that).
//   PUBLIC   checks. It is compiled into the app and may be shown to anyone.
//
// The first key (k1) is the one the Worker uses. The second (k2) is a spare:
// keep its private half offline (a password manager, a printed page), so
// that the day k1 has to go, the Worker can be given k2 and every app
// already out there, which knows both public halves, goes on believing it.
//
// Nothing is written to disk and nothing is sent anywhere: the keys are made
// on this machine and printed to this terminal, once.
import { webcrypto } from 'node:crypto';

const subtle = webcrypto.subtle;
const names = process.argv.slice(2).length > 0 ? process.argv.slice(2) : ['k1', 'k2'];

for (const name of names) {
  if (!/^[a-z0-9]{1,16}$/.test(name)) {
    console.error(`"${name}" is not a name for a key: lower case letters and digits, 16 at most.`);
    process.exit(1);
  }
}

const b64 = (buffer) => Buffer.from(buffer).toString('base64');

console.log('');
console.log('Keys for the ZestSSH status service. Shown once: copy what you need now.');
for (const name of names) {
  const pair = await subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  const privateKey = b64(await subtle.exportKey('pkcs8', pair.privateKey));
  const publicKey = b64(await subtle.exportKey('raw', pair.publicKey));
  // Checked before it is shown: a key that does not check out is no key.
  const probe = new TextEncoder().encode('zestssh.status.v1 key check');
  const signature = await subtle.sign({ name: 'Ed25519' }, pair.privateKey, probe);
  if (!(await subtle.verify({ name: 'Ed25519' }, pair.publicKey, signature, probe))) {
    console.error('A key was made that does not check out. Nothing was shown; run this again.');
    process.exit(1);
  }
  console.log('');
  console.log(`== ${name} ==`);
  console.log(`PUBLIC  (give this to whoever builds the app):  ${name} ${publicKey}`);
  console.log(`PRIVATE (a secret, see above):                  ${privateKey}`);
}
console.log('');
console.log('Next, for the first key:');
console.log('  npx wrangler secret put STATUS_SIGNING_KEY     (paste its PRIVATE line, the part after the colon)');
console.log('and make sure STATUS_KEY_ID in wrangler.toml is its name.');
console.log('');
