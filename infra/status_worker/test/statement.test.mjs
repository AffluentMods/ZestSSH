// The statement the status service signs, held to the vectors the app is
// held to as well (test/vectors.json; the app's side is
// test/services/cloud/cloud_statement_test.dart).
import assert from 'node:assert/strict';
import { readFileSync, writeFileSync } from 'node:fs';
import { test } from 'node:test';

import {
  DOMAIN,
  canonical,
  fieldProblem,
  fromBase64,
  importSigningKey,
  importVerifyingKey,
  pkcs8OfSeed,
  sign,
  toBase64,
  verify,
} from '../src/statement.js';

const vectorsPath = new URL('./vectors.json', import.meta.url);

// A key anybody can make again: its seed is the numbers 1 to 32. It signs
// nothing but these vectors, and nothing believes it but these tests.
const seed = Uint8Array.from({ length: 32 }, (_, i) => i + 1);

async function testKey() {
  const signing = await importSigningKey(pkcs8OfSeed(seed));
  // The public half, by way of a key pair made from the same seed.
  const exportable = await crypto.subtle.importKey('pkcs8', fromBase64(pkcs8OfSeed(seed)), { name: 'Ed25519' }, true, ['sign']);
  const jwk = await crypto.subtle.exportKey('jwk', exportable);
  const publicRaw = toBase64(Buffer.from(jwk.x, 'base64url'));
  return { signing, publicRaw };
}

// Down for six hours when it was asked; and up, half a minute later.
const down = { v: 1, service: 'api.zestssh.com', state: 'down', at: 1791474000, until: 1791474900, since: 1791452400, key: 'k1' };
const up = { v: 1, service: 'api.zestssh.com', state: 'up', at: 1791474030, until: 1791474930, since: 0, key: 'k1' };
// Found down this very moment: since is its own time.
const justDown = { ...down, since: down.at };

test('the bytes that are signed are the fields, one to a line, after the name of what this is', () => {
  assert.equal(canonical(down), 'zestssh.status.v1\napi.zestssh.com\ndown\n1791474000\n1791474900\n1791452400\nk1');
  assert.equal(canonical(up), 'zestssh.status.v1\napi.zestssh.com\nup\n1791474030\n1791474930\n0\nk1');
  assert.equal(DOMAIN, 'zestssh.status.v1');
});

test('a statement signed here checks out with the public half of the key, and with no other', async () => {
  const { signing, publicRaw } = await testKey();
  const signed = await sign(down, signing);
  assert.deepEqual(Object.keys(signed), ['v', 'service', 'state', 'at', 'until', 'since', 'key', 'sig']);
  assert.equal(await verify(signed, await importVerifyingKey(publicRaw)), true);
  const other = await crypto.subtle.generateKey({ name: 'Ed25519' }, true, ['sign', 'verify']);
  assert.equal(await verify(signed, other.publicKey), false);
});

test('any field changed after signing no longer checks out', async () => {
  const { signing, publicRaw } = await testKey();
  const key = await importVerifyingKey(publicRaw);
  const signed = await sign(down, signing);
  for (const changed of [
    { ...signed, state: 'up', since: 0 },
    { ...signed, at: signed.at + 1 },
    { ...signed, until: signed.until + 86400 },
    { ...signed, since: signed.since - 7 * 86400 },
    { ...signed, since: signed.at },
    { ...signed, service: 'api.zestssh.com.example' },
    { ...signed, key: 'k2' },
  ]) {
    assert.equal(fieldProblem(changed), null, 'well formed, so that it is the signature that tells');
    assert.equal(await verify(changed, key), false, JSON.stringify(changed));
  }
  // And a signature that is not one.
  assert.equal(await verify({ ...signed, sig: 'AAAA' }, key), false);
  assert.equal(await verify({ ...signed, sig: 'not base64 at all !!' }, key), false);
  assert.equal(await verify({ ...signed, sig: undefined }, key), false);
  assert.equal(await verify({ ...signed, sig: '' }, key), false);
  // And what is no statement is no statement, whatever is signed under it:
  // said as "no", not as a failure of whoever asked.
  assert.equal(await verify({ ...signed, state: 'degraded' }, key), false);
  assert.equal(await verify({ ...signed, since: signed.at + 1 }, key), false);
  assert.equal(await verify(null, key), false);
});

test('a statement that is not one cannot be signed, and says what is wrong with it', () => {
  for (const [bad, why] of [
    [{ ...down, v: 2 }, 'not version 1'],
    [{ ...down, service: 'API host' }, 'the service is not a host name'],
    [{ ...down, service: 'a\nb' }, 'the service is not a host name'],
    [{ ...down, state: 'degraded' }, 'the state is neither up nor down'],
    [{ ...down, at: 1.5 }, 'the time is not whole seconds'],
    [{ ...down, at: '1791474000' }, 'the time is not whole seconds'],
    [{ ...down, until: down.at }, 'it does not hold beyond its own time'],
    [{ ...down, since: undefined }, 'since when is not whole seconds'],
    [{ ...down, since: -1 }, 'since when is not whole seconds'],
    [{ ...down, since: 1791452400.5 }, 'since when is not whole seconds'],
    [{ ...down, since: '1791452400' }, 'since when is not whole seconds'],
    [{ ...down, since: 0 }, 'down is since a time no later than its own'],
    [{ ...down, since: down.at + 1 }, 'down is since a time no later than its own'],
    [{ ...up, since: up.at }, 'up has no since'],
    [{ ...down, key: 'K1' }, 'the name of the key is not a short word'],
    [{ ...down, key: 'k1\nup' }, 'the name of the key is not a short word'],
    [null, 'not a statement'],
  ]) {
    assert.equal(fieldProblem(bad), why);
    assert.throws(() => canonical(bad), /cannot be signed/);
  }
  assert.equal(fieldProblem(down), null);
  assert.equal(fieldProblem(up), null);
  assert.equal(fieldProblem(justDown), null);
});

test('the vectors both sides are held to are what this side signs', async () => {
  const { signing, publicRaw } = await testKey();
  const made = {
    about: 'Statements of the ZestSSH status service, signed with a key whose seed is the bytes 1 to 32. Written by test/statement.test.mjs (UPDATE_VECTORS=1); read by the Worker\'s tests and by the app\'s.',
    domain: DOMAIN,
    publicKey: publicRaw,
    statements: [
      { canonical: canonical(down), signed: await sign(down, signing) },
      { canonical: canonical(up), signed: await sign(up, signing) },
      { canonical: canonical(justDown), signed: await sign(justDown, signing) },
    ],
  };
  if (process.env.UPDATE_VECTORS === '1') {
    writeFileSync(vectorsPath, `${JSON.stringify(made, null, 2)}\n`);
  }
  const kept = JSON.parse(readFileSync(vectorsPath, 'utf8'));
  assert.deepEqual(kept, made, 'run with UPDATE_VECTORS=1 if the format was changed on purpose');
  // Ed25519 signs the same bytes the same way every time: that is what lets
  // a file of vectors stand in for running one side against the other.
  assert.equal(kept.statements[0].signed.sig.length, 88);
});
