// The statement the ZestSSH status service signs: whether the ZestSSH Cloud
// API answered when it was asked, since when it has not, and until when the
// statement may be believed.
//
// Shared by the Worker and by its tests, and written to run wherever Web
// Crypto has Ed25519 (Cloudflare Workers, Node 20 and later). The app reads
// the same bytes (lib/services/cloud/cloud_statement.dart); the two are held
// together by the vectors in test/vectors.json, which both sides check.

/** What goes first in the bytes that are signed, so that a signature made
 * here can never be taken for one made for anything else. */
export const DOMAIN = 'zestssh.status.v1';

/** The two things a statement can say. */
export const STATES = ['up', 'down'];

const SERVICE = /^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?$/;
const KEY_ID = /^[a-z0-9]{1,16}$/;

/**
 * What is wrong with a statement's fields, or null when nothing is: the
 * service a host name, the state one of the two, the times whole seconds
 * with the end after the start, the key's name a short word. "Down" says
 * since when (a time no later than its own); "up" has no since (0).
 */
export function fieldProblem(s) {
  if (s === null || typeof s !== 'object') return 'not a statement';
  if (s.v !== 1) return 'not version 1';
  if (typeof s.service !== 'string' || !SERVICE.test(s.service)) return 'the service is not a host name';
  if (!STATES.includes(s.state)) return 'the state is neither up nor down';
  if (!Number.isSafeInteger(s.at) || s.at <= 0) return 'the time is not whole seconds';
  if (!Number.isSafeInteger(s.until) || s.until <= s.at) return 'it does not hold beyond its own time';
  if (!Number.isSafeInteger(s.since) || s.since < 0) return 'since when is not whole seconds';
  if (s.state === 'up' && s.since !== 0) return 'up has no since';
  if (s.state === 'down' && (s.since === 0 || s.since > s.at)) return 'down is since a time no later than its own';
  if (typeof s.key !== 'string' || !KEY_ID.test(s.key)) return 'the name of the key is not a short word';
  return null;
}

/** The text that is signed: the fields, one to a line, after [DOMAIN]. */
export function canonical(s) {
  const problem = fieldProblem(s);
  if (problem !== null) throw new Error(`A statement that cannot be signed: ${problem}`);
  return [DOMAIN, s.service, s.state, String(s.at), String(s.until), String(s.since), s.key].join('\n');
}

export function toBase64(bytes) {
  let binary = '';
  for (const b of new Uint8Array(bytes)) binary += String.fromCharCode(b);
  return btoa(binary);
}

export function fromBase64(text) {
  const binary = atob(text);
  const out = new Uint8Array(binary.length);
  for (let i = 0; i < binary.length; i++) out[i] = binary.charCodeAt(i);
  return out;
}

/** The private key as Web Crypto holds it, from its PKCS#8 form in base64
 * (what tool/make_keys.mjs prints, and what the Worker's secret holds). */
export function importSigningKey(pkcs8Base64) {
  return crypto.subtle.importKey('pkcs8', fromBase64(pkcs8Base64.trim()), { name: 'Ed25519' }, false, ['sign']);
}

/** The public key, from its 32 bytes in base64 (what the app is given). */
export function importVerifyingKey(rawBase64) {
  return crypto.subtle.importKey('raw', fromBase64(rawBase64.trim()), { name: 'Ed25519' }, false, ['verify']);
}

/** [statement] with its signature under [signingKey]. */
export async function sign(statement, signingKey) {
  const bytes = new TextEncoder().encode(canonical(statement));
  const signature = await crypto.subtle.sign({ name: 'Ed25519' }, signingKey, bytes);
  const { v, service, state, at, until, since, key } = statement;
  return { v, service, state, at, until, since, key, sig: toBase64(signature) };
}

/** Whether [signed] is a well formed statement signed by [verifyingKey]. */
export async function verify(signed, verifyingKey) {
  if (fieldProblem(signed) !== null || typeof signed.sig !== 'string') return false;
  let signature;
  try {
    signature = fromBase64(signed.sig);
  } catch (_) {
    return false;
  }
  const bytes = new TextEncoder().encode(canonical(signed));
  return crypto.subtle.verify({ name: 'Ed25519' }, verifyingKey, signature, bytes);
}

// A private Ed25519 key in PKCS#8 is these sixteen bytes and then its seed.
const PKCS8_PREFIX = [0x30, 0x2e, 0x02, 0x01, 0x00, 0x30, 0x05, 0x06, 0x03, 0x2b, 0x65, 0x70, 0x04, 0x22, 0x04, 0x20];

/** The PKCS#8 form, in base64, of the private key whose seed is [seed]
 * (32 bytes). For tests, which need the same key every time. */
export function pkcs8OfSeed(seed) {
  if (seed.length !== 32) throw new Error('A seed is 32 bytes');
  return toBase64(new Uint8Array([...PKCS8_PREFIX, ...seed]));
}
