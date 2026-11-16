// The status service itself: what it finds when it asks the API, what it
// answers, since when it says the API has been down, and that it asks and
// keeps no more than it must.
import assert from 'node:assert/strict';
import { test } from 'node:test';

import { fromBase64, importVerifyingKey, pkcs8OfSeed, toBase64, verify } from '../src/statement.js';
import worker, {
  FINDING_SECONDS,
  KEPT_KEY,
  KEPT_SECONDS,
  RETRY_AFTER_MS,
  SAME_OUTAGE_SECONDS,
  STILL_DOWN_EVERY_SECONDS,
  handle,
  healthState,
  look,
  newMemory,
  readKept,
  sinceWhen,
  verdict,
} from '../src/worker.js';

const seed = Uint8Array.from({ length: 32 }, (_, i) => i + 1);

async function publicKeyOfSeed() {
  const exportable = await crypto.subtle.importKey('pkcs8', fromBase64(pkcs8OfSeed(seed)), { name: 'Ed25519' }, true, ['sign']);
  const jwk = await crypto.subtle.exportKey('jwk', exportable);
  return importVerifyingKey(toBase64(Buffer.from(jwk.x, 'base64url')));
}

const env = (more = {}) => ({
  SERVICE: 'api.zestssh.com',
  HEALTH_URL: 'https://api.zestssh.com/v1/health',
  STATUS_KEY_ID: 'k1',
  VALID_SECONDS: '900',
  STATUS_SIGNING_KEY: pkcs8OfSeed(seed),
  ...more,
});

const ok = () => new Response(JSON.stringify({ status: 'ok', service: 'zestssh-api', db: 'ok' }), { status: 200 });
const gone = () => new Response('error code: 530', { status: 530 });
const noWait = async () => {};

/** An API that gives [answers] in turn (a Response, or an Error to throw),
 * the last one for ever after. */
function api(...answers) {
  const calls = [];
  const fetcher = async (url, init) => {
    calls.push({ url, init });
    const answer = answers[Math.min(calls.length - 1, answers.length - 1)];
    if (answer instanceof Error) throw answer;
    return typeof answer === 'function' ? answer() : answer.clone();
  };
  return { fetcher, calls };
}

/** The KV namespace the one line is kept in, as a test holds it. */
function store(line) {
  const map = new Map(line === undefined ? [] : [[KEPT_KEY, typeof line === 'string' ? line : JSON.stringify(line)]]);
  const ops = [];
  let failing = null;
  return {
    ops,
    fail(what) {
      failing = what;
    },
    async get(key) {
      ops.push(['get', key]);
      if (failing === 'get' || failing === 'all') throw new Error('KV unavailable');
      return map.has(key) ? map.get(key) : null;
    },
    async put(key, value, options) {
      ops.push(['put', key, value, options]);
      if (failing === 'put' || failing === 'all') throw new Error('KV unavailable');
      map.set(key, value);
    },
    async delete(key) {
      ops.push(['delete', key]);
      map.delete(key);
    },
    kept() {
      return map.has(KEPT_KEY) ? JSON.parse(map.get(KEPT_KEY)) : null;
    },
    writes() {
      return ops.filter((o) => o[0] !== 'get').length;
    },
  };
}

// Six in the morning of an outage.
const T0 = 1791452400;

test('the API answering its health check with "ok": up, asked once', async () => {
  const { fetcher, calls } = api(ok());
  assert.equal(await healthState('https://api.zestssh.com/v1/health', { fetcher, wait: noWait }), 'up');
  assert.equal(calls.length, 1);
  assert.equal(calls[0].url, 'https://api.zestssh.com/v1/health');
  assert.equal(calls[0].init.method, 'GET');
  assert.equal(calls[0].init.redirect, 'manual', 'a redirect is not followed to somewhere that says ok');
  assert.ok(calls[0].init.signal instanceof AbortSignal, 'it does not wait for ever');
  const sent = Object.keys(calls[0].init.headers).map((h) => h.toLowerCase());
  assert.ok(!sent.includes('authorization') && !sent.includes('cookie'), 'nothing of anyone goes with the question');
});

