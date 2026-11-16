// The ZestSSH status service: one small Cloudflare Worker that says, signed,
// whether the ZestSSH Cloud API answers, and since when it has not.
//
// Why it exists. The app works without ZestSSH Cloud, but what goes through
// it waits while it cannot be reached, and from inside one device a service
// that is down, a network that blocks it and a device with no internet all
// look the same. This service looks from somewhere else. The app asks it
// only after its own request to the API got no answer, and learns which of
// the three it is. And because the answer is signed with a key the app
// knows, a "down" is proof of an outage: an Orchard's offline limit does not
// count the time we were down against a device.
//
// What it is not. It knows nothing about anyone: it is told nothing about
// whoever asks and keeps no log of them. The one thing it keeps is a single
// line about the API (since when it has been down), and that only while it
// is down.
//
//   GET /v1/now   {"v":1,"service":"api.zestssh.com","state":"up"|"down",
//                  "at":<seconds>,"until":<seconds>,"since":<seconds, 0 when up>,
//                  "key":"k1","sig":"<base64>"}
//
// Settings (wrangler.toml):
//   SERVICE             the host the statement is about      api.zestssh.com
//   HEALTH_URL          what is asked                        https://api.zestssh.com/v1/health
//   STATUS_KEY_ID       the name of the key that signs       k1
//   VALID_SECONDS       how long a statement may be believed 900
//   STATUS_SIGNING_KEY  (secret) the private key, PKCS#8 in base64, from tool/make_keys.mjs
//   STATUS_KV           (KV namespace) where the start of an outage is kept
//   a cron trigger      every minute, so that an outage is noticed when it
//                       starts and not when somebody first asks

import { importSigningKey, sign } from './statement.js';

/** How long the API is given to answer one question. */
export const CHECK_TIMEOUT_MS = 5000;

/** How long after a question that got no good answer it is asked once more:
 * one failed request is not an outage. */
export const RETRY_AFTER_MS = 1500;

/** How long a finding is good for before the API is asked again. */
export const FINDING_SECONDS = 30;

/** The name the one line that is kept is kept under. */
export const KEPT_KEY = 'down';

/** Two findings of "down" no further apart than this are one outage. Further
 * apart, nothing is known of the time between them, and the outage counts
 * from the later one: "since" is never claimed across a gap nobody looked
 * into. (With the cron trigger there is a finding every minute.) */
export const SAME_OUTAGE_SECONDS = 15 * 60;

/** How often, while an outage lasts, the kept line is written again to say
 * "still down" (not at every finding: a free KV namespace takes a thousand
 * writes a day). */
export const STILL_DOWN_EVERY_SECONDS = 5 * 60;

/** How long the kept line stays when it is not written again. */
export const KEPT_SECONDS = 24 * 3600;

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

/**
 * What one answer of the health check says of the API: "down" for a fault
 * (HTTP 500 to 599: its own, or the way to it saying it cannot be reached)
 * and for a health check that itself says it is not ok; "up" for everything
 * else that answers.
 *
 * "Down" has to be earned, because a signed "down" holds a team's offline
 * limit open. A redirect, a refusal, "too many requests" (which the API
 * says to a caller it is throttling, and the question may be counted
 * against whoever asked this service), an answer that is not the API's at
 * all: each shows that something is serving at the address, none shows an
 * outage, and none is taken for one.
 */
export function verdict(status, body) {
  if (status >= 500 && status <= 599) return 'down';
  if (status === 200 && body !== null && typeof body === 'object') {
    if (typeof body.status === 'string' && body.status !== 'ok') return 'down';
  }
  return 'up';
}

/**
 * Whether the API answers: "down" when its health check gets no answer (in
 * time, or at all) or an answer that says so ([verdict]), asked a second
 * time before "down" is said: one failed request is not an outage.
 */
export async function healthState(healthUrl, { fetcher = fetch, wait = sleep } = {}) {
  for (let attempt = 0; attempt < 2; attempt++) {
    if (attempt > 0) await wait(RETRY_AFTER_MS);
    try {
      const response = await fetcher(healthUrl, {
        method: 'GET',
        redirect: 'manual',
        signal: AbortSignal.timeout(CHECK_TIMEOUT_MS),
        headers: { 'user-agent': 'zestssh-status', accept: 'application/json' },
      });
      const body = response.status === 200 ? await response.json().catch(() => null) : null;
      if (verdict(response.status, body) === 'up') return 'up';
    } catch (_) {
      // No answer: asked once more, then it is down.
    }
  }
  return 'down';
}