test('down has to be earned: no answer, a fault, or a health check that says it is not ok, and twice in a row', async () => {
  for (const [name, answer] of [
    ['a fault of its own', new Response('{"error":"Internal server error"}', { status: 500 })],
    ['its database not answering', new Response('{"status":"degraded","db":"down"}', { status: 503 })],
    ['the way to it answering in its place', new Response('<html>Bad gateway</html>', { status: 502 })],
    ['an origin that cannot be reached', gone()],
    ['the last of the faults', new Response('', { status: 599 })],
    ['200 saying it is not ok', new Response('{"status":"degraded"}', { status: 200 })],
    ['no answer', new TypeError('fetch failed')],
    ['no answer in time', new DOMException('The operation was aborted due to timeout', 'TimeoutError')],
  ]) {
    const { fetcher, calls } = api(answer);
    const waited = [];
    const state = await healthState('https://api.zestssh.com/v1/health', { fetcher, wait: async (ms) => waited.push(ms) });
    assert.equal(state, 'down', name);
    assert.equal(calls.length, 2, `${name}: one failed request is not an outage`);
    assert.deepEqual(waited, [RETRY_AFTER_MS], name);
  }
});

test('whatever else answers shows that something serves there: it is not an outage, and is not signed as one', async () => {
  for (const [name, answer] of [
    // What the API says to a caller it is throttling. The question this
    // service asks can be counted against whoever asked it, so somebody who
    // got themselves throttled must not get a "down" out of it.
    ['too many requests', new Response('{"error":"Too many requests. Try again in a minute."}', { status: 429 })],
    ['a refusal', new Response('error code: 1020', { status: 403 })],
    ['not found (the address is set wrong)', new Response('{"error":"Not found"}', { status: 404 })],
    ['a sign-in asked for', new Response('', { status: 401 })],
    ['a redirect', new Response('', { status: 302, headers: { location: 'https://elsewhere.example/' } })],
    ['200 with something that is not its answer', new Response('<html>Sign in to this network</html>', { status: 200 })],
    ['200 with an answer that is no object', new Response('"degraded"', { status: 200 })],
    ['200 with a list', new Response('[{"status":"degraded"}]', { status: 200 })],
    ['200 with nothing said of how it is', new Response('{}', { status: 200 })],
    ['200 with a status that is no word', new Response('{"status":503}', { status: 200 })],
  ]) {
    const { fetcher, calls } = api(answer);
    assert.equal(await healthState('https://api.zestssh.com/v1/health', { fetcher, wait: noWait }), 'up', name);
    assert.equal(calls.length, 1, name);
  }
  assert.equal(verdict(499, null), 'up');
  assert.equal(verdict(500, null), 'down');
  assert.equal(verdict(599, null), 'down');
  assert.equal(verdict(600, null), 'up');
  assert.equal(verdict(200, { status: 'ok' }), 'up');
  assert.equal(verdict(200, { status: 'degraded' }), 'down');
  assert.equal(verdict(404, { status: 'degraded' }), 'up', 'only its own answer is read for what it says');

  // And through the Worker: throttled, it says "up", signed.
  const throttled = api(new Response('{"error":"Too many requests. Try again in a minute."}', { status: 429 }));
  const statement = await (await handle(new Request('https://status.zestssh.com/v1/now'), env({ STATUS_KV: store() }), {
    mem: newMemory(),
    now: () => T0 * 1000,
    fetcher: throttled.fetcher,
    wait: noWait,
  })).json();
  assert.equal(statement.state, 'up');
  assert.equal(statement.since, 0);
  assert.equal(await verify(statement, await publicKeyOfSeed()), true);
});

test('one request that fails and a second that answers: up', async () => {
  const { fetcher, calls } = api(new TypeError('fetch failed'), ok());
  assert.equal(await healthState('https://api.zestssh.com/v1/health', { fetcher, wait: noWait }), 'up');
  assert.equal(calls.length, 2);
});

test('GET /v1/now: a statement about the API, signed, that checks out and may be believed for a quarter of an hour', async () => {
  const { fetcher } = api(ok());
  const now = () => 1791474000_500;
  const response = await handle(new Request('https://status.zestssh.com/v1/now'), env(), { mem: newMemory(), now, fetcher, wait: noWait });
  assert.equal(response.status, 200);
  assert.match(response.headers.get('content-type'), /^application\/json/);
  assert.equal(response.headers.get('cache-control'), 'no-store');
  const statement = await response.json();
  assert.deepEqual(Object.keys(statement), ['v', 'service', 'state', 'at', 'until', 'since', 'key', 'sig']);
  assert.equal(statement.v, 1);
  assert.equal(statement.service, 'api.zestssh.com');
  assert.equal(statement.state, 'up');
  assert.equal(statement.at, 1791474000);
  assert.equal(statement.until - statement.at, 900);
  assert.equal(statement.since, 0, 'up has no since');
  assert.equal(statement.key, 'k1');
  assert.equal(await verify(statement, await publicKeyOfSeed()), true);
});

test('the API down: the statement says so and since when, signed the same way', async () => {
  const { fetcher } = api(gone());
  const kv = store();
  const first = await (await handle(new Request('https://status.zestssh.com/v1/now'), env({ STATUS_KV: kv }), {
    mem: newMemory(),
    now: () => T0 * 1000,
    fetcher,
    wait: noWait,
  })).json();
  assert.equal(first.state, 'down');
  assert.equal(first.since, T0, 'found down this moment: since now');
  assert.equal(await verify(first, await publicKeyOfSeed()), true);
  // Six hours on, wherever Cloudflare happens to run it by then.
  const later = await (await handle(new Request('https://status.zestssh.com/v1/now'), env({ STATUS_KV: kv }), {
    mem: newMemory(),
    now: () => (T0 + 21600) * 1000,
    fetcher,
    wait: noWait,
  })).json();
  assert.equal(later.state, 'down');
  assert.equal(later.at, T0 + 21600);
  // (Nothing looked in between in this test, so it is a new outage to it.)
  assert.equal(later.since, T0 + 21600);
  assert.equal(await verify(later, await publicKeyOfSeed()), true);
});

test('a statement is of the moment the answer was in, not of the moment the question was put', async () => {
  let clock = T0 * 1000;
  const slow = async () => {
    clock += 4000;
    return ok();
  };
  const statement = await (await handle(new Request('https://status.zestssh.com/v1/now'), env(), {
    mem: newMemory(),
    now: () => clock,
    fetcher: slow,
    wait: noWait,
  })).json();
  assert.equal(statement.at, T0 + 4);
  assert.equal(statement.until, T0 + 4 + 900);
});

test('however many ask, the API is asked at most once in half a minute', async () => {
  const { fetcher, calls } = api(ok());
  const mem = newMemory();
  let clock = 1791474000_000;
  const ask = () => handle(new Request('https://status.zestssh.com/v1/now'), env(), { mem, now: () => clock, fetcher, wait: noWait });
  const first = await (await ask()).json();
  // Many at once, and more over the next seconds.
  await Promise.all(Array.from({ length: 20 }, ask));
  clock += (FINDING_SECONDS - 1) * 1000;
  const later = await (await ask()).json();
  assert.equal(calls.length, 1);
  assert.deepEqual(later, first, 'the same finding, with the time it was found');
  // Half a minute on, it is asked again.
  clock += 1000;
  const again = await (await ask()).json();
  assert.equal(calls.length, 2);
  assert.equal(again.at, first.at + FINDING_SECONDS);
});