/** One Worker's memory, for as long as Cloudflare keeps it: the key once it
 * is read, the last statement, the question that is under way, the outage
 * as this instance has seen it, and when it last found the API up. A test
 * makes its own. */
export function newMemory() {
  return { keyText: null, key: null, last: null, asking: null, down: null, upAt: 0 };
}

const memory = newMemory();

const wholeSeconds = (n) => Number.isSafeInteger(n) && n > 0;

/**
 * The kept line as what it says, or null when it says nothing that can be
 * used. It is one of two things:
 *
 *   {"since":S,"seen":T,"after":U}   down since S, last found down at T, and
 *                                    last known up at U (0: never seen up)
 *   {"up":U}                         found up at U, after it had been down
 */
export function readKept(text) {
  if (typeof text !== 'string') return null;
  let value;
  try {
    value = JSON.parse(text);
  } catch (_) {
    return null;
  }
  if (value === null) return null;
  if (wholeSeconds(value.up)) return { up: value.up };
  const { since, seen } = value;
  if (!wholeSeconds(since) || !wholeSeconds(seen) || seen < since) return null;
  const after = wholeSeconds(value.after) ? value.after : 0;
  if (after > since) return null;
  return { since, seen, after };
}

/** Whether [outage] (a kept line that says "down", or this instance's
 * memory of one; null for none) is the outage a finding of "down" at [at]
 * belongs to: last found down no longer ago than [SAME_OUTAGE_SECONDS] (and
 * not from a time further ahead than that, which no honest clock gives). */
export function sameOutage(outage, at) {
  return outage !== null && Math.abs(at - outage.seen) <= SAME_OUTAGE_SECONDS;
}

/**
 * Since when the API has been down, for a finding of [state] at [at], and
 * the keeping of it: 0 for "up".
 *
 * It is kept in two places. This instance's own memory, which is gone when
 * Cloudflare starts another. And the KV namespace STATUS_KV where one is
 * bound, which every instance shares, so that "since" is the same wherever
 * the question lands and outlives all of them.
 *
 * Two rules keep "since" from saying more than anybody knows. It is never
 * carried across a gap nobody looked into ([SAME_OUTAGE_SECONDS]). And it is
 * never earlier than the last time the API was found up, by this instance
 * or, through the kept line, by any other: an outage that ended and one that
 * began after it are two. Whatever goes wrong with the keeping, a statement
 * is still made, with the latest "since" that is certain.
 */
export async function sinceWhen(env, mem, state, at) {
  const kv = env.STATUS_KV;
  // What the others kept: an outage, or the time it was found over, or nothing.
  let keptDown = null;
  let keptUp = 0;
  if (kv) {
    try {
      const line = readKept(await kv.get(KEPT_KEY));
      if (line !== null && line.up !== undefined) keptUp = line.up;
      if (line !== null && line.up === undefined) keptDown = line;
    } catch (_) {
      // Nothing is known of what the others kept.
    }
  }
  if (state === 'up') {
    const wasDown = mem.down !== null || keptDown !== null;
    mem.down = null;
    mem.upAt = at;
    // Said once, when it comes back: the line now says when it was found
    // up, for the instances that did not see it.
    if (kv && wasDown) {
      try {
        await kv.put(KEPT_KEY, JSON.stringify({ up: at }), { expirationTtl: KEPT_SECONDS });
      } catch (_) {
        // Left as it is: it is not believed across a gap, and runs out.
      }
    }
    return 0;
  }
  // The last time anybody is known to have found it up.
  const up = Math.max(mem.upAt, keptUp, keptDown === null ? 0 : keptDown.after);
  // The earliest start anybody saw who is still of this outage.
  let since = at;
  for (const outage of [mem.down, keptDown]) {
    if (sameOutage(outage, at) && outage.since >= up && outage.since < since) since = outage.since;
  }
  mem.down = { since, seen: at };
  if (kv) {
    const current = keptDown !== null && keptDown.since === since && at - keptDown.seen < STILL_DOWN_EVERY_SECONDS;
    if (!current) {
      try {
        const after = Math.min(up, since);
        await kv.put(KEPT_KEY, JSON.stringify({ since, seen: at, after }), { expirationTtl: KEPT_SECONDS });
      } catch (_) {
        // This instance's memory still holds it.
      }
    }
  }
  return since;
}