test('many asking while the first question is still out share that one question', async () => {
  let release;
  const held = new Promise((resolve) => (release = resolve));
  const calls = [];
  const fetcher = async (url) => {
    calls.push(url);
    await held;
    return ok();
  };
  const mem = newMemory();
  const asked = Array.from({ length: 10 }, () =>
    handle(new Request('https://status.zestssh.com/v1/now'), env(), { mem, now: () => 1791474000_000, fetcher, wait: noWait }));
  await new Promise((resolve) => setTimeout(resolve, 20));
  release();
  const statements = await Promise.all(asked.map(async (r) => (await r).json()));
  assert.equal(calls.length, 1);
  assert.equal(new Set(statements.map((s) => s.sig)).size, 1);
});

test('a finding from the future (the clock was set back) is not kept', async () => {
  const { fetcher, calls } = api(ok());
  const mem = newMemory();
  let clock = 1791474000_000;
  const ask = () => handle(new Request('https://status.zestssh.com/v1/now'), env(), { mem, now: () => clock, fetcher, wait: noWait });
  await ask();
  clock -= 3600_000;
  const statement = await (await ask()).json();
  assert.equal(calls.length, 2);
  assert.equal(statement.at, 1791474000 - 3600);
});

test('how long a statement may be believed is the setting, within what makes sense', async () => {
  for (const [setting, expected] of [['900', 900], ['60', 60], ['3600', 3600], ['30', 900], ['86400', 900], ['soon', 900], [undefined, 900]]) {
    const { fetcher } = api(ok());
    const response = await handle(new Request('https://status.zestssh.com/v1/now'), { ...env(), VALID_SECONDS: setting }, {
      mem: newMemory(),
      now: () => 1791474000_000,
      fetcher,
      wait: noWait,
    });
    const statement = await response.json();
    assert.equal(statement.until - statement.at, expected, String(setting));
  }
});

test('not set up: it says that it cannot answer, and says nothing unsigned about the API', async () => {
  for (const broken of [
    { ...env(), STATUS_SIGNING_KEY: undefined },
    { ...env(), STATUS_SIGNING_KEY: '  ' },
    { ...env(), STATUS_SIGNING_KEY: 'bm90IGEga2V5' },
    { ...env(), SERVICE: undefined },
    { ...env(), STATUS_KEY_ID: 'Key One' },
  ]) {
    const { fetcher } = api(ok());
    const response = await handle(new Request('https://status.zestssh.com/v1/now'), broken, { mem: newMemory(), fetcher, wait: noWait });
    assert.equal(response.status, 500);
    const body = await response.json();
    assert.equal(body.error, 'the status service is not set up');
    if (typeof broken.STATUS_SIGNING_KEY !== 'string' || broken.STATUS_SIGNING_KEY.trim() === '') {
      assert.equal(body.detail, 'no signing key is set', 'and says which setting is missing');
    }
    assert.equal(body.state, undefined);
    assert.equal(body.sig, undefined);
    assert.ok(!JSON.stringify(body).includes(env().STATUS_SIGNING_KEY), 'the key is never part of an answer');
  }
});

test('a key that is changed is the one that signs from then on', async () => {
  const { fetcher } = api(ok());
  const mem = newMemory();
  let clock = 1791474000_000;
  const other = Uint8Array.from({ length: 32 }, (_, i) => 200 - i);
  const first = await (await handle(new Request('https://status.zestssh.com/v1/now'), env(), { mem, now: () => clock, fetcher, wait: noWait })).json();
  clock += 60_000;
  const second = await (await handle(new Request('https://status.zestssh.com/v1/now'),
    { ...env(), STATUS_SIGNING_KEY: pkcs8OfSeed(other), STATUS_KEY_ID: 'k2' }, { mem, now: () => clock, fetcher, wait: noWait })).json();
  const k1 = await publicKeyOfSeed();
  assert.equal(await verify(first, k1), true);
  assert.equal(second.key, 'k2');
  assert.equal(await verify(second, k1), false);
});

test('everything else it is asked: a line of text at the root, and no for the rest', async () => {
  const options = { mem: newMemory(), fetcher: api(ok()).fetcher, wait: noWait };
  const root = await handle(new Request('https://status.zestssh.com/'), env(), options);
  assert.equal(root.status, 200);
  assert.match(await root.text(), /ZestSSH status service/);
  assert.equal((await handle(new Request('https://status.zestssh.com/v1/then'), env(), options)).status, 404);
  assert.equal((await handle(new Request('https://status.zestssh.com/v1/now/'), env(), options)).status, 404);
  const post = await handle(new Request('https://status.zestssh.com/v1/now', { method: 'POST', body: '{}' }), env(), options);
  assert.equal(post.status, 405);
  assert.equal(post.headers.get('allow'), 'GET, HEAD');
  const head = await handle(new Request('https://status.zestssh.com/v1/now', { method: 'HEAD' }), env(), options);
  assert.equal(head.status, 200);
  assert.equal(await head.text(), '');
});

// ── Since when ──────────────────────────────────────────────────────────

test('found down for the first time: since is that moment, and it is kept', async () => {
  const kv = store();
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0), T0);
  assert.deepEqual(kv.kept(), { since: T0, seen: T0, after: 0 });
  const put = kv.ops.find((o) => o[0] === 'put');
  assert.equal(put[1], KEPT_KEY);
  assert.deepEqual(put[3], { expirationTtl: KEPT_SECONDS }, 'it runs out by itself if nothing writes it again');
});

test('found down again by an instance that never saw it: since is what was kept, and it is not written at every finding', async () => {
  const kv = store();
  await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 60), T0);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + STILL_DOWN_EVERY_SECONDS - 1), T0);
  assert.equal(kv.writes(), 1);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + STILL_DOWN_EVERY_SECONDS), T0);
  assert.equal(kv.writes(), 2, 'still down, said once in five minutes');
  assert.deepEqual(kv.kept(), { since: T0, seen: T0 + STILL_DOWN_EVERY_SECONDS, after: 0 });
});

test('an outage of six hours, looked at every minute by whichever instance: since stays, 73 writes', async () => {
  const kv = store();
  for (let minute = 0; minute <= 360; minute++) {
    assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 60 * minute), T0, `minute ${minute}`);
  }
  assert.equal(kv.writes(), 73, 'a free KV namespace takes a thousand a day');
});

test('a gap nobody looked into: since starts again after it', async () => {
  const line = { since: T0, seen: T0 + 600, after: 0 };
  assert.equal(await sinceWhen({ STATUS_KV: store(line) }, newMemory(), 'down', T0 + 600 + SAME_OUTAGE_SECONDS), T0);
  const kv = store(line);
  const at = T0 + 600 + SAME_OUTAGE_SECONDS + 1;
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', at), at, 'nobody knows what was in between');
  assert.deepEqual(kv.kept(), { since: at, seen: at, after: 0 });
  // The same goes for an instance's own memory.
  const mem = newMemory();
  assert.equal(await sinceWhen({}, mem, 'down', T0), T0);
  assert.equal(await sinceWhen({}, mem, 'down', T0 + SAME_OUTAGE_SECONDS), T0);
  assert.equal(await sinceWhen({}, mem, 'down', T0 + 2 * SAME_OUTAGE_SECONDS + 1), T0 + 2 * SAME_OUTAGE_SECONDS + 1);
});

test('an instance asked every ten minutes keeps since for as long as it is asked', async () => {
  for (const env of [{}, { STATUS_KV: store() }]) {
    const mem = newMemory();
    for (let tenth = 0; tenth <= 12; tenth++) {
      assert.equal(await sinceWhen(env, mem, 'down', T0 + 600 * tenth), T0, `after ${tenth * 10} minutes`);
    }
  }
});

test('found up: nothing is written while nothing was down, and coming back is said once', async () => {
  const kv = store();
  for (let minute = 0; minute < 10; minute++) {
    assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'up', T0 + 60 * minute), 0);
  }
  assert.equal(kv.writes(), 0);
  await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 600);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'up', T0 + 720), 0);
  assert.deepEqual(kv.kept(), { up: T0 + 720 });
  assert.equal(kv.writes(), 2);
  assert.deepEqual(kv.ops.filter((o) => o[0] === 'put')[1][3], { expirationTtl: KEPT_SECONDS }, 'it runs out by itself too');
  await sinceWhen({ STATUS_KV: kv }, newMemory(), 'up', T0 + 780);
  await sinceWhen({ STATUS_KV: kv }, newMemory(), 'up', T0 + 840);
  assert.equal(kv.writes(), 2, 'up, and up again, is no news');
});