async function signingKey(env, mem) {
  const text = env.STATUS_SIGNING_KEY;
  if (typeof text !== 'string' || text.trim() === '') throw new Error('no signing key is set');
  if (mem.keyText !== text) {
    mem.key = await importSigningKey(text);
    mem.keyText = text;
  }
  return mem.key;
}

function validSeconds(env) {
  const n = Number.parseInt(env.VALID_SECONDS ?? '900', 10);
  // A statement that may be believed for less than a minute helps nobody,
  // and one for more than an hour would say "down" long after it stopped
  // being so.
  return Number.isFinite(n) && n >= 60 && n <= 3600 ? n : 900;
}

/**
 * The signed statement as it stands now, asking the API when the last
 * finding is older than [FINDING_SECONDS]. Everybody who asks at once shares
 * the one question.
 */
export async function statementNow(env, { mem = memory, now = () => Date.now(), fetcher = fetch, wait = sleep } = {}) {
  const seconds = Math.floor(now() / 1000);
  if (mem.last !== null && seconds - mem.last.at < FINDING_SECONDS && seconds >= mem.last.at) return mem.last;
  mem.asking ??= (async () => {
    try {
      const key = await signingKey(env, mem);
      const state = await healthState(env.HEALTH_URL, { fetcher, wait });
      const at = Math.floor(now() / 1000);
      const since = await sinceWhen(env, mem, state, at);
      mem.last = await sign(
        {
          v: 1,
          service: env.SERVICE,
          state,
          at,
          until: at + validSeconds(env),
          since,
          key: env.STATUS_KEY_ID,
        },
        key,
      );
      return mem.last;
    } finally {
      mem.asking = null;
    }
  })();
  return mem.asking;
}

/**
 * What the cron trigger does, every minute: asks the API and keeps since
 * when it has been down, so that an outage counts from when it started and
 * not from when somebody first asked. It signs nothing and answers nobody.
 */
export async function look(env, { mem = memory, now = () => Date.now(), fetcher = fetch, wait = sleep } = {}) {
  const state = await healthState(env.HEALTH_URL, { fetcher, wait });
  const at = Math.floor(now() / 1000);
  const since = await sinceWhen(env, mem, state, at);
  return { state, at, since };
}

function json(body, status, extra = {}) {
  return new Response(JSON.stringify(body), {
    status,
    headers: {
      'content-type': 'application/json; charset=utf-8',
      'cache-control': 'no-store',
      'x-content-type-options': 'nosniff',
      ...extra,
    },
  });
}

/** The Worker as a function of its request, for the tests and for the
 * default export below. */
export async function handle(request, env, options = {}) {
  const url = new URL(request.url);
  if (request.method !== 'GET' && request.method !== 'HEAD') {
    return json({ error: 'only GET' }, 405, { allow: 'GET, HEAD' });
  }
  if (url.pathname === '/') {
    return new Response('ZestSSH status service. GET /v1/now says, signed, whether the ZestSSH Cloud API answers.\n', {
      status: 200,
      headers: { 'content-type': 'text/plain; charset=utf-8', 'cache-control': 'no-store' },
    });
  }
  if (url.pathname !== '/v1/now') return json({ error: 'not found' }, 404);
  try {
    const statement = await statementNow(env, options);
    if (request.method === 'HEAD') {
      return new Response(null, { status: 200, headers: { 'cache-control': 'no-store' } });
    }
    return json(statement, 200);
  } catch (e) {
    // Nothing unsigned is ever said about the API: whoever asked hears that
    // this service could not answer, and takes it as no answer.
    return json({ error: 'the status service is not set up', detail: String(e && e.message ? e.message : e) }, 500);
  }
}

export default {
  fetch: (request, env) => handle(request, env),
  scheduled: (event, env, ctx) => ctx.waitUntil(look(env).catch(() => {})),
};