test('an outage that ended and one that began after it are two, also for an instance that slept through the up', async () => {
  const kv = store();
  const sleeper = newMemory();
  assert.equal(await sinceWhen({ STATUS_KV: kv }, sleeper, 'down', T0), T0);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, sleeper, 'down', T0 + 60), T0);
  // Another instance (the cron's) finds it up; the sleeper is not asked.
  await sinceWhen({ STATUS_KV: kv }, newMemory(), 'up', T0 + 120);
  // Down again. The sleeper last saw it down four minutes ago, which would
  // be the same outage, had it not been up in between.
  assert.equal(await sinceWhen({ STATUS_KV: kv }, sleeper, 'down', T0 + 300), T0 + 300);
  assert.deepEqual(kv.kept(), { since: T0 + 300, seen: T0 + 300, after: T0 + 120 });

  // The same when a third instance says "down again" first: what it wrote
  // carries the time it was last up, so the sleeper's older memory loses.
  const kv2 = store();
  const sleeper2 = newMemory();
  await sinceWhen({ STATUS_KV: kv2 }, sleeper2, 'down', T0);
  await sinceWhen({ STATUS_KV: kv2 }, newMemory(), 'up', T0 + 120);
  assert.equal(await sinceWhen({ STATUS_KV: kv2 }, newMemory(), 'down', T0 + 300), T0 + 300);
  assert.equal(await sinceWhen({ STATUS_KV: kv2 }, sleeper2, 'down', T0 + 360), T0 + 300);
  assert.deepEqual(kv2.kept(), { since: T0 + 300, seen: T0 + 300, after: T0 + 120 }, 'and it does not write its older start back');

  // And an instance that itself found it up never says an earlier since,
  // whatever line is kept.
  const awake = newMemory();
  await sinceWhen({}, awake, 'up', T0 + 120);
  const stale = store({ since: T0, seen: T0 + 200, after: 0 });
  assert.equal(await sinceWhen({ STATUS_KV: stale }, awake, 'down', T0 + 300), T0 + 300);
  assert.deepEqual(stale.kept(), { since: T0 + 300, seen: T0 + 300, after: T0 + 120 });
});

test('found up and found down within the same second: since holds from then on', async () => {
  const kv = store();
  const mem = newMemory();
  await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0 - 600);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'up', T0), 0);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0), T0);
  assert.deepEqual(kv.kept(), { since: T0, seen: T0, after: T0 });
  assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0 + 60), T0, 'by the instance that saw both');
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 120), T0, 'and by one that saw neither');
  // Without the store, too.
  const alone = newMemory();
  await sinceWhen({}, alone, 'up', T0);
  assert.equal(await sinceWhen({}, alone, 'down', T0), T0);
  assert.equal(await sinceWhen({}, alone, 'down', T0 + 60), T0);
});

test('one instance that sees it go down, come back and stay up writes twice in all', async () => {
  const kv = store();
  const mem = newMemory();
  await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0);
  for (let minute = 1; minute <= 30; minute++) {
    assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'up', T0 + 60 * minute), 0);
  }
  assert.equal(kv.writes(), 2, 'that it went down, and that it came back');
  assert.deepEqual(kv.kept(), { up: T0 + 60 });
});

test('whoever noticed the outage first is believed over one that noticed later', async () => {
  const kv = store();
  const first = newMemory();
  // The store could not be reached when the first one noticed.
  kv.fail('all');
  assert.equal(await sinceWhen({ STATUS_KV: kv }, first, 'down', T0), T0);
  assert.equal(kv.kept(), null);
  kv.fail(null);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 30), T0 + 30);
  assert.equal(await sinceWhen({ STATUS_KV: kv }, first, 'down', T0 + 60), T0);
  assert.deepEqual(kv.kept(), { since: T0, seen: T0 + 60, after: 0 }, 'and from then on everybody says so');
  assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0 + 90), T0);
});

test('the keeping failing never stops a statement: it says what this instance knows', async () => {
  for (const what of ['get', 'put', 'all']) {
    const kv = store({ since: T0 - 3600, seen: T0 - 30, after: 0 });
    kv.fail(what);
    const mem = newMemory();
    const expected = what === 'put' ? T0 - 3600 : T0;
    assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0), expected, what);
    assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'down', T0 + 400), expected, what);
    assert.equal(await sinceWhen({ STATUS_KV: kv }, mem, 'up', T0 + 460), 0, what);
    // An instance that saw the outage says that it is over, also when it
    // could not read what the others kept.
    if (what === 'get') assert.deepEqual(kv.kept(), { up: T0 + 460 });
  }
  // Through the Worker: a statement all the same.
  const kv = store();
  kv.fail('all');
  const { fetcher } = api(gone());
  const response = await handle(new Request('https://status.zestssh.com/v1/now'), env({ STATUS_KV: kv }), {
    mem: newMemory(),
    now: () => T0 * 1000,
    fetcher,
    wait: noWait,
  });
  assert.equal(response.status, 200);
  const statement = await response.json();
  assert.equal(statement.since, T0);
  assert.equal(await verify(statement, await publicKeyOfSeed()), true);
});

test('a kept line that says nothing usable is passed over', async () => {
  for (const line of [
    'not json',
    '[]',
    'null',
    '"down"',
    '{}',
    '{"since":"1791452400","seen":1791452460}',
    '{"since":1791452460,"seen":1791452400}',
    '{"since":0,"seen":1791452400}',
    '{"since":1791452400.5,"seen":1791452460}',
    '{"since":1791452400}',
    '{"since":1791452340,"seen":1791452380,"after":1791452341}',
    '{"up":0}',
    '{"up":"1791452000"}',
  ]) {
    assert.equal(readKept(line), null, line);
    const kv = store(line);
    assert.equal(await sinceWhen({ STATUS_KV: kv }, newMemory(), 'down', T0), T0, line);
    assert.deepEqual(kv.kept(), { since: T0, seen: T0, after: 0 }, line);
  }
  assert.equal(readKept(null), null);
  assert.equal(readKept(undefined), null);
  assert.deepEqual(readKept('{"since":5,"seen":9}'), { since: 5, seen: 9, after: 0 });
  assert.deepEqual(readKept('{"since":5,"seen":9,"after":4}'), { since: 5, seen: 9, after: 4 });
  assert.deepEqual(readKept('{"since":5,"seen":9,"after":5}'), { since: 5, seen: 9, after: 5 }, 'up, and down within the second');
  assert.deepEqual(readKept('{"since":5,"seen":5}'), { since: 5, seen: 5, after: 0 });
  assert.deepEqual(readKept('{"up":7}'), { up: 7 });
});

test('without the store: this instance\'s own memory, which says less', async () => {
  const mem = newMemory();
  assert.equal(await sinceWhen({}, mem, 'down', T0), T0);
  assert.equal(await sinceWhen({}, mem, 'down', T0 + 60), T0);
  assert.equal(await sinceWhen({}, newMemory(), 'down', T0 + 120), T0 + 120, 'another instance knows only what it saw');
  assert.equal(await sinceWhen({}, mem, 'up', T0 + 200), 0);
  assert.equal(await sinceWhen({}, mem, 'down', T0 + 260), T0 + 260, 'it was up in between');
});

test('clocks that differ a little: still one outage, and since is never later than the finding', async () => {
  // Ten seconds behind the instance that wrote the line.
  assert.equal(await sinceWhen({ STATUS_KV: store({ since: T0, seen: T0 + 100, after: 0 }) }, newMemory(), 'down', T0 + 90), T0);
  // A line from a start later than this finding's own time.
  assert.equal(await sinceWhen({ STATUS_KV: store({ since: T0 + 50, seen: T0 + 100, after: 0 }) }, newMemory(), 'down', T0 + 40), T0 + 40);
  // A line from further ahead than any honest clock is: not this outage,
  // whatever start it names.
  const far = store({ since: T0 + 5000, seen: T0 + 5000, after: 0 });
  assert.equal(await sinceWhen({ STATUS_KV: far }, newMemory(), 'down', T0), T0);
  const farBack = store({ since: T0 - 100, seen: T0 + 5000, after: 0 });
  assert.equal(await sinceWhen({ STATUS_KV: farBack }, newMemory(), 'down', T0), T0);
  // Found up "later" than this finding by a clock that is ahead: since is
  // the finding's own time, and what is kept is still a line that can be read.
  const ahead = store({ up: T0 + 20 });
  assert.equal(await sinceWhen({ STATUS_KV: ahead }, newMemory(), 'down', T0), T0);
  assert.deepEqual(ahead.kept(), { since: T0, seen: T0, after: T0 });
  assert.deepEqual(readKept(JSON.stringify(ahead.kept())), { since: T0, seen: T0, after: T0 });
});

// ── The cron trigger ────────────────────────────────────────────────────

test('every minute it looks, so that an outage counts from when it began and not from when somebody asked', async () => {
  const kv = store();
  const down = api(gone());
  // Nobody asks for a statement for two hours; the cron looks every minute.
  for (let minute = 0; minute < 120; minute++) {
    const found = await look(env({ STATUS_KV: kv }), { mem: newMemory(), now: () => (T0 + 60 * minute) * 1000, fetcher: down.fetcher, wait: noWait });
    assert.deepEqual(found, { state: 'down', at: T0 + 60 * minute, since: T0 });
  }
  // Then a device asks.
  const statement = await (await handle(new Request('https://status.zestssh.com/v1/now'), env({ STATUS_KV: kv }), {
    mem: newMemory(),
    now: () => (T0 + 7200) * 1000,
    fetcher: down.fetcher,
    wait: noWait,
  })).json();
  assert.equal(statement.state, 'down');
  assert.equal(statement.since, T0, 'two hours, though this is the first time anybody asked');
  assert.equal(await verify(statement, await publicKeyOfSeed()), true);
  // It comes back; the cron sees it; the next outage is another.
  const found = await look(env({ STATUS_KV: kv }), { mem: newMemory(), now: () => (T0 + 7260) * 1000, fetcher: api(ok()).fetcher, wait: noWait });
  assert.deepEqual(found, { state: 'up', at: T0 + 7260, since: 0 });
  assert.deepEqual(kv.kept(), { up: T0 + 7260 });
});

test('looking needs no key and signs nothing', async () => {
  const kv = store();
  const found = await look({ HEALTH_URL: 'https://api.zestssh.com/v1/health', STATUS_KV: kv }, {
    mem: newMemory(),
    now: () => T0 * 1000,
    fetcher: api(gone()).fetcher,
    wait: noWait,
  });
  assert.deepEqual(found, { state: 'down', at: T0, since: T0 });
});

test('what the Worker exports: the request handler, and the cron handler, which never fails its run', async () => {
  assert.equal(typeof worker.fetch, 'function');
  const response = await worker.fetch(new Request('https://status.zestssh.com/'), env());
  assert.equal(response.status, 200);

  assert.equal(typeof worker.scheduled, 'function');
  const waited = [];
  // Settings that cannot even be read: the run still ends well.
  const broken = {
    get HEALTH_URL() {
      throw new Error('no such setting');
    },
  };
  await assert.rejects(look(broken));
  worker.scheduled({ cron: '* * * * *' }, broken, { waitUntil: (p) => waited.push(p) });
  assert.equal(waited.length, 1);
  await assert.doesNotReject(waited[0]);
});
